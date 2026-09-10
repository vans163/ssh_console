# ssh_console
Interact with erlang nodes. Useful for agents

Copy/paste [lib/ssh_console.ex](lib/ssh_console.ex) into a running IEx session, or include it in your project and add it to your supervisor tree so it restarts after crashes. The SSH daemon starts automatically, uses the app's OS username and `~/.ssh/authorized_keys`, and listens on `127.0.0.1:4022` by default. Replace `MyApp.DynamicSupervisor` below with your existing supervisor's name.

```elixir
DynamicSupervisor.start_child(MyApp.DynamicSupervisor, {SSHConsole, %{
  ip: "127.0.0.1",
  port: 4022
}})

# From another terminal: ssh -p 4022 user@127.0.0.1 'Node.self()'
```

https://github.com/user-attachments/assets/5aa450ea-3052-45b9-810e-d472daadacd8
