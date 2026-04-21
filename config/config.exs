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

config :tractor, :provider_pricing, %{
  {"claude", "claude-opus-4-7"} => %{input_per_mtok: 5.00, output_per_mtok: 25.00},
  {"claude", "claude-sonnet-4-6"} => %{input_per_mtok: 3.00, output_per_mtok: 15.00},
  {"claude", "claude-haiku-4-5"} => %{input_per_mtok: 1.00, output_per_mtok: 5.00},
  {"codex", "gpt-5"} => %{input_per_mtok: 1.25, output_per_mtok: 10.00},
  {"codex", "gpt-5-mini"} => %{input_per_mtok: 0.25, output_per_mtok: 2.00},
  {"codex", "gpt-5-nano"} => %{input_per_mtok: 0.05, output_per_mtok: 0.40},
  {"gemini", "gemini-3-pro"} => %{input_per_mtok: 2.00, output_per_mtok: 12.00},
  {"gemini", "gemini-3.1-pro-preview"} => %{input_per_mtok: 2.00, output_per_mtok: 12.00},
  {"gemini", "gemini-3-flash"} => %{input_per_mtok: 0.50, output_per_mtok: 3.00},
  {"gemini", "gemini-3-flash-preview"} => %{input_per_mtok: 0.50, output_per_mtok: 3.00},
  {"gemini", "gemini-3-flash-lite"} => %{input_per_mtok: 0.25, output_per_mtok: 1.50},
  {"gemini", "gemini-3.1-flash-lite-preview"} => %{input_per_mtok: 0.25, output_per_mtok: 1.50}
}

import_config "#{config_env()}.exs"
