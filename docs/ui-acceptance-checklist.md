# UI acceptance checklist

Interactions the observer UI must pass through automated browser-driven testing. This file is the spec for a SPRINT-0009+ agent-browser-based acceptance harness (Vercel Agent Browser, Playwright MCP, or similar).

Each item should be automatable: launch a known run (via `POST /dev/reap?path=...`), interact with the DOM, assert observable state (DOM classes, text content, HTTP status).

## Graph canvas

- [ ] On mount, every declared DOT node renders with `.tractor-node` and a shape class; none missing.
- [ ] `start` node renders green (`.succeeded`) once its handler finishes.
- [ ] A running node renders orange (`.running`) with animated pulse; flips to green (`.succeeded`) on completion within 1s of the `node_succeeded` event.
- [ ] Failed node renders red (`.failed`).
- [ ] `wait.human` node renders with dashed blue border (`.waiting`) on suspension.
- [ ] Judge node with a reject verdict renders red (`.rejected`); accept renders green (`.accepted`).
- [ ] Conditional edges and fallback edges are visually distinguishable from unconditional edges.
- [ ] Back-edges (edges in a legal SCC) render with `constraint=false` routing.
- [ ] Iteration badge `×N` updates on re-entry.
- [ ] Cumulative duration `Σ` badge appears when iterations > 1.
- [ ] Edge-taken pulse animation fires when an edge is traversed.

## Timeline / activity panel

- [ ] Selecting a node shows its iteration-banded activity list.
- [ ] Prompt, response, stderr, lifecycle, tool events render with distinguishable chips / icons.
- [ ] Judge verdict events render with accept/reject tone.
- [ ] Plan updates render as a live checklist with state transitions (`pending` → `in_progress` → `completed`).
- [ ] `prefers-reduced-motion` disables CSS transitions on plan items.
- [ ] Long tool stdout renders with a truncation marker when `:tool_output_truncated` event present.

## Status feed (left panel)

- [ ] `status_agent=off` pipelines render "Status agent disabled" empty state.
- [ ] `status_agent=<provider>` pipelines render observations newest-on-top.
- [ ] Streaming status-agent output coalesces into a single row (not one row per chunk).
- [ ] Feed scroll container doesn't grow the page.

## Wait.human form

- [ ] Clicking a `wait.human` node in the graph opens the WaitForm in the node panel (top-right).
- [ ] WaitForm renders exactly one button per outgoing edge label.
- [ ] Clicking a button submits that specific label (not a neighboring one — regression check against the "click reject → resolves as approved" bug).
- [ ] On successful submission, the form disappears within 1s.
- [ ] On successful submission, the waiting node's graph state flips to `succeeded`.
- [ ] On successful submission, the downstream edge matching the chosen label is traversed (edge-taken pulse fires).
- [ ] Submitting a stale label (e.g. form open against a run that's since resolved) surfaces inline error without page teardown.
- [ ] Submitting while the run is in a crash-restart loop fails clearly; does not silently succeed.
- [ ] `wait_timeout` auto-selection fires the default edge and emits `:wait_human_resolved{source: :timeout}`.
- [ ] Resume after mid-wait crash: form re-prompts with same `outgoing_labels` / `waiting_since`.

## Run index (left side)

- [ ] Run status badges: `running`, `completed`, `errored`, `goal_gate_failed`, `interrupted`.
- [ ] A run with a `waiting` node shows as `running`, not `interrupted`.
- [ ] Cost totals display in the run header.

## Run lifecycle via Codergen → wait.human

The specific regression that prompted this doc:

- [ ] Launch `examples/_debug_wait_after_llm.dot` (Claude → wait.human → exit).
- [ ] `draft` runs exactly once, emits exactly one `node_succeeded` event.
- [ ] `review` transitions to `waiting` state within 1s of `draft.node_succeeded`.
- [ ] No supervisor restart: `_run/events.jsonl` contains exactly one `run_started` event.
- [ ] No duplicate Claude calls: events.jsonl for `draft` contains one `iteration_started` / `iteration_completed` pair.
- [ ] WaitForm renders; clicking `approve` or `reject` advances to `exit` via the matching edge.
- [ ] Run finalizes with `status: "ok"`; neither `approved` nor `rejected` status lingers.

## Pre-requisites for the harness

- A dev-mode POST route to launch pipelines in the Phoenix BEAM (`POST /dev/reap?path=...` — already landed).
- A dev-mode POST route to stop pipelines (`POST /dev/stop/:run_id`, `POST /dev/stop-all` — already landed).
- A way to read `events.jsonl` from the server side via an API (currently only readable from disk — may want a dev-only JSON endpoint).
- Stable DOM selectors / `data-*` attrs on all interactive elements so the agent browser can target them reliably.
