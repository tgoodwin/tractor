# `validate-prompt`

`validate-prompt` is a reference checklist for reviewing Tractor DOT pipelines before they are run. It is not a separate CLI feature. Use it when authoring prompts, node wiring, and handler choices so the graph passes `tractor validate` and avoids design mistakes that Tractor warns about.

## Supported Providers

Tractor supports these LLM providers:

- `claude`
- `codex`
- `gemini`

Tractor does not maintain a model allowlist. If you set `llm_model`, choose one that your configured provider can actually serve.

## Supported Handler Types

Tractor recognizes these node types and implied shapes:

- `start`
- `exit`
- `codergen`
- `tool`
- `wait.human`
- `conditional`
- `judge` *(tractor extension; being phased out — see "Canonical feedback loop" below)*
- `parallel`
- `parallel.fan_in`

If you set both `type` and `shape`, they should agree. Tractor warns when they disagree.

## Canonical Feedback Loop (3-node pattern)

The strongDM attractor spec separates **validation** (an LLM call that produces a verdict) from **adjudication** (a routing decision based on that verdict). The canonical pattern is three nodes:

```
agent → reviewer (codergen, has prompt) → gate (diamond, no prompt) → agent / next
```

The reviewer's prompt asks the LLM to emit a structured verdict (e.g. `VERDICT: accept` or `VERDICT: reject`). The gate is a `conditional` (diamond) node with no prompt — it routes based on edge conditions that read the reviewer's output:

```
reviewer -> gate
gate -> agent     [condition="context.reviewer.last contains \"VERDICT: reject\""]
gate -> next_step [condition="context.reviewer.last contains \"VERDICT: accept\""]
```

`examples/haiku_feedback.dot` is the reference.

The `judge` handler collapses reviewer-and-gate into a single node. It exists for backward compatibility but it triggers `two_way_edge` and (when paired with `shape=hexagon`) `type_shape_mismatch` warnings, because a single-node loop short-circuits the spec's separation of concerns. Prefer the 3-node pattern.

## Authoring Guidance

Use `codergen` for LLM-backed work — both generation and review steps. `codergen` is the only node family Tractor treats as agent-capable for new pipelines. `judge` remains agent-capable for now but is on a deprecation path.

Use `tool` only when a direct shell command is the right abstraction. Tool nodes run commands directly and do not get the same prompt-driven diagnosis and repair behavior as agent-capable nodes.

Use `wait.human` only for development-time debugging or explicit operator checkpoints. Production pipelines should avoid human gates.

Use `parallel` for fan-out routing and `parallel.fan_in` for join behavior. Do not treat them as generic agent nodes during validation.

## Prompt And Attribute Rules

Prompts belong on `codergen` (and `judge`) nodes. Diamond gates must NOT have a prompt — they are pure routing. Tractor warns when a `tool` node has a `prompt`.

Commands belong on `tool` nodes. Tractor warns when `command` appears on a non-tool node.

`goal_gate=true` only makes sense on `codergen` (and `judge`) nodes.

`llm_provider` and `llm_model` only make sense on `codergen` (and `judge`) nodes.

`timeout` should not be used on instant-routing nodes: `start`, `exit`, `conditional`, and `parallel`.

`allow_partial=true` only helps when effective `retries` is greater than zero.

`retry_target` and `fallback_retry_target` should point at existing non-terminal nodes outside parallel blocks.

## Design Principles

Avoid human gates in production. Tractor warns on every `wait.human` node because autonomous pipelines are the default design target.

Prefer agent-capable nodes over direct tool nodes when the step may need diagnosis, retry strategy, or iterative repair.

Avoid two-way edges between the same pair of nodes. They are usually a malformed review loop and often imply a node is validating its own work. The spec-aligned alternative is the three-node pattern in "Canonical Feedback Loop" above.

Do not design a loop where the same node both produces work and validates that work. Separate generation, review, and repair responsibilities — that is what the codergen-reviewer-plus-diamond-gate pattern is for.

## Review Checklist

Before shipping a pipeline, check that:

- every LLM-backed node uses one of `claude`, `codex`, or `gemini`
- every prompt is on a `codergen` or `judge` node
- every shell command is on a `tool` node
- no `wait.human` node is required for normal production execution
- no pair of nodes has edges in both directions unless the loop is deliberate and defensible
- retry targets exist and do not point at `start`, `exit`, the declaring node, or a node inside a parallel block
- `goal_gate` and `llm_*` attrs appear only on agent-capable nodes
- `type` and `shape` agree when both are present

## Validate The Graph

Build the escript and run validation directly:

```sh
mix cli   # builds bin/tractor with MIX_ENV=prod
./bin/tractor validate path/to/pipeline.dot
```

`tractor validate` exits `10` when any error-severity diagnostic is present and `0` otherwise. On a clean graph it prints `No issues found.`. Warning-only and error cases end with a diagnostic summary line.
