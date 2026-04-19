# Tractor

Tractor runs a Graphviz DOT pipeline through coding agents. Sprint 1 supports
one command:

```sh
./tractor reap examples/three_agents.dot
```

The sprint-one path parses a strict DOT subset, walks a linear pipeline, and
drives Claude, Codex, and Gemini through ACP-compatible bridge commands. Run
artifacts are written under the configured Tractor data directory.

## Install

Tractor is an Elixir escript.

```sh
mix deps.get
mix escript.build
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
