Code.require_file("ssh_console_helper.exs", __DIR__)

defmodule SSHConsoleKeysTest do
  use ExUnit.Case, async: false
  alias SSHConsole.TestSupport, as: SSH

  @moduletag capture_log: true

  setup context do
    SSH.fixture(context)
  end

  test "accepts the authorized key, ignores malformed lines, and rejects other users and keys", c do
    File.write!(c.auth, "  # #{SSH.public_key(c.other)}\nssh-ed25519 invalid-base64\n#{SSH.public_key(c.client)}")
    assert SSH.command!(c, "1 + 2") == "3"
    SSH.denied(c, client: c.other)
    SSH.denied(c, user: c.user <> "-wrong-user")
  end

  test "deleting and replacing authorized_keys changes access on the next connection", c do
    SSH.settle(c.auth)
    assert SSH.command!(c, "1 + 2") == "3"
    File.rm!(c.auth)
    SSH.denied(c)

    File.write!(c.auth, SSH.public_key(c.other))
    assert SSH.command!(c, "1 + 2", client: c.other) == "3"
    SSH.denied(c)
  end

  test "atomic replacement revokes a cached key even with the same size and mtime", c do
    SSH.settle(c.auth)
    assert SSH.command!(c, "1 + 2") == "3"
    before = File.stat!(c.auth)
    replacement = Path.join(c.dir, "replacement")
    File.write!(replacement, SSH.public_key(c.other))
    File.touch!(replacement, before.mtime)
    File.rename!(replacement, c.auth)
    after_stat = File.stat!(c.auth)
    assert after_stat.mtime == before.mtime
    assert after_stat.size == before.size
    refute after_stat.inode == before.inode
    assert SSH.command!(c, "1 + 2", client: c.other) == "3"
    SSH.denied(c)
  end

  test "immediate same-size edits take effect on successive SSH connections", c do
    assert SSH.command!(c, "1 + 2") == "3"
    File.write!(c.auth, SSH.public_key(c.other))
    assert SSH.command!(c, "1 + 2", client: c.other) == "3"
    SSH.denied(c)
    File.write!(c.auth, SSH.public_key(c.client))
    assert SSH.command!(c, "1 + 2") == "3"
    SSH.denied(c, client: c.other)
  end

  test "authorized_keys2 cannot restore access when authorized_keys is absent or empty", c do
    assert SSH.command!(c, "1 + 2") == "3"
    File.write!(Path.join(c.dir, "authorized_keys2"), SSH.public_key(c.client))
    File.rm!(c.auth)
    SSH.denied(c)
    File.write!(c.auth, "")
    SSH.denied(c)
  end

  test "startup generates a host identity that survives restart and public-key recovery", c do
    path = Path.join(c.dir, "id_ed25519")
    private = SSH.fingerprint(path)
    public = SSH.public_key(c.dir)
    assert :erlang.band(File.stat!(path).mode, 0o777) == 0o600
    assert SSH.command!(c, "1 + 2") == "3"

    c = SSH.restart(c)
    assert SSH.command!(c, "1 + 2") == "3"
    assert SSH.fingerprint(path) == private
    assert SSH.public_key(c.dir) == public

    File.rm!(path <> ".pub")
    c = SSH.restart(c)
    # The client still pins the original host public key.
    assert SSH.command!(c, "1 + 2") == "3"
    assert SSH.fingerprint(path) == private
    assert File.regular?(path <> ".pub")
  end

  test "the client verifies the server's host identity", c do
    File.write!(c.known_hosts, "[127.0.0.1]:#{c.opts.port} #{SSH.public_key(c.other)}")
    {output, status} = SSH.command(c, "1 + 2")
    assert status != 0
    assert output =~ "Host key verification failed"
  end

  @tag prepare_only: true
  test "a public key without its private half fails supervised startup without replacing it", c do
    path = Path.join(c.dir, "id_ed25519")
    File.write!(path <> ".pub", SSH.public_key(c.client))
    assert {:error, {:ssh_host_key, :missing_private_key}} = SSH.start(c)
    refute File.exists?(path)
    assert SSH.public_key(c.dir) == SSH.public_key(c.client)
  end

  @tag prepare_only: true
  test "an invalid existing private key fails supervised startup without replacement", c do
    path = Path.join(c.dir, "id_ed25519")
    File.write!(path, "not an SSH private key")
    assert {:error, {:ssh_host_key, _}} = SSH.start(c)
    assert File.read!(path) == "not an SSH private key"
    refute File.exists?(path <> ".pub")
  end

  @tag prepare_only: true
  test "an encrypted private key fails supervised startup explicitly and never opens a listener", c do
    SSH.generate_key(c.dir, "console-test")
    path = Path.join(c.dir, "id_ed25519")
    private = SSH.fingerprint(path)
    public = SSH.public_key(c.dir)
    message = "SSHConsole private key is encrypted: #{path}"
    assert {:error, {%RuntimeError{message: ^message}, _stacktrace}} = SSH.start(c)
    assert DynamicSupervisor.which_children(c.supervisor) == []
    assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, c.opts.port, [active: false], 1_000)
    assert SSH.fingerprint(path) == private
    assert SSH.public_key(c.dir) == public
  end
end
