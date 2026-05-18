# SPRINT-0015 baseline inventory

Captured at sprint start (2026-05-18) so PR review can compare against the post-sprint state.

## Baseline focused suite

`mix test test/tractor/run_test.exs test/tractor/tool_run_test.exs test/tractor/wait_human_run_test.exs test/tractor/run_watcher/reconcile_test.exs test/tractor/acp/session_test.exs test/tractor_web/run_live_test.exs` → **88 tests, 0 failures**.

## Finalize-site inventory (pre-sprint)

Direct `RunStore.finalize(...)` callers in `lib/`:

- `lib/tractor/run_watcher/reconcile.ex` — `mark_reconciled!/2,3`
- `lib/tractor/runner.ex` — `complete_success/1`, `fail_node/3`, `fail_goal_gate/3`, `finalize_interrupted/1` (four sites)

Each runner site additionally emits its own `:run_finalized` event inline. The reconciler site does NOT emit `:run_finalized` (the surfaced bug).

Production code that observes the terminal-event surface (`run_completed | run_failed | run_interrupted | goal_gate_failed | run_finalized`):

- `lib/tractor/run_watcher/tail.ex` — `@terminal_kinds`
- `lib/tractor_web/run_index.ex` — manifest → status derivation
- `lib/tractor_web/run_live/show.ex` — live run_finalized handling
- `lib/tractor_web/templates/run_live/show.html.heex` — goal_gate_failed banner

## Encode/push-event inventory (pre-sprint)

`Jason.encode!` / `Jason.encode_to_iodata!` in `lib/tractor` + `lib/tractor_web`:

- `lib/tractor/run_store.ex:237` — manifest, status.json
- `lib/tractor/event_log.ex:48` — every event row
- `lib/tractor/acp/session.ex:432, 709` — outbound ACP messages, wire log
- `lib/tractor/status_agent.ex:299, 307, 321, 351` — per-node status writes
- `lib/tractor/checkpoint.ex:51, 117` — checkpoint serialization + graph hash
- `lib/tractor/context.ex:51` — context deep-copy via JSON roundtrip
- `lib/tractor/agent/codex.ex:53` — `-c writable_roots=...` argv
- `lib/tractor/runner/control_file.ex:72` — control-file write
- `lib/tractor/handler/judge.ex:48` — judge response artifact
- `lib/tractor/handler/tool.ex:197` — tool output artifact
- `lib/tractor/handler/wait_human.ex:27` — wait_human payload
- `lib/tractor_web/markdown.ex:22` — pretty markdown JSON block
- `lib/tractor_web/run_live/tool_call_view.ex:261` — tool call detail view
- `lib/tractor_web/run_live/show.ex:924` — inline JSON pretty-print

`push_event(socket, ...)` in `lib/tractor_web`:

- `lib/tractor_web/run_live/show.ex:291, 422, 620, 638, 687` — `graph:selected`, `graph:node_state`, `graph:edge_taken`, `graph:badges`

## sanitize_text duplicate inventory

- `lib/tractor_web/format.ex:40-59` — `TractorWeb.Format.sanitize_text/2` (duplicate of `Tractor.Text.sanitize/2`).
- `test/tractor_web/format_test.exs:39-43` — covers the duplicate.

Callers of the canonical `Tractor.Text.sanitize/2`:

- `lib/tractor/acp/session.ex:170, 175`
- `lib/tractor/status_agent.ex:317, 341, 345`
- `lib/tractor/runner.ex:1375` (output_digest)
- `lib/tractor/assistant.ex:127`
