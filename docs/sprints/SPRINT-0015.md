# SPRINT-0015 — Reliability & resilience: consolidate four structural weak spots

A debt-paydown sprint, not a feature sprint. A recent session surfaced 12+ bugs that all trace back to the same four shapes: terminal state is written from many sites, JSON encoding is invoked from many sites, the ACP wire-format parser has structural assumptions, and "did the gate accept?" is inferred from signals that don't carry the verdict. Each fix replaces a scattered pattern with one consolidated boundary so whole classes of bugs become structurally impossible (or caught at a single tested choke point) rather than re-emerging at a new call site.

## Exit criteria (measurable in code)

1. **One terminal-state writer.** `Tractor.Run.finalize/2` at `lib/tractor/run.ex` is the only path to manifest `"status" ∈ {"ok","error","interrupted","goal_gate_failed"}` and to the canonical `_run/run_finalized` event. Every runner site (`complete_success`, `fail_node`, `fail_goal_gate`, `finalize_interrupted`) and the reconciler site (`RunWatcher.Reconcile.mark_reconciled!`) route through it. `rg "RunStore\.finalize\(" lib test` returns one match, inside `Tractor.Run.finalize/2`.
2. **One sanitize-at-boundary wrapper.** `Tractor.JSON.encode!/2` (and `encode_to_iodata!/2`) is the only path from Tractor code to `Jason.encode!`. `TractorWeb.SafePush.push_event/3` is the only path to Phoenix `push_event`. `rg "Jason\.encode_?(to_iodata)?!" lib/tractor*` returns matches only inside `Tractor.JSON`; `rg "Phoenix\.LiveView\.push_event\|push_event\(\s*socket" lib/tractor_web` returns matches only inside `TractorWeb.SafePush`. A CI check enforces both.
3. **ACP wire-replay regression gate.** `test/tractor/acp/wire_replay_test.exs` exists, replays at least two redacted captured wire-log fixtures, and asserts zero `FunctionClauseError`, zero process crashes, and exactly the expected `:acp_unhandled_*` telemetry for any unknown frames.
4. **`gate_verdict` event distinct from `node_succeeded`.** Conditional gates emit a first-class `_node/gate_verdict` event from `Tractor.Runner.enqueue_next/3` carrying `verdict`, `routed_to`, `condition`, `label`, `routing_status`. UI graph/sidebar colors derive from `gate_verdict` (mirroring `judge_verdict`). The substring-match-on-edge-condition branch in `lib/tractor_web/run_live/show.ex` is deleted.

## Non-goals

New pipeline features, new node types, new observer widgets, validator/DOT-parser changes, the skills bundle, SPRINT-0014 (ACP transient quota — revisited after this sprint on the cleaner foundation). Backwards-compat for on-disk runs is nice-to-have but not load-bearing — manifest schema can break if it simplifies the contract. PR-body polish / demo GIFs.

---

## Current grounding

### Weak spot 1 — finalize scatter

| Site | File:line | Behavior |
|---|---|---|
| `complete_success/1` | `lib/tractor/runner.ex:819` | finalize ok + emits `run_completed` + `run_finalized` + stops StatusAgent |
| `fail_node/3` | `lib/tractor/runner.ex:791` | finalize error + emits `run_failed` + `run_finalized` + stops StatusAgent |
| `fail_goal_gate/3` | `lib/tractor/runner.ex:838` | finalize goal_gate_failed + emits `goal_gate_failed` + `run_finalized` + stops StatusAgent |
| `finalize_interrupted/1` | `lib/tractor/runner.ex:856` | finalize interrupted + emits `run_interrupted` + `run_finalized` + stops StatusAgent |
| `RunWatcher.Reconcile.mark_reconciled!/2,3` | `lib/tractor/run_watcher/reconcile.ex:62-74` | finalize interrupted + emits `run_reconciled` (NOT `run_finalized` — the bug surfaced this session) |
| `RunStore.resume/1` | `lib/tractor/run_store.ex` | non-terminal reset back to `"running"` — separate path |

Each terminal-state site duplicates the same recipe with subtle variations. The reconciler additionally calls `Tractor.RunEvents.register_run/2` because the events table may be missing on a fresh observer BEAM — that quirk must be preserved.

### Weak spot 2 — Jason / push_event boundary

`Tractor.Text.sanitize/2` (`lib/tractor/text.ex`) exists and is correct. Recent commit `aee9eaa` papered over two ACP-prompt sites where a byte-truncated em-dash crashed `Jason.encode!`. But `rg 'Jason\.encode' lib/` shows ~14 callers; any of them can be handed a binary from an LLM bridge. Sanitizing inbound at the prompt site doesn't protect the other 12. `TractorWeb.Format.sanitize_text/2` is a duplicate of `Tractor.Text.sanitize/2` that must be reconciled.

### Weak spot 3 — ACP wire-format brittleness

`lib/tractor/acp/session.ex` matches on:
- Port data shape: `:noeol` (line 184), `:eol` (line 192), `:exit_status` (line 204). **No `{port, _other}` catch-all** — a future port mode or fragment crashes the GenServer.
- `sessionUpdate` kinds in `dispatch_update/3` — catch-all `acp_unknown_update` exists (good).
- JSON-RPC `handle_message/2` — catch-all `emit_unknown_message/2` exists (good).
- Top-level `handle_info/2` and `handle_call/3` — catch-alls partial/absent.

Recent fixes (`bf10b4c` for `:noeol`, `123f829` for `usage_update`) addressed individual surprises but not the class.

### Weak spot 4 — gate verdict / routing / execution-status conflation

`lib/tractor/handler/conditional.ex` is a 12-line no-op handler returning `{:ok, %{}, %{status: %{"status" => "ok"}}}`. The gate's decision lives in the edge picked by `Tractor.Runner.enqueue_next/3` at `lib/tractor/runner.ex:883`. The UI at `lib/tractor_web/run_live/show.ex` (≈ lines 585-606) substring-matches `"reject"|"fail"|"accept"|"pass"` against `edge.condition` from the `:edge_taken` event — that's where green-on-reject came from. `lib/tractor/handler/judge.ex:191-207` emits `:judge_verdict` and the UI consumes it as a first-class signal. Conditionals should mirror that contract.

---

## Phase 0 — Baseline & inventory

Lands first; pure measurement, no behavior change.

- [x] Run focused baseline suite: `mix test test/tractor/run_test.exs test/tractor/tool_run_test.exs test/tractor/wait_human_run_test.exs test/tractor/run_watcher/reconcile_test.exs test/tractor/acp/session_test.exs test/tractor_web/run_live_test.exs`. Record green.
- [x] Capture finalize-site inventory: `rg "RunStore\.finalize|run_finalized|run_completed|run_failed|run_interrupted|goal_gate_failed" lib/tractor lib/tractor_web test`. Save to PR body / sprint notes.
- [x] Capture encode/push inventory: `rg "Jason\.encode_?(to_iodata)?!|push_event\(" lib/tractor lib/tractor_web`. Save.
- [x] Capture `Tractor.Text.sanitize_text` duplicate inventory: `rg "sanitize_text" lib/tractor_web/format.ex test`.

---

## Phase A — Single run finalization

### A.1 — Add `Tractor.Run.finalize/2` and migrate every production caller (one commit)

Signature lives at `lib/tractor/run.ex`, next to `start/2`, `resume/2`, `await/2`, `info/1`. `RunStore.finalize/2` becomes a one-line delegating shim during this phase; A.2 deletes it.

```elixir
@type finalize_attrs :: %{
        required(:status) => String.t(),     # "ok"|"error"|"interrupted"|"goal_gate_failed"
        optional(:reason) => term(),
        optional(:provider_commands) => list(),
        optional(:total_cost_usd) => String.t(),
        optional(:source) => :runner | :reconciler,  # default :runner
        optional(:terminal_event) => {atom(), map()} # caller-supplied status-specific event
      }

@spec finalize(RunStore.t(), finalize_attrs()) :: :ok
```

Internal behavior, in order: (1) read latest on-disk manifest; if already terminal, return `:ok` (idempotent for repeat terminate/reconcile races). (2) Call `RunStore.write_terminal_manifest/2` (a new private helper that absorbs `RunStore.finalize/2`'s side-effects). (3) Ensure-register the events table only when `RunEvents.emit/4` reports `:run_not_registered` — never blindly. (4) Emit the caller's `:terminal_event` if provided, else a stock status-specific event (`:run_completed`, `:run_failed`, `:run_interrupted`, `:goal_gate_failed`). When `source: :reconciler`, additionally emit `:run_reconciled` with `reason`, `owner_pid`. (5) Emit canonical `:run_finalized` with `%{"status" => status, "reason" => reason_or_nil, "source" => source}`. (6) Call `Tractor.StatusAgent.stop_run/1`. (7) Clear runner pidfile via `RunStore.delete_runner_pidfile/1`.

- [x] Add `Tractor.Run.finalize/2` per signature above; place after `info/1` so public-API ordering stays start/resume/await/info/finalize.
- [x] Move `RunStore.finalize/2`'s on-disk side-effects into a new private `RunStore.write_terminal_manifest/2`. Keep `RunStore.finalize/2` as a one-line delegating shim until A.2.
- [x] Make `Tractor.Run.finalize/2` idempotent: re-read manifest before writing; if already terminal, return `:ok` without re-emitting events.
- [x] Add the "ensure-registered only on `:run_not_registered`" PubSub safety to the finalizer.
- [x] Update `Tractor.Runner.complete_success/1` (`lib/tractor/runner.ex:819`) to call `Tractor.Run.finalize/2` with `status: "ok"` + provider commands + total cost.
- [x] Update `Tractor.Runner.fail_node/3` (`lib/tractor/runner.ex:791`) to call `Tractor.Run.finalize/2` with `status: "error"`. Keep per-node `:node_failed` emission at the call site.
- [x] Update `Tractor.Runner.fail_goal_gate/3` (`lib/tractor/runner.ex:838`) to pass `terminal_event: {:goal_gate_failed, %{node_id: node_id, reason: reason}}` so the dedicated payload survives.
- [x] Update `Tractor.Runner.finalize_interrupted/1` (`lib/tractor/runner.ex:856`) to call `Tractor.Run.finalize/2` with `status: "interrupted"`.
- [x] Update `Tractor.RunWatcher.Reconcile.mark_reconciled!/2,3` (`lib/tractor/run_watcher/reconcile.ex:51-74`) to call `Tractor.Run.finalize/2` with `status: "interrupted", reason: reason, source: :reconciler`. Drop the inline `RunStore.finalize`, `register_run`, and `run_reconciled` emit — they all move into the finalizer's `:reconciler` branch.
- [x] Add `test/tractor/run_finalize_test.exs` with cases: ok / error / interrupted-runner / interrupted-reconciler / goal_gate_failed. Each asserts both the status-specific event AND the canonical `run_finalized`. The reconciler case asserts `run_reconciled` + `run_interrupted` + `run_finalized` are all present (this is the surfaced bug).
- [x] Update `test/tractor/run_watcher/reconcile_test.exs` to assert `events.jsonl` contains `run_finalized` after `reconcile_dead_runs/1`. The existing test currently passes by *not* asserting this — that's the bug. Treat assertion update as the fix.
- [x] Add `test/tractor/run_store_resume_test.exs` asserting `RunStore.resume/1`: drops `finished_at` and `reason`, sets `"status" => "running"`, does NOT emit `run_finalized`, leaves `started_at` intact.
- [x] Add idempotency regression: call `Tractor.Run.finalize/2` twice in a row on the same store; assert exactly one `run_finalized` event in `events.jsonl`.
- [x] Update `Tractor.Run` moduledoc: `finalize/2` is the only public path to terminal state.

### A.2 — Delete the `RunStore.finalize/2` shim (separate commit)

- [x] Grep `lib/`, `test/`, `examples/` for any remaining direct callers of `RunStore.finalize/2`; route them through `Tractor.Run.finalize/2`. Tests are the most likely holdouts.
- [x] Delete the `RunStore.finalize/2` shim.
- [x] Verify exit criterion: `rg "RunStore\.finalize\(" lib test` returns zero matches (stronger than the planned single-match — `Tractor.Run.finalize/2` writes via `RunStore.write_terminal_manifest/2`, not `RunStore.finalize/2`).

---

## Phase B — Sanitize JSON & LiveView boundaries

### B.1 — Add `Tractor.JSON` and `TractorWeb.SafePush` (commit; both unused on land)

```elixir
defmodule Tractor.JSON do
  @moduledoc """
  The only path from Tractor code to Jason.encode!/1. Recursively sanitizes
  binaries via Tractor.Text.sanitize/2 before delegating, so a byte-truncated
  multibyte string can never crash the encoder.
  """

  @spec encode!(term(), keyword()) :: String.t()
  def encode!(term, opts \\ []), do: term |> sanitize_payload(opts) |> Jason.encode!(opts)

  @spec encode_to_iodata!(term(), keyword()) :: iodata()
  def encode_to_iodata!(term, opts \\ []),
    do: term |> sanitize_payload(opts) |> Jason.encode_to_iodata!(opts)

  @spec sanitize_payload(term(), keyword()) :: term()
  def sanitize_payload(bin, opts) when is_binary(bin), do: Tractor.Text.sanitize(bin, opts)
  def sanitize_payload(list, opts) when is_list(list), do: Enum.map(list, &sanitize_payload(&1, opts))
  def sanitize_payload(map, opts) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {sanitize_payload(k, opts), sanitize_payload(v, opts)} end)
  def sanitize_payload(other, _opts), do: other
end
```

`TractorWeb.SafePush.push_event/3` is a thin wrapper that calls `Tractor.JSON.sanitize_payload(payload)` before delegating to `Phoenix.LiveView.push_event/3`.

- [x] Add `lib/tractor/json.ex` (`Tractor.JSON`). Keep `Tractor.Text.sanitize/2` as the underlying sanitizer — encoding and sanitization stay separate concerns; Text is not the home of the encode boundary.
- [x] Add `lib/tractor_web/safe_push.ex` (`TractorWeb.SafePush.push_event/3`).
- [x] Add `test/tractor/json_test.exs`:
  - encodes binary ending mid-codepoint (`<<0xE2, 0x80>>`) without raising.
  - encodes deeply-nested map whose innermost string is byte-truncated; structure preserved, leaf sanitized.
  - encodes a `DateTime` struct without sanitizing its internal fields (the `not is_struct` guard).
  - round-trip preserves valid-UTF-8 strings byte-for-byte.
- [x] Add `test/tractor_web/safe_push_test.exs`: pushes a payload containing an invalid-UTF-8 binary, asserts the pushed event carries sanitized strings.

### B.2 — Migrate every caller (commit per logical group)

Sites to migrate (`rg -l 'Jason\.encode' lib/`): `run_store.ex`, `acp/session.ex`, `status_agent.ex`, `agent/codex.ex`, `runner/control_file.ex`, `context.ex`, `tractor_web/run_live/tool_call_view.ex`, `tractor_web/markdown.ex`, `tractor_web/run_live/show.ex`, `handler/judge.ex`, `handler/tool.ex`, `handler/wait_human.ex`, `checkpoint.ex`, `event_log.ex`.

- [x] Migrate `Tractor.RunStore.encode_json!/1` to delegate to `Tractor.JSON.encode_to_iodata!/2`. This single change covers manifest, status.json, and per-node status files.
- [x] Migrate `Tractor.EventLog.append/3` encoding to `Tractor.JSON.encode!/1`. Highest-leverage migration — every event payload flows through here.
- [x] Migrate `lib/tractor/acp/session.ex` (`send_message/2`, `write_wire/3`) to `Tractor.JSON.encode!/1`. Keep the inbound `Tractor.Text.sanitize/2` at handle_call sites — defense in depth.
- [x] Migrate the remaining 10 callers in one commit (one-line changes; group reduces review burden): `status_agent.ex`, `agent/codex.ex`, `runner/control_file.ex`, `context.ex`, `tractor_web/run_live/tool_call_view.ex`, `tractor_web/markdown.ex`, `tractor_web/run_live/show.ex`, `handler/judge.ex`, `handler/tool.ex`, `handler/wait_human.ex`, `checkpoint.ex`.
- [x] Replace every `push_event(socket, ...)` in `lib/tractor_web/run_live/show.ex` (graph state, edge_taken, badges, selection) with `TractorWeb.SafePush.push_event/3`. Use `import TractorWeb.SafePush, only: [push_event: 3]` to avoid renaming at every call site.
- [x] Reconcile `TractorWeb.Format.sanitize_text/2`: either delegate to `Tractor.Text.sanitize/2` or delete after migrating callers. Pick the cheaper. (Now delegates.)

### B.3 — Add CI gate against direct callers (commit)

- [x] Add `mix tractor.check_encoding` (or extend an existing `mix check` task) that fails non-zero if any production code outside `Tractor.JSON` calls `Jason.encode!`/`Jason.encode_to_iodata!`, or if any production code outside `TractorWeb.SafePush` calls `Phoenix.LiveView.push_event` / `push_event(socket, ...)`. Wire into CI.
- [x] Add a regression smoke test that hands `Tractor.RunEvents.emit/4` an `agent_message_chunk` payload whose text ends in `<<0xE2>>` (the original `aee9eaa` repro) and asserts `events.jsonl` writes successfully with a valid-UTF-8 row.
- [x] Add a LiveView push test that constructs a graph state payload with invalid UTF-8 in a nested map and asserts the rendered LiveView remains valid.

---

## Phase C — ACP parser fallbacks & replay harness

### C.1 — Catch-all-with-telemetry (commit)

- [x] Add to `Tractor.ACP.Session` moduledoc: every protocol parser path emits `:acp_unhandled_*` telemetry on unmatched input and never raises.
- [x] Add `defp emit_unhandled(state, kind, payload)` that: emits `:acp_unhandled_<kind>` to the event sink with sanitized metadata, and emits `[:tractor, :acp, :unhandled]` via `:telemetry.execute/3` (the two channels are distinct: event sink → timeline; telemetry → dashboards).
- [x] Add `handle_info({port, _other}, %{port: port} = state)` catch-all after the `:exit_status` clause (~line 207). Emits `:acp_unhandled_port_data`. Place explicitly so it can't swallow non-port messages.
- [x] Audit `handle_info(_other, state)` catch-all — verify it fires for unknown messages without `{:EXIT, ...}` shape.
- [x] Add `handle_call(_other, _from, state)` catch-all replying `{:reply, {:error, :unknown_call}, state}` if absent.
- [x] Audit `dispatch_update/3` catch-all (already exists as `:acp_unknown_update`) — ensure `kind` is sanitized via `Tractor.JSON.sanitize_payload/1` before logging.
- [x] Audit `finish_prompt/2` — replace any case-clause crash on a missing/non-binary `stopReason` with a controlled `{:invalid_prompt_result, result}` error plus telemetry.
- [x] Add regression tests: send `{:foo, :bar}` to a session GenServer; assert no crash + `:acp_unhandled_message` event. Send a `{:data, :some_weird_atom}` port shape; assert no crash + `:acp_unhandled_port_data` event.

### C.2 — Wire-log replay harness (commit)

The replay harness lives in test/support — it does NOT need a production-side `Tractor.ACP.WireReplay` API. If the replay turns out awkward without extracting a `Tractor.ACP.Session.Decoder`, do the extraction as a follow-up; don't pre-emptively refactor protocol-core code in a reliability sprint.

- [x] Extend `test/support/fake_acp_agent.exs` (or add a sibling) with modes for: raw port chunks, malformed prompt results, unknown notifications, unknown requests, unknown `session/update` kinds. (Added `silent` mode; existing fake-agent already covered the other shapes.)
- [x] Add `test/support/acp_wire_replay.ex` with `ACPWireReplay.run_fixture(path, opts \\ [])` — feeds a redacted fixture line-by-line through a fake-port-backed `Tractor.ACP.Session`, splits frames > `@line_length` into `:noeol` + `:eol` to exercise the buffer, and returns the captured event-sink output.
- [x] Capture and redact two real wire-log fixtures into `test/fixtures/acp/wire_logs/`:
  - `claude-happy-prompt.jsonl` — full prompt cycle: init, agent_message_chunks, tool_calls, usage event, stop_reason.
  - `codex-noeol-and-usage.jsonl` — Codex session with `:noeol` chunk splits, at least one `usage_update`, and one novel `sessionUpdate` kind (hand-add a `"sessionUpdate": "experimental_plan_v2"` row to exercise the unknown path).
- [x] Add `docs/notes/acp-wire-replay.md` documenting the redaction policy (hand-edit prompts/responses to remove project-identifying strings, keep frame shape) and the refresh process for fixtures.
- [x] Add `test/tractor/acp/wire_replay_test.exs`:
  - Replays `claude-happy-prompt.jsonl`; asserts agent_message_chunks in order, a final usage event, zero `:acp_unhandled_*`.
  - Replays `codex-noeol-and-usage.jsonl`; asserts zero `FunctionClauseError`, zero process crashes, exactly one `:acp_context_window` event, at least one `:acp_unknown_update`, and the line-buffer correctly rejoined split chunks.
- [x] Update `docs/usage/testing.md` with the replay test command and fixture refresh expectations.

---

## Phase D — Gate verdict event

### D.1 + D.2 — Emit and consume (one commit)

Three independent signals get three independent events:

| Signal | Event | Emitted from |
|---|---|---|
| Execution success/failure | `:node_succeeded` / `:node_failed` | Runner success/failure paths (existing) |
| Routing outcome | `:edge_taken` | `Runner.enqueue_next/3` (existing) |
| Gate verdict | `:gate_verdict` (new) | `Runner.enqueue_next/3`, after `:edge_taken` |

```elixir
defp maybe_emit_gate_verdict(state, %Node{type: "conditional", id: node_id}, edge, routing_outcome) do
  verdict = derive_gate_verdict(edge, routing_outcome)

  RunEvents.emit(state.store.run_id, node_id, :gate_verdict, %{
    "node_id" => node_id,
    "iteration" => Map.get(state.iterations, node_id),
    "verdict" => verdict,             # "accept" | "reject" | "unknown"
    "routed_to" => edge.to,
    "condition" => edge.condition,
    "label" => edge.label,
    "routing_status" => Atom.to_string(routing_outcome.status)
  })
end

defp maybe_emit_gate_verdict(_state, _node, _edge, _outcome), do: :ok

defp derive_gate_verdict(%{label: label}, _outcome)
     when label in ["accept", "reject"], do: label
defp derive_gate_verdict(%{condition: condition}, _outcome) when is_binary(condition) do
  lowered = String.downcase(condition)
  cond do
    String.contains?(lowered, "reject") or String.contains?(lowered, "fail") -> "reject"
    String.contains?(lowered, "accept") or String.contains?(lowered, "pass") -> "accept"
    true -> "unknown"
  end
end
defp derive_gate_verdict(_edge, _outcome), do: "unknown"
```

Verdict derivation prefers explicit edge `label` (the structured signal), falls back to condition substring (today's UI heuristic, now centralized in one place), and explicitly emits `"unknown"` when neither matches — never silently falls through to a wrong color.

- [x] Add `maybe_emit_gate_verdict/4` and `derive_gate_verdict/2` (private) in `lib/tractor/runner.ex` next to `enqueue_next/3`.
- [x] Update `Runner.enqueue_next/3` to call `maybe_emit_gate_verdict/4` immediately after the `:edge_taken` emit. Thread `routing_outcome` through if not already in scope.
- [x] Add LiveView clauses in `lib/tractor_web/run_live/show.ex` `update_node_state/3` mirroring the `:judge_verdict` clauses: `"verdict" => "reject"` → `"rejected"`, `"verdict" => "accept"` → `"accepted"`, `"verdict" => "unknown"` → leave state unchanged.
- [x] Add `test/tractor/runner/gate_verdict_test.exs`:
  - Conditional node with explicit `accept`/`reject` labelled edges: drive both routings, assert `gate_verdict` event with correct verdict + `routed_to` + `label`, AND `node_succeeded`, AND `edge_taken` all present and distinct.
  - Conditional with verbose condition like `context.x contains "VERDICT: reject"`: assert `verdict: "reject"` derived from condition substring.
  - Conditional with ambiguous condition: assert `verdict: "unknown"`.
  - Assert recovery routing (via `Routing.next_target/2`) does NOT fire `gate_verdict`.
- [x] Add LiveView regression test: feed a `:gate_verdict reject` event via `RunBus.broadcast/2`; assert `node_states[gate]` becomes `"rejected"` and `graph:node_state` push fires.

### D.3 — Delete the substring-match-on-edge-condition (separate commit)

- [x] Delete the `update_node_state(states, node_id, %{"kind" => "edge_taken", "data" => %{"condition" => condition}})` clause in `lib/tractor_web/run_live/show.ex` (the substring matcher I added in `c04bdd1`). The verdict path is now `gate_verdict`-driven.
- [x] Confirm `replay_node_state_events/2` (event-replay-from-disk path on mount) still reaches the correct final state for runs whose `events.jsonl` predates `gate_verdict` — back-compat smoke. Per intent, manifest-schema breakage is acceptable, so a regressed color for pre-sprint runs is OK; verify nothing crashes.
- [x] Update `docs/handlers.md` conditional-node section to document `gate_verdict` as the routing verdict event and `node_succeeded` as execution-status only.

---

## Phase E — Secondary scope (in-scope-if-it-fits)

### Burrito-for-dev question

Default recommendation: park. The escript leaks (`priv_dir`, cwd-relative paths, dev-env config bleed) are diagnosable case-by-case and have been fixed in place; Burrito-wrapping `bin/tractor` for dev adds a build-time cost on every rebuild that the team would pay constantly.

- [x] Write `docs/notes/burrito-for-dev.md` summarizing: the four leaks observed; how Burrito would fix them; the dev-loop cost (mix release + wrap on every rebuild); the recommendation to defer; the trigger conditions for revisiting (e.g. a third class of leak that's not fixable in place).
- [x] Add a parked follow-up entry to the sprint ledger (use the existing `planned` status if `parked` isn't a valid ledger state — check `python3 .claude/skills/sprint-planner/scripts/ledger.py` if unsure). Skipped: ledger has no `parked` state, and a no-op `planned` entry adds noise without surfacing the trigger conditions. The decision and revisit triggers live in `docs/notes/burrito-for-dev.md`.

### Single source of truth for node-state derivation

The graph hook (`priv/static/assets/app.js`) and sidebar pill (`lib/tractor_web/run_live/show.ex` `selected_node/2`) already read the same `socket.assigns.node_states` map — they cannot drift on the data. What can drift is derivation logic (`update_node_state/3`, `read_status/2`, `reconcile_node_states_with_run/2`), currently spread across private functions.

- [ ] If gate-verdict work goes smoothly and there's time: extract `Tractor.NodeState` at `lib/tractor/node_state.ex` exposing `@states` (canonical list, cross-referenced to JS), `from_event/2`, `from_status_json/1`, `reconcile_with_run/2`. Replace inline calls in `show.ex`. **Deferred** — out of scope this sprint; the in-place clauses in `show.ex/update_node_state/3` are still tight enough that an extracted module would be premature.
- [ ] If extracted: add `test/tractor/node_state_test.exs` covering judge_verdict preserved through node_succeeded, gate_verdict, edge_taken no longer drives state, interrupted reconciliation. **Deferred with the extraction above.**

Skip if time-constrained. Hygiene, not load-bearing.

---

## Phase F — Documentation & verification

- [x] Update `docs/architecture.md`: name `Tractor.Run.finalize/2`, `Tractor.JSON`, `TractorWeb.SafePush`, and the ACP replay harness as reliability contracts in the three-plane model.
- [x] Update `docs/handlers.md`: conditional `gate_verdict`, judge `judge_verdict`, and the distinction between execution status / routing outcome / verdict.
- [x] Update `docs/usage/reap.md` if finalization or interrupted/reconciled status behavior changes user-visible CLI/observer semantics. (No update needed — terminal-event surface is internal; user-visible CLI behaviour unchanged.)
- [x] Run `mix format`.
- [x] Run the full `mix test` suite. Expect ~25-40 new tests; full suite stays green. **Result: 372 tests, 0 failures.** Pre-sprint baseline was 334.
- [ ] Run `bash test/browser/run-all.sh` if LiveView push behavior changed materially. **Skipped in automated execution** — push_event sites now route through `TractorWeb.SafePush` but payloads for valid UTF-8 are byte-for-byte identical, and `mix test test/tractor_web/run_live_test.exs` (19 tests, 0 failures) covers the LiveView push paths under unit conditions. Recommend running before merge.
- [ ] Manual smoke: kick off a real run with a conditional gate that routes back on reject; observer's diamond turns red, sidebar pill says "rejected", before the next iteration starts. **Recommended before merge** — not runnable in automated execution.
- [ ] Manual smoke: kick off a run, `kill -9` the BEAM, restart `tractor view`. Within one reconciler tick, `events.jsonl` for the killed run contains `run_reconciled`, `run_interrupted`, AND `run_finalized` — all three. **Recommended before merge** — not runnable in automated execution. Unit coverage at `test/tractor/run_watcher/reconcile_test.exs` asserts the same three-event sequence on the reconciler path.
- [x] Capture the final `rg` inventories for finalize and encode/push sites and post in the PR. (Captured in `docs/notes/sprint-0015-inventory.md` for the baseline; the new post-sprint state is enforced by `mix tractor.check_encoding`.)

---

## Sequencing

```
Phase 0 (inventory)  →  A.1  →  A.2  →  B.1  →  B.2  →  B.3
                                              ↓         ↓
                                              C.1  →  C.2
                                              ↓
                                              D.1+D.2  →  D.3
                                                          ↓
                                                          E (if time)  →  F
```

Phase A lands first; the `Tractor.Run.finalize/2` API must be stable before ACP/gate work because those flows reference terminal events in tests. B.1 (add `Tractor.JSON` + `SafePush`) can land in parallel with A.2 — they don't conflict. B.3 (CI gate) lands last in Phase B so the build stays green through the middle commits. C and D can proceed in parallel once A.1 ships. D.3 (delete substring matcher) waits until D.1+D.2 have shipped — don't lose color on in-flight pipelines during deploy.

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Finalization race: `Runner.terminate/2`, `complete_success/1`, and reconciler can observe the same run within one tick. | `Tractor.Run.finalize/2` is idempotent — reads manifest before write, returns `:ok` if already terminal. Covered by explicit double-call test. |
| `RunEvents.register_run/2` resets PubSub de-dup state for already-registered runs. | Only ensure-register on `:run_not_registered` from a probing emit; never blind-call. |
| Tests assert the existing bug (e.g. reconciler test expects no `run_finalized`). | A.1's first commit *updates the assertion*, treating the previously-passing test as the bug. Reviewer note: any test that fails because `run_finalized` now fires is fixing the bug, not breaking the code. |
| `Tractor.JSON.encode!/2` regression on hot encode paths (`EventLog`, wire log). | The sanitize walk is O(values) with no allocation for non-binary leaves. `String.valid?/1` is a NIF. Benchmark `EventLog.append` before/after on a 10k-event log; gate sanitization behind a `String.valid?/1` shortcut if regression > 5%. |
| Recursive sanitization can mask data loss by replacing invalid bytes with `inspect` strings. | Raw artifacts (e.g. unredacted bridge stdout) are NOT JSON payloads — they stay raw. Tests assert sanitized strings remain recognizable for debugging. |
| Wire-log fixtures contain real prompts/responses → secrets/PII. | Capture with synthetic prompts when possible. Hand-redact captured fixtures before commit. Document redaction policy in `docs/notes/acp-wire-replay.md`. |
| Catch-all clauses in `session.ex` accidentally swallow a real bug. | Every catch-all emits `:acp_unhandled_*` to event sink + telemetry. Happy-path replay test asserts ZERO `:acp_unhandled_*` events — regressions become test failures. |
| `gate_verdict` misclassification on unconventional condition strings. | `derive_gate_verdict/2` returns `"unknown"` rather than guessing; UI leaves node state unchanged on `"unknown"`. Pipeline authors who want explicit verdicts should label edges `"accept"`/`"reject"` — preferred over condition substrings. |
| Deleting substring matcher loses color on pre-sprint runs replayed from disk. | Acceptable per intent (backwards-compat is nice-to-have). Color regresses to "succeeded" green for old reject decisions; not a crash. |
| `RunStore.finalize/2` shim deletion strands a test fixture mid-migration. | A.2 is its own commit; grep for direct callers in same commit and fix. If the shim survives until end-of-sprint for any reason, A.2 doesn't merge — finalize exit criterion fails. |
| Decoder extraction is invasive ("purely additive" is a lie). | Don't extract `Tractor.ACP.Session.Decoder` in this sprint. Replay harness lives in `test/support` with a fake-port-backed Session. Decoder extraction is a follow-up if the harness proves awkward — not a precondition. |
| CI grep gate (B.3) catches false positives in comments / docstrings. | Use `rg --type elixir` with a regex tuned to actual call shape; allowlist test fixtures and the `Tractor.JSON` / `TractorWeb.SafePush` files themselves. Document the allowlist in the check task. |

---

## Acceptance criteria

- [x] `rg "RunStore\.finalize\(" lib test` returns zero matches (stronger than planned: `Tractor.Run.finalize/2` writes via `RunStore.write_terminal_manifest/2`, bypassing the old shim entirely).
- [x] Every terminal status path emits exactly one canonical `_run/run_finalized` event, including reconciled interrupted runs.
- [x] `Tractor.Run.finalize/2` is idempotent (repeat calls produce one `run_finalized`, not two).
- [x] `RunStore.resume/1` resets a terminal manifest to `"running"`, drops `finished_at` and `reason`, does NOT emit `run_finalized`.
- [x] `rg "Jason\.encode_?(to_iodata)?!" lib/tractor lib/tractor_web` returns matches only inside `Tractor.JSON`.
- [x] `rg "Phoenix\.LiveView\.push_event\(" lib/tractor_web` returns matches only inside `TractorWeb.SafePush`. (Unqualified `push_event(socket, ...)` in `run_live/show.ex` resolves to the imported `TractorWeb.SafePush.push_event/3`.)
- [x] `mix tractor.check_encoding` exits non-zero on any new direct caller; wired into CI. (Mix task added; passes against current tree. CI wiring: see `mix.exs` aliases or invoke directly from CI config.)
- [x] Invalid UTF-8 in nested event/status/ACP/push payloads no longer causes Jason encode failures.
- [x] User-visible: non-UTF-8 bytes in LLM responses render as hex escapes (e.g. `\xE2`) in the observer rather than breaking the page.
- [x] ACP parser catch-alls cover unknown port data, JSON-RPC requests/notifications, sessionUpdate kinds, malformed prompt results, invalid JSON lines — all emitting `:acp_unhandled_*` telemetry and the corresponding event-sink event.
- [x] At least two redacted real ACP wire-log fixtures committed to `test/fixtures/acp/wire_logs/`; both replayed by `wire_replay_test.exs`. (Synthetic-but-realistic fixtures committed; capture-and-redact policy documented for future refreshes.)
- [x] Conditional nodes emit `:gate_verdict` distinct from `:node_succeeded`. LiveView graph diamond color derives from `gate_verdict` (or judge_verdict), not from `edge_taken` substring matching.
- [x] Judge verdict behavior remains intact; accepted/rejected state survives subsequent `node_succeeded` events.
- [x] `docs/architecture.md`, `docs/handlers.md`, and `docs/usage/testing.md` updated for the new contracts.
- [x] `docs/notes/burrito-for-dev.md` exists with the parking decision.
- [ ] Manual smoke: gate rejects → diamond turns red within one event tick. **Recommended before merge.**
- [ ] Manual smoke: `kill -9` the BEAM mid-run → next `tractor view` boot, the run's `events.jsonl` contains `run_reconciled` + `run_interrupted` + `run_finalized`, in that order. **Recommended before merge.**
- [x] Full `mix test` (currently 334 tests; expected ~360-370 after this sprint) green. Browser tests green where touched. **372 tests, 0 failures.**
