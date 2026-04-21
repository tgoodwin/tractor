# SPRINT-0009 — Observer UI fixes + polish, verified via agent-browser

**Status:** planned
**Target:** as long as it takes. No time box — sign-off requires every feature in §4 green.
**Builds on:** SPRINT-0004 (observer shell) · 0005 (feedback loops + back-edges + iteration badges) · 0006 (status feed + plan checklist + run meta) · 0007 (cost budget + goal-gate pill) · 0008 (wait.human form + tool/conditional handlers).
**Scope owners:** `lib/tractor_web/**`, `priv/static/assets/**`, new `test/browser/**`.

## 1. Intent

Four sprints shipped ~40 user-visible UI surfaces on the Phoenix LiveView observer with almost no end-to-end browser coverage. We've relied on `mix test` for LiveView assertions and manual eyeballing for everything else. This sprint closes the gap with **Vercel's [agent-browser][ab]** — a headless Chromium CLI with accessibility-tree snapshots and semantic locators — running scripted tests against a live Phoenix server. Each feature in §4 gets a scripted suite; the implementing agent drives the suites, logs regressions, fixes them, re-runs until green. Success is measured in passing suites, not in commits.

[ab]: https://agent-browser.dev — `npm install -g agent-browser` / `brew install agent-browser` / `npx agent-browser`

**Why agent-browser and not Playwright directly.** Agent-browser produces ref-based accessibility-tree snapshots (`@e1`, `@e2`…) that an LLM can reason about without HTML DOM noise, and its `find role`/`find label`/`find testid` semantic locators pair naturally with the ARIA attributes already in our HEEx templates. It's a better primitive for the "LLM-driven audit" style we want, and avoids bespoke Playwright glue for the execution agent.

## 2. Goals

- [x] agent-browser CLI installed locally; first-run Chromium downloaded; smoke `open localhost:4001/runs/<id>` → `snapshot -i` → `close` works end-to-end.
- [x] Exhaustive UI feature catalog (this document, §4) enumerates every user-visible surface shipped in SPRINT-0004..0008.
- [ ] Every feature in §4 has a `test/browser/<feature>.sh` suite: sequential agent-browser commands with assertions, exit non-zero on failure.
- [ ] Every interactive target in §4 resolvable by semantic locator (ARIA role + name, `aria-label`, `<label for=>`, or `data-testid`). Attribute gaps filled with the least-invasive hook (prefer ARIA over testid).
- [ ] Four fixture pipelines exercise the full matrix; each drives its suite(s):
  - `examples/haiku_feedback.dot` — judge + conditional back-edge + iteration badges + verdict timeline entries
  - `examples/resilience.dot` — retry/backoff + timeout → status pill transitions + failed-tone lifecycle
  - `examples/plan_probe.dot` — condition DSL + cost budget + goal-gate path + status feed
  - `examples/wait_human_review.dot` — wait.human form + pending → resolved transition + operator choice
- [x] **User-reported regression fixed**: operator clicks `approve`/`reject` button in the wait.human form → pipeline actually advances (selected outgoing edge fires, next node runs, run reaches `completed`). See §4.10 for the end-to-end assertion. This is not a "verify UI state" test — it's a "verify the whole decision→progression chain" test, because the user has observed this chain silently breaking.
- [ ] `test/browser/README.md` indexes every suite + last-pass commit SHA.
- [ ] `test/browser/run-all.sh` is a serial harness: boot Phoenix, load fixtures via `/dev/reap`, run every suite, teardown. Exit 0 ⇒ sign-off.
- [ ] One-shot invocation instructions for the executor agent in §6; runbook lives with the code, not in the PR description.

## 3. Non-goals

- [ ] **No unit-test replacement.** Existing `mix test` + feature-test suite stays. Browser tests are additive.
- [ ] **No visual-regression / pixel-diff tooling.** No Percy, no Chromatic, no screenshot comparisons. Assertions are semantic (element exists, text matches, class toggles).
- [ ] **No parallel suite execution.** Phase-B runs serially — one Phoenix server, one Chromium, one test at a time. Keeps the run log human-readable and avoids test-to-test state leakage.
- [ ] **No CI wiring.** This sprint produces local scripts. CI hookup is SPRINT-0010+ follow-up (flagged in §9 seeds).
- [ ] **No new UI features.** Only bug fixes discovered during testing, plus ARIA/testid hooks when a target isn't resolvable.
- [ ] **No refactor.** Don't collapse components, rename LiveViews, or reorganize CSS. A rename is only in scope if a test can't otherwise pass.
- [ ] **No demo GIFs, screenshots, or PR-body artifacts.** (Per prior sprint-deliverable policy.)
- [ ] **No write controls** (cancel, retry, force-accept, extend-budget). Observer stays read-only except for the wait.human form, consistent with SPRINT-0004..0008 non-goals.

## 4. UI feature catalog

**Conventions.**
- *Route/selector/assertion* columns describe how an agent-browser script interacts and verifies.
- *Sprint* indicates which sprint first shipped the feature (inferred from recent commits `85ec3f2..HEAD` and sprint docs).
- *Fixture* names the pipeline that best exercises the feature.
- Selectors use agent-browser syntax: `role:<role>[name="..."]`, `text:"..."`, `label:"..."`, `testid:"..."`, or `css:<selector>` as last resort.

### 4.1 Top bar — brand + version

| Item | Selector | Assert | Sprint | Fixture |
|---|---|---|---|---|
| Brand mark | `text:"Tractor"` within `aria-label="Tractor"` | visible on every run page | 0004 | any |
| Version pill | `css:.top-bar-version` | text matches `/^v\d/` when `Application.spec(:tractor, :vsn)` set | 0004 | any |

Test file: `test/browser/01_top_bar.sh`.

### 4.2 Theme toggle

| Item | Selector | Assert | Sprint |
|---|---|---|---|
| Toggle button | `role:button[name="Toggle dark mode"]` | clickable; hook `ThemeToggle` attached | 0004 |
| Light→dark persistence | — | after click + reload, `html` carries the `dark` class (or whatever the hook sets) | 0004 |
| Icon swap | `css:.theme-toggle-slot-light svg`, `.theme-toggle-slot-dark svg` | both present in DOM; one visible at a time via CSS | 0004 |

Steps: `find role button --name "Toggle dark mode" click` → `snapshot -i` → reload → `snapshot -i` → assert attribute / visible icon differs. Test: `test/browser/02_theme_toggle.sh`.

### 4.3 Runs panel (left sidebar)

| Item | Selector | Assert | Sprint |
|---|---|---|---|
| Panel heading | `css:.runs-panel-header .eyebrow` text `"Runs"` | present | 0004 |
| Runs count | `css:.runs-count` | integer equal to list length | 0004 |
| Run row | `role:link` inside `css:.runs-row` | navigates to `/runs/<id>` | 0004 |
| Pipeline name | `css:.runs-row-pipeline` | non-empty | 0004 |
| Status pill | `css:.status-pill.status-<state>` | one of: running/completed/errored/goal_gate_failed/interrupted/unknown | 0007 (goal_gate_failed added) |
| Current-run highlight | `css:.runs-row.is-current` | exactly one element | 0004 |
| run_id line (mono) | `css:.runs-row-id` | matches UUID | 0004 |
| started_at · duration | `css:.runs-row-meta` | duration renders `—` when unfinished, formatted else | 0004 |
| Empty state | `css:.runs-row-empty` with text `"no runs yet"` | visible only when `/dev/stop-all` was issued in a fresh data dir | 0004 |
| Auto-refresh (5s) | — | after launching a second run via `/dev/reap`, within 10s it appears in the list without reload | 0004 |

Test: `test/browser/03_runs_panel.sh`. Needs fixture side-channel: POST `/dev/reap?path=...` to seed a run mid-test.

### 4.4 Status feed (left sidebar, above runs)

| Item | Selector | Assert | Sprint |
|---|---|---|---|
| Panel heading | `text:"Status"` inside `aria-label="Status agent"` | visible | 0006 |
| Empty (agent off) | `css:#status-feed-empty` text `"Status agent disabled"` | when DOT has no `status_agent` attr | 0006 |
| Empty (agent on, no updates yet) | same id, text `"Waiting for first node..."` | when `status_agent=claude\|codex\|gemini` and no events fired | 0006 |
| Update row | `css:.status-feed-row` | stream renders newest-on-top | 0006 |
| Node id + iteration | `.status-feed-node`, `.status-feed-iteration` | match active node; iteration `x1`/`x2`/... | 0006 |
| Markdown summary | `.status-feed-summary` | renders backticks, emphasis, line breaks | 0006 |
| Coalescing | — | repeated `plan_update` with same `status_update_id` updates one row, not N | 0006 |

Test: `test/browser/04_status_feed.sh`. Fixture: `plan_probe.dot` with `status_agent=claude`.

### 4.5 Graph — SVG rendering, selection, live state

| Item | Selector | Assert | Sprint |
|---|---|---|---|
| Graph container | `css:#graph.graph-svg` | SVG child exists; hook `GraphBoard` attached | 0004 |
| Node click selects | `css:#graph [data-node-id]` | clicking pushes `select_node`; right panel updates | 0004 |
| State class | `css:[data-node-id] .node-state-<s>` | state ∈ {pending, running, succeeded, failed, waiting, rejected, accepted} | 0005 (rejected/accepted), 0008 (waiting) |
| Back-edge styling | `css:path.edge-back` (or similar) | rendered with distinct class when `condition=reject` edge exists | 0005 |
| Edge-taken animation | — | after `graph:edge_taken` event, the taken edge gets `edge-taken` class for ≥200ms | 0005 |
| Cutting-mat grid | `css:.graph-svg pattern#grid` (or inline grid) | grid pattern present | 0004 |
| Badges overlay | `css:[data-node-id] .badge-duration/.badge-tokens/.badge-iterations` | populated after node finishes | 0004/0005 |
| Iteration badge (×N) | `.badge-iterations` text matches `/^×\d+$/` | only when iteration ≥ 1 | 0005 |
| Cumulative duration | `.badge-cumulative` | only when iteration > 1 | 0005 |

Test: `test/browser/05_graph.sh`. Fixture: `haiku_feedback.dot` drives iteration ≥ 2 and a `reject`→loop. Uses `find testid "node-<id>"` — **prerequisite: ensure `<g data-testid="node-<id>">` attribute on SVG node wrappers** (see §7 gaps).

### 4.6 Node panel header (right sidebar)

| Item | Selector | Assert | Sprint |
|---|---|---|---|
| Empty state | `css:.empty-sidebar` text `"Select a node."` | visible when no node selected | 0004 |
| Selected node title | `css:.node-panel h2` | equals clicked node_id | 0004 |
| Model pill | `css:.panel-pills .pill-model` | renders from `node.llm_model` or provider fallback | 0004 |
| reasoning_effort pill | second `.pill-model` | renders if attr set | 0004 |

Test: `test/browser/06_node_panel_header.sh`. Combined with 4.5.

### 4.7 Run summary card (right sidebar, top)

| Item | Selector | Assert | Sprint |
|---|---|---|---|
| Run ID heading | `css:.run-summary-card h2` | equals URL run_id | 0004 |
| Run status pill | `css:.run-summary-card .status-pill` | class matches `run_status_label/1` output | 0004 |
| `goal_gate_failed` pill | same, class `status-goal_gate_failed` | when terminal gate fail | 0007 |
| `goal_gate_failed` note | `text:"Goal-gate failure terminated the run"` | visible only in that state | 0007 |
| Cost pill | `css:.pill-model` text starts with `"cost "` | formatted via `Format.usd/1` | 0007 |
| Cost updates live | — | after node with token_usage completes, cost pill value grows (poll via reload for stability) | 0007 |

Test: `test/browser/07_run_summary.sh`. Goal-gate path: `plan_probe.dot` variant or new fixture that forces bypass.

### 4.8 Plan checklist

| Item | Selector | Assert | Sprint |
|---|---|---|---|
| Section heading | `css:.panel-section-heading .eyebrow` text `"Plan"` | only when plan non-empty | 0006 |
| Plan list | `css:ul.tractor-plan` | `<li>` per entry | 0006 |
| Item status | `css:.tractor-plan-item.pending/.in_progress/.completed` | reflects latest `plan_update` event | 0006 |
| Status dot | `.tractor-plan-status[aria-hidden="true"]` | sibling of content | 0006 |
| Priority badge | `.tractor-plan-priority` | optional, present only when attr set | 0006 |
| Replacement semantics | — | a second `plan_update` with shorter entries list replaces, not appends | 0006 |

Test: `test/browser/08_plan_checklist.sh`. Needs a fixture emitting three plan updates via the fake ACP agent (see §7 — fixture TBD).

### 4.9 Activity timeline

| Item | Selector | Assert | Sprint |
|---|---|---|---|
| Timeline container | `css:#timeline.timeline` | hook `StickyTimeline` attached | 0004 |
| Entry tag | `css:.tl-entry.tl-<type>` | types: prompt, thinking, tool_call, tool_call_update, message, response, stderr, lifecycle, usage, iteration_header, verdict, tool_runtime, wait_runtime | 0004 + 0005 + 0006 + 0008 |
| Entry tone | `.tl-<tone>` | neutral/accent/success/failure/muted | 0004 |
| Lifecycle entry | `.tl-lifecycle` | static (no `<details>`, no caret) | 0004 |
| Expandable entry | `details` | click caret toggles `open` attr | 0004 |
| Default expanded | `details[open]` | matches `timeline_open?/1` result: response expanded, prompt/tool_call collapsed, verdict expanded, wait_runtime pending expanded | 0004 |
| Verdict entry | `.tl-verdict` with title `"Verdict"`, summary `"accept: …"` or `"reject: …"` | green tone for accept, accent for reject | 0005 |
| Iteration header | `.tl-iteration_header` summary `"Iteration N"` | bands timeline visually | 0005 |
| Usage entry | `.tl-usage` summary `"<N> tokens"` | renders on `usage` event | 0004 |
| Tool runtime | `.tl-tool_runtime` | `[TOOL] invoked` / `[TOOL] output truncated` | 0008 |
| Wait runtime | `.tl-wait_runtime` | `[WAIT] pending` expanded; `[WAIT] resolved` collapsed | 0008 |
| Stderr entry | `.tl-stderr` | tail of stderr.log (≤80 lines) | 0004 |
| Markdown body | `.tl-body-prompt/.tl-body-response/.tl-body-thinking` | renders code fences, lists | 0004 |
| Raw JSON body | `.tl-body-tool_call pre.tractor-raw-json` | pretty-printed JSON | 0004 |
| Keyboard Tab/Enter | — | Tab moves through `summary[tabindex=0]`; Enter toggles details | 0004 |
| Sticky scroll | — | adding entries while scrolled to bottom keeps bottom pinned; scrolled-up preserves position | 0004 |

Test: `test/browser/09_timeline.sh`. Biggest suite; break into sub-scripts per entry-type if needed.

### 4.10 Wait form (right sidebar) — operator decision → pipeline progression

**This is the highest-priority suite in the sprint.** User has reported that clicking `approve` / `reject` in the wait form does *not* advance the pipeline. The test below verifies the whole chain: button click → `submit_wait_choice` event → `Run.submit_wait_choice/3` → edge selection → next node runs → run completes. Every assertion below is load-bearing.

**Fixture graph** (`examples/wait_human_review.dot`):
```
start → review_gate (hexagon, wait.human, wait_timeout=30s, default_edge=reject)
review_gate -[approve]-> approved (tool: prints "approved") → exit
review_gate -[reject]-> rejected (tool: prints "rejected") → exit
```

#### 4.10.a Form presentation (static)

| Item | Selector | Assert | Sprint |
|---|---|---|---|
| Panel visible | `css:.wait-form-panel[aria-label="Human decision required"]` | only when selected node is `wait.human` AND state `waiting` | 0008 |
| Heading | `text:"Decision Required"` | visible | 0008 |
| Prompt text | `css:.wait-form-prompt` | equals `wait_prompt` attr value `"Choose the review outcome"` | 0008 |
| Waiting-since meta | `css:.wait-form-meta` | renders `"waiting <duration>"` | 0008 |
| Timeout-in meta | same node | renders `"timeout in <ms formatted>"` when `wait_timeout` set; updates as time passes | 0008 |
| Label buttons count | `role:button.wait-choice-button` | exactly 2 (one per outgoing label: `approve`, `reject`) | 0008 |
| Button text | per button | equals outgoing edge label verbatim | 0008 |

#### 4.10.b End-to-end: operator clicks `approve` → pipeline runs `approved` → `exit`

Sequence (each step an agent-browser command + assertion):

1. `POST /dev/reap?path=examples/wait_human_review.dot` → capture `run_id`.
2. `open /runs/$run_id`, `wait --load networkidle`, `snapshot -i`.
3. Wait for `review_gate` state to become `waiting`: `wait --text "Decision Required"` (≤5s).
4. Select `review_gate` if not auto-selected: `find testid "node-review_gate" click`.
5. Assert wait form visible (4.10.a rows).
6. Click approve: `find role button --name "approve" click`.
7. **Assertions after click** (all must hold within 10s of click):
   - `review_gate` node state class flips from `waiting` → `succeeded` (via `wait --fn` polling the SVG node class, or `snapshot -i` + class check). *The user-reported bug manifests here — if the pipeline is broken, `review_gate` stays `waiting` or flips to `failed`.*
   - `approved` node state class transitions to `running` then `succeeded` (within 15s total).
   - `exit` node state class becomes `succeeded`.
   - Run status pill on the right-panel summary card flips from `running` → `completed`.
   - Edge `review_gate → approved` gets the `edge-taken` class (or whatever class the JS hook applies; verify by observing the style change in snapshot).
   - Timeline for `review_gate` gains a `[WAIT] resolved` entry (`tl-wait_runtime.tl-success`) with summary `"approve via operator"`.
   - Wait form is replaced by the **Resolved panel**: `css:.wait-form-panel[aria-label="Wait resolution"]` with text containing `"approve via operator"`.
   - `POST /dev/reap` on the same pipeline from a cold data-dir → new run follows same path end-to-end. (Sanity check that it wasn't a leftover-state accident.)

#### 4.10.c End-to-end: operator clicks `reject` → pipeline runs `rejected`

Same as 4.10.b with the reject label. Mirror all assertions. Bonus: `rejected` node's tool command output (`"rejected"`) visible in its timeline `response` entry when selected.

#### 4.10.d Timeout path: no click → `default_edge=reject` fires

1. Launch fixture, select `review_gate`, but do **not** click.
2. Wait 35s (> `wait_timeout=30s` + buffer).
3. Assertions:
   - `review_gate` state → `succeeded` (same class as operator-driven success).
   - `rejected` node runs and succeeds.
   - Timeline `[WAIT] resolved` entry's summary is `"reject via timeout"` (not `"via operator"`).
   - Run completes.

Suite cost: ~1 minute because of the 30s wait. Include it once in `run-all.sh` and gate behind an env flag (`TRACTOR_BROWSER_LONG=1`) by default so iteration is fast.

#### 4.10.e Invalid-label path: malformed choice surfaces error, pipeline doesn't advance

`submit_wait_choice` accepts any string, but `Run.submit_wait_choice/3` validates against `outgoing_labels` and returns `{:error, {:invalid_wait_label, labels}}`.

1. Select `review_gate` while waiting.
2. Force-submit an invalid label. agent-browser can invoke `phx-click` with custom value via `evaluate` (JS eval against LiveSocket), or we add a hidden `aria-invalid` test button in non-production builds. *Decide during Phase B — prefer the JS-eval approach so production template stays clean.*
3. Assertions:
   - `css:.wait-form-error` visible, text contains `"Invalid choice"` and lists allowed labels `approve, reject`.
   - `review_gate` remains in `waiting` state. Pipeline does not advance.
   - Buttons remain clickable; error clears on next `wait_human_pending` tick or on successful submit.

#### 4.10.f Resume path: kill Phoenix mid-wait, restart, click still works

Tractor checkpoints pending waits to `checkpoint.json`; `ResumeBoot` re-spawns in-flight runs on BEAM start (see recent commit `0db3fb7`).

1. Launch fixture. Wait for `review_gate` to be `waiting`.
2. Kill Phoenix: `kill -TERM <phoenix_pid>` (harness tracks the PID).
3. Restart: `mix phx.server &`.
4. `open /runs/$run_id`, `snapshot -i`.
5. Assertions:
   - `review_gate` still `waiting` in the graph + wait form still visible.
   - Click `approve`. Same cascade as 4.10.b.

Suite: `test/browser/10_wait_form.sh` (with sub-scripts `10a_wait_form_static.sh`, `10b_wait_form_approve.sh`, `10c_wait_form_reject.sh`, `10d_wait_form_timeout.sh`, `10e_wait_form_invalid.sh`, `10f_wait_form_resume.sh` if we split; keep in one file if manageable). Fixture: `wait_human_review.dot`.

### 4.11 Help overlay

| Item | Selector | Assert | Sprint |
|---|---|---|---|
| Key `?` toggles | `find role button testid:"help-trigger"` or keystroke | `help-overlay` section appears | 0004 |
| Overlay heading | `text:"Keys"` | visible | 0004 |
| Key list | four `<p>` entries (Esc / ? / Tab / Enter) | all present | 0004 |
| Dismiss `Esc` | keystroke | overlay hides; selection still cleared if a node was selected | 0004 |

Test: `test/browser/11_help_overlay.sh`. **Gap:** there's no visible trigger button and no keyboard hook for `?` in the current HEEx — either the hook is in app.js unscoped, or it was never wired. Audit in §7.

### 4.12 Resizer handles

| Item | Selector | Assert | Sprint |
|---|---|---|---|
| Left resizer | `css:#resizer-left[phx-hook="Resizer"]` | present, `aria-hidden="true"` | 0004 |
| Right resizer | `css:#resizer-right[phx-hook="Resizer"]` | present | 0004 |
| Drag left → narrower left panel | via `mouse` | `.runs-panel` computed width decreases by ≥20px | 0004 |
| Drag right → narrower right panel | via `mouse` | `.node-panel` computed width decreases | 0004 |
| Persistence | — | after reload, panel widths restored if hook writes to localStorage | 0004 |

Test: `test/browser/12_resizers.sh`. agent-browser supports `mouse drag @e1 @e2` — verify in docs before writing. **Gap:** if no persistence, flag and decide during Phase B.

### 4.13 Dev endpoints (API-level, not LiveView)

| Item | Request | Assert | Sprint |
|---|---|---|---|
| Launch | `POST /dev/reap?path=examples/haiku_feedback.dot` with `Accept: application/json` | 200, JSON `{run_id, url, path}`; `url` navigable and renders run | 0006 |
| Launch missing file | `?path=examples/nonexistent.dot` | 404, JSON `{error:"file not found", path:...}` | 0006 |
| Launch invalid DOT | fixture with validator-rejected DOT | 422, JSON `{error:"validation failed", messages:[...]}` | 0006 |
| Stop single | `POST /dev/stop/:run_id` after `reap` | 200 `{stopped: <id>}`; run's status pill flips to `interrupted` within 30s | 0006 |
| Stop missing | unknown run_id | 404 `{error:"run not found in registry", ...}` | 0006 |
| Stop all | `POST /dev/stop-all` after launching 2 runs | 200 `{stopped: 2}`; both flip to `interrupted` | 0006 |
| Param missing | `POST /dev/reap` with no query | 400 `{error:"missing ?path=..."}` | 0006 |

Test: `test/browser/13_dev_endpoints.sh`. These can run via `curl` (not agent-browser) but verification (status-pill flip) uses a browser snapshot.

### 4.14 Error states

| Item | Selector | Assert | Sprint |
|---|---|---|---|
| Missing run (no manifest) | navigate `/runs/<bogus-uuid>` | LiveView renders something resolvable — **gap: current `missing?: true` branch has no template block**; Phase B decides: 404 redirect, empty-state screen, or "run not found" banner | 0004 |
| 404 for any other path | GET `/nope` | 404 plain text `"not found"` (`ErrorController.not_found/2`) | 0004 |

Test: `test/browser/14_error_states.sh`.

## 5. Execution phases

### Phase A — Setup and bootstrap (~0.5d)

- [x] Install agent-browser: `brew install agent-browser && agent-browser install`. Verify `agent-browser --version` runs.
- [x] Confirm Phoenix dev server boots (`mix phx.server`) on `localhost:4001`.
- [x] Seed one test run: `POST /dev/reap?path=examples/haiku_feedback.dot` → note run_id.
- [x] Smoke: `agent-browser open http://localhost:4001/runs/<id> && agent-browser wait --load networkidle && agent-browser snapshot -i`. Expect element refs for top bar, runs panel, graph, node panel.
- [x] Write `test/browser/_lib.sh` helpers: `ab_assert_visible`, `ab_assert_text`, `ab_assert_class`, `ab_click`, `ab_reload`, `ab_wait_event`. Keep it 50-100 lines, no framework.
- [x] Write `test/browser/run-all.sh` harness: boots Phoenix in background (`mix phx.server` pid tracked), loops test files alphabetically, reports pass/fail count, tears down.

### Phase B — Feature coverage pass (~3–5d)

- [ ] Walk §4 top-to-bottom. For each row:
  1. Author the agent-browser script.
  2. Run it. If it can't locate the target: add the minimal ARIA / testid attribute to the HEEx template.
  3. If it locates but assertion fails: the bug is real. Fix it. Add a fix commit referencing the failing suite (e.g. `fix(observer): wait form error clears on resolve (test/browser/10_wait_form.sh)`).
  4. Re-run the suite until green. Move on.
- [ ] Where a feature requires a specific pipeline state (e.g. status-agent off vs. claude), write the fixture inline into the test script or add a small example DOT under `test/browser/fixtures/`.
- [ ] Log every regression in a `test/browser/regressions.md` append-only log with {date, test file, symptom, root cause, fix commit}. This becomes the sprint's quality artifact — not a PR body.

### Phase C — Gap-fill and stabilization (~1–2d)

- [ ] Audit: are there interactive elements in §4 that can only be reached by CSS selectors (not ARIA or testid)? List them; fix each. Preference order: ARIA role + name > `aria-label` > `<label for>` > `data-testid`.
- [ ] Flake-hunt: re-run `run-all.sh` three times. Any intermittent failure → investigate race in the suite (missing `wait --load` / `wait --text`), or real event-order bug in the LiveView. Fix the underlying cause; don't insert blind `wait 2000`.
- [ ] Known-gap decisions from §4:
  - [ ] `.11` Help overlay trigger: either wire the `?` hotkey in app.js, or add a visible `role=button aria-label="Keyboard help"` in the top bar. Pick one, not both.
  - [ ] `.12` Resizer persistence: if not implemented, either (a) add localStorage write in `Resizer` hook, or (b) drop the persistence row from the test. Decide.
  - [ ] `.14` Missing-run state: LiveView branch `missing?: true` renders nothing. Ship a one-sentence empty state `"Run not found."` + link to `/` (but `/` 404s — so link to the most recent run, or omit).

### Phase D — Sign-off

- [ ] `bash test/browser/run-all.sh` exits 0. Copy the last-run log to `test/browser/LAST-GREEN.log` (git-tracked).
- [ ] `test/browser/README.md` finalized: per-suite one-liner + which fixture it drives.
- [ ] Update `docs/spec-coverage.md` for any spec rows that become falsifiable through browser tests (if any).
- [ ] Sprint ledger flipped to `done`.

## 6. Agent-browser invocation template for the executor

The executor (opus / sonnet / gpt-5.4 / gemini — whichever the user picks via `/sprint-execute`) should follow this pattern per suite:

```bash
# 1. Navigate
agent-browser open "http://localhost:4001/runs/$RUN_ID"
agent-browser wait --load networkidle

# 2. Accessibility snapshot (gives ref handles @e1, @e2, ...)
agent-browser snapshot -i

# 3. Interact via semantic locator (preferred) or ref (fallback)
agent-browser find role button --name "Toggle dark mode" click
# or
agent-browser click @e7

# 4. Wait for the expected state change
agent-browser wait --text "Dark mode"        # or
agent-browser wait --fn "document.documentElement.classList.contains('dark')"

# 5. Assert
agent-browser find css ".theme-toggle[aria-pressed='true']" text
# exit non-zero if missing — wrap in test helper

# 6. Close between suites (refs invalidate on page change anyway)
agent-browser close
```

For natural-language prompts during exploratory debugging (Phase B drift), `agent-browser chat "open the observer and verify the wait form appears when you click the hexagon"` is allowed — but every passing finding **must** be translated back into a scripted suite before Phase D.

## 7. Known gaps + pre-identified bugs (to fix during Phase B)

Discovered while authoring §4. These are pre-conditions for the tests, not deferrals.

| Gap | Current state | Fix |
|---|---|---|
| **Wait-form decision → pipeline progression broken** (user-reported) | Clicking `approve`/`reject` in the wait form does not advance the pipeline. Root cause unknown — could be (a) `submit_wait_choice` handler not calling `Run.submit_wait_choice/3`, (b) `Run.submit_wait_choice/3` not rehydrating the suspended frontier entry, (c) edge selector not consuming the resolved label, (d) runner not emitting `wait_human_resolved`. §4.10.b is the diagnostic; Phase B must root-cause and fix, not paper over with UI-only assertions. | Reproduce with `wait_human_review.dot`; follow the chain from `show.ex:188 submit_wait_choice` → `Run.submit_wait_choice/3` → `Tractor.Runner` wait-resume path. Add regression test at the layer where the bug lives (not just the browser suite). |
| SVG nodes not test-addressable | `graph_renderer.ex` emits raw SVG from dot-to-svg; no per-node handles | Wrap each `<g>` with `data-testid="node-<id>"` + `data-node-id="<id>"` (latter already referenced in `show.ex` selection handler) |
| `?` hotkey undocumented | `show_help?` assign flips via `toggle_help` event, but no visible trigger in HEEx and no key listener in app.js | Add either visible trigger (top-bar icon button) or keyboard hook; §5.C picks one |
| Missing-run template | `assign(socket, missing?: true, runs: [])` but `show.html.heex` has no `@missing?` branch — renders the default scaffold with empty data | Add `:if={@missing?}` branch with friendly empty state |
| Edge-taken class lifecycle | `graph:edge_taken` hook handler adds class; duration of `.edge-taken` unspecified | Spec it (≥200ms) + assert in test |
| Wait-form button names | `<button>{label}</button>` without `aria-label` — relies on text content only | Fine for `find text`, but flag if labels include whitespace/punctuation that trips the locator |
| Status-pill colors | CSS classes `.status-running` etc. — visual-only, not testable without pixel diff | Skip. Assert class presence, not color. |

## 8. Testing / risk table

| Risk | Likelihood | Mitigation |
|---|---|---|
| agent-browser flaky on macOS Chromium | Med | Pin version in `README.md`; use `wait --load networkidle` religiously; if Chromium headless differs from headed, use `--headed` during debugging |
| LiveView stream timing races with assertions | High | All `stream_insert` assertions wait on `--text` or `--fn`, never fixed-duration sleeps |
| Fixtures mutate shared `.tractor/runs/` state across suites | High | Each suite launches its own run via `/dev/reap`; harness wipes `.tractor/runs/` before `run-all.sh` |
| Markdown rendering differs between prompts and responses | Low | Test both directions (prompt body + response body) in timeline suite |
| Cost formatting drifts (`Format.usd/1`) under new budgets | Low | Assert prefix `"cost $"` + numeric suffix, not exact digits |
| Wait-form timeout display clock-skew | Low | Assert presence of `/timeout in \d+/`, not exact remaining ms |

## 9. Seeds for SPRINT-0010+

- [ ] CI wiring (GitHub Actions matrix: Node LTS × agent-browser latest). Depends on Phase D.
- [ ] Visual regression via agent-browser screenshots + pHash diff (opt-in).
- [ ] Parallel test execution (one Chromium per suite) — requires fixture isolation.
- [ ] Write-mode observer controls (cancel / retry / extend-budget). Their tests extend 4.3, 4.7.
- [ ] Accessibility audit pass using `agent-browser accessibility` snapshot + axe ruleset.
- [ ] `agent-browser chat "..."` session recording → auto-convert to scripted suite (stretch).

## 10. Merge gates

Same as prior sprints:
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix credo --strict`
- `mix test`
- `mix test --include integration`
- `mix escript.build`

**Plus** (new):
- `bash test/browser/run-all.sh` exits 0.
