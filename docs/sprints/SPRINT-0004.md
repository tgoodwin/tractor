# SPRINT-0004 — Observer polish: pan/zoom, activity timeline, cutting-mat aesthetic

**Status:** planned
**Target:** 5–7 focused days. UI-heavy sprint with a small additive engine delta (token-usage capture).
**Builds on:** SPRINT-0002 (`--serve` LiveView observer, RunBus, events.jsonl, %Turn{}). SPRINT-0003 is an unrelated project in the shared ledger; numbering skips to 0004.
**Scope owner:** `lib/tractor_web/**`, `priv/static/assets/**`, `lib/tractor/acp/session.ex` (additive only).
**Merged from:** 3 drafts + 3 cross-critiques under `docs/sprints/drafts/`.

## 1. Intent

Turn the current observer from a functional-but-spartan three-section stack into a design-literate operator console. The graph becomes a pannable/zoomable Figma-like board on a faint cutting-mat grid. Clicking a node swaps the sidebar to that node's **chronological activity timeline** — a single interleaved stream of timestamped, color-coded, collapsible entries (prompt, thinking, tool calls, message chunks, response, stderr, lifecycle, usage). Completed nodes carry two small badges: **execution duration** and **abbreviated token count** (hidden entirely when the bridge doesn't surface usage). Typography, palette, and spacing draw from papercompute.com + extend.ai; the aesthetic is a drafter's cutting mat — faint 8px grid with thicker 40px section dividers on a cool neutral base.

Engine/substrate is **off-limits** except for one additive change: extend `Tractor.ACP.Session` to capture token usage into `%Turn{}`, emit an optional `:usage` event to `events.jsonl`, and persist the final total in `status.json`. If a bridge doesn't surface usage, the token badge is absent — no fallback estimation.

## 2. Visual references (WebFetch'd during planning)

- **Paper Compute** (`https://papercompute.com/`) — operator-tooling feel. Lift: faint graph-paper grid behind content, framed page rules, compact mono labels, monospace chip styling on a warm tan, single accent, cool neutral canvas. **Don't copy brand assets.**
- **Extend** (`https://www.extend.ai/`) — product-shell discipline. Lift: fixed navbar with uppercase mono navigation, `gap-px`-feeling section dividers, shallow rounded tiles (≤8px radii), stone-neutral surfaces, direct-language document/workflow copy.

Constraint: this is a developer's operator board, not a marketing surface. Cool neutral base, muted green grid lines, dark ink text, single orange/amber reserved for *live/running* accent. **No dominant beige/cream/warm-tan palette.**

## 3. Goals

- [ ] Graph pan/zoom: mouse-wheel zoom around cursor, drag-to-pan, double-click (or reset button) to recenter. Figma-board feel.
- [ ] SVG is **client-owned**: `phx-update="ignore"` on the graph container; `GraphBoard` LiveView hook is the single owner of SVG class + badge mutations. LiveView pushes state diffs via events; the hook mutates DOM in place.
- [ ] Clicking a node pushes a `select_node` event; sidebar swaps to that node's timeline *without* resetting the viewport or re-initializing pan/zoom.
- [ ] The sidebar renders a **single chronological timeline** (not separate sections). Entries are merged from `events.jsonl` + `prompt.md` + `response.md` + `stderr.log` + `status.json` and sorted by timestamp (falling back to `seq`).
- [ ] Timeline entry families, each with a distinct color-coded chip: `prompt`, `thinking`, `tool_call`, `tool_call_update`, `message`, `response`, `stderr`, `lifecycle` (node_started/succeeded/failed, branch_started/settled), `usage`.
- [ ] Each entry has a **timestamp** (HH:MM:SS.mmm, relative-to-node-start toggle available), a **type chip**, a **one-line summary**, and an **expand-to-detail** body (`<details>`).
- [ ] Default collapse: `prompt`, `response` expanded; `thinking`, `tool_call`, `tool_call_update`, `stderr`, `lifecycle`, `usage` collapsed.
- [ ] Tool-call entries show human-readable summaries rendered as **text-only tags** (no emojis): `[READ] file.txt`, `[EDIT] config.yaml (3 changes)`, `[WRITE] report.md (1.2 kB)`, `[BASH] npm install`, `[GREP] "TODO" in src/`, `[GLOB] **/*.ex`, `[FETCH] example.com`, falling back to `[TOOL] <kind>: <title>`. Full raw JSON accessible under a "raw" disclosure.
- [ ] Live streaming: during a running node, new entries stream in via `stream_insert/3`; scroll position preserved if user scrolled up, auto-sticks to bottom otherwise.
- [ ] Completed nodes on the graph carry two SVG-native badges rendered by the `GraphBoard` hook using live `getBBox()`: **duration** and **abbreviated token count**.
- [ ] Duration format: `<1s → 842ms`, `<60s → 18s`, `<60m → 2m14s`, `else → 1h03m`.
- [ ] Token format: `<1000 → 412`, `<1_000_000 → 28k`, `>=1_000_000 → 1.2M`. Always ≤2 sig figs above 1000.
- [ ] Token badge hidden entirely if no total is derivable from captured usage. Duration badge hidden while pending/running.
- [ ] `%Tractor.ACP.Turn{}` gains a `token_usage` field (normalized `%{input_tokens, output_tokens, total_tokens, raw}` or `nil`). `Session` captures usage from both `session/update` payloads *and* the `session/prompt` result.
- [ ] `Tractor.Handler.Codergen` writes `token_usage` into node `status.json` when available; also emits a `:usage` event via `Tractor.RunEvents` so the timeline can interleave it chronologically and future sprints can stream cost displays.
- [ ] **Cutting-mat aesthetic**: faint 8-px graph-paper grid behind the graph region only; thicker 40-px grid lines align with section dividers between header, graph, and sidebar. Grid is on the *container*, not the SVG — it stays fixed as the SVG pans/zooms.
- [ ] Typography: system sans (`Inter`, `-apple-system`, `system-ui`) for UI; system mono (`ui-monospace`, `JetBrains Mono`, `Menlo`) for timestamps, chips, badges, and event bodies. **No web-font downloads** — preserve the escript-served static asset model.
- [ ] Sprint-1 regression preserved: `./bin/tractor reap examples/three_agents.dot` (no `--serve`) still exits 0; no Phoenix booted on that path.
- [ ] Merged to `main` with green CI + a ~30s demo GIF linked in the PR body.

## 4. Non-goals (push back hard)

- [ ] **Multi-run history browser.** Single-run per server. No `/runs` index, no run picker, no diff view.
- [ ] **Writable UI.** No cancel, retry, step, re-prompt, edit, pause. Read-only observer.
- [ ] **Mobile / responsive.** Laptop-desktop only. Minimum viewport 1280×800.
- [ ] **Auth / multi-user / non-localhost binding.** Carry forward 127.0.0.1; no login.
- [ ] **Engine / substrate refactor.** Runner, RunBus, RunStore, existing event kinds untouched except the additive `:usage` event.
- [ ] **Asset pipeline** (npm, esbuild, Tailwind, package-lock). Vendor `svg-pan-zoom.min.js` into `priv/static/assets/vendor/` with a `LICENSE.txt` alongside it. Hand-written CSS only.
- [ ] **Web fonts.** System font stacks only.
- [ ] **Custom DAG layout engine.** Still shell out to Graphviz `dot -Tsvg`.
- [ ] **Persisted UI state across refreshes** (expanded-entry memory, pan/zoom position memory, selected-node memory). Ephemeral client-side only.
- [ ] **Token-cost estimation / pricing display.** Just the count.
- [ ] **Dark mode.** Light palette only this sprint.
- [ ] **Emojis in UI or code files.** Text tags for tool humanization. ASCII for everything.
- [ ] **Redesigning node shapes on the SVG.** Badges overlay; we don't re-layout.
- [ ] **Dominant beige/cream/warm-tan palette.** The cutting-mat base is cool neutral with muted green grid.
- [ ] **Adding a `/runs/:run_id` landing view that lists multiple runs** (implied by the first non-goal, naming it so no drafter sneaks it in).

## 5. Architecture — the opinionated calls

### 5.1 `GraphBoard` LiveView hook owns the SVG

**Decision:** wrap the graph container in `phx-update="ignore"` and make a single `GraphBoard` hook the sole owner of SVG class, badge, and selected-node mutations. LiveView no longer rewrites the SVG string on every event. Instead, it pushes `push_event` messages (`graph:node_state`, `graph:badges`, `graph:selected`) that the hook applies via direct DOM ops.

```js
// priv/static/assets/app.js — ~50 lines
const GraphBoard = {
  mounted() {
    this.svg = this.el.querySelector('svg');
    if (!this.svg) return;

    this.panZoom = svgPanZoom(this.svg, {
      zoomEnabled: true, panEnabled: true, controlIconsEnabled: false,
      fit: true, center: true, minZoom: 0.2, maxZoom: 8,
      dblClickZoomEnabled: false
    });

    this.el.addEventListener('dblclick', () => this.panZoom.reset());

    // Hook-bound click listeners on Graphviz node groups
    this.svg.querySelectorAll('g.tractor-node[data-node-id]').forEach(g => {
      g.addEventListener('click', (e) => {
        const nodeId = g.getAttribute('data-node-id');
        this.pushEvent('select_node', { 'node-id': nodeId });
      });
    });

    // Apply initial state from server
    this.handleEvent('graph:node_state', ({ node_id, state }) => this.applyState(node_id, state));
    this.handleEvent('graph:badges',     ({ node_id, duration, tokens }) => this.applyBadges(node_id, duration, tokens));
    this.handleEvent('graph:selected',   ({ node_id }) => this.applySelected(node_id));

    // Badge placement needs layout; wait a frame after fonts resolve
    requestAnimationFrame(() => this.placeBadges());
    window.addEventListener('resize', () => this.placeBadges());
  },
  destroyed() { this.panZoom?.destroy(); }
  // applyState / applyBadges / applySelected / placeBadges implemented on the hook
};
```

**Why:** server-side SVG string rewrites were forcing full re-renders that either teardown pan/zoom or force a snapshot/restore dance. Hook-owned SVG mutations eliminate the class entirely and let LiveView focus on data.

**Cost:** `GraphRenderer.apply_node_states/2`'s current regex-class-injection path goes away. Server still renders initial SVG with `data-node-id` + `tractor-node` classes; runtime state is hook-applied only. **Runtime guard:** add a comment in `GraphRenderer` explicitly banning server-side class injection going forward; runtime assert in LiveView that it doesn't re-push raw SVG after mount.

**Trade acknowledged:** this is a bigger change than a snapshot-and-restore on `updated()`. But every critique landed on this being the structurally correct move, and Claude's draft conceded it outright.

### 5.2 Browser-side badge placement via `getBBox()`

**Decision:** badges are SVG `<g>` elements (rect + text) appended inside each `g.tractor-node` by the `GraphBoard` hook at layout time, using live `getBBox()` to position them below the node's existing shape. Badges inherit the SVG's pan/zoom transform for free.

**Why not server-side:** Graphviz outputs variable geometry per shape (component, tripleoctagon, box, Mdiamond, Msquare) — parsing coordinates from the SVG string in Elixir is fragile. Browser `getBBox()` is the canonical measurement.

**Cold-start:** `getBBox()` can return `0` before the SVG is fully laid out (fonts not yet resolved). Wrap the first placement in `requestAnimationFrame` after mount, and re-place on resize and after state transitions. If it's still flaky, add a `MutationObserver` beat.

**Format:**
- Duration: `<1s → 842ms`, `<60s → 18s`, `<60m → 2m14s`, `else → 1h03m`.
- Token: `<1000 → 412`, `<1_000_000 → 28k`, `>=1_000_000 → 1.2M` (≤2 sig figs above 1000).
- Token badge hidden if `total_tokens` is nil or 0.

Badges have `pointer-events: none` so they don't intercept node clicks.

### 5.3 Token-usage capture path

**Additive changes only** in `lib/tractor/acp/turn.ex`, `lib/tractor/acp/session.ex`, `lib/tractor/handler/codergen.ex`.

- [ ] `%Tractor.ACP.Turn{}` gains `token_usage :: nil | %{input_tokens, output_tokens, total_tokens, raw}`.
- [ ] `Session.handle_update/2` (or equivalent capture path) matches usage under *any* of these keys: `usage`, `tokenUsage`, `token_usage`, `modelUsage`, `content.usage`. Field-level normalization handles `input_tokens`/`inputTokens`/`prompt_tokens` variance (reuse the `first_present/3` pattern already in `Session` for tool_call normalization).
- [ ] `Session.finish_prompt/2` inspects `result["usage"]` and merges into `state.turn.token_usage` before replying. Last-write-wins per field, preferring non-nil.
- [ ] `Session` emits a `:usage` event via `state.event_sink` whenever `token_usage` is updated — lands in `events.jsonl` chronologically. Future sprints (streaming cost display) get this for free.
- [ ] `Handler.Codergen` writes the final `token_usage` into `status.json` under a `token_usage` key (additive — existing readers ignore it). This is what the `graph:badges` push-event reads on terminal lifecycle.
- [ ] Gracefully ignore unknown shapes. `Turn.events` keeps the raw payload for debugging. Never fail a run on malformed usage data.

**Hedged on the event question:** Codex's critique argued `status.json` alone is enough; Claude argued `events.jsonl` future-proofs streaming. We do both. Cost: a few lines. Benefit: sidebar can show a chronological usage entry AND the badge can read status.json on terminal lifecycle without subscribing to a stream.

### 5.4 Timeline data model

**New module: `TractorWeb.RunLive.Timeline`.** Pure functions; no GenServer state.

```elixir
@type entry :: %{
  id: String.t(),         # stable; event seq or synthesized
  ts: DateTime.t() | nil, # primary sort
  seq: integer() | nil,   # tiebreaker
  type: atom(),           # :prompt | :thinking | :tool_call | :tool_call_update | :message | :response | :stderr | :lifecycle | :usage
  title: String.t(),      # type chip label, e.g. "[READ] file.txt"
  summary: String.t(),    # one-line summary
  body: binary() | map(), # rendered in collapsed <details>
  collapsed_by_default?: boolean(),
  tone: atom()            # CSS class modifier: :neutral | :accent | :success | :failure | :muted
}
```

**Builders:**
- [ ] `Timeline.from_disk(run_dir, node_id)` — reads `events.jsonl`, `prompt.md`, `response.md`, `stderr.log`, `status.json`; returns sorted list of entries.
- [ ] `Timeline.insert(entries, event)` — takes one new event and returns `{position, %entry{}}` for `stream_insert/3`.

**Synthesis rules:**
- `prompt.md` → single synthesized `:prompt` entry with timestamp = `node_started.ts` or first event ts.
- `agent_message_chunk` → collapsed under a single `:response` entry; do NOT emit a separate entry per chunk. Response entry body is the final concatenated text from `response.md` when run is complete; during live run, append chunks to the entry body via `stream_insert`.
- `agent_thought_chunk` → one `:thinking` entry per chunk (they're sparse and meaningful).
- `tool_call` → one `:tool_call` entry, keyed by `toolCallId`.
- `tool_call_update` → subsequent entries grouped under the same `toolCallId`, displayed nested inside the `:tool_call` entry's body.
- `stderr.log` → single `:stderr` entry if non-empty; body is tail of file.
- `status.json` terminal state → `:lifecycle` entry for `:succeeded`/`:failed`.
- `:usage` event → `:usage` entry with the token totals.
- `node_started`, `branch_started`, `branch_settled` → `:lifecycle` entries (collapsed by default).

### 5.5 Tool-call humanizer (`TractorWeb.ToolCallFormatter`)

Pure module, pattern-matches on `{kind, title, rawInput}`. Returns `{tag, summary}`. **Text-only tags, no emojis.** Prefer ACP-provided `title` when it's concise and human-readable (Codex's guidance); fall to the matchers otherwise.

```elixir
def format(%{"kind" => kind, "title" => title} = tc) when is_binary(title) and byte_size(title) < 80,
  do: {tag_for(kind), title}

# fallback matchers below
def format(%{"kind" => "read", "rawInput" => %{"path" => p}}),        do: {"[READ]",  Path.basename(p)}
def format(%{"kind" => "edit", "rawInput" => %{"path" => p, "edits" => e}}) when is_list(e),
                                                                       do: {"[EDIT]",  "#{Path.basename(p)} (#{length(e)} changes)"}
def format(%{"kind" => "write", "rawInput" => %{"path" => p, "content" => c}}),
                                                                       do: {"[WRITE]", "#{Path.basename(p)} (#{humanize_bytes(byte_size(c))})"}
def format(%{"kind" => kind, "rawInput" => %{"command" => cmd}}) when kind in ["bash", "execute", "shell"],
                                                                       do: {"[BASH]",  truncate(cmd, 60)}
def format(%{"kind" => kind, "rawInput" => %{"pattern" => pat, "path" => p}}) when kind in ["grep", "search"],
                                                                       do: {"[GREP]",  ~s("#{pat}" in #{p})}
def format(%{"kind" => "glob", "rawInput" => %{"pattern" => pat}}),    do: {"[GLOB]",  pat}
def format(%{"kind" => "fetch", "rawInput" => %{"url" => u}}),         do: {"[FETCH]", URI.parse(u).host || u}
def format(%{"kind" => kind, "title" => t, "toolCallId" => id}),       do: {"[TOOL]",  "#{kind}: #{t || id}"}
def format(%{"toolCallId" => id}),                                     do: {"[TOOL]",  id}
```

Raw JSON kept in the expanded body for debugging. Tests cover each matcher + fallthrough + missing-field cases.

### 5.6 CSS grid / cutting-mat aesthetic

**Page-level grid (CSS Grid):**

```
┌────────────────────────────── thick divider ──────────────────────────────┐
│  header: run id · pipeline path · overall state · elapsed                  │
├────────── thick divider ─────────────┬── thick divider ───────────────────┤
│  graph surface (cutting-mat bg)      │  sidebar (timeline)                │
│  — pan/zoom region                   │  — scrollable, fixed-width 480px   │
│                                      │                                    │
└──────────────────────────────────────┴────────────────────────────────────┘
```

`display: grid; grid-template-columns: 1fr 480px; grid-template-rows: 56px 1fr;` with 2px borders at grid lines.

**Cutting-mat background** (on `.graph-surface` container only, not on the SVG):

```css
.graph-surface {
  background-color: var(--surface);
  background-image:
    linear-gradient(to right,  var(--grid-faint) 1px, transparent 1px),
    linear-gradient(to bottom, var(--grid-faint) 1px, transparent 1px),
    linear-gradient(to right,  var(--grid-strong) 1px, transparent 1px),
    linear-gradient(to bottom, var(--grid-strong) 1px, transparent 1px);
  background-size: 8px 8px, 8px 8px, 40px 40px, 40px 40px;
}
```

**Palette (starting points — cool neutral, muted green grid, single accent):**

- `--surface: #F3F2EE` — cool off-white, *not* warm cream
- `--ink: #1A1A1A` — high-contrast body text
- `--ink-muted: #6B6B6B` — timestamps, chip text
- `--grid-faint: rgba(63, 99, 61, 0.06)` — muted green, 8px grid
- `--grid-strong: rgba(63, 99, 61, 0.14)` — muted green, 40px section dividers
- `--divider: #2A2A2A` — section borders (header/graph/sidebar)
- `--accent-live: #D97706` — single orange/amber reserved for running/live state
- `--state-pending: #9A9A9A`
- `--state-running: var(--accent-live)` *pulsing*
- `--state-success: #1F7A3C`
- `--state-failure: #B3261E`
- Entry-type tones: `--tone-prompt: #2B5FE8` (blue ink), `--tone-thinking: #6B4FB0` (desaturated purple), `--tone-tool: #4A6B4A` (muted green), `--tone-response: #1A1A1A` (ink), `--tone-stderr: #8B5A00` (amber-brown), `--tone-lifecycle: #6B6B6B`, `--tone-usage: #4A5568`

Hex values are starting points — implementor iterates with agent-browser. Constraint is the family (cool neutral, muted green, single orange), not exact values. **No warm cream/beige dominance.**

**Typography:**
- UI: `Inter, -apple-system, system-ui, sans-serif`. Body 14px/1.5. Header 16px/1.3.
- Chip: 11px uppercase, letter-spacing 0.05em, mono.
- Mono: `ui-monospace, JetBrains Mono, Menlo, monospace`. 12.5px. Used for timestamps, chips, tool raw JSON, prompts, responses.
- System fallbacks only — no web-font download.

**`prefers-reduced-motion`** disables the running-node pulse and any CSS transitions.

### 5.7 Scroll-position preservation for streaming timeline

During a live run, timeline entries append via `stream_insert/3`. Default behavior: if the user is scrolled to the bottom of the sidebar (within 40px), auto-stick to bottom. If they've scrolled up, leave scroll untouched. Implemented via a small inline JS snippet in the sidebar's `phx-mounted` hook that reads `scrollTop + clientHeight === scrollHeight` on each stream update.

### 5.8 Accessibility minima

- [ ] `aria-label` on graph nodes and badges.
- [ ] `Esc` clears selected node.
- [ ] `?` toggles a small help overlay (once, sprint-local — not reused across other sprints).
- [ ] `prefers-reduced-motion` respected.
- [ ] Keyboard focus traversal on the timeline (tab moves between entries, Enter toggles expansion).

## 6. Task list (sequenced for independent revertability)

### Phase A — Foundations, fixtures, baseline (0.5 day)

- [x] Capture before-screenshots of the current observer for comparison; save under `docs/sprints/notes/sprint-0004-before/`.
- [x] WebFetch https://papercompute.com/ and https://www.extend.ai/; paste relevant CSS tokens into `docs/sprints/notes/sprint-0004-references.md` with citations.
- [x] Confirm `vercel-labs/agent-browser` CLI works: drive a smoke run and screenshot the current observer. Document the exact invocation pattern in `docs/sprints/notes/sprint-0004-agent-browser.md`.
- [x] Update `test/support/fake_acp_agent.exs` (env-gated) to optionally emit usage payloads in two different shapes: one via `session/update`, one via `session/prompt` result.
- [x] Commit.

### Phase B — ACP token-usage capture (0.5 day)

- [x] Add `token_usage` field to `%Tractor.ACP.Turn{}` with typespec; default `nil`.
- [x] Extend `Session` update-capture path to match usage under `usage | tokenUsage | token_usage | modelUsage | content.usage` keys; normalize per-field name variants (`input_tokens | inputTokens | prompt_tokens`).
- [x] Merge usage from `finish_prompt/2` result before replying.
- [x] Emit `:usage` event through `state.event_sink` when usage is updated.
- [x] `Handler.Codergen` writes `token_usage` into `status.json` on node completion.
- [x] Unit tests: `Session` captures usage from both wire paths, merges correctly, tolerates unknown shapes without failing; `events.jsonl` contains a `:usage` entry; `status.json` carries the normalized struct.
- [x] Regression: existing `Turn` assertions still pass with `token_usage: nil`.
- [x] Commit.

### Phase C — Vendor svg-pan-zoom + `GraphBoard` hook (1 day, architectural)

- [x] Download `svg-pan-zoom@3.6.x` UMD minified → `priv/static/assets/vendor/svg-pan-zoom.min.js`; include `svg-pan-zoom.LICENSE.txt` alongside.
- [x] Load vendor script in root layout *before* `app.js`.
- [x] Rewrite `app.js` (~50 lines) to define `GraphBoard` hook per §5.1 and register it with `LiveSocket`.
- [x] Update `run_live/show.html.heex`: wrap graph container in `<div id="graph" phx-hook="GraphBoard" phx-update="ignore">`.
- [x] Remove `GraphRenderer.apply_node_states/2` (server-side regex class injection) from the live path. `GraphRenderer` still emits the initial SVG with `data-node-id` + `tractor-node` classes; runtime state is hook-applied. Add a comment in `GraphRenderer` banning re-renders.
- [x] `RunLive.Show.handle_info/2` for each lifecycle event pushes `graph:node_state` via `push_event` to the hook instead of re-rendering.
- [x] Hook binds node click listeners and calls `pushEvent("select_node", ...)`.
- [x] Hook: `applyState`, `applySelected`, `reset()` via dblclick.
- [x] Manual smoke: pan, zoom, dblclick reset, click node, drive a full parallel_audit run and confirm graph state updates without viewport reset.
- [x] Commit.

### Phase D — Cutting-mat CSS + layout grid (0.75 day)

- [x] Rewrite `priv/static/assets/app.css` around the CSS Grid shell per §5.6.
- [x] Implement the two-layer 8px/40px cutting-mat background on `.graph-surface`.
- [x] Define palette and typography as CSS custom properties on `:root`.
- [x] Header bar: run id, pipeline path, overall status pill, elapsed counter.
- [x] Empty-sidebar state: small cutting-mat illustration + "Select a node."
- [x] `prefers-reduced-motion` handling.
- [x] Visual check with agent-browser at 1440×900: graph surface shows the faint grid, thicker lines align with section dividers, palette is cool neutral, no warm-cream dominance.
- [x] Commit.

### Phase E — Timeline data model + sidebar rendering (1.5 days — the meatiest chunk)

- [x] Implement `TractorWeb.ToolCallFormatter` per §5.5; tests for each matcher + fallthrough.
- [x] Implement `TractorWeb.RunLive.Timeline` per §5.4; tests for `from_disk` ordering, `insert` tie-breaking, synthesis rules.
- [x] `TractorWeb.Format` module: `duration_ms/1`, `token_count/1`, `humanize_bytes/1`, `truncate/2`. Tests cover the full formatting taxonomy.
- [x] Rewrite sidebar section of `show.html.heex`: timeline rendered as `<ol>` of `<details>` entries; each entry has `.tl-entry`, `.tl-<type>`, `.tl-<tone>` classes.
- [x] Replace separate prompt/response/thought/tool assigns in `RunLive.Show` with a single `:timeline` stream, populated on mount via `Timeline.from_disk/2` for the selected node.
- [x] `handle_event("select_node", ...)` rebuilds the timeline stream for the new node from disk.
- [x] `handle_info/2` for live events: convert each ACP event to one or more `%Entry{}` and `stream_insert` into the selected node's timeline (only if `selected_node_id` matches).
- [x] Scroll-position preservation hook (§5.7).
- [x] LiveView tests: mount rebuilds timeline for selected node; stream insertion for live events; select_node rebuilds from disk for target node.
- [x] Commit.

### Phase F — SVG badges via `GraphBoard` hook (0.75 day)

- [x] Hook: after SVG mount, compute bbox for each `g.tractor-node` and append a `<g class="tractor-badges">` child containing empty `text` elements for duration + tokens.
- [x] `RunLive.Show.handle_info/2` on terminal lifecycle events reads the node's `status.json` (or in-memory `node_states`) and pushes `graph:badges` to the hook with `{node_id, duration, tokens}`.
- [x] Hook's `applyBadges` fills in text content and toggles visibility based on node state.
- [x] Badges have `pointer-events: none` so clicks pass through to the node.
- [x] Badge re-placement triggers: initial mount (rAF), window resize, pan/zoom events (optional — they transform with the SVG so re-placement isn't needed unless text scaling becomes wonky).
- [x] Visual check: parallel_audit run shows 3 branches with 3 different token magnitudes formatted distinctly (e.g., `412`, `28k`, `1.2M`).
- [ ] Commit.

### Phase G — Polish, a11y, demo, merge (0.5 day)

- [ ] `aria-label`s on nodes, badges, timeline entries.
- [ ] `Esc` clears selection; `?` toggles help overlay.
- [ ] Keyboard focus traversal on timeline (Tab + Enter).
- [ ] Record 30s screen capture of `./bin/tractor reap --serve examples/parallel_audit.dot` end-to-end: initial pan/zoom, click a branch, timeline fills, inspect tool-call expansion, see badges on completed nodes. Convert to GIF; commit to `docs/sprints/notes/sprint-0004-demo.gif`.
- [ ] Merge-gate checks: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`, `mix test --include integration`, `mix escript.build`.
- [ ] Sprint-1 regression smoke: `./bin/tractor reap examples/three_agents.dot` (no `--serve`) still exits 0, no Phoenix booted.
- [ ] PR body: goals checklist + demo GIF + a **"flagged choices"** section naming judgment calls (exact palette hex values, text-tag tool formatting style, chosen badge placement heuristic) inviting veto.
- [ ] Merge to `main` once CI is green.

## 7. Sequencing notes

- **Phase A → B** in any order; A is mostly doc work, B is trivial engine additive. Land B early so the badge path has data to show by Phase F.
- **Phase C is the architectural gate.** Every subsequent UI phase assumes the hook-owned SVG model. Don't start D/E/F before C is green.
- **Phase D (CSS) before Phase E (timeline)** — intentional inversion of draft sequencing. Claude's critique argued the opposite, but CSS is a shell and can stabilize while timeline data model is still in flux. The timeline *content* populates into whatever layout exists; don't rebuild styling against an old layout.
- **Phase F (badges) after Phase E** — badges depend on both hook infrastructure (C) and node-state push events (E). Data path proven before visual integration.
- **Every phase revertable.** If E's scroll-position preservation misbehaves, ship without it. If F's badges don't align, hide them by default and ship. Phase G's demo GIF is the only unskippable artifact.

## 8. Risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `phx-update="ignore"` + hook-owned SVG is a larger refactor than estimated (touching GraphRenderer, Show LiveView, and the JS hook protocol all at once). | Med-High | Land Phase C in two commits: (1) add the hook, wire clicks through `pushEvent`, keep server-side class injection running; (2) remove class injection and push state events instead. Bisectable; revert-friendly. |
| `svg-pan-zoom` drag vs. click conflict (drag becomes click at small movement). | Med | Library distinguishes drag from click; verify in Phase C smoke. If broken, add a 3px `mousedown→mouseup` threshold guard in the hook. |
| Browser `getBBox()` returns zeros before SVG is fully laid out (fonts not resolved). | High | Initial placement in `requestAnimationFrame`; resize listener; optional `MutationObserver` on `g.tractor-node` children. |
| ACP bridges surface usage in wildly different shapes (or not at all). | High | Tolerant field-matching (§5.3); hide badge if `total_tokens` nil/0; raw payload preserved in `Turn.events` for debugging; test coverage uses both documented + unknown shapes. |
| Server-side SVG re-renders sneak back in post-sprint (new code path triggers a string replacement). | Med | Comment in `GraphRenderer` banning it; runtime assertion in LiveView during test mount. |
| Timeline stream insertion duplicates response content (chunks + `response.md` both rendered). | Med | Explicit rule (§5.4): chunks append to a single `:response` entry body, never emit separate chunk entries. Tests cover. |
| Cutting-mat grid + Graphviz SVG overlap muddily at high zoom. | Low | Grid on container only, not on SVG. Zoom-to-8x agent-browser screenshot in Phase D. |
| Pixel-level iteration is slow without fast visual feedback loop. | Low now (agent-browser installed) | Document the agent-browser invocation in Phase A. Drive each CSS commit through an agent-browser screenshot cycle. |
| Scope creep in Phase G polish (accessibility, keyboard nav, demo recording all together). | Med | Each polish item is ≤30 min; total Phase G budget 0.5 day. If Phase E overruns, cut `?` help overlay first, then demo GIF to a still screenshot. |
| Palette taste drift: implementor picks warm cream anyway. | Med | Explicit hex starting points in §5.6; "no dominant warm-tan" is both a non-goal and a risk callout; agent-browser screenshot in Phase D checks palette family. |
| User dislikes text-tag tool humanization once they see it in situ. | Low | Single `TractorWeb.ToolCallFormatter` module — swapping tags for icons later is a 10-line change. |
| Token badge appears for some nodes and not others (bridge-dependent), reading as inconsistent. | Med | Acceptance criterion explicitly tolerates this. Flag in PR body. |

## 9. Acceptance criteria

- [ ] `mix test` green; `mix test --include integration` green on laptop.
- [ ] `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict` clean.
- [ ] `./bin/tractor reap --serve examples/parallel_audit.dot` opens a browser UI that exhibits:
  - Mouse-wheel zoom around cursor on the graph surface.
  - Drag-pan of the graph surface.
  - Double-click resets zoom and recenters.
  - Clicking any node swaps the sidebar to a single chronological timeline for that node, entries color-coded by type, each timestamped, each expandable.
  - Tool-call entries show human-readable text-tag summaries (`[READ]`, `[BASH]`, etc.) with raw JSON available on expansion.
  - At least one completed node shows both a duration badge and a token badge; at least one node (if its agent didn't surface usage) shows only the duration badge.
  - Viewport does *not* reset when live node events arrive.
  - Cutting-mat grid visible behind the graph surface; 40px thicker lines align with section dividers between header, graph, and sidebar.
  - Palette reads as cool neutral with muted green grid and single orange/amber live accent — **not** warm cream/beige dominant.
  - No browser console errors across a full run.
- [ ] Sprint-1 regression: `./bin/tractor reap examples/three_agents.dot` (no `--serve`) still exits 0 with no Phoenix booted.
- [ ] `mix test` includes new coverage for: `TractorWeb.ToolCallFormatter` (all matchers + fallthrough), `TractorWeb.RunLive.Timeline` (ordering, synthesis, tiebreaking), `TractorWeb.Format` (duration + token formatters), `Session` token-usage capture (both wire paths, unknown shapes, merge semantics).
- [ ] Demo GIF committed under `docs/sprints/notes/sprint-0004-demo.gif` showing pan/zoom, node selection, timeline population, tool-call expansion, badge visibility.
- [ ] PR body includes: goals checklist + demo GIF + "flagged choices" section (palette hex values, text-tag formatting style, badge placement heuristic) for user veto.
- [ ] Branch merged to `main` with green CI.

## 10. Sprint-5+ seeds (don't expand here)

- [ ] Run history browser (`/runs` index, picker, diff).
- [ ] Dark mode.
- [ ] Mobile / responsive layout.
- [ ] Writable UI (cancel/retry/step/re-prompt).
- [ ] Pure-Elixir layered-DAG SVG layout (Graphviz replacement).
- [ ] Token-cost estimation with per-model pricing.
- [ ] Persistent UI state across refresh (expanded-entry memory, pan/zoom position memory).
- [ ] Streaming cost display (uses the `:usage` event emission landed in §5.3).
- [ ] `first_success` join policy (requires ACP cancellation — sprint-3 seed).

## 11. Appendix — contested calls and how the merge resolved them

| Contested call | Decision | Reasoning |
|---|---|---|
| SVG re-render strategy: `phx-update="ignore"` + hook-owned (Codex) vs. snapshot/restore in `updated()` (Claude) | **Hook-owned** | All three critiques converged — Claude conceded outright. Eliminates re-render flicker class of bugs; cleaner long-term architecture. |
| Badge placement: browser `getBBox()` in hook (Codex) vs. server-side SVG post-processing (Claude) | **Browser `getBBox()`** | Graphviz geometry varies per shape; parsing coordinates in Elixir is fragile. Claude conceded. |
| Token usage transport: emit `:usage` event (Claude) vs. `status.json` re-read only (Codex) | **Both** | Hedge. Event future-proofs streaming cost displays; status.json drives badges. Cost is a few lines; benefit is no retrofitting later. |
| Tool humanization icons: emoji (Claude) vs. text tags (Codex) | **Text tags** | User preference (no emojis in code/output). Claude flagged this would need veto anyway. |
| Palette direction: warm cream (Claude's `#F5F1E8`) vs. cool neutral with muted green grid (Codex) | **Cool neutral** | Codex's critique called out warm cream as a violation of the "no beige/cream dominance" constraint. Claude's palette-hex discipline kept, but with cool hexes. |
| Sequencing: CSS before timeline (all drafts) vs. timeline before CSS (Claude's critique) | **CSS (D) before timeline (E)** | Sidebar layout is a shell; timeline data model populates *into* the shell. Landing the shell first lets the timeline team iterate on content without layout churn. |
| GraphBoard phase position: after timeline (Codex) vs. before timeline (Claude's critique) | **Before — Phase C** | Codex conceded the architectural gate should land early. Every later UI phase depends on the hook-owned ownership model. |
| Tool matcher list completeness: explicit list (Claude) vs. verbs+fields guidance (Codex) | **Explicit list** | Avoids implementor inventing a list under pressure. Claude's structure kept; emojis swapped for text tags. |
| Typography: `Geist Mono` web font (Gemini) vs. system mono stacks (Codex/Claude) | **System mono** | No asset pipeline → no web-font downloads. Constraint from sprint-2 carries forward. |
| TDD discipline: red-green fixtures first (Codex Phase A) vs. foundations-first but not red-green (Claude) | **Foundations-first, not red-green** | This is fundamentally a visual sprint. Write tests for pure modules (ToolCallFormatter, Timeline, Format) but don't TDD the LiveView rendering path. |
| `:usage` event vs. no new event kind | **Emit `:usage`** | Claude's future-proofing argument won. Negligible cost, meaningful benefit. |
| Scroll-position preservation: included (Claude) vs. not mentioned (Codex) | **Included** | Real UX paper-cut during streaming. Small inline JS, bounded scope. |
| Demo GIF: required (Claude) vs. "laptop demo" (Codex) | **Required** | Visual sprint needs a visual artifact. Regression-catch tool for future sprints. |
| Flagged-choices PR section: explicit (Claude) vs. not mentioned (Codex) | **Explicit** | Taste-heavy sprint; invite veto on the judgment calls cheaply. |
