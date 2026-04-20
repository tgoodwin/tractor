import Config

# Base endpoint config shared by all envs. Runtime overrides (port, server on/off
# for the escript --serve path) still flow through TractorWeb.Server.configure/1.
config :tractor, TractorWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: false,
  url: [host: "127.0.0.1"],
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "tractor_live_view_salt"],
  pubsub_server: Tractor.PubSub,
  render_errors: [formats: [html: TractorWeb.ErrorHTML], layout: false],
  check_origin: false

import_config "#{config_env()}.exs"
