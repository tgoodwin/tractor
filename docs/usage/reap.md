# `tractor reap`

Build the escript:

```sh
mix deps.get
mix escript.build
```

Run a DOT pipeline:

```sh
./bin/tractor reap examples/three_agents.dot
```

Run with the local LiveView observer:

```sh
./bin/tractor reap --serve examples/parallel_audit.dot
```

`--serve` starts an HTTP observer on `127.0.0.1`, prints the run URL before the
first node starts, runs the pipeline, then keeps the page available for
post-mortem inspection until Ctrl-C.

Use an explicit loopback port:

```sh
./bin/tractor reap --serve --port 4040 examples/parallel_audit.dot
```

Suppress browser auto-open:

```sh
./bin/tractor reap --serve --no-open examples/parallel_audit.dot
```

Write runs to a specific directory:

```sh
./bin/tractor reap examples/three_agents.dot --runs-dir /tmp/tractor-runs
```

Set a prompt timeout:

```sh
./bin/tractor reap examples/three_agents.dot --timeout 5m
```

Supported duration suffixes are `ms`, `s`, `m`, and `h`.

## Observer Requirements

The observer renders DOT through Graphviz at runtime. Install `dot` before using
`--serve`:

```sh
brew install graphviz
# or
sudo apt install graphviz
```

The page shows the DOT graph as SVG with node states, and a side panel for the
selected node's prompt, response, ACP message chunks, reasoning trace from ACP,
tool calls, and stderr.

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
