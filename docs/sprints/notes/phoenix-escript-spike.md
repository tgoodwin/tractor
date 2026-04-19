# Phoenix-in-escript spike

Date: 2026-04-19

Outcome: stay on the escript path for `tractor reap --serve`.

The sprint spike was exercised with the same dependency set planned for the
application: Phoenix, Phoenix LiveView, Phoenix HTML, Phoenix PubSub, and
Bandit. The endpoint is started dynamically rather than as a static
application child, assets are served from `priv/static`, and `mix
escript.build` keeps the no-`--serve` CLI path as the primary distribution.

Implementation notes carried into the sprint:

- `TractorWeb.Endpoint` is configured at runtime before it is started under
  `Tractor.WebSup`.
- `priv/static` is embedded into the escript via `:embed_extra_files`.
- `--serve` remains the only path that probes Graphviz or starts the endpoint.
- If a later environment-specific escript issue appears, the fallback remains
  a `mix release` for `--serve` only, but the fallback is not active now.
