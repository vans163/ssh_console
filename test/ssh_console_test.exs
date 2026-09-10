Code.require_file("ssh_console_helper.exs", __DIR__)

defmodule SSHConsoleTest do
  use ExUnit.Case, async: false
  alias SSHConsole.TestSupport, as: SSH

  @probe SSHConsoleHotloadProbe
  @moduletag capture_log: true

  setup context do
    SSH.fixture(context)
  end

  test "OpenSSH authenticates as the app's OS user and evaluates in the running node", c do
    assert SSH.command!(c, "{1 + 2, System.pid()}") == inspect({3, System.pid()})
  end

  test "interactive shell preserves bindings and disconnects on Ctrl-C", c do
    {output, status} = SSH.shell(c, "x = Enum.sum([\n20,\n20\n])\nx + 2\n", "ssh(3)> ")
    assert status == 0, output
    assert output =~ "ssh(1)>"
    assert output =~ "...(1)>"
    assert output =~ "42"
    assert SSH.command!(c, "1 + 2") == "3"
  end

  test "ordinary expressions and nested module definitions work over SSH", c do
    assert SSH.command!(c, "Enum.sum([1, 2, 3])") == "6"
    output = SSH.command!(c, """
    defmodule SSHConsoleOuterProbe do
      defmodule Inner do
        def value, do: 42
      end
    end
    """)
    assert output =~ "status: :loaded"
    assert output =~ "SSHConsoleOuterProbe.Inner"
    assert SSH.command!(c, "SSHConsoleOuterProbe.Inner.value()") == "42"
  end

  test "queues a third version without killing a server or losing its in-flight tick", c do
    assert SSH.command!(c, source(1)) =~ "status: :loaded"
    pid = start_probe()
    parent = self()
    tick = Task.async(fn -> GenServer.call(pid, {:tick, parent}, 15_000) end)
    assert_receive {:entered, 1, ^pid}

    assert SSH.command!(c, source(2)) =~ "status: :loaded"
    assert SSH.command!(c, "SSHConsoleHotloadProbe.version()") == "2"
    queued = SSH.command!(c, source(3))
    assert queued =~ "status: :queued"
    assert queued =~ inspect(pid)
    assert Process.alive?(pid)

    send(pid, {:finish, :tick_one})
    assert Task.await(tick) == {:finished, 1, :tick_one}
    assert Process.alive?(pid)
    SSH.eventually(fn -> SSH.command!(c, "SSHConsoleHotloadProbe.version()") == "3" end)
    assert GenServer.call(pid, :version) == 3
  end

  test "a successful SSH hotload supersedes an overlapping queued update", c do
    assert SSH.command!(c, source(1)) =~ "status: :loaded"
    pid = start_probe()
    parent = self()
    tick = Task.async(fn -> GenServer.call(pid, {:tick, parent}, 15_000) end)
    assert_receive {:entered, 1, ^pid}

    assert SSH.command!(c, source(2)) =~ "status: :loaded"
    older = source(3) <> "\ndefmodule SSHConsoleLatestProbe do\n  def version, do: 1\nend"
    assert SSH.command!(c, older) =~ "status: :queued"
    assert SSH.command!(c, "defmodule SSHConsoleLatestProbe do\n  def version, do: 2\nend") =~ "status: :loaded"

    send(pid, {:finish, :tick_one})
    assert Task.await(tick) == {:finished, 1, :tick_one}
    # Allow the retry timer to fire before checking that the newer code survives.
    Process.sleep(150)
    assert SSH.command!(c, "{SSHConsoleHotloadProbe.version(), SSHConsoleLatestProbe.version()}") == "{2, 2}"
    assert GenServer.call(pid, :version) == 2
  end

  @tag console_name: nil
  test "SSH commands hotload through an unnamed owning server", c do
    refute Process.whereis(SSHConsole)
    assert SSH.command!(c, source(1)) =~ "status: :loaded"
    assert SSH.command!(c, "SSHConsoleHotloadProbe.version()") == "1"
  end

  test "hotloads a file through the public API over SSH", c do
    path = Path.join(c.root, "probe.ex")
    File.write!(path, source(1))
    command = "SSHConsole.hotload(File.read!(#{inspect(path)}), server: SSHConsoleE2EServer)"
    assert SSH.command!(c, command) =~ "status: :loaded"
    assert SSH.command!(c, "SSHConsoleHotloadProbe.version()") == "1"
  end

  test "syntax and evaluation failures return nonzero SSH exit status", c do
    for {source, message} <- [{"1 +", "TokenMissingError"},
      {"raise \"console probe\"", "console probe"}, {"exit(:console_probe)", "console_probe"}] do
      {output, status} = SSH.command(c, source)
      assert status != 0
      assert output =~ message
    end
    assert SSH.command!(c, "1 + 2") == "3"
  end

  test "the supervisor restores SSH access after the console crashes", c do
    monitor = Process.monitor(c.server)
    {_output, status} = SSH.command(c, "GenServer.call(SSHConsoleE2EServer, :deliberate_test_crash)")
    assert status != 0
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    SSH.eventually(fn ->
      case Process.whereis(SSHConsoleE2EServer) do
        pid when is_pid(pid) and pid != c.server -> true
        _ -> false
      end
    end)
    SSH.eventually(fn ->
      {output, status} = SSH.command(c, "1 + 2")
      status == 0 and String.trim(output) == "3"
    end)
  end

  defp start_probe do
    start_supervised!(%{id: @probe, start: {@probe, :start_link, []}, restart: :temporary})
  end

  defp source(version) do
    """
    defmodule SSHConsoleHotloadProbe do
      use GenServer
      def start_link, do: GenServer.start_link(__MODULE__, nil)
      def version, do: #{version}
      def init(nil), do: {:ok, %{ticks: 0}}

      def handle_call({:tick, parent}, _from, state) do
        send(parent, {:entered, #{version}, self()})
        receive do
          {:finish, tick} -> {:reply, {:finished, #{version}, tick}, %{state | ticks: state.ticks + 1}}
        end
      end

      def handle_call(:version, _from, state), do: {:reply, #{version}, state}
    end
    """
  end
end
