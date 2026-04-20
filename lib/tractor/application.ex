defmodule Tractor.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Tractor.RunRegistry},
        {Registry, keys: :unique, name: Tractor.AgentRegistry},
        {Task.Supervisor, name: Tractor.HandlerTasks},
        {DynamicSupervisor, strategy: :one_for_one, name: Tractor.ACP.SessionSup},
        {DynamicSupervisor, strategy: :one_for_one, name: Tractor.RunSup},
        {Phoenix.PubSub, name: Tractor.PubSub},
        Tractor.RunEvents,
        {DynamicSupervisor, strategy: :one_for_one, name: Tractor.WebSup}
      ] ++ maybe_endpoint_child()

    opts = [strategy: :one_for_one, name: Tractor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Start the observer endpoint as a permanent child only when the :server
  # flag is true in the compile-time config (dev via config/dev.exs) AND we
  # are not running as an escript. In prod / test / escript the endpoint is
  # only brought up on demand by TractorWeb.Server under WebSup.
  defp maybe_endpoint_child do
    cond do
      escript?() -> []
      Application.get_env(:tractor, TractorWeb.Endpoint)[:server] -> [TractorWeb.Endpoint]
      true -> []
    end
  end

  # Escripts run from a bundled archive; :code.which/1 returns :preloaded or
  # an archive path like '<.../bin/tractor>/tractor/ebin/Elixir.Tractor.beam'.
  # Detect by the `.beam` file living inside a zip (no regular file on disk).
  defp escript? do
    case :code.which(__MODULE__) do
      path when is_list(path) ->
        path_str = List.to_string(path)
        String.contains?(path_str, "/bin/tractor/") or not File.regular?(path_str)

      _ ->
        false
    end
  end
end
