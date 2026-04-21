# Observer UX backlog

Running log of observer-UI polish items surfaced during manual acceptance testing. Not sprint-sized yet — accumulate here, batch into a future UX-focused sprint when there's enough weight.

## Outstanding

### Edge rendering

- **Conditional vs. fallback edges are indistinguishable in the graph.** When a node has multiple outgoing edges (one conditional, one fallback), the rendering doesn't show which edge is conditional or what its condition is. Example: in `plan_probe.dot`, `ask_claude → inspect_probe [condition="..."]` + `ask_claude → exit` both render as plain arrows. Operator has no way to tell from the graph alone which edge will be taken or why.
  - Fix idea: label conditional edges with a short truncated form of the condition expression (or an icon + tooltip).
  - Related: edge-taken pulse (SPRINT-0005) does highlight which edge actually fired during a run, but doesn't help before the pipeline runs.
- **Curved / tangled edge routing** when Graphviz can't lay out parallel edges cleanly. The `plan_probe.dot` layout shows a sharply-curved fallback edge that reads as a rendering glitch.
  - Fix idea: investigate `splines=ortho` or `splines=line` for graph-level layout hints; may improve fallback-edge routing.

### State legibility

- **`×1` iteration badges** on every node are visual noise when no loop exists. Most nodes run exactly once; the badge adds clutter.
  - Fix idea: suppress `×1` badge; only render when `iteration > 1`. (Earlier polish commit inverted this intentionally to show iteration always; revisit whether it's worth the noise.)

### Bugs found during manual acceptance of SPRINT-0005/0006/0007/0008

- **Codergen → wait.human crash-restart loop.** Real ACP Claude path (not the mocked test path) causes the Runner GenServer to crash after `draft.node_succeeded` but before `review.node_started`. Supervisor restarts with stale checkpoint (`agenda: ["draft"]`), re-runs draft, re-crashes. Burns LLM tokens. Not caught by `mix test` because `AgentClientMock` returns a sanitized `%Turn{}` that doesn't reproduce whatever non-JSON-safe / crash-inducing value is in the real `updates` map. Temporary mitigation: added `Process.flag(:trap_exit, true)` + try/rescue + Logger.error in `Runner.handle_info/2` (not yet landed in the running BEAM because Phoenix file_system live-reload is broken on this machine).
- **WaitForm label mismatch.** Clicking `reject` in the WaitForm resolved as `approved` in the dialog. Indicates either the form's `phx-value-label` binding is wrong, the server-side `handle_event("submit_wait_choice", ...)` picks the wrong label, or the synthesized success path uses the wrong `preferred_label`. Zero test coverage for this — LiveView tests check the state transition but don't exercise actual button clicks through the rendered DOM.
- **WaitForm resolution doesn't advance the pipeline.** After the form reported the wait as resolved, neither the approved nor rejected node changed color in the graph and the run status stayed "running". Could be related to the Codergen→wait.human crash (if the underlying run was already dead), or could be a separate bug where the synthesized-success path doesn't trigger the downstream transition. Needs repro in a clean run.
- **Phoenix `file_system` / `mac_listener` missing.** Live-reload not functional on this machine → my code edits aren't picked up by the running BEAM, forcing full restarts to test changes. Not a Tractor bug but a dev-env snag worth documenting.

## Testing-methodology gap

The common thread across all four bugs above: `mix test` with `Mox` stubs passes green but the *real* UI + ACP + runner chain breaks in ways unit tests never see. We need a browser-driven acceptance layer that actually clicks things and verifies the resulting DOM / graph state / pipeline completion.

Candidate tool: Vercel Agent Browser (or Playwright MCP). Either lets a coding agent drive `http://127.0.0.1:4000/runs/<id>`, click buttons, read the DOM, and assert transitions.

See `docs/ui-acceptance-checklist.md` for the full list of interactions that belong in the automated suite.

## Resolved

(none yet)
