# `validate-prompt`

Design guidance for Tractor `.dot` pipelines. Use this when authoring or reviewing a pipeline so it passes `tractor validate` and avoids the design mistakes Tractor warns about.

This document is for *design*. For syntax, attributes, and grammar, see `pipeline-reference.md`. For canonical loop topologies, see `loop-patterns.md`. Both live in this directory.

## The Goal

Every pipeline should declare a concise `goal` on the graph:

```dot
digraph {
  graph [goal="Make mosort pass all GCSORT test cases except the three Not Supported features"]
  ...
}
```

The goal is the single load-bearing constraint every node sees. It surfaces in the observer, in the run manifest, and — once the feature ships — in prompts via the `{{goal}}` template variable. Keep it concise: one sentence stating what done looks like, plus an EXCLUDED clause if there are explicit out-of-scope items.

```
Make mosort pass all GCSORT test cases.
Quality bar: byte-for-byte identical output through mosort.
EXCLUDED: NS-1 (IX/ISAM), NS-2 (SQMF), NS-3 (E15/E35 exits).
```

A verbose `goal` is a footgun — every agent treats it as a to-do list. Detailed specs and step-specific instructions belong in node prompts, not in the goal.

## Spec Expansion (when there's no spec yet)

If the request is vague — "port this to Elixir," "make tests pass," "build a renderer" — and there is no concrete written specification, add a single codergen node at the very start of the pipeline whose only job is to produce a written spec document (e.g. `{{run_dir}}/SPEC.md`) with verifiable requirements. Every downstream prompt then references that file.

This turns "we don't really know what done looks like" into something the implement/test loops can converge on. Without it, reviewers have nothing concrete to verify against and feedback loops drift indefinitely.

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
- `judge` *(tractor extension; deprecation candidate — see "Canonical feedback loop" below)*
- `parallel`
- `parallel.fan_in`

If you set both `type` and `shape`, they should agree. Tractor warns when they disagree.

## Canonical Feedback Loop (3-node pattern)

The strongDM attractor spec separates **validation** (an LLM call that produces a verdict) from **adjudication** (a routing decision based on that verdict). The canonical pattern is three nodes:

```
agent → reviewer (codergen, has prompt) → gate (diamond, no prompt) → agent / next
```

The reviewer's prompt asks the LLM to emit a structured verdict (e.g. `VERDICT: accept` or `VERDICT: reject`). The gate is a `conditional` (diamond) node with no prompt — it routes based on edge conditions that `contains`-match the reviewer's response:

```dot
reviewer -> gate
gate -> agent     [condition="context.reviewer.last_output contains \"VERDICT: reject\""]
gate -> next_step [condition="context.reviewer.last_output contains \"VERDICT: accept\""]
```

The context key is `<node_id>.last_output` (set by the runner; see `pipeline-reference.md` "Run Context"). `examples/haiku_feedback.dot` is the reference. For the full prompt templates and a worked example, see `loop-patterns.md` Pattern 1.

The `judge` handler collapses reviewer-and-gate into a single node. It triggers `two_way_edge` warnings because a single-node loop short-circuits the spec's separation of concerns. Prefer the 3-node pattern.

## Prompt Design Principles

These are the load-bearing rules for prompt content. They apply to every codergen node, especially nodes inside loops.

**Lead with `{{goal}}`.** The first line of every prompt should be `{{goal}}` (or, until the feature ships, repeat the goal text inline). Every agent needs to know the constraint it's operating under.

**Role first.** Open with what the agent is: "You are an implementation engineer," "You are a verification engineer." Sets behavioral expectations and what the agent is NOT supposed to do.

**Context before task.** Reference materials, prior-feature outputs, file paths, and other context come *before* the task description.

**Requirements as numbered lists.** Each requirement becomes an item the reviewer can verify. "Handle edge cases" is not a requirement; "Return error on empty input, nested quotes, and UTF-8 multibyte characters" is.

**Output format and checklist last.** LLMs weight the end of the prompt most heavily. A pre-completion checklist there is the single strongest influence on final behavior.

```
PRE-COMPLETION CHECKLIST:
[ ] Every requirement above is implemented
[ ] No TODOs, FIXMEs, or placeholders remain
[ ] Tests pass
[ ] All changes are committed
```

**Loop-aware prompts.** A node inside a loop runs every iteration. The implementor's prompt must handle both first-visit (build from scratch) and subsequent visits (read the reviewer's last critique and fix). Make the iteration-mode check explicit:

```
Previous reviewer critique (empty on first visit): {{review.last_output}}

If a critique exists above, this is a fix iteration: read it carefully and address every issue.
If empty, this is your first visit: implement from scratch.
```

Tractor leaves unresolved placeholders verbatim, so an empty `{{review.last_output}}` literally renders as `{{review.last_output}}` in the prompt. Tell the agent to treat that as "first visit."

**Anti-gaming clauses.** Agents will take shortcuts unless told not to. Include these in implementation prompts:

```
- Do NOT weaken, skip, or remove any requirement to make it pass.
- Do NOT defer any item as "minor" or "needs its own effort."
- Do NOT modify code outside this feature's scope unless necessary for integration.
```

**Pareto-optimal review.** Reviewer prompts must say "FAIL only on issues that materially affect correctness, completeness, or quality. Do not fail over minor stylistic, cosmetic, or trivial issues." Without this, audit loops nit-pick endlessly.

**Inter-node artifacts via `{{run_dir}}`.** When a downstream node consumes a structured artifact from an upstream one (test report, audit document, spec), write it to a path under `{{run_dir}}/` and have the consumer read it explicitly. Output in plain prompt context (`{{node.last_output}}`) is fine for short signals like a verdict line; full reports belong on disk.

**No memory between iterations.** Tractor doesn't currently maintain agent session memory across iterations. Each invocation is fresh — the prompt must be self-contained and reference everything it needs explicitly.

## Common Failure Modes

Patterns that go wrong in practice. Check for these during review.

**Reviewer too lenient.** Test passes quickly but downstream consumers find gaps. → Tighten the reviewer prompt with strict structured output and per-requirement evidence. Reviewer's job is to enumerate the same requirements as the implementor and verify each.

**Reviewer too strict (nit-picking).** Loop never converges because the reviewer flags trivial issues. → Add the Pareto-optimal clause. If trivial findings remain, the work is done.

**Implementor weakens the spec to pass.** Test passes after the implementor "skipped" or "removed" failing cases. → Anti-gaming clauses in the prompt. Cap exclusions explicitly. Have a separate auditor verify the test count hasn't shrunk.

**Implementor never sees the critique.** Loop spins because the implementor treats every iteration as first-visit. → Make sure the implementor's prompt references `{{<reviewer>.last_output}}` and explicitly handles the "critique present" case.

**Loop exhausts iteration budget.** Hits `max_iterations` without converging. Either requirements are ambiguous (two reasonable agents disagree on what "correct" means), the implementor isn't getting actionable critique, or the test/review is checking against later-phase requirements. → Review requirements for ambiguity. Keep features small (~7 requirements). Verify scope of every prompt.

**Two-way edge between work and validation.** `implement ↔ review` without a diamond gate is the validator's `two_way_edge` warning. → Always route validation through a `diamond`. The implementor must not directly receive a "fail" signal from a node that also produces work.

**Diamond with no matching condition at runtime.** A gate's outgoing edges all evaluate false → run fails with "no matching edge." → Always have either a fallback unconditional edge, or conditions that exhaust the cases (e.g. `contains "accept"` and `contains "reject"`).

**Audit loop fix routes back to fan-out, not preparer.** Reviewers see stale evidence on the next cycle. → Fix loops back to the preparer; preparer regenerates evidence; fan-out restarts with fresh state.

**Tool node where a codergen would do.** Direct shell commands can't diagnose, retry, or repair. → Use a codergen node that runs the command and reasons about the output. Reserve `tool` for genuinely deterministic gating (file-existence checks, mechanical transformations).

**Human gate left in production.** `wait.human` makes the pipeline non-autonomous. → Replace with a codergen node + verifier loop unless the operator-in-the-loop is the actual design intent.

## Authoring Guidance

Use `codergen` for LLM-backed work — both generation and review steps. It's the only node family Tractor treats as agent-capable for new pipelines. `judge` remains agent-capable for now but is on a deprecation path.

Use `tool` only when a direct shell command is the right abstraction. Tool nodes run commands directly and do not get the same prompt-driven diagnosis and repair behavior as agent-capable nodes.

Use `wait.human` only for development-time debugging or explicit operator checkpoints. Production pipelines should avoid human gates.

Use `parallel` for fan-out routing and `parallel.fan_in` for join behavior. Do not treat them as generic agent nodes during validation.

When a pipeline has multiple distinct phases, separate them with audit gates. Per-feature Implement/Test loops catch most issues; a phase-level Audit/Fix loop at the end of a phase catches integration issues that per-feature tests miss. See `loop-patterns.md`.

## Prompt And Attribute Rules

Prompts belong on `codergen` (and `judge`) nodes. Diamond gates must NOT have a prompt — they are pure routing. Tractor warns when a `tool` node has a `prompt`.

Commands belong on `tool` nodes. Tractor warns when `command` appears on a non-tool node.

`goal_gate=true` only makes sense on `codergen` (and `judge`) nodes.

`llm_provider` and `llm_model` only make sense on `codergen` (and `judge`) nodes.

`timeout` should not be used on instant-routing nodes: `start`, `exit`, `conditional`, and `parallel`.

`allow_partial=true` only helps when effective `retries` is greater than zero.

`retry_target` and `fallback_retry_target` should point at existing non-terminal nodes outside parallel blocks.

`max_iterations` defaults to 3 — bump it to 10 or 20 for real implementation loops, otherwise the loop runs out of budget before converging.

## Design Principles

**Autonomous by default.** Tractor warns on every `wait.human` node because autonomous pipelines are the design target. Add human gates only for development-time debugging or for operator-checkpointed external actions.

**Prefer agent-capable nodes over tool nodes** when the step may need diagnosis, retry strategy, or iterative repair.

**Avoid two-way edges between the same pair of nodes.** They are usually a malformed review loop and often imply a node is validating its own work. The spec-aligned alternative is the three-node pattern in "Canonical Feedback Loop" above.

**Do not design a loop where the same node both produces work and validates that work.** Separate generation, review, and repair responsibilities.

**YAGNI ruthlessly.** More nodes = more tokens = more failure surface. Implement/Test loops are not subject to YAGNI when verification matters — they are the default. Everything else needs to earn its keep.

## Review Checklist

Before shipping a pipeline, check that:

- the `goal` graph attribute is set, concise, and includes any EXCLUDED clauses
- every LLM-backed node uses one of `claude`, `codex`, or `gemini`
- every prompt is on a `codergen` or `judge` node, and starts with `{{goal}}`
- every prompt has a pre-completion checklist (for implementation/fix nodes) or a structured-output requirement (for reviewer/audit nodes)
- reviewer prompts include the Pareto-optimal clause
- implementation prompts include anti-gaming clauses
- implementor prompts inside loops handle both first-visit and fix-iteration explicitly
- every loop terminates: `max_iterations` is set deliberately, not left at the default 3
- every shell command is on a `tool` node — and if it could be a codergen, that's almost always the better choice
- no `wait.human` node is required for normal production execution
- no pair of nodes has edges in both directions unless the loop is deliberate and defensible (i.e. routes through a diamond gate)
- every diamond has a guaranteed-matching outgoing edge (either fallback unconditional or exhaustive conditions)
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
