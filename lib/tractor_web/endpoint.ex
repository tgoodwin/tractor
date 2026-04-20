defmodule TractorWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :tractor

  @session_options [
    store: :cookie,
    key: "_tractor_key",
    signing_salt: "tractor"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  # phoenix_live_reload in dev: exposes the websocket and watches files for
  # hot-swapping CSS / HEEx / LiveView .ex.
  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.Static,
    at: "/",
    from: "priv/static",
    gzip: false,
    only: ~w(assets favicon.ico)
  )

  plug(Plug.Session, @session_options)
  plug(TractorWeb.Router)
end
