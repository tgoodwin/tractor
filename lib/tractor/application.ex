defmodule Tractor.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Burrito.Util.Args, as: BurritoArgs

  @impl true
  def start(_type, _args) do
    Application.put_env(:tractor, :runs_dir, Tractor.Paths.runs_dir())

    children =
      [
        {Registry, keys: :unique, name: Tractor.RunRegistry},
        {Registry, keys: :unique, name: Tractor.AgentRegistry},
        {Registry, keys: :unique, name: Tractor.StatusAgentRegistry},
        {Task.Supervisor, name: Tractor.HandlerTasks},
        {Task.Supervisor, name: Tractor.StatusAgentTasks},
        {DynamicSupervisor, strategy: :one_for_one, name: Tractor.ACP.SessionSup},
        {DynamicSupervisor, strategy: :one_for_one, name: Tractor.StatusAgentSup},
        {DynamicSupervisor, strategy: :one_for_one, name: Tractor.RunSup},
        {Phoenix.PubSub, name: Tractor.PubSub},
        Tractor.RunEvents,
        {DynamicSupervisor, strategy: :one_for_one, name: Tractor.WebSup}
      ] ++ maybe_resume_boot_child() ++ maybe_endpoint_child() ++ maybe_run_watcher_children()

    opts = [strategy: :one_for_one, name: Tractor.Supervisor]
    result = Supervisor.start_link(children, opts)
    maybe_dispatch_release_cli()
    result
  end

  # When booted as a Burrito-wrapped release (or `mix release` started binary),
  # the supervision tree starts headless and we hand argv to Tractor.CLI.main/1
  # in a separate process so Application.start/2 can return :ok promptly. The
  # CLI calls System.halt/1 itself when done.
  defp maybe_dispatch_release_cli do
    if release_cli?() do
      argv = BurritoArgs.argv()
      spawn(fn -> Tractor.CLI.main(argv) end)
    end
  end

  # Start the observer endpoint as a permanent child only when the :server
  # flag is true in the compile-time config (dev via config/dev.exs) AND we
  # are not running as an escript. In prod / test / escript the endpoint is
  # only brought up on demand by TractorWeb.Server under WebSup.
  defp maybe_endpoint_child do
    cond do
      cli_boot?() -> []
      Application.get_env(:tractor, TractorWeb.Endpoint)[:server] -> [TractorWeb.Endpoint]
      true -> []
    end
  end

  defp maybe_resume_boot_child do
    cond do
      cli_boot?() -> []
      Application.get_env(:tractor, TractorWeb.Endpoint)[:server] -> [Tractor.ResumeBoot]
      true -> []
    end
  end

  defp maybe_run_watcher_children do
    cond do
      cli_boot?() ->
        []

      Application.get_env(:tractor, TractorWeb.Endpoint)[:server] ->
        [
          {DynamicSupervisor, strategy: :one_for_one, name: Tractor.RunWatcher.TailSupervisor},
          Tractor.RunWatcher
        ]

      true ->
        []
    end
  end

  defp cli_boot?, do: escript?() or release_cli?()

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

  # `RELEASE_NAME` is set by `mix release` when the generated start script
  # boots the BEAM. Burrito-wrapped binaries inherit this. Dev (`iex -S mix`,
  # `mix phx.server`) does not set it.
  defp release_cli? do
    System.get_env("RELEASE_NAME") == "tractor"
  end
end
