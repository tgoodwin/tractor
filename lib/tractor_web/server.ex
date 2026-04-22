defmodule TractorWeb.Server do
  @moduledoc """
  Runtime starter for the observer endpoint.
  """

  @host {127, 0, 0, 1}
  @secret_key_base String.duplicate("a", 64)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: TractorWeb.Endpoint,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    with :ok <- TractorWeb.GraphRenderer.probe_dot() do
      configure(opts)

      Supervisor.start_link(
        [
          TractorWeb.Endpoint,
          {DynamicSupervisor, strategy: :one_for_one, name: Tractor.RunWatcher.TailSupervisor},
          Tractor.RunWatcher
        ],
        strategy: :one_for_one
      )
    end
  end

  @spec configure(keyword()) :: :ok
  def configure(opts) do
    port = Keyword.get(opts, :port, 0)
    runs_dir = Keyword.get(opts, :runs_dir, Tractor.Paths.runs_dir()) |> Path.expand()

    base = [
      adapter: Bandit.PhoenixAdapter,
      server: true,
      url: [host: "127.0.0.1"],
      secret_key_base: @secret_key_base,
      live_view: [signing_salt: "tractor_live_view_salt"],
      pubsub_server: Tractor.PubSub,
      render_errors: [formats: [html: TractorWeb.ErrorHTML], layout: false],
      check_origin: false
    ]

    # Merge onto whatever compile-time config.exs / dev.exs set (e.g.
    # code_reloader, live_reload patterns) so dev-mode extras survive.
    existing = Application.get_env(:tractor, TractorWeb.Endpoint, [])

    merged =
      existing
      |> Keyword.merge(base)
      |> Keyword.put(:http, ip: @host, port: port)

    Application.put_env(:tractor, TractorWeb.Endpoint, merged)
    Application.put_env(:tractor, :runs_dir, runs_dir)

    :ok
  end

  @spec configured_host() :: :inet.ip_address()
  def configured_host, do: @host
end
