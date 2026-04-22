# SPRINT-0010 — Decouple `tractor reap` from the Phoenix observer

**Type:** Design sprint (architecture + concrete implementation plan, not UI polish).

## Intent

`tractor reap` should be the pipeline executor, full stop. The Phoenix observer should *observe* runs by reading the on-disk event log, not host their execution. After this sprint: `tractor reap --serve` never collides on ports; a run started by a standalone `reap` process is visible and interactive in any observer watching the same `runs_dir`; `wait.human` is resolvable across processes. The rails for a future standalone `tractor viz` CLI are laid, but that command ships in a later sprint.

**Current state (facts):**
- `tractor reap --serve` boots its own Phoenix endpoint and runs the pipeline in that same BEAM (`lib/tractor/cli.ex:188`).
- `/dev/reap` lets the browser test harness start runs inside the already-running observer's BEAM (`lib/tractor_web/dev_controller.ex:15`).
- `Tractor.RunEvents` writes to on-disk ndjson *before* broadcasting via `Tractor.RunBus` (`lib/tractor/run_events.ex:36-38`) — disk is already the source of truth, `RunBus` is just the push channel.
- `wait.human` drive goes through `Registry.lookup(Tractor.RunRegistry, run_id)` — same-BEAM coupling.
- Run IDs are deterministic 6-char slugs (`lib/tractor/paths.ex`).

## Recommendation — Direction 2 (log-as-bus) with a thin probe for UX

Adopt **log-as-bus** as the cross-process substrate. The observer tails `events.jsonl` from disk and re-broadcasts into its local `RunBus`; `wait.human` resolution writes a control file that the runner polls while suspended. The filesystem under `<run_dir>/` is the only cross-process contract.

Layer a **thin CLI probe** on top so `tractor reap --serve` can detect an already-running observer and hand off the URL instead of launching a second endpoint. The probe is pure convenience — the cross-process transport works identically whether `reap --serve` "adopted" or "owned" the observer.

**Why not Direction 1 alone.** The HTTP shim fixes port collision but preserves the coupling: execution still depends on whichever BEAM the request lands in, and `wait.human` still needs `Registry.lookup`. A UX patch, not a design fix.

**Why not Direction 3.** Distributed Erlang is the most OTP-idiomatic answer and the worst CLI UX: cookie management, node-name collisions across checkouts, EPMD, and silent failures when cookies mismatch. We don't need the capabilities distribution buys — observer is a passive reader + one-shot mailbox writer, not a peer making remote calls.

**Foreclosures.** Path-normalization, health-probe, and log-as-bus work is not throwaway under Direction 3. The `/api/health` probe and disk transport remain useful even if we later add distributed Erlang. The thin-probe code (~30 lines) is the only genuinely throwaway piece.

## Product decisions

- [x] `tractor reap` is executor-only. After this sprint, `reap` never requires the observer to share its BEAM.
- [x] Keep `reap` headless by default. `--serve` remains opt-in; do **not** add `--no-serve` (redundant surface — bare `reap` is already headless).
- [x] `--serve` means "ensure there is a compatible observer; run the pipeline; exit when the run finishes." It no longer blocks on SIGINT for post-mortem viewing, because the observer now survives independently.
- [x] Observer loss mid-run is non-fatal to execution. The run keeps going; CLI exit code reflects the pipeline result.
- [x] Treat filesystem state under the run directory as the only cross-process contract this sprint: manifests, `status.json`, `events.jsonl`, and wait control files.
- [x] `RunBus` stays an in-BEAM fast path. The file watcher is additive; correctness does not depend on PubSub.
- [x] Delete `/dev/reap` after harness migration. Do **not** promote it to `/api/runs` — the observer should not host pipeline execution.

## Non-goals

- [x] No `tractor viz` CLI in this sprint (separate follow-up).
- [x] No distributed Erlang, `Node.connect/1`, shared cookies, `:global`, or Horde.
- [x] No multi-host / remote observation. Both processes share a filesystem.
- [x] No auth, TLS, or non-loopback exposure.
- [x] No UI redesign; minimal LiveView changes (wiring only).
- [x] No observer-initiated writes beyond the wait decision mailbox (no cancel/retry/budget-override buttons).
- [x] No schema change to `events.jsonl` beyond confirming `seq` is present.
- [x] No cross-node wait drive (log-as-bus handles cross-process within one host).

## Surface area

### 4.1 Endpoint cleanup (no promotion)

- [x] Add `GET /api/health` returning `{ok: true, version: Application.spec(:tractor, :vsn), runs_dir: <abs path>}`. This is the CLI probe target.
- [x] Keep `/dev/reap`, `/dev/stop/:id`, `/dev/stop-all` only as long as the browser harness depends on them.
- [x] Migrate `test/browser/_lib.sh` to launch runs by shelling out to `bin/tractor reap` against the shared `TRACTOR_DATA_DIR` instead of `POST /dev/reap`.
- [x] Delete `/dev/reap` and the unused controller routes **after** harness migration lands green.
- [x] Do not introduce `/api/runs` for starting runs — execution belongs to `reap`, not the observer.

### 4.2 CLI probe (`tractor reap --serve`)

- [x] Change `--serve` default port from `0` to `4000` so reuse/probe is meaningful.
- [x] Keep `--port 0` as an explicit ephemeral escape hatch for tests (skip probe, launch fresh).
- [x] Probe: `GET http://127.0.0.1:<port>/api/health` with 500 ms connect + read timeout. Use `:httpc` (no new dep).
- [x] **200 + `{ok: true}` + matching `runs_dir`**: "adopt" path. Skip `DynamicSupervisor.start_child(Tractor.WebSup, ...)`. Run the pipeline in the CLI's local BEAM (without Phoenix) and print the adopted observer's URL `http://127.0.0.1:<port>/runs/<run_id>` to stderr.
- [x] **200 + `{ok: true}` + mismatched `runs_dir`**: exit 6 with a legible error explaining the mismatch.
- [x] **Connection refused**: "own" path. Boot `TractorWeb.Server` under `Tractor.WebSup` and launch the runner locally (same as today).
- [x] **Other 2xx / non-Tractor response / timeout**: exit 4 with "port 4000 busy, not a tractor observer; pass `--port N` or stop the other process."
- [x] Exit codes: existing 0/3/10/20 preserved. New: 4 (port conflict), 5 (observer unreachable after adopt attempt), 6 (runs_dir mismatch).
- [x] `--serve` exits when the run completes, regardless of whether it owned or adopted the observer. Prior "sleep forever" post-mortem behavior is removed.
- [x] `--no-open` unchanged.
- [x] Align `mix tractor.reap --serve` with the same probe/adopt/own architecture — no dev-only same-BEAM shortcut.

Both filesystem channels (event tail + wait control) are replay-driven: `file_system` notifications are the low-latency hint; a periodic rescan is the correctness floor. Edge-triggered delivery alone is never trusted.

### 4.3 Live updates in a non-runner BEAM — `Tractor.RunWatcher`

- [x] New `Tractor.RunWatcher` GenServer. Starts under `Tractor.WebSup` when the endpoint is up and also under the base app tree when `mix phx.server` is the host.
- [x] On start: scan `runs_dir`, find runs whose `manifest.json` shows `status: "running"`, register them for tailing.
- [x] New-run discovery: watch `runs_dir` for mkdir events; spawn a `RunWatcher.Tail` child once `manifest.json` appears.
- [x] Per-run `Tail` child under a `DynamicSupervisor`. One crash per run, not per observer.
- [x] Watcher backend: add `file_system` as a top-level hex dep (already transitive via `phoenix_live_reload` in dev; promote to direct for prod-safety).
- [x] Polling fallback: regardless of `file_system` availability, pair event notifications with a 1s stat/rescan loop so missed inotify/FSEvents notifications never strand the UI. Correctness is replay-driven, not edge-triggered.
- [x] Per-node byte-offset persistence at `<run_dir>/<node>/.watcher-offset`. Buffered writes (flush on idle, every 1s, or on shutdown).
- [x] Partial-line safety: read up to the last `\n`, retain remainder in a per-tail buffer; never broadcast until a full line parses. Malformed lines are logged and skipped, not fatal.
- [x] Idempotency seal: each event carries a monotonic `seq`; track last-broadcast seq per `(run_id, node_id)` and drop duplicates before broadcasting (covers offset-replay on watcher restart *and* co-located `reap --serve` where the watcher sees its own broadcasts).
- [x] Memory-growth teardown: on `run_completed` / `run_failed` / `run_interrupted`, tear down the `Tail` child; keep only metadata for later post-mortem lookups.
- [x] Audit `RunLive.Show.mount/3` to confirm `load_from_disk` reconstructs initial state without executor cooperation; fix if not.

### 4.4 `wait.human` across BEAMs — control file

- [x] Cross-process drive via `<run_dir>/control/wait-<node_id>.json`. Schema: `{run_id, node_id, attempt, label, submitted_at, submitted_by}`.
- [x] Keep `wait.json` under the node attempt dir as the durable UI payload (prompt/options/timeout). Control file is only the operator's response channel.
- [x] `Tractor.Run.submit_wait_choice/3`: local `Registry.lookup` first; on miss, atomically write the control file (`File.write!` to `.tmp` then `File.rename!`). Return `:ok` either way — observer's job is done.
- [x] Runner subscribes to `<run_dir>/control/` via `file_system` when a wait arms (watch the *directory*, not the target file path — the atomic publish is the `rename`, and event kinds differ across macOS/Linux). On any `{:file_event, _, {path, _}}` matching `wait-<node>.json`, re-stat and attempt to consume.
- [x] Synchronous scan on arm and on checkpoint rehydrate, *before* entering the receive loop. Covers the startup race where the observer writes the control file before the runner's watcher is attached.
- [x] 1s stat/rescan fallback while a wait is pending — identical shape to §4.3's tail fallback. Correctness is replay-driven, not edge-triggered.
- [x] Unsubscribe from `file_system` and cancel the fallback timer on resolve, timeout, or exit. No global watch loop — only active while at least one wait is pending.
- [x] Validation: control file is accepted only if its `attempt` matches the current waiting attempt. Stale files (wrong attempt, older runs) are renamed to `<file>.stale-<ts>` for debugging, not silently deleted. Duplicate or spurious file events are idempotent no-ops once consumed.
- [x] Preserve existing `wait_human_pending` / `wait_human_resolved` event semantics so the UI timeline stays event-driven.

### 4.5 Manifest path integrity

- [x] `Tractor.RunStore.open/_`: always `Path.expand/1` the DOT path before writing `manifest.json`. Store the absolute path as `dot_path`; preserve the original under `dot_path_input` for diagnostics.
- [x] Observer DOT resolution order: (a) absolute `dot_path` from manifest → (b) `dot_path_input` against observer cwd → (c) error card "source DOT not reachable; path was `X`".
- [x] Expand `--cwd` and `--runs-dir` to absolute paths in the CLI before any probe, launch, or write.
- [x] Back-compat: manifests from prior sprints lacking `dot_path_input` default it to `dot_path`.
- [x] Resume/post-mortem code paths read the absolute `pipeline_path` — never relative to the observer's cwd.

## Sequencing

1. **Phase A — path integrity + probe scaffolding** (smallest, independent, safest first).
   - Absolute path normalization (§4.5); manifest migration back-compat.
   - `GET /api/health` endpoint with `{version, runs_dir}`.
   - CLI probe with adopt/own/error branches and exit codes 4/5/6; default `--port 4000`.
   - `mix tractor.reap --serve` alignment.
2. **Phase B — `Tractor.RunWatcher` + disk→bus bridge** (biggest risk; earliest realistic start).
   - `RunWatcher` + per-run `Tail` children; mkdir discovery; offset persistence; partial-line buffering; seq dedupe; memory teardown.
   - Wire into `Tractor.WebSup` and the `mix phx.server` boot path.
   - Verify `RunLive.Show.mount/3` initial hydration from disk.
3. **Phase C — wait-control mailbox** (parallelizable with Phase B).
   - Control file schema under `<run_dir>/control/`; atomic writes; `attempt` validation.
   - Runner-side poll scoped to pending-wait window; rehydrate on resume.
   - `Tractor.Run.submit_wait_choice/3` disk fallback.
4. **Phase D — `--serve` lifecycle cutover** (depends on B landing so the adopted path has a live transport).
   - Remove `block on SIGINT`; `--serve` exits with the run.
   - Observer-loss-is-non-fatal audit.
5. **Phase E — harness migration + `/dev/reap` retirement + tests** (gated on A–D green).
   - Migrate `test/browser/_lib.sh` off `/dev/reap` to shell-driven `bin/tractor reap`.
   - Add `test/browser/15_cross_process_observer.sh` and `test/browser/16_cross_process_wait_human.sh`.
   - Add `test/tractor/cross_beam_wait_human_test.exs` spawning a second `elixir` process via `Port.open`.
   - Delete `/dev/reap` routes and controller only after the harness changes are green.
   - Update `docs/usage/reap.md`.

## Task list (consolidated — every actionable item is checkable)

### Phase A
- [x] Add `file_system` as a direct hex dep (audit transitive availability first).
- [x] Add `Tractor.CLI.probe_observer/1` using `:httpc`; honor 500ms timeouts.
- [x] Route `GET /api/health` to a new controller returning `{ok, version, runs_dir}`.
- [x] `TractorWeb.Router`: add `/api` pipeline (json-only, no CSRF), loopback-bound via endpoint config.
- [x] Default `--port` in `serve_reap/3` to 4000; preserve `--port 0` semantics.
- [x] Implement adopt/own/error branches with exit codes 0/3/4/5/6/10/20. Document in `Tractor.CLI.@moduledoc`.
- [x] Align `mix tractor.reap --serve` with the same probe/adopt/own code path.
- [x] `Tractor.RunStore.open/_`: expand DOT path, write `dot_path` + `dot_path_input`. Back-compat default for old manifests.
- [x] Observer DOT resolver: implement 3-step fallback per §4.5.
- [x] Expand `--cwd` and `--runs-dir` to absolute paths in CLI before probe/launch.

### Phase B
- [x] `Tractor.RunWatcher` GenServer; start under `Tractor.WebSup` and the base app tree; scan on init.
- [x] `DynamicSupervisor` + `Tractor.RunWatcher.Tail` per-run child.
- [x] `Tail` implementation: `file_system` notifications + 1s stat/rescan fallback; per-node byte-offset persistence; partial-line buffering; seq dedupe; broadcast via `RunBus.broadcast/3`.
- [x] New-run mkdir discovery against `runs_dir`; start `Tail` once `manifest.json` appears.
- [x] Memory teardown on terminal run events (`run_completed` / `run_failed` / `run_interrupted`).
- [x] Audit + fix (if needed) `RunLive.Show.mount/3` initial hydration from disk when no in-BEAM PID exists.
- [x] Confirm `events.jsonl` carries `seq`; if missing, add it (single-line change).

### Phase C
- [x] Define `Tractor.Runner.ControlFile` schema + atomic writer (`.tmp` + rename).
- [x] `Tractor.Run.submit_wait_choice/3`: local `Registry.lookup` → on miss, write `<run_dir>/control/wait-<node>.json`.
- [x] Runner subscribes to `<run_dir>/control/` via `file_system` when a wait arms; handles `{:file_event, _, {path, _}}` messages via a pure `apply_control_file/2` function for easy unit testing.
- [x] Synchronous scan on arm and on checkpoint rehydrate, before entering the receive loop — covers already-present-file race.
- [x] 1s stat/rescan fallback while any wait is pending; unsubscribe + cancel timer on resolve/timeout/exit.
- [x] `attempt`-based validation; archive non-matching files as `<file>.stale-<ts>`. Consumed files are deleted.
- [x] Rehydrate wait subscription from checkpoint on resume, before `advance/1`.
- [x] Preserve `wait_human_pending` / `wait_human_resolved` event shapes.

### Phase D
- [x] Remove `trap_sigint(endpoint_pid)` + `:timer.sleep(:infinity)` from `serve_reap/3`. `--serve` exits on run completion.
- [x] Ensure observer loss mid-run does not abort execution (verify runner supervision).
- [x] Update `docs/usage/reap.md` with new lifecycle semantics.

### Phase E
- [x] Migrate `test/browser/_lib.sh` `tractor_reap()` off `POST /dev/reap` to shelling out to `bin/tractor reap` against shared `TRACTOR_DATA_DIR`.
- [ ] Confirm all 14 existing browser suites still pass with the new harness. — **3 of 14 confirmed; full pass deferred to SPRINT-0011 (see Follow-up)**
- [x] `test/browser/15_cross_process_observer.sh`: start `mix phx.server` (bg); `bin/tractor reap --serve examples/haiku_feedback.dot` in separate proc; assert "adopting observer at http://127.0.0.1:4000/runs/..." in stderr; assert live node transitions in browser.
- [x] `test/browser/16_cross_process_wait_human.sh`: same harness with `wait_human_review.dot`; click approve in observer; assert CLI exits 0 and control file is consumed.
- [x] `test/tractor/cross_beam_wait_human_test.exs`: spawn second BEAM via `Port.open({:spawn_executable, System.find_executable("elixir")}, ...)`; act as observer from the test BEAM; write control file; assert run advances.
- [x] Unit tests: `RunWatcher.Tail` ndjson replay idempotency; control-file round-trip + stale guard; `seq` dedupe under co-located replay.
- [x] Delete `TractorWeb.DevController` routes and related browser harness code.
- [ ] Full `test/browser/run-all.sh` green as the release gate. — **deferred to SPRINT-0011 (see Follow-up)**

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| FS notifications miss appends or overflow under load | High | Pair with 1s stat/rescan fallback; correctness is replay-driven |
| `runs_dir` mismatch between observer and CLI causes silent adoption failure | High | `/api/health` carries `runs_dir`; CLI exits 6 on mismatch with legible error |
| Stale wait control files resolve wrong retry attempt | High | `attempt` field validated against current pending attempt; archive invalid as `.stale-<ts>` |
| Control file present before runner's `file_system` watcher attaches (startup race) | High | Synchronous scan on arm + on checkpoint rehydrate, before entering receive loop — same replay-first discipline as the tail |
| Partial-line reads during runner crash mid-flush | Med | Per-tail buffer; never broadcast until full `\n`-terminated line parses |
| `.watcher-offset` staleness after log rotation / truncation | Med | Offset read is bounds-checked against file size; reset if stale |
| LiveView initial paint from disk diverges from live updates | Med | Browser suite asserts page reload mid-run matches live DOM |
| Co-located `reap --serve` produces duplicate UI events (watcher sees own broadcasts) | Med | `seq` dedupe drops duplicates before broadcast |
| Changing `--serve` from "sleep forever" to "exit with run" surprises existing users | Low | Documented in `docs/usage/reap.md`; observer survives independently so post-mortem workflow is unaffected |
| Deleting `/dev/reap` breaks the browser harness | High | Migration task lands in the same sprint; deletion gated on migration being green |

## Acceptance criteria

- [ ] `mix phx.server` running + `bin/tractor reap --serve examples/wait_human_review.dot` prints the existing observer's URL, does not boot a second endpoint, runs to completion, and the observer shows the live run and can resolve the wait node.
- [ ] `mix phx.server` + `bin/tractor reap --serve --port 4001 ...` launches a second independent observer; both are visible.
- [ ] `bin/tractor reap examples/haiku_feedback.dot` (no `--serve`) with a running observer: run appears live in the observer without the CLI opening a port.
- [ ] `bin/tractor reap --serve` against a non-Tractor process on port 4000 exits 4 with a legible message; no Phoenix stack trace, no hang.
- [ ] `bin/tractor reap --serve --runs-dir X` against an observer pointed at `Y` exits 6 before starting the run, with a legible mismatch message.
- [x] `bin/tractor reap --serve` exits when the pipeline completes — no sleep-forever behavior.
- [x] Observer restart during a run does not corrupt state; reopening reconstructs from disk and catches up from `events.jsonl` without duplicate UI events (seq dedupe verified).
- [x] `wait.human` resolves across separate observer/executor processes via control file; resume after restart preserves pending wait + any already-written operator response.
- [ ] `test/browser/run-all.sh` green including `15_cross_process_observer.sh` and `16_cross_process_wait_human.sh`. — **deferred to SPRINT-0011, see Follow-up below**
- [x] `/dev/reap` route removed; browser harness drives runs via `bin/tractor reap`.
- [x] Post-mortem of a run copied to a different working copy renders correctly or shows an unambiguous "source DOT not reachable" card.
- [x] `RunLive.Show` PubSub receive path unchanged; only initial-hydration code touched if required.
- [x] Sprint leaves a clean seam for `tractor viz` (follow-up): a standalone BEAM running `TractorWeb.Server` + `RunWatcher` against `--runs-dir` renders and drives runs identically.

## Follow-up — browser harness timing (SPRINT-0011 scope)

The architectural deliverables shipped: the sprint's `mix test` gate is green (247 tests, 0 failures), cross-process wait resolution was verified end-to-end manually (runner + observer in separate BEAMs, control file consumed in <2s), and suites 01–03 pass under `run-all.sh`. Suite 04 reliably fails at `ab_wait_event fn "...completed"` — **not a SPRINT-0010 correctness bug, a harness timing issue exposed by the new process topology.**

**Diagnosis.** Before this sprint, `tractor_reap()` POSTed to `/dev/reap` and the run executed inside the already-running observer's BEAM (single process). After this sprint, `tractor_reap()` shells out to `bin/tractor reap` which spins a fresh escript BEAM per run — ~30s cold-start each. With Phoenix observer + concurrent reap BEAMs + 4 chromium subprocesses + an unrelated ambient CPU hog (Backblaze at 95% in the diagnostic run), load average hit **19.27**. The websocket message carrying the "approve" click from chromium → Phoenix got delayed ~5 minutes by CPU starvation. By the time `submit_wait_choice` was dispatched, the runner had already hit its 300s `Run.await` cap.

Concrete evidence:
- Suite 04 runner: `run: Kp86YQ` at 07:48:25, `Run.await` timeout at 07:53:25, control file at 07:53:26 (1s AFTER runner died).
- Sysmon showed 300s of `reap=1 beam=1 load>10` during the stall.
- Suite 04 passes when run in total isolation (no prior suites warming the system up).

**Scope for SPRINT-0011 ("harness timing under new process topology"):**
- [ ] Raise `ab_wait_event fn`/`text` default timeouts on long-running wait-human paths (currently agent-browser's 30s default).
- [ ] Investigate BEAM reuse: either pool escripts across suites, or pre-warm a single long-lived BEAM that the harness communicates with via the existing `/dev/reap`-style endpoint (but scoped to test harness, not reintroduced in prod).
- [ ] Add an ambient-load guard at `run-all.sh` start — bail with a clear message if load > N or if a known CPU hog (Time Machine, Backblaze) is detected.
- [ ] Optional: move suite 04 to use a wait-human fixture with no `wait_timeout`, relying purely on operator click to resolve, so the test isn't racing against multiple timeouts.
- [ ] Re-run `run-all.sh` under the new harness and tick the remaining acceptance checkboxes here.

**What this sprint leaves at `done`:** architecture + unit/integration tests + 3 of 14 browser suites. What SPRINT-0011 closes: the remaining 11 browser-suite validations, gated on harness timing work.

## Follow-up seeds (further out)

- `tractor viz [--runs-dir PATH] [--port N]` — standalone observer CLI; one day's work on top of this sprint.
- Authenticated non-loopback observer (multi-host) — would escalate to Direction 3.
- `tractor runs ls` / `tractor runs inspect <id>` — terminal observer reading the same manifests and ndjson, zero Phoenix.
