# Browser Suites

Last green harness commit: `84ed789`

Run everything:

```bash
bash test/browser/run-all.sh
```

Run the repeat gate:

```bash
bash test/browser/run-all-repeat.sh
```

## Harness

`run-all.sh` now boots one resident test launcher over a unix-domain socket and routes browser-triggered reaps through it by default. The observer still stays read-only: runs execute in the launcher BEAM or an explicit `bin/tractor reap` subprocess, never inside Phoenix.

Every `tractor_reap` call logs its routing decision to stderr:

- `routing: launcher`
- `routing: subprocess (reason: …)`

Suites `15_cross_process_observer.sh` and `16_cross_process_wait_human.sh` are intentionally subprocess-only and must keep using `tractor_reap_subprocess` so the escript path stays exercised.

## Environment

- `TRACTOR_BROWSER_NO_LAUNCHER=1` forces every reap onto `bin/tractor reap`.
- `TRACTOR_BROWSER_SKIP_LOAD_GUARD=1` disables the ambient-load guard entirely.
- `TRACTOR_BROWSER_FORCE=1` bypasses only the abort threshold and still prints warnings.
- `TRACTOR_BROWSER_LOAD_WARN` and `TRACTOR_BROWSER_LOAD_ABORT` override the default warning and abort thresholds (`6` and `10`).
- `TRACTOR_BROWSER_LAUNCHER_SOCK` overrides the launcher socket path.
- `TRACTOR_BROWSER_PORT` overrides the observer port; subprocess suites now pass that port through explicitly.

## Notes

- `run-all.sh` wipes `TRACTOR_DATA_DIR` once at the top; it does not wipe between suites.
- `run-all-repeat.sh` runs five full harness passes and forces iteration 3 onto the subprocess path with `TRACTOR_BROWSER_NO_LAUNCHER=1`.
- CI or noisy local machines should usually use either `TRACTOR_BROWSER_SKIP_LOAD_GUARD=1` or `TRACTOR_BROWSER_FORCE=1`, depending on whether you want warnings preserved.

Suites:

- `01_top_bar.sh` — top-bar brand/version smoke on `examples/wait_human_review.dot`.
- `02_theme_toggle.sh` — dark-mode toggle and persistence on `examples/wait_human_review.dot`.
- `03_runs_panel.sh` — run list count/current-row navigation across `examples/wait_human_review.dot` and `examples/resilience.dot`.
- `04_status_feed.sh` — status-agent empty/live states on `examples/wait_human_review.dot` and `test/browser/fixtures/status_feed_wait.dot`.
- `05_graph.sh` — graph node/edge classes and cumulative loop badges on `examples/wait_human_loop.dot`.
- `06_node_panel_header.sh` — selected-node heading/model/reasoning pills on `test/browser/fixtures/node_panel_header.dot`.
- `07_run_summary.sh` — goal-gate summary state and live cost growth on `test/browser/fixtures/goal_gate_tool_fail.dot` and `test/browser/fixtures/run_summary_usage.dot`.
- `08_plan_checklist.sh` — plan replacement semantics on `examples/plan_probe.dot` with fake ACP `plan_replace`.
- `09_timeline.sh` — prompt/thinking/tool/runtime/wait/verdict timeline coverage on `test/browser/fixtures/timeline_markdown.dot`, `test/browser/fixtures/timeline_tool_runtime.dot`, `examples/wait_human_review.dot`, and `examples/haiku_feedback.dot`.
- `10_wait_form.sh` — static/error/approve/reject/timeout/restart-resume wait-form flow on `examples/wait_human_review.dot`.
- `11_help_overlay.sh` — `?` / `Escape` keyboard help behavior on `test/browser/fixtures/node_panel_header.dot`.
- `12_resizers.sh` — left/right drag plus persistence on `examples/wait_human_review.dot`.
- `13_dev_endpoints.sh` — `/api/health` coverage plus `/dev/*` retirement checks using `test/browser/fixtures/node_panel_header.dot`.
- `14_error_states.sh` — missing-run LiveView state and plain 404 route on `/runs/<bogus>` and `/nope`.
- `15_cross_process_observer.sh` — external `bin/tractor reap --serve` adopts the running observer and the browser sees a deterministic cross-process run complete using `test/browser/fixtures/run_summary_usage.dot`.
- `16_cross_process_wait_human.sh` — external `bin/tractor reap --serve` resolves `wait.human` across BEAMs and consumes the control file.
