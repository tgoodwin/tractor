# Architecture

Orientation doc. The API and module layout will keep evolving — what's here is the load-bearing structure. When in doubt, the code is authoritative; when this doc disagrees with the code, the code is right.

## Three planes, one log directory

Tractor runs as three loosely-coupled planes that share state only through the filesystem:

```
            ┌──────────────────┐         ┌─────────────────────┐
            │   Execution      │ writes  │   $TRACTOR_DATA_DIR │
            │   (reap / CLI)   ├────────►│   /<run_id>/        │
            └──────────────────┘         │     events.jsonl    │
                                         │     manifest.json   │
                                         │     <node>/...      │
            ┌──────────────────┐ tails   │                     │
            │   Observation    ├────────►│                     │
            │   (Phoenix BEAM) │         └─────────────────────┘
            └──────────────────┘
                     ▲
            ┌────────┴─────────┐
            │   Driving        │
            │   (CLI / browser)│
            └──────────────────┘
```

1. **Execution.** `bin/tractor reap` (an escript) parses a DOT file, walks it as a DAG, dispatches each node to a handler, and writes events + per-node artifacts to `$TRACTOR_DATA_DIR/<run_id>/`. Crashes are tolerated; the on-disk state is the source of truth.
2. **Observation.** A Phoenix BEAM tails the same log directory via `Tractor.RunWatcher`, broadcasts events into `Tractor.PubSub`, and serves LiveView pages that visualize runs in progress.
3. **Driving.** The CLI for humans, plus the browser-test harness that drives the observer UI via `agent-browser`.

The decoupling is the point. Execution and observation are separate OS processes that never talk directly — only through `events.jsonl`. This is why a reap can crash without affecting the observer, why an observer can attach to a run-in-progress and replay history from disk, and why the browser harness can run pipelines fast (resident launcher BEAM) without coupling to the observer.

## Layout

```
lib/
├── tractor.ex
├── tractor/
│   ├── application.ex          # OTP supervision tree (escript-aware)
│   ├── cli.ex                  # escript entrypoint; subcommands: reap, validate
│   ├── runner.ex               # main DAG walker, handler dispatch, retries, parallel
│   ├── runner/                 # routing, budgets, control files, adjudication
│   ├── handler.ex              # behaviour: run/3, default_timeout_ms/0
│   ├── handler/                # one module per node type — see docs/handlers.md
│   ├── engine/branch_executor  # parallel-branch task contract
│   ├── pipeline.ex             # lowered Pipeline struct (nodes, edges, attrs)
│   ├── pipeline/parallel_block # discovered parallel regions
│   ├── node.ex                 # Node struct + accessors + shape↔type table
│   ├── edge.ex                 # Edge struct
│   ├── dot_parser.ex           # DOT → Pipeline lowering (uses :dotx)
│   ├── condition.ex            # recursive-descent edge-condition parser/evaluator
│   ├── validator.ex            # all lint rules (errors + warnings)
│   ├── diagnostic.ex           # Diagnostic struct
│   ├── diagnostic/formatter.ex # shared rendering for validate + reap
│   ├── event_log.ex            # writer side of the log-as-bus
│   ├── run_events.ex           # event emission API
│   ├── run_bus.ex              # PubSub broadcast for the observer side
│   ├── run_store.ex            # run directory layout, manifest writes
│   ├── run_watcher.ex          # observer-side tail; broadcasts to Phoenix.PubSub
│   ├── run_watcher/tail.ex     # per-run tail process
│   ├── agent.ex + agent/       # ACP backends: claude, codex, gemini
│   ├── acp/                    # ACP session/turn machinery (uses :acpex)
│   └── …
├── tractor_web/                # Phoenix observer (LiveView, graph render, wait form)
└── mix/                        # mix tasks
```

Outside `lib/`:

- `examples/*.dot` — sample pipelines, validated in CI.
- `test/browser/` — sh-driven browser harness (16 suites + a resident test launcher BEAM).
- `bin/tractor` — escript artifact; rebuild with `mix cli`.

## OTP supervision (boot)

`Tractor.Application.start/2` builds a supervision tree whose shape depends on whether the BEAM is running as an escript or as `mix phx.server`:

**Always started:**
- `Tractor.RunRegistry`, `Tractor.AgentRegistry`, `Tractor.StatusAgentRegistry`
- `Tractor.HandlerTasks`, `Tractor.StatusAgentTasks` (Task supervisors)
- `Tractor.ACP.SessionSup`, `Tractor.StatusAgentSup`, `Tractor.RunSup` (DynamicSupervisors)
- `Phoenix.PubSub` (named `Tractor.PubSub`)
- `Tractor.RunEvents`
- `Tractor.WebSup` (DynamicSupervisor for on-demand observer)

**Only when NOT escript AND `:server` flag set in config (i.e. `mix phx.server` in dev):**
- `TractorWeb.Endpoint`
- `Tractor.ResumeBoot`
- `Tractor.RunWatcher` + tail supervisor

Escript invocations of `tractor reap --serve` start the endpoint on demand under `Tractor.WebSup` instead of as a permanent child.

## Log-as-bus contract

The disk artifacts under `$TRACTOR_DATA_DIR/<run_id>/` are the durable interface between execution and observation:

| File | Written by | Read by | Purpose |
|---|---|---|---|
| `events.jsonl` | `Tractor.EventLog` (append-only) | `Tractor.RunWatcher.Tail` | Append-only event stream — every state change, prompt, response, decision, gate resolution |
| `manifest.json` | `Tractor.RunStore` | observer + resume + watcher | Run-level summary: status, start/end times, pipeline path, exit info |
| `<node_id>/` | individual handlers | observer + post-mortem | Per-node artifacts: `prompt.md`, `stderr.log`, `wait.json`, etc. |
| `checkpoint.json` | runner | resume | Snapshot for `tractor reap --resume` |

Anything that needs to outlive a process crash goes through this. Anything that's purely intra-process (e.g. handler internals) does not.

## Reap lifecycle (single-pipeline, normal path)

```
parse  →  validate  →  start engine  →  loop: pick node → run handler → write events → pick next edge  →  exit  →  write manifest
```

Concretely (`Tractor.CLI.run(["reap" | _])`):

1. **Parse** — `Tractor.DotParser.parse_file/1` produces a `Pipeline`.
2. **Validate** — `Tractor.Validator.validate_path/1`. Errors block (exit 10); warnings print to stderr and continue.
3. **Engine boot** — `Tractor.Runner` starts under `Tractor.RunSup`, opens the run directory, writes `manifest.json` with status `running`, emits `_run run_started`.
4. **Step loop** — `Runner` walks the DAG:
   - Pick the next node (start → outgoing edge selection).
   - Resolve the handler via `handler_for/1` (`runner.ex:1823`).
   - Apply the retry policy (`runner/budget.ex` + `runner/failure.ex`).
   - Invoke `handler.run(node, context, run_dir)`.
   - Write events as the handler reports them via `Tractor.RunEvents.emit/4`.
   - Pick the next edge based on outcome + condition evaluation (`runner/routing.ex` + `condition.ex`).
   - Repeat.
5. **Termination** — exit node reached, budget exhausted, or runtime failure. `manifest.json` flips to terminal status, final events flushed.
6. **Observer reap** — when `--serve` was used, the Phoenix BEAM stays alive until Ctrl-C; `RunWatcher` keeps tailing.

## Where the planes hand off

| Boundary | Mechanism |
|---|---|
| CLI → engine | `Tractor.Runner.start_link/1` under `Tractor.RunSup` |
| Engine → handler | `Tractor.Handler` behaviour: `run(node, context, run_dir) :: {:ok, outcome, updates} \| {:wait, …} \| {:error, reason}` |
| Engine → log | `Tractor.RunEvents.emit/4` → `Tractor.EventLog` (file) + `Tractor.RunBus` (PubSub) |
| Disk → observer | `Tractor.RunWatcher` polls/tails new run dirs, spawns a `Tractor.RunWatcher.Tail` per run, broadcasts `{:run_event, …}` on `Tractor.PubSub` |
| Observer → UI | LiveView mounts subscribe to `Tractor.PubSub` and re-render |
| Operator → engine | `wait.human` resolution writes a control file under the run dir; `Tractor.Runner.ControlFile` polls it |

## Validation pipeline

Pure functional analysis over the lowered `Pipeline` struct. No LLM. See `docs/usage/validate-prompt.md` for the rule list and authoring guidance.

```
DOT file
   ↓ DotParser.parse_file
Pipeline {nodes, edges, graph_attrs, parallel_blocks}
   ↓ Validator.diagnostics
[Diagnostic{code, severity, message, node_id, edge, fix}]
   ↓ Diagnostic.Formatter.format
formatted text  →  stdout (validate) or stderr (reap)
```

Same code path for both `tractor validate` and `tractor reap`. The shared formatter guarantees byte-identical diagnostic body text between the two commands.

## Browser harness (test/browser)

Three OS processes during a test run:

```
launcher BEAM   ────►  $TRACTOR_BROWSER_LOG_DIR/<run_id>/events.jsonl
   ▲                       ▲
   │                       │
   │ UDS                   │ tail
sh suites              Phoenix BEAM ◄──── chromium (agent-browser)
```

- The **launcher BEAM** is a long-lived test process that accepts pipeline-run requests over a UNIX-domain socket. Replaces per-reap escript cold-starts (~30s each) with a single warm process. Test-only code under `test/browser/launcher/`.
- The **Phoenix BEAM** runs the observer normally.
- **agent-browser** drives chromium against the observer.

Suites can opt into the subprocess path with `TRACTOR_BROWSER_NO_LAUNCHER=1`; the meta-test (`run-all-repeat.sh`) does this on iteration 3 to keep the subprocess path warm.

Details: `test/browser/README.md`, plus SPRINT-0010 / SPRINT-0011 plans for the design history.

## What this doc deliberately omits

- ACP protocol details — see `https://agentclientprotocol.com` and the `Tractor.ACP.*` modules.
- Per-handler semantics — see `docs/handlers.md`.
- Validator rule catalog — see `docs/usage/validate-prompt.md`.
- Reap CLI flag/env reference — see `docs/usage/reap.md`.
- Spec coverage map (which strongDM attractor spec sections tractor implements) — see `docs/spec-coverage.md`.
