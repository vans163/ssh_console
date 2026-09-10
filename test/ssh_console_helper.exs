defmodule SSHConsole.TestSupport do
  import ExUnit.Assertions

  def fixture(context) do
    root = Path.join(System.tmp_dir!(), "ssh-console-e2e-#{System.pid()}-#{System.unique_integer([:positive])}")
    dir = Path.join(root, "server")
    client = Path.join(root, "client")
    other = Path.join(root, "other")
    auth = Path.join(dir, "authorized_keys")
    File.mkdir_p!(dir)

    ExUnit.Callbacks.on_exit(fn ->
      :persistent_term.erase({SSHConsole, :authorized_keys, auth})
      File.rm_rf!(root)
      for module <- [SSHConsoleHotloadProbe, SSHConsoleLatestProbe, SSHConsoleOuterProbe, SSHConsoleOuterProbe.Inner] do
        :code.soft_purge(module)
        :code.delete(module)
        :code.soft_purge(module)
      end
    end)

    generate_key(client)
    generate_key(other)
    File.write!(auth, public_key(client))
    {user, 0} = System.cmd("id", ["-un"])
    supervisor = ExUnit.Callbacks.start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    opts = %{port: free_port(), user_dir: dir, name: Map.get(context, :console_name, SSHConsoleE2EServer)}
    c = %{root: root, dir: dir, client: client, other: other, auth: auth, user: String.trim(user),
      supervisor: supervisor, opts: opts, known_hosts: Path.join(root, "known_hosts"), server: nil}

    if context[:prepare_only] do
      c
    else
      {:ok, server} = start(c)
      File.write!(c.known_hosts, "[127.0.0.1]:#{opts.port} #{public_key(dir)}")
      %{c | server: server}
    end
  end

  def start(c), do: DynamicSupervisor.start_child(c.supervisor, {SSHConsole, c.opts})

  def restart(c) do
    :ok = DynamicSupervisor.terminate_child(c.supervisor, c.server)
    {:ok, server} = start(c)
    %{c | server: server}
  end

  def generate_key(dir, passphrase \\ "") do
    File.mkdir_p!(dir)
    {output, status} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-a", "1", "-N", passphrase,
      "-C", "ssh-console-e2e", "-f", Path.join(dir, "id_ed25519")], stderr_to_stdout: true)
    assert status == 0, output
  end

  def public_key(dir), do: File.read!(Path.join(dir, "id_ed25519.pub"))
  def fingerprint(path), do: :crypto.hash(:sha256, File.read!(path))

  def command(c, source, opts \\ []) do
    System.cmd("ssh", client_args(c, opts) ++ [source], stderr_to_stdout: true)
  end

  def command!(c, source, opts \\ []) do
    {output, status} = command(c, source, opts)
    assert status == 0, output
    String.trim(output)
  end

  def shell(c, input, final_prompt) do
    port = Port.open({:spawn_executable, System.find_executable("ssh")},
      [:binary, :exit_status, :stderr_to_stdout, args: client_args(c, tty: true)])
    try do
      Port.command(port, input)
      shell_output(port, final_prompt, "")
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp shell_output(port, final_prompt, output) do
    receive do
      {^port, {:data, data}} ->
        output = output <> data
        if final_prompt && String.contains?(output, final_prompt) do
          Port.command(port, <<3>>)
          shell_output(port, nil, output)
        else
          shell_output(port, final_prompt, output)
        end
      {^port, {:exit_status, status}} -> {output, status}
    after
      5_000 -> flunk("SSH shell stalled: #{output}")
    end
  end

  def denied(c, opts \\ []) do
    {output, status} = command(c, "1 + 2", opts)
    assert status != 0
    assert output =~ "Permission denied"
  end

  def settle(path) do
    stat = File.stat!(path, time: :posix)
    Process.sleep(max(0, (max(stat.mtime, stat.ctime) + 1) * 1_000 - :os.system_time(:millisecond)))
  end

  def eventually(fun, attempts \\ 40) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition did not become true")
      true ->
        Process.sleep(25)
        eventually(fun, attempts - 1)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp client_args(c, opts) do
    ["-F", "/dev/null", if(opts[:tty], do: "-tt", else: "-T"), "-p", to_string(c.opts.port), "-l", Keyword.get(opts, :user, c.user),
      "-i", Path.join(Keyword.get(opts, :client, c.client), "id_ed25519"),
      "-o", "UserKnownHostsFile=#{c.known_hosts}", "-o", "GlobalKnownHostsFile=/dev/null",
      "-o", "StrictHostKeyChecking=yes", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
      "-o", "BatchMode=yes", "-o", "PreferredAuthentications=publickey", "-o", "ConnectTimeout=3",
      "-o", "LogLevel=ERROR", "127.0.0.1"]
  end
end
