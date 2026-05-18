# ACP wire-log replay harness

`Tractor.ACP.Session` parses a JSON-RPC stream from a subprocess and routes
each frame to a handler. New ACP wire surprises (a fresh `sessionUpdate`
kind, a `:noeol` frame split, an oddly-typed `stopReason`) have historically
crashed individual handler clauses before catch-alls landed in SPRINT-0015
phase C.1. The replay harness gives every future surprise a test home.

## Where it lives

| Asset | Path | Purpose |
|---|---|---|
| Harness | `test/support/acp_wire_replay.ex` (`ACPWireReplay`) | Drives a `Tractor.ACP.Session` from a captured wire log; returns the event-sink output + telemetry. |
| Fixtures | `test/fixtures/acp/wire_logs/*.jsonl` | Redacted JSONL captures matching the wire-log writer's `direction|payload|ts` schema. |
| Test | `test/tractor/acp/wire_replay_test.exs` | Asserts each fixture produces zero `:acp_unhandled_*` (happy path) or the expected mix of recognized + unknown events. |

## How the harness drives the session

The harness starts a `Tractor.ACP.Session` backed by a silent fake agent
(`ACPWireReplay.SilentFakeAgent`) that loops on stdin without responding.
This means every inbound frame is sourced from the fixture, not from a real
provider. A background `Task` calls `Session.prompt/2` so the session
progresses to `:prompting` after init completes — without that step,
`session/update` notifications are dropped by design.

For each inbound frame in the fixture, the harness sends a port-shaped
message into the GenServer mailbox:

```elixir
send(pid, {state.port, {:data, {:eol, frame_json}}})
```

Frames longer than `:split_at` bytes are split into successive `:noeol`
chunks terminated by `:eol`. This exercises the session's 1 MiB
line-buffer rejoin logic without requiring multi-megabyte fixtures —
`wire_replay_test.exs` sets `split_at: 256` for that case.

Events emitted by the session's event-sink and the
`[:tractor, :acp, :unhandled]` telemetry stream are collected and returned
from `ACPWireReplay.run_fixture/2`. The happy-path test asserts both are
empty; the unknown-update test asserts a non-empty `:acp_unknown_update`
entry corresponds to each unknown `sessionUpdate` kind in the fixture.

## Redaction policy

Fixtures are committed to the repo. Real wire logs MUST be hand-redacted
before commit. Two rules:

1. **Strip identifying strings.** Replace project names, hostnames,
   absolute paths, account IDs, email addresses, and prompt-text that
   reflects internal work with neutral placeholders (`replay-session`,
   `fixture-driven prompt`, etc.). The frame *shape* is what's being
   tested, not the content.
2. **Preserve protocol-level details.** Keep all `id`, `method`,
   `sessionUpdate`, `stopReason`, `toolCallId`, `kind`, and `status`
   fields verbatim. Those are what the parser cares about. Likewise keep
   any oddly-typed values (numeric `stopReason`, null `content`,
   alternate `usage` shapes) that reproduce the surprise being captured.

A fixture commit must NOT include user prompts, model responses, file
paths from a user's working tree, or tool output. When in doubt, replace.

## Refreshing fixtures

Live capture is done by setting `wire_log:` on `Session.start_link/2` and
running a real session. The resulting `acp-wire.jsonl` lives under the
run's directory. Hand-edit per the redaction policy above and copy into
`test/fixtures/acp/wire_logs/<provider>-<scenario>.jsonl`.

`docs/usage/testing.md` lists the test commands; the wire-replay test is
fast (< 1s) and runs as part of the standard `mix test`.
