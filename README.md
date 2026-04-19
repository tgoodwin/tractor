# Tractor

Tractor runs a Graphviz DOT pipeline through coding agents.

```sh
./bin/tractor reap examples/three_agents.dot
```

The default path parses a strict DOT subset, walks the pipeline, and drives
Claude, Codex, and Gemini through ACP-compatible bridge commands. Run artifacts
are written under the configured Tractor data directory.

Use the local observer UI for live inspection and post-mortems:

```sh
./bin/tractor reap --serve examples/parallel_audit.dot
```

The observer binds to `127.0.0.1`, prints a `/runs/<run_id>` URL before the run
starts, and keeps serving after completion until Ctrl-C.

## Install

Tractor is an Elixir escript.

```sh
mix deps.get
mix escript.build
```

`--serve` requires Graphviz at runtime:

```sh
brew install graphviz
# or
sudo apt install graphviz
```

## ACP Bridges

Tractor does not install agent bridges. Install and authenticate each provider
before running a real pipeline.

### Gemini

Default command:

```sh
gemini --acp
```

If the Gemini CLI changes its ACP flag, override the args:

```sh
export TRACTOR_ACP_GEMINI_ARGS='["--acp-mode"]'
```

### Claude

Default command:

```sh
npx acp-claude-code
```

The `Xuanwo/acp-claude-code` project is archived. Prefer an actively maintained
bridge such as `@zed-industries/claude-code-acp` when available:

```sh
export TRACTOR_ACP_CLAUDE_COMMAND=npx
export TRACTOR_ACP_CLAUDE_ARGS='["@zed-industries/claude-code-acp"]'
```

### Codex

Default command:

```sh
codex-acp
```

## Runtime Overrides

Each provider supports command, args, and environment overrides:

```sh
export TRACTOR_ACP_CODEX_COMMAND=codex-acp
export TRACTOR_ACP_CODEX_ARGS='[]'
export TRACTOR_ACP_CODEX_ENV_JSON='{"EXAMPLE":"value"}'
```

Environment values are redacted in run manifests.
