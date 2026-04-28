# Handler reference

One module per node type. All implement the `Tractor.Handler` behaviour:

```elixir
@callback run(node :: Node.t(), context :: map(), run_dir :: Path.t()) ::
            {:ok, outcome :: String.t(), updates :: map()}
            | {:wait, %{kind: :wait_human, payload: map()}}
            | {:error, reason :: term()}

@callback default_timeout_ms() :: pos_integer() | nil  # optional
```

`Tractor.Runner.handler_for/1` (`runner.ex:1823`) maps `node.type` → module. The `parallel` type has no handler module — it's handled inline by the runner.

| `node.type` | Module | Default shape | Default timeout | Has prompt | Calls LLM |
|---|---|---|---|---|---|
| `start` | `Tractor.Handler.Start` | `Mdiamond` | none | no | no |
| `exit` | `Tractor.Handler.Exit` | `Msquare` | none | no | no |
| `codergen` | `Tractor.Handler.Codergen` | `box` | 600s (10m) | yes | yes |
| `tool` | `Tractor.Handler.Tool` | `parallelogram` | none | no | no |
| `wait.human` | `Tractor.Handler.WaitHuman` | `hexagon` | indefinite (suspends) | optional (`wait_prompt`) | no |
| `conditional` | `Tractor.Handler.Conditional` | `diamond` | none | **must NOT have prompt** | no |
| `judge` | `Tractor.Handler.Judge` | (none — explicit `type=judge`) | 300s (5m) | yes | yes (or stub) |
| `parallel` | (inline in `Tractor.Runner`) | `component` | n/a | no | no |
| `parallel.fan_in` | `Tractor.Handler.FanIn` | `tripleoctagon` | 120s | optional | optional |

---

## `start` — `Tractor.Handler.Start`

No-op. Returns `{:ok, "start", %{}}`. Every pipeline must have exactly one.

```elixir
def run(_node, _context, _run_dir) do
  {:ok, "start", %{}}
end
```

Validation: `start_cardinality`, `start_no_incoming`.

---

## `exit` — `Tractor.Handler.Exit`

No-op. Returns `{:ok, "exit", %{}}`. Every pipeline must have exactly one. Goal-gate enforcement happens in the runner before reaching exit, not in the handler.

Validation: `exit_cardinality`, `missing_incoming` (must have at least one incoming), `missing_outgoing` is exempted for exit.

---

## `codergen` — `Tractor.Handler.Codergen`

The LLM-call workhorse. Renders the node's `prompt` against the context (template substitution), starts an ACP session against the configured provider, sends the prompt, captures the streaming response, stops the session.

**Required attrs:** `llm_provider` (`claude`, `codex`, or `gemini`).

**Optional attrs:** `llm_model`, `timeout`, `retries`, `max_iterations`, `goal_gate`, `allow_partial`, `reasoning_effort`.

**Outcome:** the response text (a string); updates carry `:response`, `:status`, `:context`, `:prompt`, `:provider_command`.

**Provider mapping:** `@provider_modules` in `codergen.ex:13` — each provider has an `Agent.{Claude,Codex,Gemini}` adapter that returns a `{command, args, env}` tuple for spawning the ACP subprocess. Sessions go through `Tractor.ACP.Session` (overridable via `:agent_client` config for testing).

**Per-node artifacts under `<run_dir>/<node_id>/`:** `prompt.md`, `stderr.log`, plus whatever the agent adapter writes.

**Events emitted:** `:prompt_sent`, `:response_chunk`, `:tool_call`, `:reasoning`, `:token_usage` (originally `:usage`, renamed in the event sink), `:turn_complete`.

This is also the de-facto handler for any LLM-backed work, including review nodes in the canonical 3-node feedback loop (see `docs/usage/validate-prompt.md`).

---

## `tool` — `Tractor.Handler.Tool`

Spawns a subprocess via `:exec` (or equivalent), captures stdout/stderr up to a configurable byte limit, returns the captured output.

**Required attrs:** `command` — non-empty list of strings (argv). The first element is resolved as an executable.

**Optional attrs:** `cwd` (defaults to `run_dir`), `env` (string→string map), `stdin` (template-rendered before piping), `max_output_bytes` (1 to 100_000_000).

**Outcome:** the captured stdout (truncated to `max_output_bytes`).

**Per-node artifacts:** none currently — output is in events.

**Events emitted:** `:tool_invoked` (with command, cwd, env), `:tool_output_truncated` (when stdout exceeds the limit), `:tool_completed` (with exit_status, captured output).

**Validation warnings** (Moab opinions, may be revisited per the spec audit):
- `tool_node_warning` — every tool node emits this; the spec-aligned recommendation is to prefer a codergen node that can diagnose and retry.
- `prompt_on_tool_node` — tool nodes shouldn't have prompts.

---

## `wait.human` — `Tractor.Handler.WaitHuman`

Suspends the pipeline until an operator resolves the node via the observer UI (or a configured timeout fires). Writes a `wait.json` payload describing the prompt and outgoing edge labels, then returns `{:wait, …}` to the runner.

**Optional attrs:** `wait_prompt` (template-rendered question shown to the operator), `wait_timeout` (duration; without it the pipeline waits indefinitely), `default_edge` (label of the edge to follow when the timeout fires).

**Outcome:** the runner re-enters the node with the operator's selected edge label set in context; the handler does not produce a return value in the normal `{:ok, …}` shape — it always returns `{:wait, …}`.

**Per-node artifacts:** `<run_dir>/<node_id>/attempt-<N>/wait.json`.

**Resolution path:** observer LiveView writes a control file (`Tractor.Runner.ControlFile`) which the runner polls.

**Validation warnings:**
- `human_gate_warning` — fires on every `wait.human` (Moab principle warning: pipelines should run autonomously).
- `wait_human_no_timeout` — fires when `wait_timeout` is absent.
- `wait_without_default` — fires when `wait_timeout` is set but `default_edge` is missing.

---

## `conditional` — `Tractor.Handler.Conditional`

A no-op routing node. Returns `{:ok, %{}, %{status: %{"status" => "ok"}}}`. The diamond shape is purely a routing fork — the runner evaluates outgoing edge `condition` expressions in priority order and picks the first match.

**Must NOT have a prompt.** The whole point of the conditional/diamond is to separate routing-decision from LLM-work. Pair it with an upstream codergen reviewer to form the canonical 3-node feedback loop.

**Outgoing edges:** at least one of:
- conditions covering both `accept` and `reject` outcomes, OR
- conditions plus an unconditional fallthrough.

The validator's `condition_coverage` check exempts conditional and judge nodes from strict accept/reject coverage, so you can route on arbitrary `context.X` expressions, but stalling at a diamond with no matching edge will fail the run at runtime.

---

## `judge` — `Tractor.Handler.Judge`

**Tractor extension; deprecation candidate.** Combines an LLM verdict (or stub) with structured accept/reject/partial_success routing. Tractor-only — not in the strongDM attractor spec, which uses codergen + diamond instead. See `docs/usage/validate-prompt.md` "Canonical Feedback Loop" for the spec-aligned alternative.

**Two modes via `judge_mode` attr:**
- `"llm"` (default): renders prompt, calls the configured `llm_provider`, parses the response for a `verdict` JSON object (`{"verdict": "accept|reject|partial_success", "critique": "..."}`).
- `"stub"`: deterministic pseudo-random verdict based on `(run_id, node_id, iteration)` and `reject_probability` — used to demo loops without spending tokens.

**Required attrs (LLM mode):** `llm_provider`, `prompt`.

**Optional attrs:** `llm_model`, `timeout`, `judge_mode`, `reject_probability`, `accept_critique`, `reject_critique`, `allow_partial`.

**Outgoing edges:** must cover exactly `accept` and `reject` conditions (or `accept`, `reject`, `partial_success` when `allow_partial=true`). Enforced by `judge_edge_cardinality` validator rule.

**Outcome:** the raw verdict response; updates carry `:status` with the verdict and the runner uses condition shorthand (`condition="accept"` etc.) to route.

**Why deprecation:** collapses validate-and-gate into one node, which forces 2-node feedback loops (`agent ↔ judge`) that trip the `two_way_edge` warning. The spec separates these concerns — see `docs/usage/validate-prompt.md`.

---

## `parallel` — handled inline in `Tractor.Runner`

No handler module. When the runner encounters a `parallel` node it transitions into a parallel-block state machine (`runner.ex:enter_parallel/2`):

1. Discover the structured block: branches that converge on a common `parallel.fan_in` node (validator's `discover_parallel_block/2`).
2. Clone the parent context per branch.
3. Schedule branches up to `max_parallel`.
4. As branches complete, write per-branch results into context under `parallel.results.<parallel_id>`.
5. When all branches complete, transition to the fan-in node.

**Required attrs:** none beyond standard. **Optional attrs:** `max_parallel` (1–16, default 1), `join_policy` (currently only `wait_all` supported).

**Validator constraints:** branches must currently be exactly one node (sprint-2 constraint, tracked as a follow-up). No `retry_target` on nodes inside parallel blocks. Fan-in must be unique per parallel node.

---

## `parallel.fan_in` — `Tractor.Handler.FanIn`

Consolidates per-branch results from `context["parallel.results.<parallel_id>"]`. Picks the "best" branch (success > partial_success > failed; tiebreak by score, then branch_id).

**Two modes:**
- **Pure consolidation:** no `llm_provider` set → returns a deterministic text summary of branches.
- **LLM consolidation:** `llm_provider` set → renders an LLM prompt with branch context (`{{branch:<id>}}` template substitutions, `{{branch_responses}}`) and invokes `Codergen.run/3` internally.

**Outcome:** the consolidated summary; updates put `parallel.fan_in.best_id`, `parallel.fan_in.best_outcome`, `parallel.fan_in.summary` into context.

**Validation warnings:**
- `agent_on_non_agent` fires if `llm_provider` is set on a fan_in (Moab opinion). For LLM-consolidating fan_ins this is technically a false positive — see `examples/parallel_audit.dot` for one. Worth revisiting if the Moab principle warnings get audited.

---

## Adding a new handler

1. Implement the `Tractor.Handler` behaviour in `lib/tractor/handler/<name>.ex`.
2. Register it in `Tractor.Runner.handler_for/1`.
3. Decide whether the handler maps to a shape — if so, add it to `Node.@shape_types` (`node.ex:58`) so DOT files can declare it via `shape=…` instead of explicit `type=…`.
4. Add validator rules for any new attributes the handler reads.
5. Cover with tests under `test/tractor/handler/<name>_test.exs`.

If your handler invokes an LLM, decide whether it should be in the validator's `agent_capable?` predicate (`validator.ex`) — that gates several handler-attribute discipline warnings.
