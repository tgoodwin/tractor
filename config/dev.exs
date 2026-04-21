import Config

# Dev: start the endpoint on app boot, enable code/live reload.
config :tractor, TractorWeb.Endpoint,
  server: true,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  code_reloader: true,
  debug_errors: true,
  check_origin: false,
  live_reload: [
    patterns: [
      ~r"priv/static/assets/.*(js|css|png|jpeg|jpg|gif|svg|mjs)$",
      ~r"lib/tractor_web/(live|views|templates|run_live)/.*(ex|heex)$",
      ~r"lib/tractor_web/.*(ex)$"
    ]
  ]

config :phoenix, :plug_init_mode, :runtime
