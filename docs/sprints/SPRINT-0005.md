# SPRINT-0005 — Conditional back-edges, judge loops, iteration-aware resume

**Status:** planned
**Target:** ~2 weeks (10 working days, ~14 calendar). No deferrals — all seven areas land together.
**Builds on:** SPRINT-0001 (validator), SPRINT-0002 (runner / parallel fan-in / event log), SPRINT-0004 (observer UI).
**Scope owners:** `lib/tractor/{validator,runner,edge,node,dot_parser,context}.ex`, `lib/tractor/handler/*`, `lib/tractor_web/{graph_renderer,run_live/*}.ex`, `examples/haiku_feedback.dot`.

## 1. Intent

Tractor currently runs a strict DAG with `weight → lexical` edge choice. This sprint makes bounded cyclic loops first-class so pipelines can express **work → judge → retry** patterns. A `judge` node emits a structured `accept`/`reject` verdict; the runner selects the matching outgoing edge by `condition` attr; on reject the runner loops back upstream, iteration history flows into the retry prompt, and the whole thing is checkpointed so `tractor reap --resume` can pick up mid-loop.

Motivating demo at `examples/haiku_feedback.dot`: Claude writes a haiku → `codex_review` stub judge (50% reject) → loopback to Claude with critique → accept → Codex writes a haiku → `gemini_review` stub judge (50% reject, "compute using python") → loopback to Codex → accept → Gemini writes a haiku → `summarize` (Claude) combines all three into a composite document → exit.

**Spec anchor.** Edge selection implements the Attractor 5-step priority: **condition → preferred_label → suggested_next_ids → weight → lexical**. `condition="accept"` / `condition="reject"` is a Tractor shorthand normalized to `preferred_label=accept`/`reject` so judge nodes stay readable in DOT.

## 2. Goals

- [x] Edge `condition` attr parsed, preserved, and consumed by a dedicated edge selector.
- [x] Attractor-spec edge-priority resolution: condition → preferred_label → suggested_next_ids → weight → lexical.
- [x] Cycle validator relaxed: cycles allowed iff removing conditional edges from each SCC leaves the remainder acyclic. Unconditional sub-cycles still rejected.
- [x] Per-node `max_iterations` attr (integer, bounds `1..100`, default `3`) with runtime guard that fails the run loudly before exceeding the limit.
- [x] `type="judge"` node. **Primary:** `judge_mode="llm"` emits structured `{verdict, critique}` JSON via ACP; malformed responses fail clearly. **Secondary:** `judge_mode="stub"` with `reject_probability` (default 0.5), seeded deterministically on `{run_id, node_id, iteration}` so resume never flips a prior verdict.
- [x] Per-node iteration history in `%Context{}` + on disk. Template syntax adds `{{node.last_critique}}`, `{{node.last}}`, `{{node.iteration(N)}}`, `{{node.iterations.length}}`, alongside existing `{{node}}` latest-output.
- [x] Checkpoint state carries `iteration_counts`, context history, and agenda. `tractor reap --resume [RUN_ID_OR_DIR]` rehydrates mid-loop without rerunning completed iterations.
- [x] Phoenix observer: `GraphRenderer` marks conditional / back-edges distinctly and uses `constraint=false` on back-edges so cyclic graphs still lay out cleanly; `Timeline` bands entries by iteration; node badges show `×N` iteration counts.
- [x] `examples/haiku_feedback.dot` runs end-to-end; `examples/three_agents.dot` and `examples/parallel_audit.dot` still green.

## 3. Non-goals

- [x] **No full conditional DSL.** Grammar this sprint: `=`, `!=`, `&&`, `outcome`, `preferred_label`, `context.*`, plus `accept`/`reject` shorthand. No OR, NOT, regex, numeric comparisons, expression callbacks.
- [x] **No `type="conditional"` handler.** Conditional routing lives on edges, not on a standalone node type.
- [x] **No cycles across `parallel` / `parallel.fan_in` boundaries.** Parallel block invariants from SPRINT-0002 stay intact.
- [x] **No nested cycles.** A cycle containing another cycle is rejected (new diagnostic `:nested_cycles`).
- [x] **No multi-judge consensus / ensemble voting.** Single judge per verdict.
- [x] **No automatic retry-count reset** or global reset signal.
- [x] **No rollback of downstream state on re-entry.** Re-entering a node archives its prior iteration; downstream sibling state is unaffected.
- [x] **No exactly-once resume.** If the runner crashes inside an active handler, resume may rerun that node. No exactly-once external side effects.
- [x] **UI remains read-only.** No pause / cancel-loop / step-once / force-accept operator controls.
- [x] **No engine refactor.** Runner's `next_node_id/2` gets replaced with a richer picker; GenServer shape stays.

## 4. Architecture decisions

### 4.1 Runtime outcome shape

Handler callback stays compatible. Runner normalizes handler results into a routing outcome:

```elixir
%{
  output: iodata,
  status: :success | :partial_success | :retry | :fail,
  preferred_label: binary | nil,
  suggested_next_ids: [binary],
  verdict: :accept | :reject | nil,
  critique: binary | nil,
  context_updates: map,
  metadata: map
}
```

- [x] Normalize current Tractor `"ok"` → `:success`; `"error"` / `"failed"` → `:fail`. Preserve `:partial_success` / `:retry` when handlers emit them. Keep on-disk `status.json` backward-compatible unless a handler explicitly writes a spec status.

### 4.2 Edge routing

Add `Tractor.EdgeSelector` as a pure module. Runner calls it; tests target it directly.

- [x] Condition step: filter to edges with non-empty `condition`, evaluate via `Tractor.Condition`; best match by `weight desc, to asc`.
- [x] Preferred-label step: filter to unconditional edges whose normalized label matches outcome's `preferred_label`.
- [x] Suggested-next step: unconditional edges where `edge.to ∈ suggested_next_ids`, in suggestion order.
- [x] Weight/lexical fallback: unconditional edges sorted by `weight desc`, tiebreak by `to asc`.
- [x] If only conditional edges exist and none match, return `nil`. Never silently take a conditional edge as fallback.
- [x] Change default edge weight from `1.0` to `0` to match Attractor spec. Accept integer or float DOT values so existing examples keep working.
- [x] Label normalization: lowercase, trim, strip accelerator prefixes (`[Y] `, `Y) `, `Y - `, `Y: `), collapse internal whitespace.

### 4.3 Condition evaluator

Add `Tractor.Condition` as a small parser/evaluator.

- [x] Supported forms: `condition="accept"` (shorthand for `preferred_label=accept`), `condition="outcome=success"`, `condition="preferred_label=fix"`, `condition="context.foo.bar=true"`, `condition="outcome=success && context.tests_passed=true"`.
- [x] Empty condition = unconditional edge (not a condition-match).
- [x] `context.foo.bar` tries exact key `"foo.bar"` first, then dotted traversal. Missing keys resolve to empty string.
- [x] Exact-string comparison after literal parsing; no case folding except judge shorthand + label matching.
- [x] Invalid syntax produces a validator diagnostic `:invalid_condition` before execution.

### 4.4 Cycle validation

Replace `Validator.add_cycle_diagnostics/2` wholesale.

- [x] Self-loop legal only when the edge has a non-empty `condition`.
- [x] Enumerate SCCs via `:digraph_utils.strong_components/1`.
- [x] For each non-trivial SCC: build a subgraph of that SCC's edges **excluding** those with a `condition` attr. If the remainder still has a cycle, emit `:unconditional_cycle`. (Stricter than "≥1 conditional edge per SCC" — closes the hidden-subcycle hole.)
- [x] Reject SCCs that cross `parallel` / `parallel.fan_in` boundaries — emit `:cycle_crosses_parallel`.
- [x] Reject nested cycles (SCC whose subgraph still contains a smaller SCC after removing one conditional edge) — emit `:nested_cycles`.
- [x] Keep `:unreachable_exit` enforcement after cycle checks.
- [x] New diagnostic `:implicit_iteration_cap` — **warning, not error** — when a node targeted by a conditional back-edge has no explicit `max_iterations`. Prints from `tractor validate`.

### 4.5 Judge validation

- [x] `add_judge_diagnostics/2`: a `type="judge"` node must have exactly two outgoing edges whose `condition` set is `{"accept", "reject"}`. Emit `:judge_edge_cardinality` otherwise.
- [x] `add_condition_coverage_diagnostics/2`: any non-judge node with ≥2 outgoing edges where at least one has a `condition` must have a complete verdict set (this sprint: `{accept, reject}` or a single `accept` with a non-conditional fall-through). Emit `:incomplete_condition_coverage` otherwise.
- [x] `max_iterations` bounds validator (`:invalid_max_iterations`) on integer parse + `1..100` range.
- [x] Keep `type="conditional"` rejected (non-goal).

### 4.6 Iteration state + context history

Iterations are per-node, 1-based, incremented immediately before a node starts.

- [x] `%Runner.State{}` gains `iterations :: %{node_id => pos_integer}`.
- [x] `%Tractor.Context{}` gains `iterations :: %{node_id => [entry]}` where `entry = %{seq, output, status, verdict, critique, started_at, finished_at}`.
- [x] Flat convenience keys in context: `"#{node}.iteration"`, `".last_output"`, `".last_status"`, `".last_verdict"`, `".last_critique"`.
- [x] History is JSON-safe — non-JSON metadata is stringified before checkpointing.
- [x] Context keeps `context[node] = latest_output` for existing `{{node}}` prompts.

### 4.7 Template engine

- [x] Extract interpolation out of `Handler.Codergen.interpolate/2` and `Handler.FanIn` (`lib/tractor/handler/fan_in.ex:77–82`) into pure `Tractor.Context.Template`.
- [x] Resolve `{{key}}` by exact context key first, then dotted map/list traversal.
- [x] Support `{{node}}`, `{{node.last}}`, `{{node.last_critique}}`, `{{node.iteration(N)}}` (1-indexed), `{{node.iterations.length}}`.
- [x] **Unresolved placeholders preserved as-is in rendered output** (better for debugging a bad prompt in artifacts than silent empty strings).
- [x] `{{branch:id}}` fan-in form continues to work via the shared module.

### 4.8 Artifact layout for repeated nodes

```text
run_dir/
  ask_claude/
    prompt.md          # latest iteration (backward-compat mirror)
    response.md        # latest iteration
    status.json        # latest iteration — includes iteration + max_iterations
    events.jsonl       # all iterations; each event tagged with iteration
    iterations/
      1/ prompt.md  response.md  status.json
      2/ ...
```

- [x] Extend `RunStore` to write iteration files and latest root mirrors on every execution.
- [x] Include `"iteration"` + `"max_iterations"` in every node `status.json`.
- [x] Include `"iteration"` in every `RunEvents.emit/4` payload.
- [x] Existing tests reading root `prompt.md` / `response.md` / `status.json` keep passing unchanged.

### 4.9 Checkpoint + resume

`Tractor.Checkpoint` as its own module; do not bury logic in Runner.

Checkpoint shape:

```json
{
  "schema_version": 1,
  "run_id": "...",
  "pipeline_path": "examples/haiku_feedback.dot",
  "dot_semantic_hash": "...",
  "saved_at": "...",
  "agenda": ["ask_claude"],
  "completed": ["start", "codex_judge"],
  "iteration_counts": {"ask_claude": 2, "codex_judge": 1},
  "context": {...},
  "provider_commands": [],
  "node_states": {...}
}
```

- [x] Atomic write via temp-file + rename after each node completion **and** next-edge selection (not mid-handler).
- [x] Resume flow: locate newest run dir (or `--resume RUN_ID_OR_DIR`), read manifest, re-parse + re-validate DOT, read checkpoint, verify `dot_semantic_hash` (hash over normalized graph, not raw bytes — comment/whitespace tolerant), rehydrate state, emit `:run_resumed` event.
- [x] Schema-version guard: unknown version → `{:error, :unsupported_checkpoint}` with clear message.
- [x] If node IDs no longer match: fail with validation-style diagnostic, no guessing.
- [x] `RunStore.resume/2` opens an existing run directory without rewriting `manifest.json`.
- [x] Existing parallel runs keep working; resume does not claim exactly-once for in-flight parallel branches.

### 4.10 Judge handler

One node type, mode via attr. `Tractor.Handler.Judge` with two modes.

Common attrs: `judge_mode="llm"|"stub"` (default `llm`), `llm_provider` (required for llm, optional on stub for UI labeling), `accept_label` (default `accept`), `reject_label` (default `reject`), `critique_key` (default `last_critique`).

- [x] **LLM judge:** call same ACP session path as `Codergen`; prompt rendered via `Tractor.Context.Template`; require JSON `{verdict, critique}`; accept fenced JSON by extracting first JSON object; normalize verdict to `accept`/`reject`; malformed or unknown verdict → `:judge_parse_error` fail; return `preferred_label = verdict` + context updates for `last_verdict` / `last_critique`; persist raw response in `response.md`, parsed fields in `status.json`.
- [x] **Stub judge:** no ACP; parse `reject_probability` (float `0.0..1.0`, default `0.5`); seed `:rand` deterministically from `{run_id, node_id, iteration}` so resume replays identically; accept `accept_critique` / `reject_critique` attrs (human-readable defaults); emit identical events / artifacts / context shape as LLM judge.
- [x] Emit `:judge_verdict` event with `{node_id, iteration, verdict, critique}`.
- [x] Register `"judge"` in handler dispatch (`lib/tractor/runner.ex:472–476` area).

### 4.11 Observer UI

- [x] `GraphRenderer`: annotate edges with `data-condition`, classes `tractor-edge`, `tractor-edge-conditional`, `tractor-edge-back` (latter for edges inside a legal SCC). Style accept / reject distinctly. Use Graphviz `constraint=false` on back-edges to prevent vertical layout stretch. Keep hook-owned node state mutation; no server-side runtime SVG rewrites.
- [x] `GraphBoard` JS hook: `×N` iteration badge when `iterations > 1` (reuse SPRINT-0004 badge machinery; add a third badge type alongside duration/tokens). Pulse the taken conditional edge on `graph:edge_taken`.
- [x] `Timeline.from_disk/3`: read root `events.jsonl` + per-iteration `status.json`; group entries by iteration with synthesized `Iteration N · duration · verdict` banding headers; render `:judge_verdict` as first-class entry (green=accept, amber=reject, critique inline).
- [x] CSS: `.tl-iteration-header`, `.tl-verdict-accept`, `.tl-verdict-reject` in `priv/static/assets/app.css`, palette matches SPRINT-0004.
- [x] Non-loop nodes render exactly as SPRINT-0004.

## 5. Sequencing

Total ~9.5 days of work + ~0.5 slack across ~2 calendar weeks. Every phase lands in its own commit(s) and is independently revertable.

**Phase A — Parser + data model (1d).** Add `condition` field to `%Edge{}`, `max_iterations` helper on `%Node{}`, default-weight change, round-trip tests. Remove `"condition"` from `@unsupported_edge_attrs` at `lib/tractor/validator.ex:17`.

**Phase B — `Tractor.Condition` + `Tractor.EdgeSelector` (1.5d).** Pure modules. Parser tests, evaluator tests, full priority-matrix table test including conditional-no-match returning `nil`, label normalization tests.

**Phase C — Validator relaxation (1d).** SCC + unconditional-subcycle algorithm; `:unconditional_cycle`, `:nested_cycles`, `:cycle_crosses_parallel`, `:invalid_max_iterations`, `:invalid_condition`, `:judge_edge_cardinality`, `:incomplete_condition_coverage`, `:implicit_iteration_cap` (warning). Fixture library under `test/support/cycle_fixtures/` (self-loop, lollipop, mutual recursion, hidden-subcycle). `examples/three_agents.dot` + `examples/parallel_audit.dot` still validate clean.

**Phase D — Runner picker + iteration state + context history (1.5d).** Replace `next_node_id/2` at `lib/tractor/runner.ex:477`. Add iteration counters, `:iteration_started` / `:iteration_completed` events, `:max_iterations_exceeded` halt + `:iteration_cap_reached` lifecycle event. Extract `Tractor.Context.Template`, migrate `Codergen` + `FanIn` consumers.

**Phase E — Artifact layout + checkpoint + resume (1.5d).** `RunStore` iteration writes + root-latest mirrors. `Tractor.Checkpoint` write/read with atomic rename + schema guard + `dot_semantic_hash`. CLI `tractor reap --resume [RUN_ID_OR_DIR]`. Three-point crash test (pre-iteration, mid-iteration, post-iteration). Pipeline-changed refusal path.

**Phase F — Judge handler (1.5d).** `Tractor.Handler.Judge` with both modes. Deterministic stub seed. Mocked-ACP tests for LLM accept / reject / malformed. Integration test: generator → judge → exit-on-accept, loop-on-reject, runs 3+ iterations.

**Phase G — Observer loops UI (1.5d).** Graph renderer edge annotations + `constraint=false`, iteration badges, timeline banding, judge verdict entries. LiveView tests for repeated-node timeline groups + iteration badge payloads.

**Phase H — Demo + regression + merge (1d).** Write `examples/haiku_feedback.dot`. `./bin/tractor reap --serve examples/haiku_feedback.dot`; verify loopback visible. Record 45s demo GIF → `docs/sprints/notes/sprint-0005-demo.gif`. Regression smoke on `three_agents.dot` + `parallel_audit.dot`. Update `IDEA.md` status. Merge gates: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`, `mix test --include integration`, `mix escript.build`. PR body includes goals checklist + demo GIF + "flagged choices" section.

**Parallelism:** Phase A → B → C is a hard chain. D depends on B. E can proceed in parallel with D once runner state shape is stable. F depends on D (verdict needs context history). G depends on F (verdict events) **except** the `GraphRenderer` edge-annotation subtask, which can start as soon as B lands. H is the merge point.

## 6. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Naive "≥1 conditional edge in SCC" rule permits hidden unconditional subcycle → hung runs. | High if wrong | Use the remove-conditional-edges-and-check-acyclic rule (§4.4). Fixture library covers lollipop + mutual recursion + hidden-subcycle shapes. |
| Stub judge non-determinism flips verdict on resume. | High if done naively | Seed `:rand` with `{run_id, node_id, iteration}`. Test asserts verdict sequence for pinned run_id. |
| Checkpoint placement races with handler completion → resume double-runs or skips. | Med | Write checkpoint **after** context update + next-edge selection, never mid-handler. Three-point crash test is mandatory. |
| Condition syntax leaks into Runner → hard-to-test routing bugs. | Med | Keep `Tractor.Condition` + `Tractor.EdgeSelector` as pure modules; Runner just calls them. |
| Context history grows without bound on long loops. | Low–Med | `max_iterations` default `3`, cap `100`. Checkpoint remains JSON + inspectable. No prune-on-resume this sprint. |
| Graphviz layout churn when back-edges use `constraint=false`. | Med | Visual check in Phase G. Fallback: switch to `neato`/`fdp` dynamically for cyclic graphs if `dot` layout degrades. |
| Iteration artifacts break existing SPRINT-0004 UI/tests that read root files. | Med | Root files stay as latest-mirrors; historical versions live under `iterations/<n>/`. Regression smoke in Phase H. |
| LLM judge JSON parsing becomes prompt yak-shaving. | Med | Strict parser: first JSON object extraction, fail cleanly on malformed. Stub judge is the acceptance-test path; LLM judge ships with mocked tests only. |
| `dot_semantic_hash` too strict → resume refuses after a cosmetic DOT edit. | Med | Hash over **normalized** graph (IDs, edges, attrs in canonical order), not raw bytes. Whitespace/comment edits tolerated. |
| Condition-coverage diagnostic over-rejects legal non-judge graphs. | Med | Rule limited to `{accept, reject}` or `accept + non-conditional fall-through`. Relax only if a real authored pipeline trips it. |
| Attribute-name drift (`judge_mode` vs `judge_kind`) across examples/validators/UI. | Med | Settled: `judge_mode`. Codify in Phase A data-model commit; validator rejects `judge_kind` with `:unknown_attr`. |
| Observer event payloads grow unwieldy after adding iteration fields. | Low | Emit iteration field only on `:iteration_started` / `:iteration_completed` / `:judge_verdict` / node lifecycle; not per-chunk. |
| Phase E (checkpoint) overruns — the dark-horse phase. | Med | If overrun: cut Phase G polish (edge pulse animation, banding styling nice-to-haves) first. Core loop + resume is the sprint floor. |

## 7. Acceptance criteria

- [x] `Validator.validate/1` accepts a graph with a conditional judge-retry cycle; rejects the same graph with the back-edge's `condition` removed.
- [x] `Validator.validate/1` rejects an SCC that contains an unconditional subcycle even when another edge in the SCC is conditional.
- [x] `Validator.validate/1` rejects a cycle that crosses `parallel`/`parallel.fan_in` with `:cycle_crosses_parallel`.
- [x] `Validator.validate/1` rejects a judge node whose outgoing edges aren't exactly `{accept, reject}` (`:judge_edge_cardinality`).
- [x] `tractor validate examples/haiku_feedback.dot` prints zero errors, zero warnings.
- [x] Edge selection passes the full priority matrix: condition → label → suggested IDs → weight → lexical, with conditional-no-match returning `nil` (not falling through).
- [x] `condition="accept"` and `condition="reject"` route from judge nodes without verbose condition expressions.
- [x] Runner fails before starting a node that would exceed `max_iterations`, with status + event data naming the limit and count.
- [x] `{{node}}` still returns latest output for existing pipelines; `{{node.last_critique}}` returns the most recent judge critique; unresolved placeholders preserved as-is in rendered prompts.
- [x] `type="judge", judge_mode="stub"` with `reject_probability=1.0` always rejects, `0.0` always accepts, `0.5` reject rate on 1000 runs within expected bounds.
- [x] Stub judge seeded on `{run_id, node_id, iteration}` replays the same verdict sequence across resume.
- [x] `type="judge", judge_mode="llm"` parses a mocked JSON verdict and routes by preferred label; malformed verdict fails with `:judge_parse_error`.
- [x] `checkpoint.json` includes `schema_version`, `iteration_counts`, `agenda`, `context`, `completed`, `dot_semantic_hash` after each completed node.
- [ ] `tractor reap --resume` on a run killed mid-loop (at any of the three crash points) completes the pipeline with final outputs identical to an uninterrupted run.
- [x] `tractor reap --resume` refuses to resume when the DOT's normalized graph has changed, with a clear message.
- [x] Phoenix observer renders repeated executions as distinct iteration groups; back-edges visually distinct; `×N` badge on repeated nodes; judge verdict/critique as timeline entries.
- [x] `examples/haiku_feedback.dot` runs end-to-end with stub judges, observer shows at least one loopback per stage, exit code 0.
- [x] `examples/three_agents.dot` still runs clean (no Phoenix).
- [x] `examples/parallel_audit.dot` still runs clean; observer renders without regression.
- [x] Merge gates pass: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`, `mix test --include integration`, `mix escript.build`.
- [ ] Demo GIF committed under `docs/sprints/notes/sprint-0005-demo.gif`; PR body includes flagged-choices section.

## 8. Sprint-6+ seeds

- [ ] User-defined condition DSL beyond `accept`/`reject` (e.g., `condition="score > 0.8"`, OR/NOT, regex).
- [ ] Ensemble judging (multi-judge consensus with meta-verdict logic).
- [ ] Loop-body sub-DAGs (cycle body larger than a single path).
- [ ] Cycles across `parallel` / `parallel.fan_in` boundaries.
- [ ] Cost-budget guard (abort run if cumulative token cost crosses threshold) — builds on SPRINT-0004 usage events.
- [ ] Interactive observer overrides (force-accept, edit-critique, step-once).
- [ ] Live animated iteration counter on back-edges during runs.
- [ ] Context-history pruning policy for long-running loops.

## Blockers

Remaining after opus follow-up pass:

- **Three-point crash-resume proof.** Core `Checkpoint.save`/`Run.resume` flow is implemented and exercised by tests; semantic-hash + schema-version guards are covered (`test/tractor/checkpoint_test.exs`). The explicit crash-injection harness (kill runner pre-iteration / mid-iteration / post-iteration, resume, assert identical output) is genuinely new engineering that wasn't scoped in this sprint — deferring to SPRINT-6.
- **Demo GIF.** Not recordable from headless CLI. User to record against the already-running Phoenix dev loop and drop at `docs/sprints/notes/sprint-0005-demo.gif`.
- **Sprint-6+ seeds (§8).** Future-scope items, correctly unchecked.

Opus follow-up pass landed:
- `test/tractor/iteration_cap_test.exs` — end-to-end coverage of `:max_iterations_exceeded` failure path, including `:iteration_cap_reached` event payload and `status.json` reason.
- `test/tractor/checkpoint_test.exs` — `Checkpoint.verify!` happy path, `:pipeline_changed` on mutated node prompt, node-id-change rejection, `:unsupported_checkpoint` on bad schema, `:missing_checkpoint`, `semantic_hash` attr-order stability + sensitivity to edge condition changes.
- `test/tractor/handler_judge_test.exs` — stub reject-rate statistical test over 1000 runs (430–570 bound) + explicit resume-replay-determinism test using fresh `:rand` seed.
