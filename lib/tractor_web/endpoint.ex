defmodule TractorWeb.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :tractor

  @session_options [
    store: :cookie,
    key: "_tractor_key",
    signing_salt: "tractor"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :tractor,
    gzip: false,
    only: ~w(assets favicon.ico)

  plug Plug.Session, @session_options
  plug TractorWeb.Router

end
