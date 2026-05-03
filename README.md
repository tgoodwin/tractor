# Tractor

Write a multi-step LLM workflow as a Graphviz DOT graph; Tractor executes it
across Claude, Codex, and Gemini, with a live observer for watching the run.

```sh
./bin/tractor reap --serve examples/parallel_audit.dot
```

`reap` walks the graph, dispatches each node to its configured agent, and (with
`--serve`) opens an observer at `http://127.0.0.1:4000/runs/<id>` that streams
events as they happen. Drop `--serve` for a headless run; artifacts still land
in the runs directory.

`./bin/tractor view` opens the observer on its own — handy in a second terminal
alongside a headless reap, or for browsing finished runs.

## Setup

Tractor is an Elixir escript.

```sh
mix deps.get
mix cli                  # builds bin/tractor
brew install graphviz    # the observer renders graphs with `dot`
```

You bring your own agent CLIs. Defaults:

| Provider | Command |
| --- | --- |
| Claude | `npx acp-claude-code` |
| Codex | `codex-acp` |
| Gemini | `gemini --acp` |

The Claude default is archived upstream; if you can, swap to the
actively-maintained `@zed-industries/claude-code-acp` via the override below.

Each provider takes `_COMMAND`, `_ARGS`, and `_ENV_JSON` overrides:

```sh
export TRACTOR_ACP_CLAUDE_COMMAND=npx
export TRACTOR_ACP_CLAUDE_ARGS='["@zed-industries/claude-code-acp"]'
export TRACTOR_ACP_CLAUDE_ENV_JSON='{"ANTHROPIC_API_KEY":"…"}'
```

Same shape for `CODEX` and `GEMINI`. Env values are redacted in run manifests.

## Authoring pipelines

Writing the DOT graph by hand can be tricky. `tractor init claude` (or
`codex` / `gemini`) installs a `create-pipeline` skill into
`.<agent>/skills/` in the current project; open your agent there and ask it
to create a pipeline — the skill walks it through goal capture, topology
choice, and validation.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — three-plane architecture, supervision tree, log-as-bus contract.
- [`docs/handlers.md`](docs/handlers.md) — per-handler reference: `start`, `exit`, `codergen`, `tool`, `wait.human`, `conditional`, `judge`, `parallel`, `parallel.fan_in`.
- [`docs/usage/reap.md`](docs/usage/reap.md) — `tractor reap` flags, exit codes, log layout.
- [`docs/usage/validate-prompt.md`](docs/usage/validate-prompt.md) — pipeline authoring rules and patterns.
- [`docs/usage/testing.md`](docs/usage/testing.md) — `mix test` and browser harness.
- [`docs/spec-coverage.md`](docs/spec-coverage.md) — strongDM attractor spec → Tractor map.
- [`IDEA.md`](IDEA.md) — original design pitch.
