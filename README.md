# Tractor

Tractor is a DOT-based pipeline runner that uses directed graphs (defined in Graphviz DOT syntax) to orchestrate multi-stage AI workflows. Each node in the graph is an AI task (LLM call, human review, conditional branch, parallel fan-out, etc.) and edges define the flow between them.

```sh
tractor reap --serve examples/parallel_audit.dot
```

`reap` walks the graph, dispatches each node to its configured agent, and (with
`--serve`) opens an observer at `http://127.0.0.1:4000/runs/<id>` that streams
events as they happen. Drop `--serve` for a headless run; artifacts still land
in the runs directory.

`tractor view` opens the observer on its own — handy in a second terminal
alongside a headless reap, or for browsing finished runs.

## Install

Pre-built binaries are published with each tagged release. Tractor is in
**alpha** — expect breakage; pin a specific tag rather than tracking `main`.
Pick the asset for your platform from the
[latest release](https://github.com/tgoodwin/tractor/releases) and `curl` it:

```sh
TAG=v0.2.2-alpha
ASSET=tractor-macos_aarch64    # or macos_x86_64 / linux_x86_64 / linux_aarch64

curl -L -o tractor "https://github.com/tgoodwin/tractor/releases/download/$TAG/$ASSET"
chmod +x tractor
sudo mv tractor /usr/local/bin/   # anywhere on $PATH
```

Verify against the release's `SHA256SUMS`:

```sh
curl -L "https://github.com/tgoodwin/tractor/releases/download/$TAG/SHA256SUMS" | shasum -a 256 -c --ignore-missing
```

Two runtime prerequisites must be on `$PATH`:

- **Graphviz** (`dot`) — `brew install graphviz` (macOS) or
  `apt install graphviz` (Debian/Ubuntu). Used by the observer to render
  pipeline graphs.
- **Node.js** (`node` + `npx`) — for the maintained ACP bridges below. Bring
  your own bridges via env vars and Node becomes optional.

## Agents

You bring your own agent CLIs. Defaults all point at maintained ACP bridges:

| Provider | Command |
| --- | --- |
| Claude | `npx @zed-industries/claude-code-acp` |
| Codex | `npx @zed-industries/codex-acp` |
| Gemini | `gemini --acp` |

Override per provider with `_COMMAND`, `_ARGS`, and `_ENV_JSON` env vars:

```sh
export TRACTOR_ACP_CLAUDE_ENV_JSON='{"ANTHROPIC_API_KEY":"…"}'
export TRACTOR_ACP_CODEX_COMMAND=/path/to/codex-acp
```

Same shape for `CODEX` and `GEMINI`. Env values are redacted in run manifests.

## Build from source

Tractor is an Elixir escript. Requires Elixir 1.17 + OTP 27.

```sh
mix deps.get
mix cli                  # builds bin/tractor
brew install graphviz    # the observer renders graphs with `dot`
```

`bin/tractor` is the same CLI as the released binary — add it to `$PATH` or
invoke via `./bin/tractor` from the repo root.

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
