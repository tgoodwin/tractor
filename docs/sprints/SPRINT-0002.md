# SPRINT-0002 — LiveView observer + spec-faithful parallel fan-out

**Status:** planned
**Target:** 8–10 focused days (Phase A Phoenix-in-escript spike + Phase D Runner refactor are the schedule risks)
**Builds on:** SPRINT-0001 (linear `start → codergen* → exit`, 3 ACP agents, on-disk artifacts, escript CLI, no UI)
**Merged from:** 3 drafts (codex, gemini, claude) + 2 cross-critiques under `docs/sprints/drafts/`. Codex's critique process hung; merge proceeds from codex's draft + gemini and claude's critiques.

## 1. Intent

Deliver two co-dependent things in one sprint because they share an event substrate: a **Phoenix LiveView observer UI** (served only via `tractor reap --serve`) and **spec-faithful parallel fan-out + fan-in** in the engine. The UI renders the DOT graph as live SVG with per-node visual state, shows multiple concurrently-running nodes during a parallel block, and lets the user click any node to see its prompt, response, streaming reasoning trace, tool calls, and stderr. The engine implements the attractor spec's `parallel` handler (DOT `shape=component`, isolated branch context clones, `join_policy=wait_all` default, `max_parallel=4` default) and `parallel.fan_in` handler (DOT `shape=tripleoctagon`). Both read/write a shared per-node `events.jsonl` substrate — engine writes, UI tails. Read-only, localhost-only, single-user.

## 2. Goals

- [ ] `tractor reap --serve PATH` boots Phoenix/LiveView bound to `127.0.0.1`, prints the URL to stderr **before the first node starts**, runs the pipeline, then keeps serving after completion for post-mortem inspection. Ctrl-C is the clean shutdown.
- [ ] LiveView renders the DOT-derived graph as clickable SVG with node states: `pending`, `running`, `succeeded`, `failed`. Multiple `running` nodes visible at once during a parallel block.
- [ ] Clicking a node shows: prompt, response, ordered ACP message chunks, ordered ACP thought chunks, tool calls grouped by `toolCallId` with updates in arrival order, and tailed `stderr.log`.
- [ ] `Tractor.ACP.Session` captures `agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update` in arrival order; exposes a structured `%Tractor.ACP.Turn{}` as the handler-facing return shape.
- [ ] Every node writes an append-only `<run_dir>/<node_id>/events.jsonl` stream; `RunEvents.emit/4` writes disk first, then broadcasts to `Phoenix.PubSub`.
- [ ] `RunStore` exposes explicit node-lifecycle markers (`mark_node_pending/running/succeeded/failed`) so a late-opening browser can rebuild full node state from disk alone.
- [ ] `Tractor.Runner` moves from single-active to multi-active coordination while preserving deterministic top-level traversal (at most one active node outside a parallel region).
- [ ] `shape=component` parses and executes as the `parallel` handler; `shape=tripleoctagon` as `parallel.fan_in`.
- [ ] Parallel branches receive **isolated, JSON-safe context clones**; branch mutations never leak back into parent context.
- [ ] Branch concurrency is bounded by `max_parallel` (default `4`, attribute override).
- [ ] `join_policy=wait_all` is implemented with **spec-aligned partial-success semantics**: all-branches-succeed → success; ≥1 succeed and ≥1 fail → partial_success (fan-in still runs); all fail → fail.
- [ ] Fan-in handler consolidates branch results under the spec keys `parallel.results.<parallel_node_id>` and writes `parallel.fan_in.best_id` + `parallel.fan_in.best_outcome`; selection heuristic: status rank desc, then score desc, then lexical branch id.
- [ ] Acceptance DOT: `examples/parallel_audit.dot` = `start → audit [shape=component] → 3 codergen branches (claude/codex/gemini) → consolidate [shape=tripleoctagon] → finalize (codergen) → exit`. Runs end-to-end via `./bin/tractor reap --serve`. Browser shows live concurrent branches + streaming reasoning + clickable post-mortem.
- [ ] **Sprint-1 regression gate:** `./bin/tractor reap examples/three_agents.dot` (no `--serve`) still exits 0, identical stderr shape, no Phoenix booted.
- [ ] Branch merged to `main` with green CI and a real laptop demo.

## 3. Non-goals (push back hard)

- [ ] **Auth / multi-user UI.** 127.0.0.1 binding only. No login, no session middleware, no user model. If asked, refuse — threat model is "user's own laptop."
- [ ] **UI control commands.** Read-only viewer. No cancel, no retry, no step, no re-prompt, no edit-and-rerun. Click handlers are inspection-only.
- [ ] **Crash-resume / checkpoints.** Still deferred. Parallel makes resume harder (branch state) — explicitly don't touch.
- [ ] **Other spec handlers.** `conditional`, `wait.human`, `tool`, `stack.manager_loop` stay rejected by the validator with the existing diagnostic codes.
- [ ] **Conditional edges, edge `condition=` attr.** Edge selection inside a single branch remains sprint-1's weight-desc + lexical-tie-break.
- [ ] **`join_policy=first_success` (and other policies).** Requires in-flight ACP cancellation, which is its own sub-project (can't cleanly cancel an ACP prompt turn without corrupting JSON-RPC framing). Validator rejects with `:unsupported_join_policy`. Sprint-3 seed.
- [ ] **Sub-DAG branches.** A branch must be exactly one node for sprint 2. Validator rejects multi-node branches with `:nested_branches_unsupported`. Sprint-3 seed.
- [ ] **Per-branch retries.** Retry attr on branches is ignored; a branch failure contributes partial-success semantics, nothing else.
- [ ] **Persisted run history browser.** UI shows the *current* run only. No `/runs` index, no run picker, no diff view. Sprint-3+ if at all.
- [ ] **WebSockets / endpoint exposed beyond localhost.** Hardcoded `{127, 0, 0, 1}`. No `0.0.0.0`, no nginx config, no TLS.
- [ ] **Node asset pipeline (Tailwind / esbuild / npm).** Plain static `app.css`, 10-line `app.js` that imports LiveView. Nothing more.
- [ ] **Yaks / `tractor sow` / `tractor ls` / `tractor logs`.** Sprint-3+.
- [ ] **Hot code reload, `mix release`** (unless Phase A spike forces the fallback).

## 4. Architecture — the opinionated calls

### 4.1 Phoenix-in-escript: spike first

Phoenix has historically been awkward inside an escript (asset pipeline, priv files, code path resolution). **2h Phase A spike** is the gate:

- Can `Phoenix.Endpoint` boot from an escript binary?
- Are `priv/static` assets reachable (LiveView JS payload)?
- Does `mix escript.build` produce a single-file binary that still serves the UI?

**Fallback:** if escript fights back, `--serve` ships via `mix release` (invocation becomes `_build/prod/rel/tractor/bin/tractor reap --serve ...`); the no-`--serve` CLI path stays escript. Document the call in `docs/sprints/notes/phoenix-escript-spike.md`. Budget +1 day if the fallback triggers.

### 4.2 Minimal Phoenix dep set

Adopt only:
- `{:phoenix, "~> 1.7"}`
- `{:phoenix_live_view, "~> 1.0"}`
- `{:phoenix_html, "~> 4.1"}`
- `{:phoenix_pubsub, "~> 2.1"}`
- `{:bandit, "~> 1.5"}` (not Cowboy — smaller dep footprint, modern default)

**Not adopted:** Ecto, Tailwind, esbuild, gettext, mailer, live_dashboard, npm. Inline a ~10-line `priv/static/assets/app.js` that imports LiveView and connects the socket. Plain `priv/static/assets/app.css`. Skip `mix phx.new` entirely — hand-build the minimum.

### 4.3 Supervision tree changes

```
Tractor.Application (:one_for_one)
├── Tractor.RunRegistry               # existing
├── Tractor.AgentRegistry             # existing
├── Tractor.HandlerTasks              # existing (Task.Supervisor)
├── Tractor.ACP.SessionSup            # existing (DynamicSupervisor)
├── Tractor.RunSup                    # existing (DynamicSupervisor)
├── {Phoenix.PubSub, name: Tractor.PubSub}    # NEW — always on (cheap)
└── Tractor.WebSup                    # NEW — DynamicSupervisor, endpoint lives here when --serve
```

`TractorWeb.Endpoint` is **not** in the static children list. CLI starts it under `Tractor.WebSup` only when `--serve` is passed; plain `tractor reap` never opens a listener.

### 4.4 Runner: sequential → frontier model

Replace the sprint-1 single-active `task_ref`/`task_node_id` with a frontier:

```elixir
defstruct pipeline: nil,
          store: nil,
          frontier: %{},           # task_ref => %{node_id, branch_id, started_at_ms}
          agenda: :queue.new(),    # explicit priority queue of ready nodes
          context: %{},            # node_id => outcome (parent context)
          branch_contexts: %{},    # branch_id => %{node_id => outcome} (isolated per branch)
          parallel_state: %{},     # parallel_node_id => %ParallelBlock{...}
          completed: MapSet.new(),
          waiters: [],
          result: nil,
          provider_commands: []
```

Loop:
1. Dequeue next ready node from `agenda`; if none and `frontier` empty → run complete.
2. If node is `parallel`: don't spawn a task. Expand the block into `parallel_state`, snapshot context, enqueue up to `max_parallel` branch entries; mark the parallel node `running` on disk + PubSub.
3. Otherwise spawn via `Task.Supervisor.async_nolink/3` under `HandlerTasks`, register ref in `frontier`, mark node `running`.
4. On `{ref, result}` → resolve, write artifacts, mark `succeeded`/`failed`, broadcast lifecycle event, recompute `agenda` (predecessors-satisfied scan), loop.
5. On `:DOWN` for an unresolved ref → same failure path as `{:error, reason}`.
6. On reaching the terminal exit node: write final manifest, reply to waiters, but **do not stop the Runner if `--serve` is active** — UI needs the state alive. Transition to `:complete` and remain mounted; `Tractor.Run.await/2` resolves normally.

**Why frontier keyed by ref:** `Task.async_nolink` already gives us `{ref, result}` and `{:DOWN, ref, ...}` messages keyed by ref. Parallel maps keyed by node_id drift. Keep ref as the truth.

**Why agenda as explicit state (not recompute-every-tick):** easier to log, easier to debug, one line per scheduling decision.

**Why keep Runner as a single GenServer (don't shard per branch):** one place owns the truth about completed nodes. Branches are values in Runner state, not processes. Each handler invocation is a Task; that's the only concurrency primitive needed. Resist per-branch supervisors.

**Sprint-1 regression:** non-parallel pipelines must pass sprint-1's engine tests unchanged. Land the frontier refactor in **two commits** — first the refactor with no parallel (all tests still pass), then add parallel — so bisect is easy.

### 4.5 Parallel handler (spec §4.8)

The Runner *is* the parallel handler. `shape=component` → `type=parallel` is a **control-flow** marker, not a task to spawn.

**Structured region:** a `parallel` node's outgoing edges are branch entries. The nearest common downstream `parallel.fan_in` node is the join boundary. Branch executors run the branch entry node, then stop — they do not execute the fan-in node. (Fan-in runs once after all branches settle, as a regular handler invocation.)

**Sprint-2 constraint:** each branch must be a single node. Validator rejects any branch whose entry node has an outgoing edge to anything other than the fan-in node (`:nested_branches_unsupported`). Sprint-3 relaxes to sub-DAG branches using the same structured-region framing — no rework of the validator's region-discovery code.

**Branch identification (spec-compliant, no invented attrs):** branches are the outgoing edges of the `component` node. Branch id = `"<parallel_node_id>:<branch_entry_node_id>"`. DOT authors don't write a `branches=` attribute.

**`max_parallel` enforcement:** attribute on the parallel node (integer, default `4`, validated `> 0 and <= 16`). Runner queues excess branches in `agenda` and releases them as running branches complete.

**Context isolation:** `Tractor.Context.clone_for_branch(context, branch_id)` produces a JSON-safe snapshot with `parallel.branch_id` stamped in. Branch nodes read/write `branch_contexts[branch_id]` only; never fall back to `state.context`. JSON-safety is enforced at clone time (reject pids, refs, functions) — prevents non-serializable values from leaking into fan-in state.

**Branch failure under `wait_all`:** **do not cancel** in-flight branches (no ACP cancel primitive yet). Wait for all in-flight to settle, including timeouts. Store every branch result (success or failure) under `parallel.results.<parallel_node_id>` and hand them all to fan-in. Fan-in decides run-level success via partial-success semantics.

### 4.6 Fan-in handler (spec §4.9)

`Tractor.Handler.FanIn` is a regular handler. Reads upstream `parallel.results.<parallel_node_id>` from context, writes:

- `parallel.fan_in.best_id` — branch id selected by heuristic
- `parallel.fan_in.best_outcome` — the best branch's outcome
- `parallel.fan_in.summary` — markdown summary of all branches
- Handler's own `outcome` = summary (so downstream codergen can reference it via `{{fan_in_node_id}}`)

**Selection heuristic:** status rank (success > partial_success > failed), then `score` desc (if set on branch outcome), then lexical branch id. Deterministic; testable.

**Run status:** success if ≥1 branch succeeded; fail if all branches failed or `parallel.results` is empty. This matches spec §4.9 ("runs even when some candidates failed, fails only when all candidates fail").

**Fan-in may be a codergen:** if the fan-in node has `llm_provider` set, the handler drives an ACP session with a templated prompt (`{{branch:<id>}}`, `{{branch_responses}}` joined). If not set, the default implementation just writes the consolidated summary text.

### 4.7 `Tractor.ACP.Session` capture widening

Introduce `%Tractor.ACP.Turn{}`:

```elixir
defstruct response_text: "",
          agent_message_chunks: [],
          agent_thought_chunks: [],
          tool_calls: [],           # by arrival, keyed by toolCallId
          tool_call_updates: [],    # by arrival
          events: []                # ordered raw ACP updates for audit
```

The `Tractor.AgentClient` behaviour's `prompt/3` return type becomes `{:ok, %Turn{}} | {:error, reason}` (narrowed from sprint-1's `{:ok, String.t()}`). The Codergen handler takes `Turn.response_text` for `response.md` and writes the structured lists to `events.jsonl`.

**Event sink as an internal callback:** `Session` accepts `event_sink: (acp_event -> :ok)` option. Keeps `Tractor.ACP.Session` Phoenix-agnostic — `Codergen` wires the sink to write `events.jsonl` and broadcast on `RunBus`. Tests pass a sink that appends to an Agent.

**Backward-compat:** sprint-1's "response = concatenated message chunks" rule stays. Thought chunks and tool outputs do *not* flow into `response.md`. They live in `events.jsonl` and the UI.

**Handle both discriminator spellings:** ACP payloads in the wild use `type` and/or `sessionUpdate` as the discriminator. Extract both.

### 4.8 Event substrate: `RunEvents` + `EventLog`

**Single public API:** `Tractor.RunEvents.emit(run_id, node_id, kind, data)`:

1. Appends one JSON line to `<run_dir>/<node_id>/events.jsonl` via a node-scoped `Tractor.EventLog` file handle (opened `:raw, :append`; no `IO.puts` serialization through `:standard_io`).
2. Broadcasts `{:run_event, node_id, event}` on `Tractor.RunBus` topics `"run:<run_id>"` and `"run:<run_id>:node:<node_id>"`.

**Disk-first, PubSub-second.** If PubSub has no subscribers, fine — UI is optional. If the process crashes between disk-append and broadcast, the UI still sees the event on its next read.

**Event kinds (sprint 2):** `node_pending`, `node_started`, `node_succeeded`, `node_failed`, `branch_started`, `branch_settled`, `agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`, `parallel_started`, `parallel_completed`, `run_started`, `run_completed`, `run_failed`.

**Line format:** `{"ts":"<UTC ISO8601>","seq":<int>,"kind":"<kind>","data":{...}}`. `seq` is per-node monotonic, assigned by the `EventLog` writer.

**UI subscribe-then-read ordering:** on LiveView mount, `subscribe` first, *then* read the existing `events.jsonl` for each node. A slightly stale snapshot is better than a missed event between read and subscribe; LiveView is idempotent enough to tolerate dup events.

### 4.9 RunStore node-lifecycle markers

Add to `Tractor.RunStore`:

- `mark_node_pending(store, node_id)` — creates the node dir, writes a `status.json` with `{"status":"pending"}`.
- `mark_node_running(store, node_id, started_at)` — overwrites status.
- `mark_node_succeeded(store, node_id, outcome_meta)` — overwrites status.
- `mark_node_failed(store, node_id, reason)` — overwrites status.

**Why:** the UI must render `pending` nodes as clickable (with empty state), and a late-opening browser must rebuild full node state from disk alone. The existing sprint-1 "write at completion only" pattern makes pending state implicit-from-absence and breaks UI-state rebuild.

### 4.10 Graph rendering — shell out to `dot -Tsvg`

**Decision:** at serve time, shell out to `System.cmd("dot", ["-Tsvg"], ...)`; post-process the SVG to inject `data-node-id` and class `tractor-node` onto each `<g class="node">`.

**Why accept the dep:** writing a layered DAG layout in Elixir is a multi-day yak on the critical path of a UI-demo sprint. Users authoring DOT pipelines will already have Graphviz installed (they use it to visualize the pipelines they're writing). This is a *runtime* dep for `--serve` only; sprint-1's pure-Elixir parser path is unchanged.

**Fail loud if missing:** on `--serve` startup, probe for `dot` on PATH. If absent, error with an actionable message (`install graphviz (brew install graphviz / apt install graphviz) or run without --serve`). Exit code 2.

**SVG is cached per Pipeline:** pipeline is immutable for the lifetime of a run — render once on mount, update only classes via LiveView diff.

### 4.11 LiveView surface

**One LiveView module:** `TractorWeb.RunLive.Show` at `/runs/:run_id`. Single template. No components library, no HEEx partials beyond the one template.

**Mount:** lookup run via `Tractor.RunRegistry`, subscribe to `RunBus` *first*, then read existing disk state (`status.json` per node + `events.jsonl` for selected node), compute initial node-state map.

**Render:** SVG graph + side panel. Each SVG node has `phx-click="select_node" phx-value-node-id="..."`.

**Chunks:** use `Phoenix.LiveView.stream/3` + `stream_insert/3` for message chunks, thought chunks, and tool calls. Avoid materializing full chunk arrays in assigns — every diff would otherwise ship the entire array.

**CSS classes:** `pending` (gray), `running` (pulsing blue), `succeeded` (green), `failed` (red). Plain CSS in `app.css`.

**Thought-chunk UX:** render `agent_thought_chunks` as an expandable section (collapsed by default), labeled factually ("reasoning trace from ACP") — do not imply hidden chain-of-thought beyond what the bridge actually supplies. Tool calls grouped by `toolCallId` with updates listed in arrival order.

**No JS hooks** for the SVG interaction. LiveView's normal diff is enough.

### 4.12 CLI

Extend `reap`:

- [ ] `--serve` → boot `TractorWeb.Endpoint` under `WebSup` **before** the run starts, print URL to stderr, then run the pipeline, then on completion print `Serving post-mortem at <URL> (Ctrl-C to exit)` and block on `:timer.sleep(:infinity)`. Trap SIGINT → stop endpoint → `System.halt(0)`.
- [ ] `--port N` → loopback port for `--serve`. Default `0` (ephemeral); resolve actual port via endpoint info.
- [ ] `--no-open` → suppress auto-open. Without it, `--serve` attempts `System.cmd("open", [url])` on macOS, `xdg-open` on Linux, `Task.start` wrapped so failure is silent.
- [ ] Without `--serve`, behavior is identical to sprint 1 — no Phoenix is booted, no port is opened.

**Exit codes** stay sprint-1 (`0`/`2`/`3`/`10`/`20`/`130`). SIGINT under `--serve` exits `0` (graceful post-mortem shutdown).

## 5. Task list (sequenced)

### Phase A — Phoenix-in-escript spike + scaffold (day 1, ~5h)

- [x] **2h spike:** create throwaway `spike/` with `:phoenix`, `:phoenix_live_view`, `:phoenix_pubsub`, `:bandit` added to mix.exs. Build a "hello world" LiveView route. `mix escript.build` + run + GET the URL. Document outcome in `docs/sprints/notes/phoenix-escript-spike.md`. **Decision gate:** escript works → stay escript. Fails → switch `--serve` path to `mix release`, document invocation change, budget +1 day.
- [x] Add Phoenix deps to `mix.exs` post-spike. Update `mix.lock`.
- [x] Add `{Phoenix.PubSub, name: Tractor.PubSub}` to `Tractor.Application` static children (always on).
- [x] Add `Tractor.WebSup` as `DynamicSupervisor` to static children (empty — endpoint starts here on `--serve`).
- [x] Create `lib/tractor_web/`: `endpoint.ex` (host `127.0.0.1`, no code reloader, server true, runtime-only config), `router.ex` (single `live "/runs/:run_id", RunLive.Show` + 404 catch-all), `run_live/show.ex` skeleton, `templates/run_live/show.html.heex` stub.
- [x] Create `priv/static/assets/app.js` (~10 lines: import LiveView, connect socket) and `priv/static/assets/app.css` (empty scaffold).
- [x] `Tractor.RunBus` module: `subscribe/1`, `subscribe/2`, `broadcast/3`. Topic convention: `"run:<run_id>"` and `"run:<run_id>:node:<node_id>"`.
- [x] Unit test: normal `tractor reap` (no `--serve`) does NOT open a listener (assert `:gen_tcp.connect({127,0,0,1}, 4000, [])` fails).
- [x] Unit test: `TractorWeb.Server.start_link/1` binds only to `127.0.0.1` (config assertion).
- [x] Commit.

### Phase B — Event substrate + ACP capture widening (day 2–3, ~7h)

- [x] `Tractor.EventLog` module: `open(node_dir) :: {:ok, log}`, `append(log, kind, data) :: :ok`, `close(log) :: :ok`. Single `:raw, :append` file handle; monotonic per-node `seq`; UTC ISO8601 `ts`. **Writes binaries only** — never `IO.puts` through `:standard_io`.
- [x] `Tractor.RunEvents.emit(run_id, node_id, kind, data)`: find node's open `EventLog` in a `Registry` or pass explicitly; append via EventLog; then `Tractor.RunBus.broadcast`.
- [x] `Tractor.ACP.Turn` struct (see §4.7).
- [x] Update `Tractor.AgentClient` behaviour: `prompt/3 :: {:ok, %Turn{}} | {:error, reason}`.
- [x] Refactor `Tractor.ACP.Session`:
  - [x] Accept `event_sink: (acp_event -> :ok)` opt. Default = no-op.
  - [x] Capture `agent_message_chunk` (both `type` and `sessionUpdate` discriminator spellings).
  - [x] Capture `agent_thought_chunk` (both spellings).
  - [x] Capture `tool_call` with `toolCallId`, `title`, `kind`, `status`, `content`, `locations`, `rawInput`, `rawOutput` when present.
  - [x] Capture `tool_call_update` in order, associate by `toolCallId`; preserve late/partial updates.
  - [x] Build `%Turn{}` at end of turn; return from `prompt/3`.
  - [x] Emit each captured update via `event_sink` in arrival order.
- [x] Update `test/support/fake_acp_agent.exs`: add optional `FAKE_ACP_EVENTS=full` mode that emits thought chunks, tool calls, tool_call_updates, and mixed discriminator spellings.
- [x] Update sprint-1 ACP session tests: assert `Turn` shape, port-leak assertion preserved, 50-concurrent-session stress test preserved.
- [x] New ACP session tests: thought chunk capture, tool call lifecycle with updates, unknown discriminator handling (graceful ignore), sink called in arrival order.
- [x] Add `RunStore` lifecycle markers: `mark_node_pending/2`, `mark_node_running/3`, `mark_node_succeeded/3`, `mark_node_failed/3`. Each atomic-write to `status.json`. Tests.
- [x] Integration test: a handler that opens Session with sink wired to EventLog + RunBus drives fake agent in `FAKE_ACP_EVENTS=full` mode; assert `events.jsonl` contains expected kinds in order AND PubSub subscriber received same events.
- [x] **Late-reader rebuild test:** snapshot a completed run's node state purely from `status.json` + `events.jsonl`, assert it matches the live state the Runner broadcast.
- [ ] Commit.

### Phase C — Parser & validator for parallel shapes (day 3, ~3h)

- [ ] Extend `Tractor.DotParser` shape mapping: `component → parallel`, `tripleoctagon → parallel.fan_in`.
- [ ] Parse node attrs `join_policy` (string) and `max_parallel` (integer) into `attrs`; add helper accessors `Node.join_policy/1` (default `"wait_all"`) and `Node.max_parallel/1` (default `4`).
- [ ] Remove `parallel` and `parallel.fan_in` from the validator's rejected-types list.
- [ ] Validate `join_policy == "wait_all"` (reject `first_success` and anything else with `:unsupported_join_policy`).
- [ ] Validate `max_parallel > 0 and <= 16` with `:invalid_max_parallel`.
- [ ] **Structured region discovery:** for each `parallel` node, compute the set of branch entry nodes (outgoing edges) and the nearest common downstream `parallel.fan_in` node. Reject with `:no_common_fan_in` if absent, `:multiple_common_fan_ins` if ambiguous.
- [ ] **Single-node branch constraint (sprint-2):** each branch entry node must have exactly one outgoing edge that points to the fan-in node. Reject otherwise with `:nested_branches_unsupported`.
- [ ] Validate each `parallel.fan_in` has at least one incoming branch edge and exactly one matching upstream `parallel` node.
- [ ] Continue rejecting `conditional`, `wait.human`, `tool`, `stack.manager_loop` with existing codes.
- [ ] New DOT fixtures: `valid_parallel_audit.dot`, `missing_fan_in.dot`, `multiple_fan_ins.dot`, `nested_branch.dot`, `invalid_join_policy.dot`, `invalid_max_parallel.dot`, `fan_in_without_parallel.dot`.
- [ ] One test per fixture failure mode.
- [ ] Commit.

### Phase D — Multi-active Runner + parallel region + fan-in (day 4–6, ~10h, riskiest piece)

- [ ] `Tractor.Context` module: `initial/1`, `snapshot/1` (JSON-safe; reject pids/refs/functions), `clone_for_branch/2` (stamps `parallel.branch_id`), `apply_updates/2`.
- [ ] Refactor `Tractor.Runner` state to frontier + agenda model (§4.4). **Commit 1:** refactor with no parallel support; all sprint-1 engine tests pass unchanged. **Commit 2:** add parallel. Bisectable.
- [ ] Replace `task_ref`/`task_node_id` with `frontier :: %{ref => %{node_id, branch_id, started_at_ms}}` and `agenda :: :queue.t()`.
- [ ] `ready_set/1` / enqueue-after-completion logic.
- [ ] `{ref, result}` and `:DOWN` handlers updated for frontier.
- [ ] Run lifecycle broadcasts via `RunEvents`: `run_started`, `node_started`, `node_succeeded`, `node_failed`, `run_completed`, `run_failed`.
- [ ] `Tractor.Pipeline` gains `parallel_blocks :: %{parallel_node_id => %ParallelBlock{branches, fan_in_id, max_parallel, join_policy}}`, populated by parser (Phase C).
- [ ] Runner: on dequeuing a `parallel` node, enter `enter_parallel/2` — snapshot context, initialize `parallel_state[id]`, enqueue branch entries (up to `max_parallel`; queue the rest).
- [ ] `Tractor.Engine.BranchExecutor.run_until/5` — walks branch from entry node to fan-in boundary. For sprint 2 with single-node branches this is effectively "run exactly the entry node and stop."
- [ ] Branch context isolation: `Codergen` reads from `branch_contexts[branch_id]` when `branch_id` is set in its input env; never falls back to parent context.
- [ ] Update `Codergen` to write `prompt.md` at node start (for UI to render `pending` nodes clickably), stream ACP events during the run via `RunEvents`, write `response.md` + `status.json` at completion, return structured `%Turn{}`.
- [ ] Branches that fail emit `branch_settled` events; Runner does NOT cancel sibling branches; waits for all branches in the block (including their timeouts) to settle.
- [ ] After all branches settle, store results in context under `parallel.results.<parallel_node_id>` as a list of `%{branch_id, entry_node_id, status, outcome, started_at, finished_at, score?}` maps.
- [ ] Enqueue fan-in node; Runner advances to it directly (parallel node has no outgoing edges to non-branch nodes).
- [ ] `Tractor.Handler.FanIn`:
  - [ ] Reads upstream `parallel.results.<parallel_node_id>`.
  - [ ] Writes `parallel.fan_in.best_id`, `parallel.fan_in.best_outcome`, `parallel.fan_in.summary` to parent context.
  - [ ] Selection heuristic: status rank (success > partial_success > failed), then score desc, then lexical branch id.
  - [ ] If fan-in node has `llm_provider`, drives ACP session with templated prompt (`{{branch:<id>}}`, `{{branch_responses}}`).
  - [ ] Run success if ≥1 branch succeeded; fail if all failed or results empty.
- [ ] **Tests:**
  - [ ] Sprint-1 linear-pipeline regression (all sprint-1 engine tests green).
  - [ ] 3-branch parallel: Mox Session emits branches with overlapping timestamps; assert true concurrency via `started_at` overlap.
  - [ ] `max_parallel=2` with 3 branches: assert only 2 in flight at any moment.
  - [ ] Branch context isolation sentinel test: 3 branches each write a unique key; assert pairwise isolation and no parent-context leak.
  - [ ] One branch fails under `wait_all`: other branches finish; fan-in receives partial results; downstream sees fan-in's outcome; run succeeds with partial_success status if fan-in picks a successful branch.
  - [ ] All branches fail: fan-in has nothing to consolidate; run fails with `:all_branches_failed`.
  - [ ] Deterministic fan-in selection: crafted `parallel.results` fixtures with varying status/score/id; assert selection matches heuristic.
  - [ ] JSON-safety enforcement: `Context.snapshot/1` rejects maps containing pids/refs/functions.
- [ ] Commit.

### Phase E — LiveView UI (day 6–8, ~7h, can start once Phase B lands)

- [ ] `TractorWeb.Endpoint` config (runtime, host `{127,0,0,1}`, server `true`, pubsub `Tractor.PubSub`).
- [ ] `TractorWeb.Router`: `live "/runs/:run_id", RunLive.Show`. Catch-all 404.
- [ ] `TractorWeb.GraphRenderer`: shells out to `dot -Tsvg`, streams the pipeline's DOT source, post-processes SVG to add `data-node-id` and `tractor-node` class on each `<g class="node">`. Cache result per pipeline.
- [ ] `TractorWeb.RunLive.Show`:
  - [ ] `mount/3`: lookup run via `Tractor.RunRegistry`, subscribe to `RunBus` **first**, then load per-node `status.json` + `events.jsonl` for initial state.
  - [ ] `render/1`: SVG graph + side panel for selected node (prompt, response, stream-rendered chunk lists, tool calls grouped by `toolCallId`, stderr tail).
  - [ ] `handle_info({:run_event, node_id, event}, ...)`: update node-state map, `stream_insert/3` into selected-node streams.
  - [ ] `handle_event("select_node", %{"node-id" => id}, ...)`: switch selection; load target node's events into streams from disk.
- [ ] `priv/static/assets/app.css`: state classes (`pending`, `running` with pulse animation, `succeeded`, `failed`); side panel layout; monospace `<pre>` for chunks.
- [ ] `priv/static/assets/app.js`: LiveView import + socket connect (~10 lines).
- [ ] LiveView tests with `Phoenix.LiveViewTest`:
  - [ ] Stub run broadcasts `node_started` → DOM class flips to `running`.
  - [ ] Multiple concurrent `node_started` → multiple nodes show `running` simultaneously.
  - [ ] `select_node` loads prompt/response/chunks from disk.
  - [ ] Late mount (run already complete) rebuilds full UI state from disk.
- [ ] `dot` probe: on endpoint startup, fail with actionable error if `dot` not on PATH.
- [ ] Commit.

### Phase F — CLI `--serve` + acceptance + merge gate (day 8–10, ~5h)

- [ ] Add `--serve`, `--port`, `--no-open` to `Tractor.CLI` `OptionParser` strict list.
- [ ] `--serve` flow: ensure Phoenix deps started, probe for `dot`, start `TractorWeb.Endpoint` under `WebSup` with resolved loopback port, print URL to stderr BEFORE starting the run, start the run, await result, print run dir to stdout on success, print "Serving post-mortem at <URL> (Ctrl-C to exit)" to stderr, block on `:timer.sleep(:infinity)`. Trap SIGINT → stop endpoint → `System.halt(0)`.
- [ ] `--no-open` absent: `Task.start` wrapping `System.cmd("open", [url])` on macOS / `xdg-open` on Linux. Failure silent.
- [ ] No-`--serve` flow identical to sprint 1 — no Phoenix deps started.
- [ ] `examples/parallel_audit.dot`: `start → audit [shape=component, max_parallel=3] → claude_audit/codex_audit/gemini_audit [shape=box llm_provider=...] → consolidate [shape=tripleoctagon llm_provider=claude] → finalize [shape=box llm_provider=claude] → exit`. Harmless prompts ("audit this tiny code snippet for $concern"), fan-in consolidates the three audits, finalize phrases a recommendation.
- [ ] CLI tests: build escript, run `--serve --port 0`, assert URL printed on stderr, `GET <url>/runs/<id>` returns 200 with LiveView shell.
- [ ] CLI tests: `--serve` without `dot` on PATH fails with actionable error and exit 2.
- [ ] **Manual acceptance on user's laptop:**
  - [ ] `./bin/tractor reap --serve examples/parallel_audit.dot` with real Claude/Codex/Gemini bridges.
  - [ ] Browser opens automatically (unless `--no-open`).
  - [ ] Three branches highlight as `running` simultaneously during the audit phase.
  - [ ] Clicking each branch shows streaming message chunks + thought chunks + any tool calls + stderr tail.
  - [ ] Fan-in node highlights after, then finalize.
  - [ ] Run completes; UI keeps serving; post-mortem inspection works indefinitely.
  - [ ] Ctrl-C exits 0; `pgrep gemini|claude|codex` returns empty.
- [ ] **Sprint-1 regression smoke:** `./bin/tractor reap examples/three_agents.dot` still exits 0 with identical stderr shape.
- [ ] `docs/usage/reap.md` updated: `--serve`, `--port`, `--no-open`, Graphviz runtime dep install line, example screenshot.
- [ ] `README.md` updated.
- [ ] Merge-gate checks: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`, `mix test --include integration` (laptop), `mix escript.build` (or `mix release` if Phase A forced fallback).
- [ ] PR opened, reviewed, squash-merged to `main` with green CI.

## 6. Sequencing

- **A → B → C** is linear (A is the gate; B's event substrate is shared by C and everything after).
- **D depends on B and C** — Runner refactor needs the event substrate (B) to emit lifecycle events and the parallel shapes accepted by the parser/validator (C).
- **E can start mid-B** (once `RunEvents` + `RunBus` are stable) on stub events. E does *not* wait for D to finish — that's the UI-parallelization win.
- **F depends on D and E** — acceptance requires both live parallel execution and the UI.
- **Early real-agent smoke after Phase D**, before Phase F polish: one `./bin/tractor reap --serve examples/parallel_audit.dot` against real Claude/Codex/Gemini to surface ACP shape drift early. Per-bridge quirks in `agent_thought_chunk` / `tool_call` payloads are higher-probability than any other late-sprint surprise.
- **The two schedule risks are A's spike and D's Runner refactor.** If A fails, budget +1 day for `mix release` fallback. If D balloons, cut `--no-open` auto-open and the `score`-based selection heuristic (use status + lexical only) before cutting tests.

## 7. Risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Phoenix won't cleanly run from an escript (priv/assets resolution). | Med-High | Phase A 2h spike is the gate. Fallback: `mix release` for `--serve` path only; no-`--serve` CLI stays escript. |
| `dot` binary not installed on user's laptop. | Med | Probe at `--serve` startup; actionable error (`brew install graphviz` / `apt install graphviz`) + exit 2. Document in README. |
| Multi-active Runner regresses sprint-1 linear pipelines. | Med | Two-commit refactor (frontier without parallel → add parallel). All sprint-1 engine tests stay as a regression gate. |
| Branch context isolation leaks (one branch sees another's writes). | High if wrong | Pairwise sentinel test; branch context lookup never falls back to parent context; `Context.snapshot/1` enforces JSON-safety at clone time. |
| ACP `agent_thought_chunk` / `tool_call` shapes drift across Claude/Codex/Gemini bridges. | High | Both discriminator spellings handled (`type`, `sessionUpdate`); preserve raw ACP update in events.jsonl even when typed extraction is partial; fake agent covers documented shapes; laptop run catches per-bridge quirks. |
| `wait_all` + a stuck branch → run hangs forever. | Med | Per-node `timeout` attr enforced by `Session`; parallel block waits for *all* branches including timeouts to settle. Document: each branch has own timeout; block waits for all. |
| Graph layout yak-shave (Graphviz dep was the escape). | Low (escaped) | `dot -Tsvg` + CSS class injection. Sprint-3 seed: pure-Elixir layered layout if the Graphviz dep becomes painful. |
| LiveView re-renders the whole side panel on every ACP chunk → UI lags. | Med | `stream_insert/3` for all chunk lists from day one; don't materialize full arrays in assigns. |
| Endpoint accidentally binds to `0.0.0.0` in some config path. | Low but bad | Endpoint config hardcodes `{127, 0, 0, 1}`. Assertion test on config value; attempt from another interface in a CI-skippable test. |
| Phoenix deps balloon escript size / cold start. | Low-Med | Bandit over Cowboy; no esbuild/tailwind; measure pre/post. Target: escript ≤30MB, cold start ≤2s. |
| `join_policy=first_success` sneaks in because spec says so. | Med | Validator hard-rejects with `:unsupported_join_policy`. Sprint-3 seed comment at the rejection site. |
| Scope creep into UI controls / multi-run browser / auth. | Perpetual | §3 non-goals. Reject hard. |
| User new to Phoenix/LiveView. | Ongoing | §8 gotchas section; keep LiveView surface to one module + one template. |

## 8. Elixir/Phoenix gotchas to pre-empt

- **LiveView `mount/3` runs twice** — once over HTTP (initial render), once over WebSocket. Guard side effects with `if connected?(socket), do: ...`. Subscribe only in the connected phase or you'll double-subscribe.
- **`Phoenix.PubSub.broadcast/3` is fire-and-forget.** Late subscribers miss events. UI must either subscribe-then-read-disk or tolerate dup events on replay. Pick the subscribe-first ordering.
- **LiveView assigns are diffed** — large assigns (full event arrays) get sent on every update. Use `Phoenix.LiveView.stream/3` for append-only lists.
- **`Task.Supervisor.async_nolink/2`** sends both `{ref, result}` and `{:DOWN, ref, ...}`. Always `Process.demonitor(ref, [:flush])` after a normal result (sprint-1 Runner does this — preserve in the frontier rewrite).
- **Killing a Task doesn't kill its OS children.** Branch cancellation (even though we're not doing it this sprint) would leak provider subprocesses without an explicit `terminate/2` audit. `:trap_exit, true` on Runner is still load-bearing.
- **`GenServer.call` default 5s timeout** is still wrong for LLM turns; explicit timeout on every prompt.
- **`:raw, :append` file mode** is required for `events.jsonl` — bypasses `:standard_io` serialization. Write binaries only, never `IO.puts`.
- **`Phoenix.Endpoint` started outside `Application.start/2`** needs `Application.put_env/3` to set runtime endpoint config *before* `start_link/1`. CLI does this when `--serve` is passed.
- **escript + Phoenix priv_dir:** priv files must be bundled via `:escript` `:embed_extra_files` or read from the escript archive. Spike confirms.
- **`System.cmd("open", ...)` on macOS** returns 0 even if no default browser is set — don't rely on its exit code.
- **DOT `component` and `tripleoctagon` shapes** are real Graphviz shapes — render natively, no custom shape definitions needed.
- **`Logger.warn/1`** still deprecated — use `Logger.warning/1`.
- **Don't convert DOT attribute strings to atoms** (already a sprint-1 rule; still applies to new `join_policy`/`max_parallel` attrs).
- **`System.halt/1`** is still the escript exit — but `--serve` must *not* halt immediately after run completion. Post-run block on `:timer.sleep(:infinity)`; halt only on SIGINT.

## 9. Acceptance criteria (the merge gate)

- [ ] `mix test` green; `mix test --include integration` green on laptop.
- [ ] All sprint-1 acceptance criteria still pass (linear pipelines, exit codes, port-leak assertion, no-`--serve` path opens no listener).
- [ ] Engine test: 3-branch parallel block — all branches have overlapping `started_at`/`finished_at` windows (true concurrency).
- [ ] Engine test: branch context isolation — three branches each write a unique sentinel, none cross-contaminated, none leaked into parent context.
- [ ] Engine test: `max_parallel=2` with 3 branches — at most 2 in flight at any moment.
- [ ] Engine test: one branch failure under `wait_all` — other branches complete; fan-in receives partial results; run succeeds (partial_success) if fan-in picks a successful branch.
- [ ] Engine test: all branches fail — run fails with `:all_branches_failed`.
- [ ] Engine test: fan-in selection heuristic (status > score > lexical) passes crafted fixtures.
- [ ] Validator tests: rejects `join_policy != "wait_all"`, missing fan-in, multiple fan-ins, sub-DAG branches, `max_parallel` out of range.
- [ ] ACP test: `agent_thought_chunk` and `tool_call` + `tool_call_update` flow through `Session` event sink in arrival order; both discriminator spellings accepted.
- [ ] `events.jsonl` test: per-node file contains lifecycle + ACP events with monotonic per-node `seq`; late disk reader reconstructs equivalent state to live broadcast.
- [ ] LiveView test: stub broadcasts flip node CSS classes; multiple concurrent `running` render simultaneously; `select_node` loads prompt/response/chunks from disk.
- [ ] HTTP test: `--serve --port 0` starts Phoenix; GET `/runs/<id>` returns 200; endpoint bound to `127.0.0.1`.
- [ ] CLI test: `--serve` without `dot` on PATH fails with actionable error + exit 2.
- [ ] `./bin/tractor reap --serve examples/parallel_audit.dot` on user's laptop against real Claude/Codex/Gemini:
  - URL printed to stderr before run starts.
  - Browser auto-opens unless `--no-open`.
  - Three audit branches highlight as `running` concurrently.
  - Streaming reasoning + tool calls visible per branch when clicked.
  - Fan-in node consolidates and produces output downstream.
  - Run completes; UI keeps serving; any node clickable for full post-mortem.
  - Ctrl-C exits 0; `pgrep gemini|claude|codex` returns empty.
- [ ] `./bin/tractor reap examples/three_agents.dot` (no `--serve`) still exits 0 with identical stderr shape and no Phoenix booted.
- [ ] `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict` clean.
- [ ] `mix escript.build` produces a working `./bin/tractor` that serves the UI (or `mix release` equivalent if Phase A spike forced fallback; docs reflect either way).
- [ ] Branch merged to `main` with green CI.

## 10. Sprint-3 seeds (do not expand here)

- [ ] `# TODO(sprint-3): sub-DAG branches` at the validator's `:nested_branches_unsupported` rejection site.
- [ ] `# TODO(sprint-3): join_policy=first_success` at the validator's `:unsupported_join_policy` rejection site — requires ACP cancellation primitive.
- [ ] `# TODO(sprint-3): cancel in-flight branches on sibling failure` in Runner's branch-failure path — also requires ACP cancel.
- [ ] `# TODO(sprint-3): run history browser` — reserve `/runs` route (currently 404).
- [ ] `# TODO(sprint-3): pure-Elixir layered-DAG layout` as a `dot` fallback if the Graphviz runtime dep becomes painful.
- [ ] `# TODO(sprint-3): checkpoint` — the events.jsonl + `status.json` substrate is the seed of a durable resume log.

## 11. Appendix — contested calls and how the merge resolved them

| Contested call | Decision | Reasoning |
|---|---|---|
| Branch topology: spec edges (Codex) vs invented `branches=` attr (Claude) | **Spec edges** | Spec-faithful; no DSL invention. Single-node-branch constraint enforced by validator, not DOT syntax. |
| Branch length: sub-DAG (Codex) vs single-node (Claude) for sprint 2 | **Single-node, sprint 2** | Codex's structured-region framing used, but validator restricts to length 1 this sprint. Sprint 3 relaxes with no rework. |
| `join_policy=first_success`: in (Codex) / out (Claude) | **Out** | Requires ACP cancellation primitive we don't have. Half-building it is worse than rejecting. Sprint-3 seed. |
| `wait_all` on branch failure: fail run (Claude) / partial-success (Codex) | **Partial-success** | Matches spec §4.9. Fan-in decides; one branch failing ≠ run failing. |
| Graph layout: hand-rolled Elixir (Codex, Gemini) vs shell `dot -Tsvg` (Claude) | **Shell `dot -Tsvg`** | Layered-DAG layout is a multi-day yak on a UI-critical-path sprint. Graphviz is a reasonable runtime dep for `--serve` only. |
| Phoenix-in-escript: assumed OK (Codex) vs 2h spike (Claude) | **2h spike** | Cheap insurance against the biggest Unknown Unknown. `mix release` fallback documented. |
| ACP capture API: callback sink (Claude) vs structured Turn (Codex) | **Both — Turn is public, sink is internal** | Handlers see `%Turn{}` (clean struct). Session writes via sink as implementation detail. |
| Event API: fan disk+PubSub via `RunEvents.emit/4` (Codex) vs separate `EventLog`+`RunBus` (Claude) | **Codex's API wraps Claude's implementation** | Single public call; EventLog per-node file handle stays as impl. |
| RunStore lifecycle: implicit-from-absence (Claude sprint-1) vs explicit `mark_node_*` (Codex) | **Explicit** | UI must render pending nodes clickably and rebuild from disk alone. |
| CLI UX: auto-open browser (Claude) vs no mention (Codex) | **Auto-open + `--no-open` opt-out** | Nice default for a single-user local tool. |
| Dep set: Tailwind+esbuild (Gemini) vs plain CSS (Codex, Claude) | **Plain CSS** | Sprint-1's "keep escript boring" principle. Tailwind+esbuild = multi-day yak, zero demo value. |
| Runner model: split active/queued (Codex) vs frontier + agenda (Claude+Gemini) | **Frontier + agenda** | Frontier keyed by `Task.async_nolink` ref is the natural Elixir shape; agenda-as-explicit-state is easier to debug than recompute-every-tick. |
| Sequencing: UI waits on engine (Codex) vs UI starts on stub events mid-phase B (Claude) | **Start UI mid-phase B** | UI is the acceptance artifact; don't serialize it behind engine work. |
