defmodule Tractor.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Tractor.RunRegistry},
      {Registry, keys: :unique, name: Tractor.AgentRegistry},
      {Task.Supervisor, name: Tractor.HandlerTasks},
      {DynamicSupervisor, strategy: :one_for_one, name: Tractor.ACP.SessionSup},
      {DynamicSupervisor, strategy: :one_for_one, name: Tractor.RunSup}
    ]

    opts = [strategy: :one_for_one, name: Tractor.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
