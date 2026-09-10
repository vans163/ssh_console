defmodule SSHConsole.MixProject do
  use Mix.Project

  def project do
    [
      app: :ssh_console,
      version: "0.1.0",
      elixir: "~> 1.19",
      description: "SSH REPL and command evaluation for running Elixir nodes",
      source_url: "https://github.com/vans163/ssh_console",
      package: [licenses: ["Apache-2.0"], links: %{"GitHub" => "https://github.com/vans163/ssh_console"}],
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger, :ssh, :iex]]
  end
end
