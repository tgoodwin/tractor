# ACP Spike

Date: 2026-04-19

## Decision

Use the sprint fallback: implement `Tractor.ACP.Session` directly on `Port` +
`Jason` NDJSON instead of building on ACPex 0.1 internals.

The public Tractor API remains:

```elixir
Tractor.ACP.Session.start_link(agent_module, opts)
Tractor.ACP.Session.prompt(pid, text, timeout)
Tractor.ACP.Session.stop(pid)
```

## ACPex Findings

ACPex 0.1 can spawn an agent process and its internal
`ACPex.Protocol.Connection.send_request/4` can send `initialize`,
`session/new`, and `session/prompt`. Streaming `session/update` notifications
are routed to `ACPex.Client.handle_session_update/2`.

The terminal prompt response is reachable as a raw JSON-RPC response map through
the internal connection layer, but that path is not clean enough for this sprint:

- The public `ACPex.start_client/3` supports `agent_path` and `agent_args`, but
  not provider-specific environment injection.
- The managed NDJSON transport keeps the `Port` private, so Tractor cannot track
  `Port.info(port, :os_pid)` for the sprint's best-effort SIGTERM cleanup.
- `ACPex.Schema.Session.PromptResponse` validates only `"done"`, `"cancelled"`,
  and `"error"`. The sprint requires terminal reasons including `"end_turn"`,
  `"max_tokens"`, and `"max_turn_requests"`.
- Using `ACPex.Protocol.Connection` directly would couple Tractor to internal
  modules while still leaving the process cleanup and env-injection gaps.

## Fallback Shape

The direct implementation will:

- Open the provider with `Port.open/2`, `:binary`, `:exit_status`, `:use_stdio`,
  line framing, and `{:env, env}` when configured.
- Never set `:stderr_to_stdout`.
- Track the OS pid from `Port.info(port, :os_pid)`.
- Send `initialize`, `session/new`, and `session/prompt` JSON-RPC requests.
- Buffer text from `session/update` agent message chunks.
- Resolve `prompt/3` on `stopReason: "end_turn"`.
- Map terminal failure reasons and JSON-RPC errors to distinct
  `{:error, reason}` values.
