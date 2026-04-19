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
      TractorWeb.Endpoint.start_link()
    end
  end

  @spec configure(keyword()) :: :ok
  def configure(opts) do
    port = Keyword.get(opts, :port, 0)

    Application.put_env(:tractor, TractorWeb.Endpoint,
      adapter: Bandit.PhoenixAdapter,
      http: [ip: @host, port: port],
      server: true,
      url: [host: "127.0.0.1"],
      secret_key_base: @secret_key_base,
      live_view: [signing_salt: "tractor_live_view_salt"],
      pubsub_server: Tractor.PubSub,
      render_errors: [formats: [html: TractorWeb.ErrorHTML], layout: false],
      check_origin: false
    )

    :ok
  end

  @spec configured_host() :: :inet.ip_address()
  def configured_host, do: @host
end
