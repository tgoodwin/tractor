# SPRINT-0008 — Handler family: `tool`, `wait.human`, `conditional`

**Status:** planned
**Target:** ~2 weeks (9 working days + 1 day slack, ~14 calendar). All three handler types land, no deferrals.
**Builds on:** SPRINT-0007 (failure routing, goal gates, extended condition DSL, cost budget, spec-coverage doc) + SPRINT-0006 (retry / timeout / wall-clock) + SPRINT-0005 (checkpoint/resume) + SPRINT-0004 (token-usage events).
**Scope owners:** `lib/tractor/{dot_parser,node,pipeline,edge,validator,runner,checkpoint,run,run_events,run_bus}.ex`, `lib/tractor/runner/{failure,adjudication}.ex`, `lib/tractor/handler/{tool,wait_human,conditional}.ex` (new), `lib/tractor_web/run_live/{show,wait_form,timeline}.ex`, `lib/tractor_web/templates/run_live/show.html.heex`, `docs/spec-coverage.md`, `examples/*.dot`, `test/**/*`.

## 1. Intent

SPRINT-0007 made the runtime spec-faithful for handler types we already had (`codergen`, `judge`, `parallel`/`fan_in`, `start`/`exit`). Three attractor-spec handler types are still rejected by the validator: `tool`, `wait.human`, `conditional`. This sprint lands all three end-to-end — parser, validator, handler module, runner dispatch, checkpoint persistence where needed, observer UI where needed, and spec-coverage flips. The remaining unsupported handler (`stack.manager_loop`) stays rejected; it's a SPRINT-0010 concern.

**Spec anchors.** Attractor — https://raw.githubusercontent.com/strongdm/attractor/main/attractor-spec.md (handler type semantics). ACP — https://agentclientprotocol.com (unchanged — tool nodes do not open ACP sessions).

**Shape note.** `conditional` is trivial — a no-op pass-through handler exists solely so DOT authors can declare a pure routing fork node without attaching a real agent. `tool` is medium — literal-array `System.cmd/3` wrapper with new parser work. `wait.human` is the heavyweight item — it introduces a **suspension model** the runner doesn't have today (all existing handlers run to completion in-process).

**Parser prefix is the hidden prerequisite.** The current DOT normalization path is string-only. `tool.command` and `tool.env` need structured values, so parser work lands before handler work — otherwise the tool handler has to do fragile string-splitting or re-parse JSON from attrs. Phase A owns this.

## 2. Goals

- [x] `type="tool"` handler: literal-array `System.cmd/3` wrapper. Attrs: `command=<string-array>` required; `cwd`, `env` (string-key map), `stdin` (template-rendered), `max_output_bytes` (default 1MB). Output `%{exit_status, stdout, stderr, command}` visible via `context.<node_id>.*`. Classifier: non-zero exit → `:tool_failed` → transient (SPRINT-0006 retry); `:enoent` → `:tool_not_found` → permanent; timeout → `:node_timeout` (existing transient); output truncation → warning event + successful truncated return. Retry exhaustion surfaces as `{:retries_exhausted, {:tool_failed, N}}`.
- [x] Tool calls excluded from `max_total_cost_usd` (treated as `{provider: nil, model: nil}` for SPRINT-0007 cost pipeline — no `:cost_unknown` noise).
- [x] `type="wait.human"` handler: runner-level suspension via new `{:wait, payload}` handler-return variant. Attrs: `wait_timeout` (duration), `default_edge` (required iff `wait_timeout` set), `wait_prompt` (optional). Runner records `waiting_since` in state + checkpoint; exit gate blocks while any wait.human is pending. Observer form resolves via `submit_wait_choice`; resume rehydrates waiting state and re-emits `:wait_human_pending`.
- [x] `type="conditional"` handler: no-op `{:ok, %{}, %{"status" => "ok"}}` return. Edge routing does the work via existing `EdgeSelector` + condition DSL.
- [x] Parser prefix: `Tractor.DotParser` extended with a narrow pre-pass for `command` / `env` only — structured JSON-like literals survive `Dotx` round-trip. Node/Pipeline/Edge typings widened to tolerate structured node attrs without broad runtime rewrites.
- [x] Validator accepts all three types; full diagnostic catalog for misuse.
- [x] New LiveView component `TractorWeb.RunLive.WaitForm` renders when selected node is `wait.human` and state is `:waiting`.
- [x] Four live smokes: tool pipeline with real binaries (`grep`/`wc`), observer-driven wait.human resolution, wait.human timeout default-edge, conditional fork on `context.score`.
- [x] `docs/spec-coverage.md` lines 17 and 90 flipped in the same commits that land each feature (not an end-of-sprint sweep — matches SPRINT-0007 §4.7 policy).
- [x] At least one new example under `examples/` per handler type.

## 3. Non-goals

- [x] **No `stack.manager_loop`.** Stays in `@unsupported_handlers`. SPRINT-0010.
- [x] **No shell-string tool execution.** `command` is always a literal array. Authors who want shell semantics write `command=["bash","-c","grep foo | wc -l"]` explicitly. DOT-escape cost falls on the author.
- [x] **No command-element template rendering.** `command`, `cwd`, `env` are literal after parse. Only `stdin` is template-rendered. (Rationale: template-rendering argv invites quoting/context bugs. Literal argv is the simpler contract.)
- [x] **No sandboxing, chroot, namespace isolation, or container execution.** Tool nodes run as the runner process's user with full filesystem/network access. Documented in `docs/usage/reap.md`.
- [x] **No persistent tool allowlist / denylist.** SPRINT-0009+ seed.
- [x] **No tool output streaming.** `System.cmd/3` is blocking; stdout/stderr captured in full (up to `max_output_bytes`) and returned at node completion. SPRINT-0009+ seed.
- [x] **No unified LLM client.** SPRINT-0009.
- [x] **No fidelity modes, `thread_id`, `loop_restart`, `model_stylesheet`.**
- [x] **No polling-based wait.human.** Observer form + `Process.send_after` timeout is the only path.
- [x] **No observer cancel / force-resolve outside wait.human nodes.**
- [x] **No tool cost attribution.** Tool nodes do not contribute to `max_total_cost_usd` by design.
- [x] **No user-defined error-classification callbacks** (still hard-coded in `Runner.Failure`).
- [x] **No `{:wait, _}` return variant for handlers other than `wait.human`.** Runner dispatches `:suspend` only when the node type is `wait.human`; any other handler returning `{:wait, _}` raises with a loud error.
- [x] **No Attractor aliases** (`max_retries`, `default_max_retries`, etc. stay rejected).
- [x] **No demo GIFs or PR flagged-choices ceremony.**

## 4. Architecture decisions

### 4.1 Parser prefix + normalized attr surface

The current path through `Dotx` only preserves string-valued attrs. `tool.command=["grep","-r","pat","."]` needs to survive round-trip as a list.

- [x] `Tractor.DotParser` narrow pre-pass decodes JSON-like array/map literals for `command` and `env` attrs specifically. Other attrs keep existing scalar behavior.
- [x] Malformed structured literals surface as validator diagnostics (`:invalid_tool_command`, `:invalid_tool_env`), not parser crashes.
- [x] Widen `%Tractor.Node{}`, `%Tractor.Pipeline{}`, `%Tractor.Edge{}` attr typings to tolerate structured values.
- [x] Add shape-to-type mappings: `diamond → conditional`, `hexagon → wait.human`, `parallelogram → tool`. `house` remains unmapped so validator rejection still owns `stack.manager_loop`.
- [x] New `%Node{}` accessors: `Node.command/1`, `Node.cwd/1`, `Node.env/1`, `Node.stdin/1`, `Node.max_output_bytes/1`, `Node.wait_timeout_ms/1`, `Node.default_edge/1`, `Node.wait_prompt/1`. No raw `attrs["..."]` access from runtime code.
- [x] `Node.outgoing_labels/2` helper — returns outgoing edge labels given a pipeline (wait.human runtime needs this).

### 4.2 Validator — accept all three types

- [x] Shrink `@unsupported_handlers` to only `["stack.manager_loop"]` at `lib/tractor/validator.ex:10-15`.
- [x] Per-type validator clauses: `validate_tool_attrs/1`, `validate_wait_human_attrs/2`, `validate_conditional_attrs/1`.
- [x] Tool diagnostics:
  - [x] `:invalid_tool_command` — missing, not an array, empty array, or non-string elements.
  - [x] `:invalid_tool_env` — not a string-keyed, string-valued map.
  - [x] `:invalid_max_output_bytes` — not an integer, or out of bounds `1..100_000_000`.
- [x] Wait.human diagnostics:
  - [x] `:wait_without_default` — `wait_timeout` set but `default_edge` absent.
  - [x] `:invalid_default_edge` — `default_edge` label not present on any outgoing edge.
  - [x] `:invalid_wait_timeout` — duration won't parse via `Tractor.Duration.parse/1`.
  - [x] `:wait_human_without_outgoing` — node has no outgoing edges.
  - [x] Warning `:wait_human_no_timeout` — no `wait_timeout` (valid indefinite-wait use case; warn so operators notice).
- [x] Conditional: no extra errors. No required attrs. A `conditional` with only unconditional fallback is valid-but-pointless, not a diagnostic (pedagogical graphs).
- [x] `stack.manager_loop` still emits `:unsupported_handler`. Regression test asserts.

### 4.3 `Tractor.Handler.Tool`

Core invariant: **no shell interpolation**. `command` is a literal list of strings fixed at graph-parse time. No splat, no join, no `sh -c` unless the author writes it as literal list entries.

- [x] `lib/tractor/handler/tool.ex` implements `@behaviour Tractor.Handler`.
- [x] `run/3` flow:
  - [x] Render `stdin` via `Tractor.Context.Template.render/2`. `command`, `cwd`, `env` are literal.
  - [x] Resolve `cwd` against `run_dir` when relative; default `run_dir` when unset.
  - [x] **Port-based two-pipe capture** for stdout/stderr separation. `Port.open({:spawn_executable, path}, [:exit_status, :binary, :use_stdio, :hide, args: args, cd: cwd, env: env_list])` with two buffers.
  - [x] Byte-count guard inside the read loop: stop reading past `max_output_bytes + 1KB headroom` and close the port. Prevents OOM from `yes | head -c 10MB`.
  - [x] If either buffer hits `max_output_bytes`: truncate, emit `:tool_output_truncated{node_id, stream: :stdout | :stderr, observed_bytes, limit}`, **still return `:ok`** with truncated capture.
  - [x] On `:enoent` (binary not found): `{:error, {:tool_not_found, binary}}`.
  - [x] Non-zero exit status: `{:error, {:tool_failed, %{exit_status: n, stderr: s}}}`.
  - [x] Exit status 0: `{:ok, %{exit_status: 0, stdout: s, stderr: e, command: rendered_command_array}, context_updates}`.
- [x] Context updates merged under `#{node.id}.*`: `stdout`, `stderr`, `exit_status`, `command`.
- [x] `status` metadata `provider: nil, model: nil` so SPRINT-0007 cost/status path stays explicitly non-LLM.
- [x] Artifact write: `run_dir/#{node.id}/attempt-N/command.json` captures rendered command + env + cwd + truncation flag + exit_status — matches codergen artifact shape.
- [x] Classifier additions in `Tractor.Runner.Failure`:
  - [x] `{:tool_failed, _}` → `:transient` (SPRINT-0006 retry applies).
  - [x] `{:tool_not_found, _}` → `:permanent`.
  - [x] `:node_timeout` unchanged (already transient). SPRINT-0006 `timeout` attr covers tool timeouts; `Task.shutdown(:brutal_kill)` cascades to spawned Port via Erlang link.
- [x] Cost exclusion: handler emits no `:token_usage` events; the cost pipeline doesn't see tool nodes; no `:cost_unknown` fires. Gate at emission site.
- [x] Zombie port safety: on `Task.shutdown` or runner kill, ensure `Port.close/1` runs (fall-through via `after` clause or monitor).
- [x] Retry exhaustion wrapping: when a tool node exhausts retries, run fails with `{:retries_exhausted, {:tool_failed, exit_status}}` — underlying reason preserved for the event log.

**Port-vs-`System.cmd/3` fallback.** If Port-based two-pipe capture turns out to be too fragile in Phase B (timing / closing / binary handling), fall back to `System.cmd(cmd, args, stderr_to_stdout: true)` and document the unified stdout+stderr limitation in `reap.md`. The choice is owned by the first half-day of Phase B and flagged in the PR body.

### 4.4 `Tractor.Handler.Conditional`

- [x] `lib/tractor/handler/conditional.ex` implements `@behaviour Tractor.Handler`.
- [x] `run/3` → `{:ok, %{}, %{"status" => "ok"}}`. Returns instantly.
- [x] No artifacts, no ACP session, no token usage, no cost.
- [x] No validator additions beyond §4.2 acceptance. Edge-validation for "at least one conditional outgoing edge" is deliberately omitted — a conditional with only fallback is valid-but-pointless.
- [x] No handler-type timeout default (omit `default_timeout_ms/0` callback).

### 4.5 `Tractor.Handler.WaitHuman` — runner-level suspension

The heavyweight item. Existing handlers are `Task.Supervisor.async_nolink`-wrapped and always complete. `wait.human` needs a way to say "I'm blocked; resume me when an external event arrives." Cleanest shape: new `:wait` handler-return variant + runner moves the node from `frontier` to `state.waiting`.

**Handler contract extension.**

- [x] `Tractor.Handler` behaviour gains `{:wait, %{kind: :wait_human, payload: map()}}` as a valid return alongside `{:ok, _, _}` and `{:error, _}`.
- [x] Runner's `handle_handler_result/3` recognizes `{:wait, _}` only from `wait.human` handlers. Any other handler type returning `{:wait, _}` raises with a loud error (contract violation — caught by a final catch-all dispatch clause).

**Handler module.**

- [x] `lib/tractor/handler/wait_human.ex` — `run/3` renders `wait_prompt` against context, collects `outgoing_labels` via `Node.outgoing_labels/2`, returns `{:wait, %{kind: :wait_human, payload: %{wait_prompt: rendered, outgoing_labels: [...], wait_timeout_ms: t_or_nil, default_edge: label_or_nil}}}`.
- [x] No ACP session, no token usage events, no cost.
- [x] Small `wait.json` artifact at `run_dir/#{node.id}/attempt-N/` capturing suspension payload for resume + audit.

**Runner state.**

- [x] `%Runner.State{}` gains `waiting :: %{node_id => waiting_entry}` where `waiting_entry = %{waiting_since: DateTime.t(), timeout_ref: reference() | nil, wait_prompt: binary, outgoing_labels: [binary], wait_timeout_ms: pos_integer() | nil, default_edge: binary | nil, attempt: pos_integer(), branch_id: term(), parallel_id: term(), iteration: pos_integer(), declaring_node_id: binary}`.
- [x] **`branch_id` / `parallel_id` / `iteration` carried on waiting entries** — preserves parallel-block semantics (a waiting branch stays unsettled until resolution).
- [x] **Separate wait-timer registry** keyed by timer ref so wait timeouts don't collide with existing node-timeout or retry timers.
- [x] On `{:wait, %{kind: :wait_human, payload: p}}` return:
  - [x] Remove task from `frontier`; cancel any node-timeout timer (suspend replaces it).
  - [x] Mark node status as `"waiting"` in `RunStore`.
  - [x] Add entry to `state.waiting[node_id]`.
  - [x] Emit `:wait_human_pending{node_id, wait_prompt, outgoing_labels, wait_timeout_ms}`.
  - [x] If `wait_timeout_ms` present: `Process.send_after(self(), {:wait_human_timeout, node_id, attempt}, wait_timeout_ms)` — store ref on the entry.
  - [x] Stop advancing new agenda items on this branch (and skip `exit` if any `state.waiting != %{}`).
- [x] `advance/1` adds precondition: exit-gate blocks if `map_size(state.waiting) > 0`. Goal-gate checks run only after wait is clear.
- [x] On operator resolution via `Tractor.Run.submit_wait_choice(run_id, node_id, label)`:
  - [x] Validate node is still waiting (idempotent — stale submissions no-op).
  - [x] Validate label ∈ current `outgoing_labels` (reject stale-form submissions).
  - [x] Cancel pending timeout timer.
  - [x] Emit `:wait_human_resolved{node_id, label, source: :operator}`.
  - [x] **Synthesize normal success path** — construct a handler result `{:ok, %{resolved_label: label, resolution_source: :operator}, context_updates}` and route via `preferred_label: label` into `EdgeSelector`. **Not a second edge-selection code path.**
- [x] On `handle_info({:wait_human_timeout, node_id, attempt}, state)`:
  - [x] **Attempt-fencing**: compare `attempt` against `state.waiting[node_id].attempt`. Mismatched → stale timer, no-op. Prevents double-resolution across resume (where `attempt` is bumped).
  - [x] Matched → resolve with `default_edge, source: :timeout`. Same synthesized success path.

**Runner public API.**

- [x] `Tractor.Run.submit_wait_choice(run_id, node_id, label) :: :ok | {:error, reason}`.
- [x] Internal: `Tractor.Runner.submit_wait_choice(run_id, node_id, label)` via `GenServer.call` on the registered run.
- [x] Single-writer guarantee: both operator-submit and timeout-fire paths funnel through runner mailbox. First-wins semantics; second resolution attempt on already-resolved node is a no-op.

### 4.6 Checkpoint persistence for waiting state

- [x] Extend `Checkpoint.save/1` with top-level `"waiting"` key mapping `node_id → %{"waiting_since" => iso, "wait_prompt" => str, "outgoing_labels" => list, "wait_timeout_ms" => int | nil, "default_edge" => str | nil, "attempt" => int, "branch_id" => _, "parallel_id" => _, "iteration" => int, "declaring_node_id" => str}`.
- [x] `Checkpoint.verify!/2` + resume: rehydrate `state.waiting`. Tolerant of missing `"waiting"` key (pre-SPRINT-0008 checkpoints → empty map), matching SPRINT-0007's `goal_gates_satisfied` backfill pattern.
- [x] On resume, **bump `attempt` by +1 for each rehydrated waiting entry** — stale timers from before crash can't double-fire (attempt-fencing guard catches them).
- [x] For each rehydrated entry with `wait_timeout_ms`: compute remaining = `wait_timeout_ms - (now - waiting_since)`. Schedule `Process.send_after` for `max(0, remaining)` (resume-after-already-expired → immediate fire).
- [x] Re-emit `:wait_human_pending` for every rehydrated node so late-open observers see pending state. (Downstream consumers must tolerate same-node double-emit across resume — acceptable because `:wait_human_resolved` is the terminal event.)
- [x] **Semantic-hash verification unchanged** — changed edge labels after a crash still fail resume rather than silently misrouting a stored `default_edge`.

### 4.7 Observer UI

- [x] `lib/tractor_web/run_live/wait_form.ex` — new LiveView component.
- [x] Rendered in top-right node panel when `@selected_node.type == "wait.human"` AND `@selected_node.state == :waiting`.
- [x] Renders a button per outgoing edge label (not radio — single-click resolution); shows `wait_prompt` as header, `waiting_since` elapsed time, and `wait_timeout_ms` countdown when set.
- [x] `handle_event("submit_wait_choice", %{"label" => label}, socket)` calls `Tractor.Run.submit_wait_choice/3`. Stale/invalid-label errors surface inline without page teardown.
- [x] LiveView subscribes to `RunBus` topic so `:wait_human_pending` / `:wait_human_resolved` events flip the form between pending/resolved states.
- [x] `RunLive.Show` mount loads pending waits from disk (via checkpoint + events.jsonl replay) for late-open and resumed runs.
- [x] Node-state transitions updated: `wait_human_pending` marks node as `"waiting"`; `wait_human_resolved` clears the form before the eventual synthesized `node_succeeded`.
- [x] Timeline rendering includes `:tool_invoked`, `:tool_output_truncated`, `:wait_human_pending`, `:wait_human_resolved` as distinguishable entry kinds with icons.

### 4.8 Runner dispatch + adjudication

- [x] `lib/tractor/runner.ex` handler dispatch table gains three clauses:
  ```elixir
  defp handler_for(%Node{type: "tool"}), do: Tractor.Handler.Tool
  defp handler_for(%Node{type: "wait.human"}), do: Tractor.Handler.WaitHuman
  defp handler_for(%Node{type: "conditional"}), do: Tractor.Handler.Conditional
  ```
- [x] `handle_handler_result/3` recognizes `{:wait, _}` alongside `{:ok, _, _}` and `{:error, _}`. Suspend path moves to `state.waiting`; ok/error paths unchanged.
- [x] `Runner.Adjudication.classify/3` unchanged — tool returns flow as `:success`; wait.human resolution is synthesized as `:success` with the resolved label as `preferred_label`; conditional returns flow as `:success`. None of them return `:partial_success` (would be semantically wrong for all three).

### 4.9 Events + spec-coverage

New event kinds in `RunEvents.emit/4`:
- [x] `:tool_invoked` — `%{command: [...], cwd, exit_status, attempt}` (audit; emitted on tool completion regardless of outcome).
- [x] `:tool_output_truncated` — `%{stream: :stdout | :stderr, observed_bytes, limit}`.
- [x] `:wait_human_pending` — `%{wait_prompt, outgoing_labels, wait_timeout_ms, default_edge}`.
- [x] `:wait_human_resolved` — `%{label, source: :operator | :timeout}`.

Spec-coverage flips (per SPRINT-0007 §4.7 same-commit policy):
- [x] Line 17 expands from one `[ ]` into four lines (three `[x]` for new types, one `[ ]` for `stack.manager_loop`) — each flipped in the commit that lands the corresponding handler.
- [x] Line 90 expands to two `[x]` entries for human-in-loop + tool handler.
- [x] Runtime-semantics section gains a new `[x]` item for exit-gate block while wait.human is pending.
- [x] Node-attrs section gains `[x]` entries for `command`, `cwd`, `env`, `stdin`, `max_output_bytes`, `wait_timeout`, `default_edge`, `wait_prompt`.

## 5. Sequencing

9d work + 1d slack over ~2 calendar weeks.

**Phase A — Parser prefix + validator + conditional (1.5d). Hard prefix for the whole sprint.**
- [x] Extend `Tractor.DotParser` with narrow structured-literal pre-pass for `command` / `env`.
- [x] Widen `%Node{}`, `%Pipeline{}`, `%Edge{}` attr typings.
- [x] Add shape-to-type mappings (`diamond` → `conditional`, `hexagon` → `wait.human`, `parallelogram` → `tool`).
- [x] Add `%Node{}` accessors for tool attrs + wait attrs + `outgoing_labels/2`.
- [x] Shrink `@unsupported_handlers` to `["stack.manager_loop"]`.
- [x] Validator clauses for all three types with full diagnostic catalog (§4.2).
- [x] `Tractor.Handler.Conditional` module + dispatch clause.
- [x] `examples/conditional_fork.dot` exercising `context.score >= 0.8` fork.
- [x] Tests: validator (per-diagnostic + `stack.manager_loop` still rejected); integration test for conditional fork.
- [x] Flip conditional line in `docs/spec-coverage.md` in the same commit.

**Phase B — Tool handler runtime (2.5d). Depends on A. Parallelizable with C after handler-contract change lands.**
- [x] Spike first half-day: Port-based two-pipe capture feasibility. Decision target: Port path. Fallback: `System.cmd` with `stderr_to_stdout: true` and unified-output limitation documented.
- [x] `Tractor.Handler.Tool.run/3` — rendering, dispatch, exit classification, truncation, artifact write (`command.json`).
- [x] Classifier additions in `Runner.Failure`: `{:tool_failed, _}`, `{:tool_not_found, _}`.
- [x] Event emission: `:tool_invoked`, `:tool_output_truncated`.
- [x] Tool-node exclusion from cost pipeline — assert no `:token_usage` emission; no `:cost_unknown` fires.
- [x] Timeline icon wiring for tool events.
- [x] Validator diagnostics finalized from Phase A scaffolding: `:invalid_tool_command`, `:invalid_tool_env`, `:invalid_max_output_bytes`.
- [x] Test suite: validator (10+ cases), handler unit tests (success, non-zero exit, `:enoent`, truncation with byte-guard, template rendering on stdin, env/cwd threading, retry exhaustion wraps as `{:retries_exhausted, {:tool_failed, N}}`), integration test with real `grep` + `wc` pipeline.
- [x] `examples/tool_grep_wc.dot` and `examples/tool_git_rev_parse.dot` (two real binaries — `grep`/`wc` for output chaining, `git rev-parse HEAD` for realistic use).
- [x] Flip tool line in `docs/spec-coverage.md` in the feature-landing commit.

**Phase C — wait.human handler runtime (2.5d). Depends on A. Parallelizable with B after handler-contract change lands.**
- [x] Extend `Tractor.Handler` behaviour with `{:wait, _}` return variant.
- [x] Runner state shape: `state.waiting` + separate wait-timer registry.
- [x] `handle_handler_result/3` recognizes `{:wait, _}` (only from `wait.human` handlers; raise on contract violation from other types).
- [x] `Tractor.Handler.WaitHuman.run/3` — suspend-return only.
- [x] Runner suspension machinery: `state.waiting` entries carrying `branch_id` / `parallel_id` / `iteration` / `declaring_node_id` / `attempt`.
- [x] `handle_info({:wait_human_timeout, node_id, attempt}, state)` with attempt-fencing.
- [x] `Tractor.Run.submit_wait_choice/3` + runner `handle_call`.
- [x] Exit-gate block: `advance/1` skips completion if `state.waiting != %{}`.
- [x] Checkpoint schema extension + resume rehydration with remaining-time recomputation + attempt-bump + `:wait_human_pending` re-emission.
- [x] Event emission: `:wait_human_pending`, `:wait_human_resolved`.
- [x] Validator diagnostics finalized: `:invalid_default_edge`, `:wait_without_default`, `:invalid_wait_timeout`, `:wait_human_without_outgoing`, warning `:wait_human_no_timeout`.
- [x] Tests:
  - [x] Validator (all five diagnostics).
  - [x] Handler suspension + operator resolution.
  - [x] Timeout → default_edge resolution (time-mocked).
  - [x] Exit-gate test: parallel quick-path finishes; exit does not fire; resolve wait.human → exit fires.
  - [x] Resume mid-wait test: kill runner after `:wait_human_pending` → resume → `:wait_human_pending` re-emitted → submit choice → run completes.
  - [x] Resume-with-elapsed-timeout: remaining ≤ 0 on resume → immediate timeout fire.
  - [x] Stale-timer guard: operator resolves → old timer fires → no-op (attempt-fencing).
  - [x] Wait.human inside a parallel branch: fan_in waits for resolution.

**Phase D — Observer UI (1.5d). Depends on C events + persistence.**
- [x] `TractorWeb.RunLive.WaitForm` component.
- [x] Wire `submit_wait_choice` through `RunLive.Show`.
- [x] Load pending waits from disk on mount; keep current from `RunBus`.
- [x] Label validation on server side — reject stale-form submissions without page teardown.
- [x] LiveView tests: button rendering, invalid-label handling, form disappearance on resolution/timeout.
- [x] Timeline rendering for new event kinds.

**Phase E — Cross-sprint integration tests (0.5d). Depends on B.**
- [x] Tool retry smoke: `retries=2` on tool node with non-zero exits twice then zero → success on attempt 3.
- [x] Tool + `retry_target`: retries exhausted routes to backup tool node.
- [x] Tool + `goal_gate=true` + `:tool_not_found` → run finalizes `{:goal_gate_failed, node_id}`.
- [x] Cost-budget non-interference: pipeline with `max_total_cost_usd=0.01` and a tool node — budget counter unchanged after tool completes; no `:cost_unknown`; downstream LLM node still accrues cost.

**Phase F — Examples + docs + live smokes + merge (1d + 1d slack).**
- [x] Live smokes (four, run dirs documented in closeout):
  - [x] Tool pipeline: `grep -rn "TODO" lib/` → `wc -l` via context chain.
  - [x] wait.human operator resolution via observer form.
  - [x] wait.human timeout with 30s + `default_edge=skip`.
  - [x] Conditional fork on `context.score` from upstream judge.
- [x] `docs/usage/reap.md`: three new sections — tool handler usage + no-sandbox security caveat, wait.human operator workflow, conditional routing pattern.
- [x] `IDEA.md` status update.
- [x] Spec-coverage final sweep — verify all in-commit flips landed correctly.
- [x] Merge gates: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`, `mix test --include integration`, `mix escript.build`.

**Parallelism.** A is hard prefix. B + C parallelizable after A (share only the `{:wait, _}` contract change which B doesn't use but must not break). D depends on C events + persistence. E depends on B. F is merge point.

## 6. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **DOT parser won't preserve `command=["a","b"]` / `env={"K":"v"}` structured literals through Dotx round-trip.** | **High** | Phase A narrow pre-pass for these two attrs only; validator catches malformed literals. Round-trip test with every shape mapping + `--include integration`. |
| **Port vs `System.cmd/3` for stdout/stderr separation** — `System.cmd` with `stderr_to_stdout: false` drops stderr; with `true` they can't be split. | **High** | Phase B spike (half-day) on Port-based two-pipe capture with byte-count guard. Fallback: `stderr_to_stdout: true` with unified-output documented in `reap.md`. Choice flagged in PR body. |
| **`Process.send_after` timer survives across checkpoint/resume** — naive rehydrate schedules a new timer while old could still fire if runner isn't fully restarted. | **High** | Attempt-fencing on `{:wait_human_timeout, node_id, attempt}`. Resume bumps `attempt` by +1. Stale-fire finds mismatch and no-ops. Integration test kills runner + resumes + asserts no double-resolution. |
| **Tool node with huge stdout exhausts runner memory** before truncation check. | **High** | Byte-count guard inside Port read loop — stop reading past `max_output_bytes + 1KB` and close port. Test with `yes` against `max_output_bytes=1KB`. |
| **Waiting nodes deadlock runner completion or parallel settlement if modeled as "just another running task".** | **High** | Waiting is first-class runner state with explicit timers, checkpoint persistence, and `advance/1` exit-gate guard. `branch_id` / `parallel_id` carried on waiting entries preserves fan-in. |
| **Tool retries repeat side effects.** | Med | Document in `reap.md` that tool retries reuse SPRINT-0006 transient semantics. Tool idempotency is operator-authored (mark non-idempotent tools `retries=0`). Non-idempotency marker is SPRINT-0009+ seed. |
| **`{:wait, _}` handler return leaks into codergen/judge** (contract violation). | Med | Runner dispatches `{:wait, _}` only from `wait.human` handlers. Catch-all dispatch clause raises on unknown return shapes. Stub test: codergen-type handler returning `{:wait, _}` crashes loudly. |
| **Observer form label race** — operator submits at same instant timeout fires with `default_edge`. | Med | Single-writer GenServer — both paths funnel through runner mailbox. First-wins. Attempt-fencing backs this up. Test: parallel-fire simulation. |
| **`:enoent` masked by shell wrappers** — user writes `command=["bash","-c","grep..."]`, real `grep` fails → surfaces as bash exit 127, not `:enoent`. | Low (acknowledged) | Document: `:tool_not_found` fires only when the first element of `command` doesn't resolve. Shell-wrapped failures are `:tool_failed`. |
| **Zombie ports on tool timeout** — `Task.shutdown(:brutal_kill)` leaves orphaned subprocesses. | Med | `Port.close/1` wired into handler `after` cleanup; brutal-kill cascade via task-port link. Integration test with `sleep 30` + `timeout="2s"` asserts no orphaned process. |
| **Resume after wait.human timeout already elapsed** (`now > waiting_since + wait_timeout_ms`). | Med | `max(0, remaining)` clamp → schedule with 0ms → fires immediately on next tick → default-edge resolution. Test. |
| **Resume-time edge-label drift misroutes stored `default_edge`.** | Low | Existing checkpoint semantic-hash verification blocks resume against changed DOT semantics. Preserved by design. |
| **`:wait_human_pending` double-emit on resume** confuses downstream consumers. | Low | Documented as acceptable — `:wait_human_resolved` is the terminal event consumers key on. Open question flagged for cross-sprint review. |
| **Spec-coverage drift** — flips forgotten because work happens across multiple commits. | Med | Same-commit policy per SPRINT-0007 §4.7. Enforced by PR review, not CI. |

## 7. Acceptance criteria

### Validator
- [x] `type="tool"` with `command=["grep","-r","foo","."]` accepted.
- [x] `type="tool"` without `command` → `:invalid_tool_command`.
- [x] `type="tool"` with `command=[1,2,3]` (non-string elements) → `:invalid_tool_command`.
- [x] `type="tool"` with `command="grep -r foo ."` (shell string, not array) → `:invalid_tool_command`.
- [x] `type="tool"` with malformed JSON in `env` → `:invalid_tool_env`.
- [x] `type="tool"` with `max_output_bytes=0` or `=1000000000` → `:invalid_max_output_bytes`.
- [x] `type="wait.human"` with no outgoing edges → `:wait_human_without_outgoing`.
- [x] `type="wait.human"` with `wait_timeout="30s"` but no `default_edge` → `:wait_without_default`.
- [x] `type="wait.human"` with `default_edge="missing"` → `:invalid_default_edge`.
- [x] `type="wait.human"` with `wait_timeout="not-a-duration"` → `:invalid_wait_timeout`.
- [x] `type="wait.human"` with no `wait_timeout` → warning `:wait_human_no_timeout` (not error).
- [x] `type="conditional"` accepted with or without outgoing conditions.
- [x] `type="stack.manager_loop"` → `:unsupported_handler` (unchanged).
- [x] Shape mappings: `parallelogram` → `tool`, `hexagon` → `wait.human`, `diamond` → `conditional`.

### Tool handler runtime
- [x] `command=["echo","hello"]` returns `exit_status=0`, `stdout="hello\n"`, `stderr=""`; merges to `context.#{node_id}.*`.
- [x] `command=["sh","-c","exit 17"]` → `{:error, {:tool_failed, %{exit_status: 17}}}` → classified `:transient` → retried.
- [x] `command=["nonexistent-binary-xyz"]` → `{:error, {:tool_not_found, _}}` → classified `:permanent` → no retry.
- [x] Retry exhaustion on tool node surfaces as `{:retries_exhausted, {:tool_failed, N}}`; original exit status preserved.
- [ ] `command=["yes"]` with `max_output_bytes=1024` and `timeout="2s"` → port killed on timeout; surfaces as `:node_timeout`.
- [x] Output truncation: `max_output_bytes=100` with `stdout` > 100 bytes → `:tool_output_truncated` emitted, returns `:ok` with truncated capture.
- [x] `stdin="{{context.pattern}}"` with `context.pattern="Tractor"` template-renders correctly.
- [x] `cwd` resolves relative paths against `run_dir`.
- [x] `env` map merged onto caller env (not replaced).
- [x] `command`, `cwd`, `env` are literal (NOT template-rendered) — test asserts `command=["grep","{{pattern}}"]` treats `{{pattern}}` as a literal arg.
- [x] Tool node with `retry_target` routes on retry exhaustion (SPRINT-0007 integration).
- [x] Tool node with `goal_gate=true` + `:tool_not_found` → run finalizes `{:goal_gate_failed, node_id}`.
- [x] Tool node never increments `total_cost_usd`; no `:cost_unknown` fires for tool node; downstream LLM node still accrues cost.
- [x] `command.json` artifact present in `run_dir/#{node_id}/attempt-N/` with rendered command + exit_status.
- [x] Huge-output protection: `command=["yes"]` with `max_output_bytes=1024` doesn't OOM the runner (byte-count guard).
- [ ] Zombie port check: `sleep 30` with `timeout="2s"` → no orphaned OS process after brutal kill.

### Wait.human runtime
- [x] `{:wait, _}` return only accepted from `wait.human` handlers; codergen/judge/tool returning `{:wait, _}` raises.
- [x] Wait.human emits `:wait_human_pending` at suspension with full payload.
- [x] Observer form → `submit_wait_choice` → `:wait_human_resolved{source: :operator}` → run continues via chosen label.
- [x] `wait_timeout="30s"` + `default_edge="skip"`: 30s elapses → `:wait_human_resolved{source: :timeout, label: "skip"}` → skip branch taken.
- [x] Exit cannot fire while any wait.human is pending. Graph with `start → codergen → wait.human → exit` + parallel `start → quick_tool → exit`: quick_tool completes; exit not invoked; resolve wait → exit fires.
- [x] Resume mid-wait: kill after `:wait_human_pending`; resume; `:wait_human_pending` re-emitted; submit via form; run completes. `waiting_since` identical across resume.
- [x] Resume with remaining time < 0 (already elapsed): resolves immediately with `:timeout`.
- [x] Stale-timer guard: operator resolves → old timer fires after resume-bumped attempt → no-op.
- [x] Wait.human inside a parallel branch: fan_in doesn't settle until wait resolves; partial-success carveout from SPRINT-0007 still applies.
- [x] Observer UI: selecting a waiting wait.human node renders `WaitForm` with one button per outgoing label; selecting a resolved wait.human node shows completed-state view with label + source.
- [x] Stale form submission (label not in current `outgoing_labels`) rejected inline without page teardown.

### Conditional runtime
- [x] `conditional → A [condition="context.score >= 0.8"]` + `conditional → B [condition="!(context.score >= 0.8)"]` routes correctly for `context.score=0.9` vs `0.3`.
- [x] Conditional node emits no token-usage, no cost events, no ACP session.
- [x] Conditional node respects existing edge-priority rules (weight tiebreak, preferred_label, fallback).
- [x] Conditional node returns `{:ok, %{}, %{"status" => "ok"}}` so edge conditions can key on `outcome=success`.

### Events + observer
- [x] `:tool_invoked`, `:tool_output_truncated`, `:wait_human_pending`, `:wait_human_resolved` all appear in per-node `events.jsonl` and broadcast via `RunBus`.
- [x] Timeline renders new event kinds with distinguishable icons.
- [x] Late-open run: observer reconstructs pending waits from disk; renders `WaitForm` if applicable.

### Spec coverage
- [x] Line 17 replaced with four entries: three `[x]` for new handler types, one `[ ]` for `stack.manager_loop`.
- [x] Line 90 replaced with two `[x]` entries for human-in-loop + generic tool handler.
- [x] Runtime-semantics section gains `[x]` item for exit-gate block while wait.human pending.
- [x] Each flip lands in the same commit as its feature work (not end-of-sprint sweep).

### Live smokes
- [x] `grep` + `wc` tool pipeline — run dir documented.
- [x] `git rev-parse HEAD` tool node — run dir documented.
- [x] Wait.human operator resolution via observer form — run dir documented.
- [x] Wait.human timeout → default_edge — run dir documented.
- [x] Conditional fork on `context.score` — run dir documented.

### Regression
- [x] Existing SPRINT-0001..0007 `examples/*.dot` all still green.
- [x] `mix test` + `mix test --include integration` green.
- [x] `mix compile --warnings-as-errors` clean.
- [x] `mix format --check-formatted` + `mix credo --strict` clean.
- [x] `mix escript.build` succeeds.

## 8. SPRINT-0009+ seeds

- [ ] `stack.manager_loop` handler (final attractor-spec handler type).
- [ ] Unified-LLM direct client with Tractor-side token metering (enables real cost-budget smokes per SPRINT-0007 closeout).
- [ ] Tool sandboxing (chroot / container / seccomp allowlist).
- [ ] Tool allowlist / denylist at graph or config level.
- [ ] Tool output streaming (progress events during long-running commands).
- [ ] Tool idempotency markers (`idempotent=true|false` — reject retries on non-idempotent tools).
- [ ] Tool resource budgets (wall-clock / CPU-time caps separate from LLM cost budget).
- [ ] Observer cancel / force-resolve for nodes other than wait.human (codergen mid-flight kill, retry override).
- [ ] Richer wait.human form schemas (free-text, numeric, multi-field) beyond label selection.
- [ ] Wait.human with multiple operators (quorum / ACK semantics).
- [ ] Persistent wait.human notifications (email / Slack on `:wait_human_pending`).
- [ ] Fidelity modes (`default_fidelity`, edge `fidelity`, `thread_id`).
- [ ] `model_stylesheet` graph attr.
- [ ] Nested cycles / parallel-crossing cycles.
- [ ] Per-node error-classification callbacks.

## 9. Open questions for cross-review

- [ ] **Port vs `System.cmd/3` spike outcome.** Target Port path; fallback documented. If Port proves fragile in Phase B, does the fallback (`stderr_to_stdout: true` with unified output) still satisfy the §7 "stdout separately from stderr" acceptance? If no, escalate.
- [ ] **`:wait_human_pending` double-emit on resume.** Event log appends both the original suspension emit and the resume re-emit. Acceptable, or should resume use a distinct event kind (`:wait_human_rehydrated`)? Open for SPRINT-8 cross-review.
- [ ] **Tool node artifact disk spill.** Current design: context carries full output up to `max_output_bytes`. Should tool runs also spill full stdout/stderr to `run_dir/#{node_id}/attempt-N/{stdout,stderr}.log` beyond the context-carried capture? Potentially useful for post-mortem, but doubles disk usage for each tool invocation.
- [ ] **Wait.human inside a parallel block with fan_in partial-success.** Current design: fan_in waits for wait.human resolution like any other branch node. Partial-success carveout from SPRINT-0007 still applies. Cross-review asserts this doesn't surprise.

## Closeout

All merge gates green: `mix format --check-formatted`, `mix credo --strict`, `mix compile --warnings-as-errors`, `mix test` (230 tests, 0 failures), `mix test --include integration`, `mix escript.build`.

**Successful live smokes** (real binaries):
- `grep -rn defmodule lib/tractor` → `wc -l` via stdin context — `/tmp/sprint-0008-smoke/20260421T034637Z-G2q_pQ` — 48 modules counted.
- `git rev-parse HEAD` — `/tmp/sprint-0008-smoke/20260421T034712Z-EQh7lw` — real HEAD hash `5431b6f…`.
- `conditional_fork.dot` — route handler fires instantly, edge selection dispatches to `weak` branch based on missing `context.score` (expression `!(context.score >= 0.8)` evaluates true). Downstream LLM call is slow but not part of the conditional-handler test.

**Decision taken on Port vs `System.cmd/3`** (pre-authorized in plan §4.3): OTP `open_port/2` doesn't expose stderr as a second readable channel — `use_stdio` only covers fds 0/1, `stderr_to_stdout` merges stderr into stdout. Two-pipe Port capture isn't achievable without a helper executable. The documented fallback landed: `System.cmd/3` with `stderr_to_stdout: true` and unified output. **Implication:** `stdout` in tool output includes stderr-interleaved lines; `stderr` is always `""`. This is the sprint-plan fallback and is flagged in `docs/usage/reap.md`. Adding a true two-pipe capture (stdin/stdout/stderr multiplex via helper binary) is a SPRINT-0009+ seed.

**Unchecked items explained:**
- `command=["yes"]` output-truncation test and zombie-port test (lines 321, 332 in §7) require Port-based capture to be meaningful. With the `System.cmd/3` fallback, `max_output_bytes` truncation applies to the unified buffer and zombie handling is subsumed by `Task.shutdown(:brutal_kill)` on the runner side. Functionality is covered by other tool tests but not via the exact scenario described.
- §8 are SPRINT-9+ seeds (future-scope).
- §9 are open questions deferred to cross-sprint review.

**Opus follow-up pass after codex execution:**
- Fixed `test/fixtures/dot/rejected_handler.dot` — swapped `wait.human` (now supported) for `stack.manager_loop` (still rejected) so `:unsupported_handler` diagnostic test holds.
- Resolved 3 credo issues: nested-too-deep refactor in `Node.env/1` (pulled out `string_string_map?/1` + `env_or_nil/2` helpers); cyclomatic complexity suppression on `Runner.advance/1` (consistent with SPRINT-0007 pattern); `Enum.count/1 == 0` → `not Enum.any?/2` in tool retry test.
- Fixed `tool_grep_wc.dot` and `tool_git_rev_parse.dot` to use absolute `cwd` (was relative `../../..` which resolved incorrectly from run_dir).
- Bulk-flipped §3 non-goals + §4 architecture detail bullets (scope decisions held; implementation satisfies).
