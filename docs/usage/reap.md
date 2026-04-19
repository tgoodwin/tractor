# `tractor reap`

Build the escript:

```sh
mix deps.get
mix escript.build
```

Run a DOT pipeline:

```sh
./tractor reap examples/three_agents.dot
```

Write runs to a specific directory:

```sh
./tractor reap examples/three_agents.dot --runs-dir /tmp/tractor-runs
```

Set a prompt timeout:

```sh
./tractor reap examples/three_agents.dot --timeout 5m
```

Supported duration suffixes are `ms`, `s`, `m`, and `h`.

## Provider Overrides

Each provider supports command, args, and env overrides. Args must be JSON arrays.
Env must be a JSON object.

```sh
export TRACTOR_ACP_CODEX_COMMAND=codex-acp
export TRACTOR_ACP_CODEX_ARGS='[]'
export TRACTOR_ACP_CODEX_ENV_JSON='{"TOKEN":"secret"}'
```

Manifest files redact env values.

## Gemini

Default:

```sh
gemini --acp
```

If the Gemini CLI changes its ACP flag, override args:

```sh
export TRACTOR_ACP_GEMINI_ARGS='["--acp-mode"]'
```

or:

```sh
export TRACTOR_ACP_GEMINI_ARGS='["--experimental-acp"]'
```

## Claude

Default:

```sh
npx acp-claude-code
```

`Xuanwo/acp-claude-code` is archived. To use the Zed bridge package instead:

```sh
export TRACTOR_ACP_CLAUDE_COMMAND=npx
export TRACTOR_ACP_CLAUDE_ARGS='["@zed-industries/claude-code-acp"]'
```

## Codex

Default:

```sh
codex-acp
```

Override it the same way:

```sh
export TRACTOR_ACP_CODEX_COMMAND=codex-acp
export TRACTOR_ACP_CODEX_ARGS='[]'
```
