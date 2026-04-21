# Browser Regression Log

Append-only log of real regressions surfaced while landing the SPRINT-0009 browser suites.

| Date | Test file | Symptom | Root cause | Fix commit |
|---|---|---|---|---|
| 2026-04-20 | `test/browser/02_theme_toggle.sh` / `03_runs_panel.sh` / `04_status_feed.sh` / `05_graph.sh` | Live graph state and sidebar assertions flapped after node updates. | Graph hook updates were not applied consistently after LiveView patches, so browser-visible state lagged behind run events. | `1b60447` |
| 2026-04-20 | `test/browser/04_status_feed.sh` | Final status summary rows disappeared after terminal events. | Status-feed coalescing dropped the terminal update instead of preserving the last write for a status id. | `62cc05e` |
| 2026-04-20 | `test/browser/05_graph.sh` | Iteration / token / duration badges stopped reflecting cumulative node state. | Graph badge payloads were rebuilt from incomplete node status data after rerenders. | `5024a66` |
| 2026-04-20 | `test/browser/10_wait_form.sh` | Approve / reject button click fired but the run stayed `waiting` and downstream nodes never started. | `Tractor.Runner.submit_wait_choice` only consulted in-memory `state.waiting`; stale runner state after checkpointing meant the pending wait was never rehydrated from disk. | `3516ba5` |
| 2026-04-20 | `test/browser/07_run_summary.sh` | Harness restart into an alternate fake ACP mode produced malformed provider env JSON. | `_lib.sh` used brittle shell parameter expansion when defaulting `TRACTOR_ACP_*_ENV_JSON`, corrupting explicit overrides. | `4bdc8df` |
| 2026-04-20 | `test/browser/08_plan_checklist.sh` | Harness restarts left the old Phoenix server alive, so suites talked to stale code or stale ACP config. | `_lib.sh` tracked the launcher shell PID instead of the actual listener PID on port `4001`. | `2f6241f` |
| 2026-04-20 | `test/browser/09_timeline.sh` | Token-usage rows never appeared in the activity timeline. | Timeline rendering handled `"usage"` events but not `"token_usage"` events emitted by the runtime. | `75992f5` |
| 2026-04-20 | `test/browser/11_help_overlay.sh` | Pressing `Escape` cleared selection but left the keyboard-help overlay visible. | Global key handler only pushed `clear_selection`; it never toggled the help overlay off on `Escape`. | `6982164` |
| 2026-04-20 | `test/browser/13_dev_endpoints.sh` | `POST /dev/stop/:run_id` returned `200`, but the run page never flipped to `interrupted`. | Supervisor shutdown terminated the runner process without persisting an interrupted terminal state or emitting `run_finalized`. | `3989561` |
| 2026-04-20 | `test/browser/14_error_states.sh` | Navigating to an unknown run id rendered a blank LiveView surface. | `missing?: true` was assigned in `RunLive.Show.mount/3`, but the template had no missing-run branch. | `ec22c51` |

## Interaction Audit

- 2026-04-20: Theme toggle is exercised via `role=button` + accessible name (`Toggle dark mode`).
- 2026-04-20: Wait-form actions are exercised via `role=button` + exact accessible name (`approve`, `reject`, `revise`).
- 2026-04-20: Timeline disclosure is exercised via `data-testid="timeline-toggle-*"`.
- 2026-04-20: Graph-node selection keeps `data-testid="node-*"` as the stable address. The SVG `<g>` wrappers now also carry `role="button"` / `aria-label`, but agent-browser still does not actuate them directly, so suites use `ab_dom_click` against the `data-testid` target instead of a CSS-only selector.
