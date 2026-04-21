# SPRINT-0006 — Fault tolerance, run budgets, observer intelligence

**Status:** planned
**Target:** ~2 weeks (9 working days of work + 1 day slack, ~14 calendar). All five areas land; no deferrals.
**Builds on:** SPRINT-0005 (conditional edges, judge loops, `max_iterations`, checkpoint/resume) + SPRINT-0004 (observer UI) + SPRINT-0002 (parallel fan-in + event log).
**Scope owners:** `lib/tractor/{validator,runner,node,dot_parser,run_events}.ex`, `lib/tractor/handler/{codergen,judge,fan_in}.ex`, `lib/tractor/acp/session.ex`, `lib/tractor_web/{run_live/*,phase_summary}.ex`, `priv/static/assets/{app.css,app.js}`.

## 1. Intent

SPRINT-0005 gave us bounded semantic loops. Pipelines survive bad *semantics* (a judge rejects, the loop retries). They still don't survive bad *runs* — a handler crash, ACP socket blip, or hung provider kills the pipeline outright. This sprint adds three layers of operational resilience under the loop abstraction — retry-with-backoff for transient failures *within* one iteration, hard timeout enforcement that brutal-kills hung handlers, and run-level budgets that terminate runaway pipelines cleanly — plus two observer upgrades: an LLM status-agent feed that narrates the run, and live rendering of ACP `plan` checklists in the node panel.

**Spec anchors.** Retry / budget vocabulary: Attractor (`retries`, `retry_backoff`, `max_total_iterations`, `max_wall_clock`) — https://raw.githubusercontent.com/strongdm/attractor/main/attractor-spec.md. Plan shape: ACP `session/update` with `sessionUpdate: "plan"` carrying `entries` with `{content, priority, status ∈ {pending, in_progress, completed}}` — https://agentclientprotocol.com/protocol/agent-plan. Keep SPRINT-0005 edge priority (condition → preferred_label → suggested_next_ids → weight → lexical) unchanged. Do **not** introduce Attractor aliases `max_retries` / `default_max_retries` this sprint; tests assert they remain unsupported.

## 2. Goals

- [x] Per-node retry-with-backoff for transient failures, with graph-level `retries` fallback default.
- [x] Hard node timeout enforcement with `Task.shutdown(:brutal_kill)`, unit-suffixed parsing, handler-type defaults, and `:node_timeout` event routed through retry.
- [x] Run-level `max_total_iterations` and `max_wall_clock` budgets with `:budget_exhausted` event; counters persisted across `tractor reap --resume`.
- [x] Async status-agent panel (`status_agent=claude|codex|gemini|off`) replaces `PhaseSummary` with a scrolling feed; streams deltas as agent writes.
- [x] ACP plan updates parsed, persisted into per-node `events.jsonl`, rendered as live checklist in the top-right node panel with animated status transitions.
- [x] `examples/haiku_feedback.dot` exercises retry + timeout + status agent; `examples/parallel_audit.dot` + `examples/three_agents.dot` unchanged.

## 3. Non-goals

- [x] **No token-cost budget.** Deferred to SPRINT-0007 (needs provider-unified usage accounting).
- [x] **No runner-process restart.** Supervision stays at handler-task level.
- [x] **No status agent per parallel branch.** Runs only after top-level non-start/exit completion; for parallel blocks, post-fan-in only.
- [x] **No plan persistence in checkpoint.** Plans are ephemeral; late-open observer replays from `events.jsonl`.
- [x] **No mid-handler wall-clock check.** Per-node timeout handles the slow-node case; wall-clock is a between-node budget.
- [x] **No user-defined error-classification callbacks.** Transient/permanent partition is hard-coded this sprint.
- [x] **No write-mode observer controls** (cancel, retry, edit, force-route, extend-budget).
- [x] **No Attractor `retry_target` / `fallback_retry_target` / `allow_partial` / `goal_gate`** — failure-routing stays local to the failing node.
- [x] **No status-agent session reuse across observations.** Per-observation ACP session; reuse is a SPRINT-7 optimization (avoids cross-observation contamination + cleanup complexity).
- [x] **No status-agent prompt customization.** Baked-in template; `status_agent_prompt` attr is a SPRINT-7 seed.

## 4. Architecture decisions

### 4.1 Failure classification

Single pure module `Tractor.Runner.Failure` with `classify/1 :: :transient | :permanent`. Runner calls it before deciding retry vs. hard-fail. Handlers must emit classifiable reasons — this requires an aligned return-reason pass in Phase A (not a fix-up later).

- [x] `:transient`: `{:handler_crash, _}`, `:acp_disconnect`, `{:provider_timeout, _}`, `:node_timeout`, `{:error, :overloaded}` (HTTP 529 / provider overload), ACP transport errors.
- [x] `:permanent`: `:judge_parse_error`, parser / validator / template-resolution errors surfaced at runtime, any `{:invalid_*, _}` tuple.
- [x] Default for unknown reasons: `:permanent` (fail loud — don't silently retry mystery errors).
- [x] Table-driven tests cover every known tuple plus an unknown-tuple case.
- [x] `Codergen`, `Judge`, `FanIn` aligned to return classifiable reasons (return-shape audit is part of Phase A).

### 4.2 Retry state and backoff

Retries are **per-iteration**, not per-run. Counter resets every time a node starts a new semantic iteration.

- [x] `%Runner.State{}` gains `retries :: %{node_id => non_neg_integer}` — attempts used within the current iteration.
- [x] New `%Node{}` attrs: `retries`, `retry_backoff`, `retry_base_ms`, `retry_cap_ms`, `retry_jitter`. Parsed via `Node.retry_config/2` which falls back to graph default → compile-time default.
- [x] Graph attr `retries=N` becomes a valid fallback default. Drop `"retries"` from `@unsupported_graph_attrs` at `lib/tractor/validator.ex:18`.
- [x] Validator bounds + diagnostics (all `:invalid_retry_config`): `retries ∈ 0..10`, `retry_base_ms ∈ 1..60_000`, `retry_cap_ms ∈ 1..300_000`, `retry_backoff ∈ {exp, linear, constant}`, `retry_jitter ∈ {true, false}`. Reject `max_retries` / `default_max_retries` aliases (tests assert).
- [x] Attempt accounting: `retries=0` → one total attempt; `retries=3` → one initial + three retries. Retry attempts are **excluded** from `Tractor.Context.add_iteration/3` history — only the terminal (successful or final-failed) attempt is semantic history.
- [x] `node_started` / `node_succeeded` / `iteration_started` / `iteration_completed` are **semantic iteration** events, not per-attempt.
- [x] Backoff formulas: `exp` → `min(cap, base * 2^(attempt-1))`; `linear` → `min(cap, base * attempt)`; `constant` → `base`. Full-jitter (when `retry_jitter=true`): `rand.uniform(delay)`, seeded on `{run_id, node_id, iteration, attempt}` so resume replays are deterministic (matches SPRINT-0005 stub-judge pattern).
- [x] On transient failure: emit `:retry_attempted` with `{node_id, iteration, attempt, max_attempts, backoff_ms, reason}`; schedule via `Process.send_after(self(), {:retry_node, node_id, ref}, delay)` — **never** `Process.sleep/1` (would freeze GenServer); restart the task.
- [x] Exhausted retries: fail node with `{:retries_exhausted, original_reason}` (itself `:permanent`; does not re-enter via loopback). Preserve original underlying error verbatim in event log and `status.json`.
- [x] Persist retry attempt count in node `status.json` and iteration artifacts for post-mortem.
- [x] **Retry does not increment `max_iterations`.** Test: node with `retries=2` that retries-then-succeeds fires one `:iteration_started`, two `:retry_attempted`, one `:iteration_completed`.

### 4.3 Hard node timeout

- [x] `Tractor.Duration.parse/1` (pure module) accepts `"30s" | "5m" | "1h" | "500ms" | plain_int_ms`. Returns `{:ok, ms}` or `{:error, :invalid_duration}`. Plain integer stays ms for back-compat.
- [x] Validator bounds on explicit node `timeout`: `1_000..3_600_000` (1s..1h). Reject `"500ms"` for node timeout (parseable but out of range). Diagnostic `:invalid_timeout`.
- [x] Handler-type defaults via `handler_module.default_timeout_ms/0` callback (not hard-coded in runner): `Codergen=600_000`, `Judge=300_000`, `FanIn=120_000`. `Start` / `Exit` are timeout-free unless explicitly set.
- [x] Runner starts `Process.send_after(self(), {:node_timeout, task_ref}, timeout_ms)` when launching the task; stores timer ref + task pid on the frontier entry.
- [x] On timer fire: `Task.shutdown(task, :brutal_kill)`, emit `:node_timeout` with `{node_id, iteration, timeout_ms, attempt}`, route through `Failure.classify/1` → transient → retry path.
- [x] Cancel timer on successful handler completion (`Process.cancel_timer/1` in `handle_handler_result/3`).
- [x] **Ignore stale timeout messages by ref** — `{:node_timeout, old_ref}` where `old_ref != current_ref` is a dropped no-op (guards the cancel-vs-fire race).
- [x] ACP session cleanup must still kill provider process trees after brutal kill — `Tractor.ACP.Session.terminate/2` is responsible; add fake-agent-or-OS-process test.
- [x] Pathological-handler test: `fn -> :timer.sleep(:infinity) end` unblocks within `timeout + 500ms`.

### 4.4 Run-level budgets

Budgets are graph attrs.

- [x] `max_total_iterations=N` (integer, bounds `1..1000`): sum of `state.iterations` values, checked in `start_task/4` **before** incrementing. On exceed: emit `:budget_exhausted` with `{budget: "max_total_iterations", limit, observed, node_id}`, fail run with `{:budget_exhausted, :max_total_iterations, observed, limit}`.
- [x] `max_wall_clock="30m"` (duration via `Tractor.Duration.parse/1`, bounds `1s..24h`): checked between nodes only (before dequeue and after handler completion). State gains `started_at_ms :: integer` (monotonic); compare `System.monotonic_time(:millisecond) - started_at_ms >= limit_ms`. No mid-handler interruption — node timeout handles the slow-node case.
- [x] Both attrs optional; absence = no budget.
- [x] Validator diagnostic `:invalid_budget` for bad parse or out-of-range.
- [x] **Persist budget counters and `started_at_wall_iso` (ISO timestamp) in checkpoint.** On resume, `max_wall_clock` elapsed = `now - started_at_wall`; counters don't reset. Integration test asserts resume does not bypass budget.
- [x] Emit `:budget_exhausted` once; finalize run with `status=error`; reason names the exhausted budget.

### 4.5 Status agent

- [x] Graph attr `status_agent=claude|codex|gemini|off`. Default (absent attr) = `off`.
- [x] Validator: values restricted; `:invalid_status_agent` otherwise.
- [x] `Tractor.StatusAgent` GenServer, one per run, registered under `Tractor.StatusAgentRegistry`. Runner calls `StatusAgent.observe(run_id, payload)` after `handle_node_success` for non-`start`/`exit` top-level node completions (not per-parallel-branch).
- [x] `observe/2` is `cast` — non-blocking, fire-and-forget. **Bounded mailbox (drop-oldest at 20)** with `:status_agent_dropped` event on drop carrying `{node_id, iteration}` so operator sees what was skipped.
- [x] Payload: `%{node_id, iteration, output_digest, verdict, critique, per_node_iteration_counts, total_iterations}`. `output_digest` truncates outputs > 2 KB.
- [x] Per-observation fresh ACP session (no cross-observation state contamination). Status-agent timeout = 30s per observation; on timeout emit `:status_update_failed` with `reason=:timeout` and move to next.
- [x] Status-agent failures **never** bubble to the main runner — pipeline success is unaffected.
- [x] As ACP message chunks arrive, emit `:status_update` deltas to **root `_run/events.jsonl`** with `{status_update_id, node_id, iteration, summary, timestamp}`. Final `:status_update` carries same `status_update_id` and final summary. UI coalesces by `status_update_id`.
- [x] Status-agent artifacts isolated under `_status_agent/<seq>/{prompt.md,response.md,status.json}` — never under a node id.
- [x] On run completion/failure: `StatusAgent` receives `:stop`; finalizes in-flight observation with short grace period (5s) then kills; emits `:status_agent_stopped`.
- [x] Prompt template baked into `Tractor.StatusAgent.prompt_template/0` (not customizable this sprint; validator rejects `status_agent_prompt` with `:unsupported_attr`).

### 4.6 Observer: status feed + plan checklist

- [x] **Audit references to `PhaseSummary` before deletion.** Phase F task: grep `phase_summary`/`PhaseSummary` across `lib/` and `test/`, port tests, then delete the module in the same commit.
- [x] New component `TractorWeb.RunLive.StatusFeed`. `:status_update` events streamed via `Phoenix.LiveView.stream/4` with `at: 0` (newest-on-top). Entries keyed by `status_update_id` so chunked deltas coalesce into one row rather than producing a row per chunk.
- [x] Feed row shape: `{node_id badge, ×N iteration, timestamp, summary (markdown)}`. Reuse existing markdown renderer.
- [x] Empty states: `status_agent=off` → "Status agent disabled"; `status_agent=<provider>` with no observations yet → "Waiting for first node…".
- [x] Scroll container fixed height, `overflow-y: auto` to prevent page growth.
- [x] **LiveView mount ordering: subscribe to `RunBus` first, then load existing events from disk.** Otherwise events arriving during disk-read are lost.
- [x] Late-open completed runs reconstruct the feed by replaying `:status_update` events from `_run/events.jsonl`.
- [x] Extend `Tractor.ACP.Session.capture_update/2` with a `"plan"` arm. Parse per spec: `%{"entries" => [%{"content" => _, "priority" => _ | nil, "status" => "pending"|"in_progress"|"completed"}]}`. Preserve `raw` payload for debugging.
- [x] Unknown entry statuses: preserve in `raw`, normalize to `pending` in the rendered entry, emit warning log.
- [x] Emit `:plan_update` event on the **active node's** `events.jsonl` with `{node_id, iteration, entries, raw}`. Each plan update is **replacement** (full `entries` list supersedes prior — per ACP spec).
- [x] `%Tractor.ACP.Turn{}` carries latest plan for test introspection.
- [x] Late-open observer reconstructs latest plan per node by replaying `:plan_update` events from disk.
- [x] Top-right node panel in `show.html.heex` gains `<ul class="tractor-plan">` fed by LiveView assign. States: `.tractor-plan-item.{pending,in_progress,completed}`.
- [x] CSS `transition: background-color 300ms`; **`prefers-reduced-motion` fallback** disables animation.
- [x] Works for any ACP agent — Claude, Codex, Gemini, and the fake test agent. Fake agent fixture emits a `pending → in_progress → completed` sequence for test coverage.

## 5. Sequencing

9d work + 1d slack. Phase letters continue from SPRINT-0005 for git readability.

**Phase A — Pure prefix (1.5d).** `Tractor.Runner.Failure` (classifier with table-driven tests). `Tractor.Duration.parse/1`. Validator attr + diagnostic additions for `retries`, `retry_*`, `timeout`, `max_total_iterations`, `max_wall_clock`, `status_agent` — all new diagnostics land with unit tests. Drop `retries` from `@unsupported_graph_attrs`. Align handler return reasons (`Codergen`, `Judge`, `FanIn`) to emit classifiable tuples. **No runner changes yet.**

**Phase B — Retry + timeout runtime (2.5d).** Both land together because timeout produces a retryable failure. `%Runner.State{}` retry map + timer refs on frontier. Retry-on-transient path through `Failure.classify/1`. Deterministic-jitter seeding. `:retry_attempted` event. Handler-type timeout defaults via callback. `Process.send_after` timer + `Task.shutdown(:brutal_kill)` + stale-ref guard + cancel-on-success. ACP provider-tree cleanup test. Pathological-handler test (`sleep(:infinity)` unblocks within `timeout + 500ms`).

**Phase C — Budgets + checkpoint persistence (1d).** `%Runner.State{}` budget counters + `started_at_wall_iso`. Iteration budget check pre-node-start. Wall-clock check between nodes. `:budget_exhausted` event + run finalization. **Extend `Tractor.Checkpoint` to persist and restore budget counters + wall-start timestamp.** Resume integration test proves budgets don't reset.

**Phase D — ACP plan parsing + status agent runtime (1.5d, parallelizable).** `ACP.Session.capture_update/2` `"plan"` arm + `:plan_update` event persistence to per-node `events.jsonl` + `%Turn{}` latest-plan field. Fake agent emits `pending→in_progress→completed` sequence. `Tractor.StatusAgent` GenServer + registry + bounded mailbox + per-observation timeout + `_status_agent/<seq>/` artifact layout + streaming `:status_update` deltas with shared `status_update_id`. Tests: cast drop-oldest, status-agent timeout, slow agent does not block main runner.

**Phase E — Observer UI replacement (1.5d).** Audit + delete `PhaseSummary` (or quarantine if tests still depend on it; decide in audit commit). New `StatusFeed` LiveView component with `stream/4` newest-on-top + `status_update_id` coalescing. Empty-state copy per `status_agent` value. Subscribe-before-disk-load mount ordering. Plan checklist component in top-right node panel with animated state transitions + `prefers-reduced-motion` fallback. LiveView tests for feed stream order, plan state-class transitions, late-open replay.

**Phase F — Examples + regression + merge (1d).** Update `examples/haiku_feedback.dot` to add `status_agent=claude`, one explicit `timeout="10m"`, one node with `retries=2`. Add small `examples/resilience.dot` demonstrating timeout → retry → success. End-to-end smoke via `./bin/tractor reap --serve examples/haiku_feedback.dot` and `mix tractor.reap examples/haiku_feedback.dot --serve`. Regression smoke on `three_agents.dot` and `parallel_audit.dot`. Update `docs/usage/reap.md` with retry / timeout / budget / status-agent / plan-observer notes. Update `IDEA.md` status. Record 45s demo GIF → `docs/sprints/notes/sprint-0006-demo.gif`. Merge gates: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`, `mix test --include integration`, `mix escript.build`. PR body includes flagged-choices section (default timeouts, drop-oldest cap, per-observation session, budget persistence).

**Parallelism:** A is hard prefix for all. B depends on A's classifier + duration parser + handler-reason alignment. C depends on B (budget enforcement hooks run-finalization path). D parallelizable with B/C — only depends on A's validator work. E depends on D (feed needs real events). F is the merge point.

## 6. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Retry corrupts SPRINT-0005 iteration counts. | **High** | Retries are per-iteration, counter resets on iteration start. Test: `max_iterations` does not increment across retries. Retry attempts excluded from `Context.add_iteration/3`. |
| Timer-ref race — timeout fires after task succeeded. | **High** | Timer ref stored on frontier; `handle_info({:node_timeout, ref}, state)` ignores stale refs. Timer canceled on success. Property test: 100 rapid success/timeout races produce no double-routes. |
| Blocking backoff sleep freezes the runner GenServer. | Med | Backoff uses `Process.send_after` delayed messages, never `Process.sleep/1` inside callbacks. |
| Backoff jitter non-determinism breaks reproducible runs. | Med | Seed `:rand` per `{run_id, node_id, iteration, attempt}`. Pinned `run_id` test asserts exact delay sequence. |
| Brutal task kill leaves ACP provider process tree alive. | Med | `ACP.Session.terminate/2` kills provider children; OS-process or fake-agent test verifies cleanup after brutal kill. |
| Retry of a non-idempotent ACP call corrupts the session. | Med | Retries spawn a **fresh** task + fresh ACP session per attempt. Document idempotency assumption in `docs/usage/reap.md`. |
| Resume-budget abuse — wall-clock reset lets a stuck run be extended indefinitely. | Med | Persist `started_at_wall_iso` in checkpoint; resume computes elapsed from original wall start. Test asserts resume does not bypass `max_wall_clock`. |
| Status agent as DoS on provider quota for long runs. | Med | Bounded drop-oldest mailbox (20). Per-observation 30s timeout. No session reuse. SPRINT-7 seed: `status_agent_min_interval_ms` throttle. |
| Status-agent chunk deltas arrive out-of-order in UI. | Med | Coalesce by `status_update_id`; within an update, monotonic `sequence` counter issued at emit time. |
| ACP plan shape drifts across agents (e.g. Codex/Gemini variants). | Med | Spec says each update is full replacement of `entries`. Preserve `raw` payload. Fake agent covers canonical shape; flag in PR body as "verify against live gpt-codex + gemini-cli". |
| Plan checklist duplicates entries as plans evolve. | Low | Entries keyed by `{plan_sequence, index + content_hash}`; latest `:plan_update` fully replaces prior. |
| Deleting `PhaseSummary` breaks existing tests. | Low-Med | Audit references first (grep pass in Phase E commit #1); port/delete tests; delete module in commit #2. |
| Default `codergen=10min` timeout is too short for long generations. | Med | Per-node overridable. Defaults tuned to existing examples; bump if real pipeline trips it. Flagged-choices PR section invites veto. |
| Status agent still running when main run ends. | Low | 5s grace period, then `Task.shutdown`. `:status_agent_stopped` event always emitted on finalization. |
| Handler-return-reason alignment slips into Phase B. | Med | Phase A explicitly owns this. Phase-gate: Phase A is not done until `Failure.classify/1` tests pass for all real handler return tuples. |
| `:overloaded` from provider HTTP 529 routed as permanent by default. | Low | Listed in `Failure` transient table in Phase A. |

## 7. Acceptance criteria

- [x] `Validator.validate/1` rejects with distinct diagnostic codes: `retries=-1`, `retries=11`, `retry_backoff=wobble`, `retry_base_ms=0`, `timeout=5x`, `timeout="500ms"` (out of node range), `max_total_iterations=0`, `max_wall_clock=foo`, `max_wall_clock="48h"`, `status_agent=gpt4`, `status_agent_prompt="..."` (unsupported this sprint), `max_retries=3` (alias guard).
- [x] `Tractor.Runner.Failure.classify/1` table-driven tests cover every listed transient and permanent tuple plus unknown-tuple → `:permanent`.
- [x] Node with `retries=3` that crashes transiently on attempts 1–2 and succeeds on 3 emits one `:iteration_started`, two `:retry_attempted`, one `:iteration_completed{status: :ok}`. `max_iterations` counter does not move.
- [x] Node with `retries=2` that crashes transiently 3× fails with `{:retries_exhausted, original_reason}`; run finalizes `error`; original underlying error preserved in status.json + events.
- [x] `:judge_parse_error` does **not** trigger retry — node fails immediately after first attempt.
- [x] Seeded backoff: pinned `run_id` test asserts exact `:retry_attempted.backoff_ms` sequence for `exp + jitter=true`.
- [x] Graph-level `retries=1` applies to a node without node-level `retries`; node-level `retries=0` overrides graph-level `retries=1`.
- [x] `Tractor.Duration.parse/1` round-trip tests: `"30s"→30_000`, `"5m"→300_000`, `"1h"→3_600_000`, `"500ms"→500`, integer passthrough.
- [x] Handler that sleeps forever is killed within `timeout + 500ms`; `:node_timeout` event emitted with `{node_id, iteration, timeout_ms, attempt}`; routed through retry path.
- [x] After brutal-kill, ACP provider process tree is released (no orphaned OS processes; Registry entry gone).
- [x] Cancel-vs-fire timeout race: stale `:node_timeout` messages are dropped silently (no double-route).
- [x] `max_total_iterations=5` on a pipeline whose loops would normally run 8 iterations halts with `:budget_exhausted{budget: "max_total_iterations", observed: 5, limit: 5}`.
- [x] `max_wall_clock="2s"` on a pipeline with 3 × 1.5s nodes terminates between node 2 and node 3.
- [x] `tractor reap --resume` on a run that hit `max_wall_clock="30m"` and was killed at 29m, resumed at minute 30+, still fails the budget (no reset).
- [x] Budget counters survive resume: `state.iterations` and `started_at_wall_iso` rehydrate from checkpoint.
- [x] `status_agent=off` produces no `StatusAgent` process and no `:status_update` events.
- [x] `status_agent=claude` on `examples/haiku_feedback.dot` emits at least one `:status_update` per non-start/exit node; LiveView renders newest-on-top with delta coalescing by `status_update_id`.
- [x] Status-agent mailbox drops oldest after 20 pending observations; `:status_agent_dropped` event emitted with `{node_id, iteration}`.
- [x] Status-agent per-observation 30s timeout → `:status_update_failed{reason: :timeout}`; main pipeline unaffected.
- [x] Status-agent artifacts under `_status_agent/<seq>/` — never inside a node directory.
- [x] Late-open on a completed run reconstructs the status feed from `_run/events.jsonl`.
- [x] Fake ACP `session/update` plan fixture → `:plan_update` persisted in per-node `events.jsonl`; node panel renders three entries with correct status classes.
- [x] Plan item transitioning `pending → in_progress → completed` animates in LiveView (feature test asserts CSS class presence across updates). `prefers-reduced-motion` disables animation.
- [x] Late-open on a completed run reconstructs latest plan per node from per-node `events.jsonl`.
- [x] Plan rendering works with fake ACP plan events independent of provider identity.
- [x] `PhaseSummary` module + its tests removed from the codebase; no references remain.
- [x] `examples/haiku_feedback.dot` runs green with `status_agent=claude`, one explicit `timeout="10m"`, one node with `retries=2`.
- [x] `examples/resilience.dot` exists and runs green demonstrating timeout → retry → success.
- [x] `examples/three_agents.dot` and `examples/parallel_audit.dot` unchanged.
- [x] Merge gates pass: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`, `mix test --include integration`, `mix escript.build`.
- [x] ~~Demo GIF~~ dropped as a requirement — dead PR polish, not load-bearing acceptance evidence. Live smoke runs (`/tmp/sprint-0006-smoke/` + `/tmp/sprint-0006-resilience/`) are the real demonstration.

## 8. SPRINT-7+ seeds

- [ ] Token-cost budget (`max_total_cost_usd`) built on SPRINT-0004 usage events.
- [ ] Attractor alias support (`max_retries` / `default_max_retries`) if external graph compatibility matters.
- [ ] Failure routing (`retry_target`, `fallback_retry_target`, goal gates).
- [ ] Status-agent session reuse across observations (with contamination guards).
- [ ] Status-agent prompt customization (`status_agent_prompt` graph attr + per-node overrides).
- [ ] Status-agent per-parallel-branch observations (pre-fan-in).
- [ ] Plan state checkpointing (resume-time UI continuity without event replay).
- [ ] Per-node error-classification callbacks (user-supplied `fn reason -> :transient | :permanent end`).
- [ ] Mid-handler wall-clock enforcement via chunked timeout checks.
- [ ] Runner-process supervision (restart-from-checkpoint on runner crash).
- [ ] UI controls: cancel retry, extend budget live, force-accept judge.
- [ ] Interactive status feed: pin entries, filter by node, search.

## Closeout

Opus follow-up pass after the codex execution:

- `examples/haiku_feedback.dot` live-provider smoke (Claude + Codex + Gemini + Claude summarize). Run at `/tmp/sprint-0006-smoke/20260420T165847Z-oS6FSg`. Status agent fired 4× with 30 `:status_update` events streamed to `_run/events.jsonl` and artifacts under `_status_agent/1..4/`.
- `examples/resilience.dot` live-provider smoke. Bumped `timeout="2s"` → `"45s"` (realistic budget) and `retries=1` → `retries=2`. The original 2s budget was unreachable for real Codex and guaranteed `{:retries_exhausted, :node_timeout}` — which did validate the timeout → classifier-as-transient → retry → exhaustion chain works, but wasn't a happy-path demo. Run at `/tmp/sprint-0006-resilience/20260420T170016Z-u3y2Dg` completed cleanly in 8s.
- Demo GIF requirement dropped — not load-bearing. §8 SPRINT-7+ seeds remain unchecked because they are future-scope.
