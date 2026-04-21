# Browser Suites

Last green harness commit: `84ed789`

Run everything:

```bash
bash test/browser/run-all.sh
```

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
- `13_dev_endpoints.sh` — `/dev/reap`, `/dev/stop/:run_id`, and `/dev/stop-all` API coverage using `test/browser/fixtures/node_panel_header.dot`, `test/browser/fixtures/dev_interruptible.dot`, and `test/browser/fixtures/invalid_pipeline.dot`.
- `14_error_states.sh` — missing-run LiveView state and plain 404 route on `/runs/<bogus>` and `/nope`.
