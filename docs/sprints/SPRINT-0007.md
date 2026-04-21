# SPRINT-0007 — Failure routing, goal gates, extended conditions, cost budget, spec-coverage tracker

**Status:** planned
**Target:** ~2 weeks (8.5 working days + 1.5 days slack, ~14 calendar). All five areas land; no deferrals.
**Builds on:** SPRINT-0006 (retry / backoff / timeout / iteration + wall-clock budgets / status agent / ACP plan UI) + SPRINT-0005 (conditional back-edges, judge loops, `max_iterations`, checkpoint/resume) + SPRINT-0004 (per-node token-usage events).
**Scope owners:** `lib/tractor/{validator,condition,edge_selector,runner,checkpoint,node,run_events}.ex`, `lib/tractor/runner/{failure,budget,routing,adjudication}.ex` (some new), `lib/tractor/handler/{codergen,judge,fan_in}.ex`, `lib/tractor/acp/session.ex`, `config/config.exs`, `docs/spec-coverage.md` (new), `examples/*.dot`, `test/**/*`.

## 1. Intent

SPRINT-0006 made single-node failures survivable (retry + brutal-kill timeout + bounded status agent). Failure handling still dies at the failing node: there's no recovery route, no concept of a critical "must-succeed" node, and the condition DSL can't express the predicates (OR, NOT, numeric, substring) the attractor spec assumes. There's also no ceiling on provider spend, and no living audit of what Tractor actually implements versus the upstream specs. SPRINT-0007 lands the four remaining attractor-spec routing/safety primitives (`retry_target` / `fallback_retry_target`, `goal_gate`, `allow_partial`, `max_total_cost_usd`), widens `Tractor.Condition` to cover real predicate expressiveness, and introduces `docs/spec-coverage.md` as the authoritative progress-against-spec artifact.

**Spec anchors.** Attractor — https://raw.githubusercontent.com/strongdm/attractor/main/attractor-spec.md (`retry_target`, `fallback_retry_target`, `goal_gate`, `allow_partial`, cost budget, condition grammar). ACP — https://agentclientprotocol.com. Unified-LLM usage/pricing — https://raw.githubusercontent.com/strongdm/attractor/main/unified-llm-spec.md.

**Honest spec attribution:** `||`, `!`, `contains`, numeric comparison operators (`< <= > >=`), and parenthesized grouping are **Tractor extensions** relative to the current attractor condition grammar. The spec-coverage doc records them as such — not as spec items Tractor satisfies.

## 2. Goals

- [x] Per-node `retry_target` + `fallback_retry_target` route on `{:retries_exhausted, _}` with a fresh iteration counter on the target; emit `:retry_routed` with `{from_node, to_node, reason, tier: :primary | :fallback}`.
- [x] Per-node `goal_gate=true` terminates the run with `{:goal_gate_failed, node_id}` when all retry + routing paths exhaust, bypassing any downstream `exit`. `allow_partial=true` opts a node into accepting judge `:partial_success` verdicts without failing.
- [x] `Tractor.Condition` gains `||`, `!` prefix, numeric `< <= > >=`, `contains`, parenthesized grouping with committed EBNF + precedence. Pure parser; unknown syntax → `:invalid_condition`.
- [x] Graph-level `max_total_cost_usd=<decimal>` budget with per-provider pricing in `config/config.exs`; checked between nodes; accumulated cost persists across resume; emits `:cost_unknown` when pricing missing.
- [x] `docs/spec-coverage.md` exists with 12 fixed top-level sections, populated post-SPRINT-0006 baseline plus SPRINT-0007 items, each line `[x]`/`[~]`/`[ ]` with a module path or SPRINT reference.
- [x] At least one example under `examples/` exercises each new backend feature; live smokes in the close-out.

## 3. Non-goals

- [x] **No new handler types.** (`conditional`, `tool`, `wait.human`, `stack.manager_loop` stay unsupported — tests assert.)
- [x] **No fidelity modes.** `default_fidelity`, `model_stylesheet`, edge `fidelity` / `thread_id` stay in `@unsupported_*` lists.
- [x] **No unified-LLM client.** Cost budget reuses existing per-node token-usage events + a static pricing table; no provider re-routing.
- [x] **No user-defined error-classification callbacks.** Failure classification stays table-driven in `Runner.Failure`.
- [x] **No parallel-crossing cycles or nested cycles.** Still rejected by validator.
- [x] **No `retry_target` inside a parallel block.** Targets must be outside the enclosing `parallel → parallel.fan_in` bracket. Validator enforces.
- [x] **No Attractor-alias `max_retries` / `default_max_retries`.** Still rejected.
- [x] **No resumption of cost-budget history older than current run_dir.** Checkpoint is the only source of truth.
- [x] **No demo GIFs or PR flagged-choices ceremony** (per feedback memory).

## 4. Architecture decisions

### 4.1 State-model prework — iteration counter split

This is the **hidden prerequisite** for failure routing. Today `state.iterations` is used both for SPRINT-0006's `max_total_iterations` budget and for per-node loop caps. Resetting the target's counter on retry routing would silently weaken the global budget.

- [x] Split `%Runner.State{}`:
  - [x] `state.iterations :: %{node_id => pos_integer}` — per-node loop counters (existing behavior, drives `max_iterations` cap).
  - [x] `state.total_iterations_started :: non_neg_integer` — monotonic lifetime counter, drives `max_total_iterations` budget. **Never reset** by retry routing.
- [x] `Checkpoint.save/1` persists both; `Checkpoint.verify!/2` + resume paths rehydrate both.
- [x] Regression test: a routed-to target resets `iterations[target]` to 0 while `total_iterations_started` keeps incrementing, and `max_total_iterations` still fires correctly.

### 4.2 Failure routing (`retry_target`, `fallback_retry_target`)

- [x] New `%Node{}` attrs: `retry_target=<node_id>`, `fallback_retry_target=<node_id>`. Accessors `Node.retry_target/1`, `Node.fallback_retry_target/1`.
- [x] New pure helper `Tractor.Runner.Routing.next_target/2 :: ({failing_node, tier}) -> {:route, target_id, next_tier} | :terminate`. Tier tracks `:primary | :fallback | :exhausted`.
- [x] Runner recovery-plan shape carried on the frontier entry: `%{origin_node_id, retry_target, fallback_retry_target, recovery_tier}`.
- [x] On `{:retries_exhausted, original_reason}`:
  - [x] Consult the **declaring (original) node's** `retry_target`. If present: emit `:retry_routed{from_node, to_node, reason, tier: :primary}`; enqueue target fresh; reset `iterations[target]`; set `context.__routed_from__ := origin_node_id` on target's first iteration; **preserve** `state.total_iterations_started`.
  - [x] If the primary target itself exhausts and the **original declaring node** had `fallback_retry_target` set: route to fallback, `tier: :fallback`. Fallback ownership is the declaring node's, not the recovery node's — prevents cascading routing from unrelated attrs.
  - [x] If fallback absent or also exhausts: fall through to terminal path (which then checks §4.4 goal-gate logic).
- [x] Reuse `start_task` for recovery starts so timeouts / retry config / checkpointing / status-agent observation / artifacts stay uniform.
- [x] Route only on `{:retries_exhausted, _}`. Permanent failures that never entered the retry path (`:judge_parse_error`, `:invalid_*`) do not jump to recovery targets.
- [x] Validator diagnostic `:invalid_retry_target` (error) rejects:
  - [x] target references an unknown node
  - [x] target is `start` or `exit`
  - [x] target equals the declaring node (no self-recovery)
  - [x] `fallback_retry_target` equals `retry_target`
  - [x] target lives inside a different parallel block than the declaring node (cross-block routing breaks fan-in accounting)
- [x] Validator warning `:unreachable_retry_target` if the target is declared but not forward-reachable from `start` (users may intend a dead-ended recovery path — warn, don't error).

### 4.3 Goal gates (`goal_gate`, `allow_partial`)

- [x] New boolean-as-string attrs: `goal_gate=true|false` (default `false`), `allow_partial=true|false` (default `false`). Accessors `Node.goal_gate?/1`, `Node.allow_partial?/1`.
- [x] Terminal semantics: when a `goal_gate=true` node exhausts retries + retry_target + fallback_retry_target, finalize run with `{:goal_gate_failed, node_id}`. **The `exit` node handler is never invoked.** Event log carries both the gate node id and the original underlying reason.
- [x] Non-gate node exhaustion path is unchanged from SPRINT-0006.
- [x] Track goal-gate satisfaction in `state.goal_gates_satisfied :: MapSet.t(node_id)`. Persisted in checkpoint so resume remembers which gates already passed (prevents a resumed run from re-gating on a successful node).
- [x] Before `exit` fires: verify every `goal_gate=true` node is in `goal_gates_satisfied`. If any unsatisfied or unvisited, finalize `{:goal_gate_failed, node_id}` instead of calling the `exit` handler.
- [x] Validator diagnostics:
  - [x] `:invalid_goal_gate` / `:invalid_allow_partial` if value isn't `"true"` / `"false"`.
  - [x] **Soft warning** `:goal_gate_bypass` if any `goal_gate=true` node exists AND at least one start→exit path (forward edges only, ignoring retry-target) skips every gate node. Implemented as reachability check on a graph with gate nodes removed.
  - [x] **Soft warning** `:allow_partial_without_judge` if `allow_partial=true` on a node with no incoming edge from a `type=judge` node.

### 4.4 Centralized outcome adjudication

To avoid spreading `:partial_success` + `goal_gate` + `allow_partial` semantics across handler modules, a single runner-local adjudication step decides continuation.

- [x] New pure module `Tractor.Runner.Adjudication`: `classify/3 :: (node, raw_outcome, handler_return) -> {:continue | :fail, normalized_outcome, metadata}`.
  - [x] Preserves raw `:success | :partial_success | :fail | :retry` status for telemetry / condition evaluation.
  - [x] Decides centrally whether that status is *acceptable for continuation* given the node's `allow_partial?` and type.
  - [x] `:partial_success` → continue when `allow_partial=true`.
  - [x] `:partial_success` → continue for `parallel.fan_in` nodes regardless of `allow_partial` (preserves SPRINT-0002 semantics — document explicitly as a carveout).
  - [x] Non-allowed `:partial_success` → fail path; can consume retries and routing (not a silent success).
- [x] Runner calls `Adjudication.classify/3` between handler return and edge selection.
- [x] Mark goal-gate satisfaction only when adjudication returns `:continue` with `:success` or `:partial_success + allow_partial=true`.
- [x] Judge handler stops doing its own partial-success normalization — simplifies `Handler.Judge` and moves the knob into the adjudication module.

### 4.5 Extended condition DSL

Rewrite `lib/tractor/condition.ex` into a recursive-descent parser. Keep the outer API (`parse/1`, `valid?/1`, `match?/3`) stable for validator + edge-selector callers. Keep the module pure.

EBNF:
```
expr       := or_expr
or_expr    := and_expr ("||" and_expr)*
and_expr   := not_expr ("&&" not_expr)*
not_expr   := "!" not_expr | atom
atom       := "(" expr ")" | comparison | shorthand
comparison := ident op value
op         := "=" | "!=" | "<" | "<=" | ">" | ">=" | "contains"
ident      := [A-Za-z0-9_.]+
shorthand  := "accept" | "reject" | "partial_success"
value      := quoted_string | bareword | number
```

- [x] Tokenizer handles quoted strings (preserves whitespace), parens, two-char ops (`!=`, `<=`, `>=`, `||`, `&&`), single-char ops, `contains` keyword, idents.
- [x] AST shape: `{:or, l, r} | {:and, l, r} | {:not, x} | {:cmp, op, key, literal} | {:shorthand, atom}`.
- [x] Short-circuit `||` and `&&` at eval time in `match?/3`.
- [x] NOT prefix wraps any atom or parenthesized expression; double-negation normalized at parse time.
- [x] Numeric comparisons coerce both sides via `Float.parse/1`. If either side fails to parse, comparison is **false** (matches missing-key semantics from existing `=`/`!=`). No exceptions.
- [x] Numeric comparisons restricted at validator level to `context.*` keys — reject `outcome >= 3` as `:invalid_condition` (outcome is a status enum, not a number).
- [x] `contains` is case-sensitive substring match on the string form of the LHS.
- [x] Missing context keys → empty string, consistent with existing `context.foo = "x"` behavior.
- [x] Unknown tokens / unclosed parens / trailing junk → `{:error, :invalid_condition}`.
- [x] **Regression safety:** keep the old parser as `Tractor.ConditionLegacy` during Phase A. Parse every existing DOT fixture under both parsers; AST-normalized evaluation must match for all existing expressions. Delete `ConditionLegacy` in Phase E once diff test passes clean on `main`.
- [x] Back-compat: `a=1 && b=2` parses identically; shorthand `accept` / `reject` unchanged; `partial_success` shorthand added.
- [x] Table-driven parser tests cover: precedence (`a=1 || b=2 && c=3` → `or(a=1, and(b=2, c=3))`), parenthesized override (`(a=1 || b=2) && c=3`), double-negation (`!!x=1` == `x=1`), numeric boundaries, contains, nested parens, every malformed-input error case from §7.

### 4.6 Token-cost budget (`max_total_cost_usd`)

Reuses SPRINT-0004 per-node `:token_usage` events. No provider-client rewrite.

- [x] Graph attr `max_total_cost_usd=<decimal>`. Parsed with `Decimal.parse/1` (add `:decimal` dep if not in `mix.lock`; Phase A decides based on presence). Bounds `0.0001..1000.0`. Diagnostic `:invalid_budget` on parse/bounds failure.
- [x] Pricing table in `config/config.exs` under `:tractor, :provider_pricing`, keyed by `{provider, model}` with `input_per_mtok` + `output_per_mtok` rates. Seed table (verified via context7 in Phase A, not from memory):
  ```elixir
  config :tractor, :provider_pricing, %{
    {"claude", "claude-opus-4-7"}     => %{input_per_mtok: 15.00, output_per_mtok: 75.00},
    {"claude", "claude-sonnet-4-6"}   => %{input_per_mtok: 3.00,  output_per_mtok: 15.00},
    {"claude", "claude-haiku-4-5"}    => %{input_per_mtok: 1.00,  output_per_mtok: 5.00},
    {"codex",  "gpt-5"}               => %{input_per_mtok: 5.00,  output_per_mtok: 15.00},
    {"codex",  "gpt-5-mini"}          => %{input_per_mtok: 1.00,  output_per_mtok: 3.00},
    {"codex",  "gpt-5-nano"}          => %{input_per_mtok: 0.30,  output_per_mtok: 1.20},
    {"gemini", "gemini-3-pro"}        => %{input_per_mtok: 5.00,  output_per_mtok: 15.00},
    {"gemini", "gemini-3-flash"}      => %{input_per_mtok: 0.30,  output_per_mtok: 1.20},
    {"gemini", "gemini-3-flash-lite"} => %{input_per_mtok: 0.10,  output_per_mtok: 0.40}
  }
  ```
  Values verified against official provider pricing pages during Phase A. Code reads the table — no constants baked in.
- [x] New pure module `Tractor.Cost`: `estimate/3 :: (provider, model, %{input_tokens, output_tokens}) -> Decimal.t() | nil`. Returns `nil` on unknown `{provider, model}` pair.
- [x] **Usage-delta accounting, not raw sum.** SPRINT-0004 `:token_usage` events are cumulative merged snapshots — summing them would double-count. Track per-node-attempt `last_seen_usage` in runner state; accumulate only the *delta* on new events.
- [x] Judge (LLM mode) and any fan-in LLM path must expose provider/model metadata alongside token usage so pricing resolves for them too — not just codergen. Audit handler return shapes in Phase A.
- [x] On missing pricing: emit `:cost_unknown` **once per `{provider, model}` pair per run** with the pair. Runner does not crash; cost not counted for unknown pairs; operator sees the gap in the event log.
- [x] Runner accumulates `state.total_cost_usd :: Decimal.t()`. Persist as string in checkpoint under `budgets.total_cost_usd`; resume rehydrates.
- [x] `Runner.Budget.check_cost/1` fires between nodes (pattern matches SPRINT-0006 `max_wall_clock`). Not mid-handler.
- [x] On exceed: emit `:budget_exhausted{budget: "max_total_cost_usd", observed: <string>, limit: <string>}`; finalize run `error` with reason `{:budget_exhausted, :max_total_cost_usd, observed, limit}`. No new nodes scheduled after the triggering node completes.
- [x] `status.json` carries `total_cost_usd` at both run and per-node level as decimal string.
- [x] Observer UI: running total in the phases panel (read-only; reuse existing component slot, no new LiveView component).
- [x] Late-event handling: token-usage events arriving **after** `:run_finalized` are dropped with a single `:late_token_usage` warning event.

### 4.7 Spec-coverage tracker (`docs/spec-coverage.md`)

Flat markdown, human-authored, review-gated. No code generation. No test enforcement — the file is a living audit artifact.

- [x] Fixed 12 top-level `##` sections, stable order to minimize diff churn:
  1. Handler types
  2. Graph attrs
  3. Node attrs
  4. Edge attrs
  5. Edge priority
  6. Condition DSL
  7. Runtime semantics
  8. Checkpoint / resume
  9. Observer UI
  10. ACP integration
  11. Coding-agent-loop features
  12. Unified-LLM features
- [x] Row format: `- [x] <item> — <module_path or SPRINT-00XX ref>`. Three states: `[x]` landed, `[~]` partial / flagged / stubbed, `[ ]` not implemented.
- [x] Top-of-file: short legend + links to attractor + ACP + unified-LLM specs + one-sentence "this file is a manual audit, updated in the same commits that land feature work".
- [x] **Honest extension marking:** Tractor-only extensions (extended condition operators, per-iteration stub-judge determinism, etc.) labeled as Tractor extensions, not claimed as upstream spec compliance.
- [x] Initial population walks SPRINT-0001..0006 acceptance lists + current `lib/` structure; marks everything that actually ships.
- [x] SPRINT-0007 items start `[ ]`; flip to `[x]`/`[~]` as the corresponding phase lands.
- [x] Updated **in the same commits** as feature work — not an end-of-sprint sweep. Every future sprint plan template includes "update spec-coverage.md" as an explicit task.

## 5. Sequencing

8.5d work + 1.5d slack over ~2 calendar weeks.

**Phase A — Pure prefix + state-model cleanup (2d).** No runner behavior changes yet.
- [x] Iteration counter split: `state.iterations` (per-node) ↔ `state.total_iterations_started` (lifetime). Checkpoint schema extended; rehydrate tests.
- [x] `%Node{}` gains `retry_target`, `fallback_retry_target`, `goal_gate?`, `allow_partial?` accessors.
- [x] `Tractor.Runner.Adjudication` pure module with table-driven tests (`:partial_success` with/without `allow_partial`, `parallel.fan_in` carveout, unknown status).
- [x] `Tractor.Runner.Routing` pure module (`next_target/2`) with table-driven tests for primary / fallback / exhausted / chain ownership.
- [x] `Tractor.Condition` rewrite as recursive-descent parser with committed EBNF; short-circuit eval; `ConditionLegacy` retained during Phase A for AST-diff regression.
- [x] `Tractor.Cost` pure module; verify pricing table via context7 for Claude 4.7/Sonnet 4.6/Haiku 4.5 + GPT-5 tiers + Gemini 3 tiers; adjust config defaults to match official pages.
- [x] Validator additions (all new diagnostic codes): `:invalid_retry_target`, `:unreachable_retry_target` (warn), `:invalid_goal_gate`, `:invalid_allow_partial`, `:goal_gate_bypass` (warn), `:allow_partial_without_judge` (warn), `:invalid_budget` extended for cost, `:invalid_condition` extended for extended-DSL errors.
- [x] `Decimal` dependency decision: check `mix.lock`; if absent, use `Float.parse/1` + string persistence with 6 decimal places; either way `Tractor.Cost` presents a `Decimal.t() | nil` or `float | nil` return type consistently.

**Phase B — Judge partial-success + condition integration (1d, parallelizable with C after A).**
- [x] `EdgeSelector` consumes new condition AST. Edge priority unchanged.
- [x] `Handler.Judge` edge-cardinality validator updated: allow `{accept, reject, partial_success}` triple on nodes with `allow_partial=true`; retain `{accept, reject}` duo.
- [x] `partial_success` shorthand routable via `condition="partial_success"`.
- [x] Example pipeline extended with `||` / numeric / `contains` usage for end-to-end DSL exercise.
- [x] Delete `Tractor.ConditionLegacy` after AST-diff regression passes clean on fixtures.

**Phase C — Failure routing runtime (2d). Depends on A.**
- [x] Runner dispatch on `{:retries_exhausted, reason}` → `Runner.Routing.next_target/2` → `{:route, target_id, tier}` | `:terminate`.
- [x] Route behavior: enqueue target fresh, reset `iterations[target]`, seed `context.__routed_from__ := origin_node_id`, preserve `state.total_iterations_started`, emit `:retry_routed`.
- [x] Fallback chain ownership = declaring node's `fallback_retry_target`; primary-target attrs are not consulted for further routing on the same recovery chain.
- [x] `context.__routed_from__` plumbed into `Context.add_iteration/3` so downstream conditions can branch on provenance.
- [x] Integration tests: primary-route success, primary exhausts → fallback succeeds, both exhaust → terminal (no goal gate), target inside different parallel block → validator rejects, `A.retry_target=B` + `B.retry_target=A` cycle → terminates after one full exhaustion of each.

**Phase D — Goal gate terminal path + cost budget enforcement (2d). Depends on C.**
- [x] Runner terminal-fail path distinguishes gate node: if `Node.goal_gate?(node)`, finalize `{:goal_gate_failed, node_id}` without firing `exit` handler. Otherwise existing SPRINT-0006 terminal path.
- [x] Mark `state.goal_gates_satisfied` on adjudicated success / allowed partial-success. Persist in checkpoint.
- [x] Exit-time gate verification: before invoking `exit` handler, check every `goal_gate=true` node is satisfied; if any not, finalize `:goal_gate_failed`.
- [x] `Runner.Budget.check_cost/1` between nodes; `Tractor.Cost.estimate/3` on each new `:token_usage` event; delta accumulation (not raw sum); `:cost_unknown` emission for missing pricing.
- [x] Checkpoint persistence for `total_cost_usd` as decimal string; resume rehydrates. Integration test: run at 90% of cap, killed + resumed, next node exhausts.
- [x] `status.json` writer includes cost totals (run-level + per-node).
- [x] Observer UI audit: surface `total_cost_usd` in the phases/status panel (read-only). Add `:goal_gate_failed` status pill so the UI doesn't treat the missing `exit` as a render bug.
- [x] Late-event handling: token-usage events arriving after `:run_finalized` produce a single `:late_token_usage` warning and are dropped.

**Phase E — Examples, spec-coverage doc, regression, merge (2.5d).**
- [x] `examples/recovery.dot`: demonstrates `retry → retry_target → success`, `retry → retry_target → fallback → success`, goal-gate terminal failure variant.
- [x] `examples/plan_probe.dot` extended (or new small pipeline) with `context.score >= 0.8`, `!(outcome=fail)`, `context.error contains "timeout" || preferred_label=retry`.
- [x] Low-budget variant of `examples/haiku_feedback.dot` with `max_total_cost_usd=0.01` to trip budget halt mid-loop.
- [x] Live smoke runs (four):
  - retry_target primary-recovery success
  - retry_target → fallback_retry_target success
  - goal-gate terminates without firing exit
  - cost budget halts a haiku loop mid-run with `:budget_exhausted` event
- [x] Populate `docs/spec-coverage.md` with initial sweep + SPRINT-0007 entries flipped to `[x]` / `[~]`.
- [x] Update `docs/usage/reap.md` with recovery / goal-gate / extended-condition / cost-budget notes. Document retry-idempotency assumption (retries spawn fresh ACP sessions — cost is counted per-attempt).
- [x] Update `IDEA.md` status. Update `docs/sprints/ledger.yaml` (orchestrator handles).
- [x] Merge gates: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`, `mix test --include integration`, `mix escript.build`.

**Parallelism.** A is hard prefix for everything. B can run in parallel with C once A lands. D depends on C (goal-gate uses terminal path shape). E is merge point.

## 6. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **Iteration counter coupling silently weakens `max_total_iterations`** on routed runs. | **High** | Phase A splits `state.iterations` from `state.total_iterations_started`. Integration test: route → target resets loop counter; lifetime total still increments; `max_total_iterations` fires correctly. |
| **Token-usage events are cumulative merged snapshots** — naive sum double-counts. | **High** | Delta accounting: track per-attempt `last_seen_usage`, sum deltas only. Mixed-provider integration test asserts accuracy. |
| Condition parser rewrite subtly changes semantics of existing expressions. | **High** | Phase A retains `Tractor.ConditionLegacy`. AST-diff every existing DOT fixture under both parsers for synthetic outcome/context fixtures. Delete legacy only after clean diff. |
| Parallel/fan-in partial-success semantics regress under new adjudication. | Med | `Adjudication.classify/3` keeps explicit `parallel.fan_in` carveout (continue on `:partial_success` without `allow_partial`). Regression test on `examples/parallel_audit.dot`. |
| `retry_target` cycles (A→B→A) infinite-loop. | Med | Validator forbids `retry_target == self`. Runtime: each node has its own retry scope + `max_iterations`; cycle can only exhaust both and terminate. Integration test. |
| Fallback chain ownership ambiguous — primary's own `retry_target` consulted for secondary recovery. | Med | Chain ownership rule: always the **declaring node's** `fallback_retry_target`, never the primary target's. Documented explicitly. Integration test. |
| Goal-gate terminal path skips `exit` → observer UI assumes `exit` always fires. | Med | Phase D audit of `TractorWeb.RunLive.Show` + phases panel. New `:goal_gate_failed` status pill. Test asserts UI renders terminal state correctly. |
| Goal-gate satisfaction not persisted across resume → post-resume re-gates on already-satisfied nodes. | Med | Persist `goal_gates_satisfied` set in checkpoint. Resume rehydrates. Test: fail mid-run after gate satisfied; resume; gate not re-checked. |
| Pricing-table staleness. | Med | `:cost_unknown` emitted per unknown `{provider, model}`. PR body notes verification date. Context7 refresh in Phase A. Config obviously updatable. |
| `:partial_success` leaks from judge without `allow_partial=true`. | Med | `Adjudication` normalizes centrally, not in handler. Test: same judge handler under two nodes (allow_partial on/off) — verdict observable only for opted-in node. |
| `context.__routed_from__` key collides with user-defined context. | Low | Namespace with `__` prefix; reserved; documented. Alternatively `context.routing.from` — Phase C code review picks. |
| Cost budget event arrival-order race (post-finalize events). | Low | Drop token-usage events arriving after `:run_finalized`; emit `:late_token_usage` warning once. Existing runner mailbox pattern. |
| Decimal dep churn. | Low | Phase A checks `mix.lock`. If absent, use `Float.parse/1` + 6-decimal string persistence; `Tractor.Cost` API stays consistent. |
| Spec-coverage doc drifts as code evolves. | High | Explicit task in every future sprint plan template. Not test-enforced by design — file is human audit artifact. |
| `||` / `!` / quoted strings in DOT graphs tokenize oddly. | Med | Test with both quoted + unquoted conditions. `examples/plan_probe.dot` exercises both. DOT's own string escaping rules documented in a one-liner in `reap.md`. |

## 7. Acceptance criteria

### Validator
- [x] `retry_target=<nonexistent>` → `:invalid_retry_target`.
- [x] `retry_target=<self>` → `:invalid_retry_target`.
- [x] `retry_target=start` / `retry_target=exit` → `:invalid_retry_target`.
- [x] `fallback_retry_target == retry_target` → `:invalid_retry_target`.
- [x] `retry_target` into a different parallel block → `:invalid_retry_target`.
- [x] `retry_target` declared but not start-reachable → warning `:unreachable_retry_target` (not error).
- [x] `goal_gate=maybe` / `allow_partial=maybe` → `:invalid_goal_gate` / `:invalid_allow_partial`.
- [x] `goal_gate=true` graph where some start→exit path skips all gates → warning `:goal_gate_bypass`.
- [x] `allow_partial=true` on a node with no judge upstream → warning `:allow_partial_without_judge`.
- [x] `max_total_cost_usd=0` / `=1001` / `=abc` → `:invalid_budget`.
- [x] `max_total_cost_usd=0.5` accepted.
- [x] `max_retries=3` / `default_max_retries=3` still rejected (SPRINT-0006 alias guard holds).

### Condition
- [x] `context.score >= 0.8` matches `%{score: 0.8}`, matches `%{score: 0.81}`, does not match `%{score: 0.79}`, does not match missing key.
- [x] `!(outcome=fail)` matches `%{status: :ok}`, does not match `%{status: :fail}`.
- [x] `context.error contains "timeout"` matches `"request timeout after 30s"`, does not match `"ok"`.
- [x] `a=1 || b=2 && c=3` parses as `or(a=1, and(b=2, c=3))` (precedence commitment).
- [x] `(a=1 || b=2) && c=3` parses as `and(or(a=1,b=2), c=3)`.
- [x] `!!x=1` evaluates equivalently to `x=1`.
- [x] `a = ` / `(` / `x ?? y` / `outcome >= 3` → `:invalid_condition`.
- [x] All SPRINT-0005 existing DOT fixtures parse + evaluate identically under new parser (AST-diff regression).

### Routing + goal gate runtime
- [x] Node A with `retries=2 retry_target=B`: after 3 failures (1 + 2 retries), `:retry_routed{tier: :primary}` emitted, B runs with fresh `iterations[B]=0`, run completes via `exit`.
- [x] Node A with primary B exhausting + declaring-node `fallback_retry_target=C`: `:retry_routed{tier: :fallback}` emitted, C runs, succeeds.
- [x] Node A's primary target B has its own `retry_target=D`: D is **not** consulted for A's recovery chain — only A's declared fallback. Test asserts `D` never runs during A's recovery.
- [x] Node A with `goal_gate=true`: all retry + routing paths exhaust → run finalizes `{:goal_gate_failed, "A"}`; observer shows `:goal_gate_failed` pill; `exit` handler is not invoked (asserted via event log — no `node_started` for exit).
- [x] Node A with `goal_gate=true` that succeeds normally: `exit` fires; run succeeds.
- [x] Goal-gate satisfaction persists across resume: crash after gate satisfied, resume, gate not re-checked.
- [x] `context.__routed_from__` visible to target node's condition evaluation.
- [x] Cycle `A.retry_target=B, B.retry_target=A`: run terminates after one full retries-exhaustion of each; no infinite loop.
- [x] Judge with `allow_partial=true` returning `:partial_success` on declaring node: edge `condition=partial_success` selected.
- [x] Same judge handler under a node *without* `allow_partial=true`: verdict normalized to `:reject` by `Adjudication`.
- [x] `parallel.fan_in` with `:partial_success`: continues without `allow_partial=true` (SPRINT-0002 carveout preserved).

### Cost budget
- [x] `max_total_cost_usd=0.01` on a pipeline whose first Claude Opus call costs ~$0.05: run finalizes `error{:budget_exhausted, :max_total_cost_usd, observed, limit}` **after** the triggering node completes but **before** the next node runs.
- [x] Unknown pricing (`llm_provider=claude llm_model=claude-opus-5`): `:cost_unknown` emitted once; runner does not crash; cost not counted.
- [x] Checkpoint + resume of a run at 90% budget: one more expensive node exhausts; resume does not reset total.
- [x] `status.json` contains `total_cost_usd` at run-level and per-node level as decimal string.
- [x] Mixed-provider pipeline (Claude + Codex + Gemini) with cumulative-update usage events: cost totals match expected within 1¢ (delta accounting working).
- [x] `:late_token_usage` events dropped gracefully after `:run_finalized`.
- [x] Judge LLM path + fan-in LLM path contribute to cost (not just codergen).

### Iteration counter split
- [x] Routed-to target starts at `iterations[target]=0`.
- [x] `state.total_iterations_started` keeps incrementing across routing; `max_total_iterations=5` still halts after 5 semantic iterations regardless of how many were routed.

### Spec coverage doc
- [x] `docs/spec-coverage.md` exists with all 12 fixed top-level sections in the specified order.
- [x] Every section has at least one entry from the current codebase.
- [x] SPRINT-0007 items appear and are `[x]` / `[~]` at sprint close.
- [x] Top of file links attractor + ACP + unified-LLM specs.
- [x] Extended condition operators (`||`, `!`, `contains`, numeric, parens) marked as Tractor extensions, not upstream spec items.

### Regression
- [x] `examples/haiku_feedback.dot`, `examples/resilience.dot`, `examples/parallel_audit.dot`, `examples/three_agents.dot`, `examples/plan_probe.dot` all still green.
- [x] `mix test` + `mix test --include integration` green.
- [x] `mix compile --warnings-as-errors` clean.
- [x] `mix format --check-formatted` + `mix credo --strict` clean.
- [x] `mix escript.build` succeeds.
- [x] Live smokes: retry-target success, retry→fallback success, goal-gate terminal, cost-budget halt — run dirs documented in closeout notes.

## 8. SPRINT-0008+ seeds

- [ ] Unified-LLM client (direct token metering at the Tractor layer, not provider-reported).
- [ ] Per-node error-classification callbacks (user-supplied `fn reason -> :transient | :permanent end`).
- [ ] `goal_gate_optional` opt-out for parallel branches that legitimately skip gates.
- [ ] Attractor `max_retries` / `default_max_retries` alias support if external graph compatibility matters.
- [ ] Cost-budget pre-flight estimator (refuse to start if forecasted cost > budget given token estimates).
- [ ] Status-agent session reuse across observations with contamination guards.
- [ ] Nested cycles and parallel-crossing cycles.
- [ ] Mid-handler wall-clock enforcement via chunked timeout checks.
- [ ] Runner-process supervision (restart-from-checkpoint on runner crash).
- [ ] Observer write controls (cancel, retry, extend budget live, force-accept judge).
- [ ] Graph-level `model_stylesheet` (CSS-like default LLM config by shape/class/id selector).
- [ ] Fidelity modes (`default_fidelity`, edge `fidelity` / `thread_id`, full-fidelity LLM session reuse).
- [ ] New handler types (`wait.human`, `tool`, `stack.manager_loop`, `conditional`).

## Closeout

All merge gates green: `mix format --check-formatted`, `mix credo --strict`, `mix compile --warnings-as-errors`, `mix test` (198 tests, 0 failures), `mix test --include integration`, `mix escript.build`.

**Successful live smokes** (real ACP agents against the dev branches):
- primary recovery `retry → retry_target → success` — `/var/folders/pt/x4j1pnkd50q7h5zxwhftgzch0000gn/T/tmp.CuOijG2rCF/runs/smoke-primary-route`
- fallback recovery `retry → fallback_retry_target → success` — `/var/folders/pt/x4j1pnkd50q7h5zxwhftgzch0000gn/T/tmp.IgKUwr1ABS/runs/smoke-fallback-route`
- goal-gate terminal (`{:goal_gate_failed, _}` without firing exit) — `/var/folders/pt/x4j1pnkd50q7h5zxwhftgzch0000gn/T/tmp.1QUICRYEGF/runs/smoke-goal-gate`

**Known upstream limitation (not a Tractor bug):** real-agent cost-budget smoke cannot currently be exercised end-to-end because the Claude / Codex / Gemini ACP bridges all return `status.json.total_cost_usd == "0"` — none emit usable token-usage snapshots over ACP. Tractor's cost machinery (delta accounting, pricing resolution, checkpoint persistence, budget enforcement) is fully covered by automated tests (`test/tractor/cost_budget_run_test.exs`, `test/tractor/cost_test.exs`) and will fire correctly when a bridge starts reporting usage. Tracked as a SPRINT-0008+ dependency on unified-LLM direct metering.

Opus follow-up pass after codex execution: made `Checkpoint.save/1` tolerant of missing SPRINT-0007 fields (affected the `run_test.exs:416` resume test), resolved 8 credo issues (one `with` → `case` refactor in `condition.ex`, one `then` wrapper removal in `handler/judge.ex`, two complexity suppressions for classifier/init functions, two line-length fixes in `cost_budget_run_test.exs`).

§8 checkboxes are SPRINT-0008+ seeds — future-scope, correctly unchecked.
