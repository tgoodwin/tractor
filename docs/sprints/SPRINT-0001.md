# SPRINT-0001 — Minimal `DOT → reap` happy path

**Status:** planned
**Target:** 6–8 focused days (the Phase C ACP spike is the schedule risk)
**Merged from:** 3 drafts (codex, gemini, claude) + 3 cross-critiques under `docs/sprints/drafts/`

## 1. Intent

Ship `tractor reap some.dot` as a working escript on the user's laptop. Parse a Graphviz DOT pipeline, walk it, and for each agent node drive a real coding agent — **Claude, Codex, and Gemini** — to completion via the Agent Client Protocol (ACP). The run writes inspectable per-node artifacts to disk, returns a meaningful exit code, and the branch lands merged on `main` with green CI.

Multi-agent (all three) in sprint 1 is **non-negotiable**: the acceptance DOT drives one node per agent in the same run.

## 2. Goals

- [x] Scaffold `tractor` as a Mix/OTP application at the repo root (no nested dir).
- [x] Parse the sprint-1 DOT subset into Tractor-owned structs; validate strictly before anything is executed.
- [x] Wrap ACPex behind `Tractor.ACP.Session` — a GenServer that translates acpex's callback shape into a blocking `prompt(pid, text, timeout) → {:ok, final_text} | {:error, reason}` API.
- [x] Drive a linear pipeline `start → claude → codex → gemini → exit` end-to-end.
- [x] Persist run artifacts (`manifest.json` + per-node `prompt.md` / `response.md` / `status.json`) atomically.
- [x] Meaningful test suite: parser, validator, run-store, production ACP client against an in-repo fake ACP agent (NDJSON JSON-RPC over stdio), engine, CLI. Port-leak assertion included.
- [x] Stable CLI exit codes separating usage / parse+validate / agent-runtime failures.
- [x] `./tractor reap examples/three_agents.dot` exits 0 against the fake agent in CI and against real Claude/Codex/Gemini ACP bridges on the user's laptop.
- [x] Branch merged to `main` with green CI.

## 3. Non-goals (push back anything that touches these)

- [x] `tractor sow`, `tractor validate` public verb, `tractor ls`, `tractor logs`, `tractor reap --resume`.
- [x] Crash-resume / checkpoint replay / durable event log.
- [x] LiveView, web UI, TUI, streaming progress beyond stderr status lines.
- [x] Yaks integration.
- [x] Preflight auth / permission / reachability checks.
- [x] Parallel fan-out, conditional edges (`condition=`), human gates (`wait.human`), retries, tool handlers, MCP config, context-fidelity modes.
- [x] ACP reconnect on agent crash. One attempt per node; on failure, fail the run.
- [x] Daemonization, `mix release`, cross-BEAM observability. (Escript only for sprint 1.)

If a task feels like it belongs here, stop and push it out.

## 4. Architecture — the opinionated calls

### 4.1 Project shape
- Elixir 1.17 / OTP 27. Single OTP application, no umbrella, no Phoenix, no Ecto.
- Distribution: **escript** (`mix escript.build` → `./tractor`). Release deferred.
- `mix new . --sup --force` at the repo root with `IDEA.md` / `LICENSE` / `docs/` moved aside beforehand and restored after. (Gemini's "Phase 0 via /tmp skeleton + copy" is clumsy — don't do that.)

### 4.2 DOT ingest
- **Parse with `Dotx`** (Hex), not by shelling out to `dot -Tjson`. Keeps Tractor a pure-Elixir escript with no Graphviz runtime dep. Use `Dotx.decode/1` + `Dotx.flatten/1` + `Dotx.spread_attributes/1`, then normalize into Tractor structs. (If Dotx proves inadequate during Phase B, fall back to `dot -Tjson` — but that is the fallback, not the default.)
- Normalize into `%Tractor.Pipeline{}`, `%Tractor.Node{}`, `%Tractor.Edge{}`. Don't let Dotx shapes leak past the parser boundary.
- **Node selector attribute is `llm_provider`**, matching the Attractor spec (not `agent=`, not `model=`). Sprint 1 accepts exactly `"claude" | "codex" | "gemini"`.

### 4.3 DOT subset (sprint 1)
**Supported**
- One `digraph`, directed, non-strict.
- Bare node ids; `graph [goal="..."]`; node attrs `label`, `shape`, `type`, `prompt`, `llm_provider`, `llm_model`, `timeout`; edge attrs `label`, `weight`.
- Shape normalization: `Mdiamond → start`, `Msquare → exit`, `box → codergen`. Explicit `type=` attr overrides.
- Chained edges (Dotx flattening handles this).

**Rejected with `%Tractor.Diagnostic{code, message, node_id?, edge?}`**
- Zero or multiple start nodes; zero or multiple exit nodes.
- Cycles (`:digraph_utils.is_acyclic/1`).
- Edges pointing to undeclared nodes; non-exit nodes with no outgoing edge; non-start nodes with no incoming edge.
- Codergen nodes missing `llm_provider` or with a provider outside the supported three.
- Unsupported handler types: `wait.human`, `conditional`, `parallel`, `parallel.fan_in`, `tool`, `stack.manager_loop`.
- Unsupported attrs: edge `condition` / `fidelity` / `thread_id` / `loop_restart`; graph `model_stylesheet` / retries / default-fidelity.
- Undirected or `strict` graphs; multiple `digraph` blocks.

Loud failure is the point: the sprint-later feature set must not silently enter sprint 1.

### 4.4 Edge selection (deterministic, no conditions)
- Outgoing edges ordered by highest `weight` (default `1.0`), tie-broken by lexical `to` node id.
- If a non-exit node has multiple outgoing edges of equal weight, that's fine — rule above is total.

### 4.5 ACP integration — the riskiest piece
- **`Tractor.ACP.Session` GenServer** wraps ACPex. API: `start_link(agent_module, opts)`, `prompt(pid, text, timeout)` (blocking `GenServer.call`, returns `{:ok, final_text} | {:error, reason}`), `stop/1`.
- Internal state machine `:idle → :prompting → :idle` buffers streaming `session/update` deltas and resolves the pending call on `stopReason: "end_turn"`. Terminal failure modes (`max_tokens`, `max_turn_requests`, `refusal`, `cancelled`, JSON-RPC errors, port exit, timeout) each map to a distinct `{:error, reason}`.
- **One ACP session per node.** Spin up → prompt → collect → tear down. No reuse; avoids context bleed between agents and keeps the state model trivial.
- **Advertise only implemented ACP client capabilities** at `initialize`. Don't over-advertise filesystem/terminal methods.
- **Time-boxed spike (2h) kicks off Phase C:** read `lostbean/acpex` source, confirm `session/prompt` + `session/update` + terminal-turn surfacing are reachable. **Fallback:** if acpex 0.1 can't cleanly surface the terminal turn, swap to direct `Port` + `Jason` NDJSON. Wrapper API stays the same so nothing downstream moves. Budget +1 day if the fallback triggers.

### 4.6 Agent adapters (the multi-agent commitment)
- `@behaviour Tractor.Agent` with `command/1 :: {exe :: String.t(), args :: [String.t()], env :: [{String.t(), String.t()}]}`.
- Three implementations: `Tractor.Agent.Gemini` (default `gemini --acp`, override arg for `--acp-mode` / `--experimental-acp`), `Tractor.Agent.Claude` (default `npx acp-claude-code`, but **document that `Xuanwo/acp-claude-code` is archived** — configure a swap to `@zed-industries/claude-code-acp`), `Tractor.Agent.Codex` (default `codex-acp`).
- Runtime overrides via env: `TRACTOR_ACP_<PROVIDER>_COMMAND`, `TRACTOR_ACP_<PROVIDER>_ARGS`, `TRACTOR_ACP_<PROVIDER>_ENV_JSON`. Resolved command logged into the run manifest with env values redacted.
- Bridge install docs live in README; nothing auto-installs.

### 4.7 Supervision tree
```
Tractor.Application (:one_for_one)
├── Tractor.RunRegistry        # Registry, unique keys, run_id → runner pid
├── Tractor.AgentRegistry      # Registry, node_id → session pid (cheap, enables sprint-2 observe)
├── Tractor.HandlerTasks       # Task.Supervisor — handler isolation
├── Tractor.ACP.SessionSup     # DynamicSupervisor — one child per active session
└── Tractor.RunSup             # DynamicSupervisor — one Runner per active run
```
- Runner is `:transient` under RunSup. CLI starts one Runner, monitors it, blocks until exit, translates exit reason → exit code.
- Handlers run under `Task.Supervisor.async_nolink/3`. Crash → Runner gets `:DOWN` → fails the run cleanly (no retry this sprint).
- Session under `SessionSup`. `Port.close` + best-effort SIGTERM on `terminate/2`.
- **Why Runner as a GenServer (not a pure engine):** forward-compatible to sprint-2 crash-resume without rewriting the entry point. Gives us a `run_id → pid` handle and a place to hang `Process.flag(:trap_exit, true)`. Debatable for sprint 1 alone; deliberate choice for the road ahead.

### 4.8 Runner state machine
- State: `pipeline`, `current_node`, `completed`, `context :: %{node_id => outcome_string}`, `caller` (CLI pid awaiting result), `run_dir`.
- Loop: `:advance` → pick next via §4.4 → spawn handler task → await `:DOWN` → update context → write node artifacts atomically → `:advance`.
- Terminal node (`Msquare`) → write manifest-final, reply `{:ok, run_id}` to caller, stop `:normal`.
- Handler `{:error, reason}` → write failure status, reply `{:error, reason}`, stop `:normal` (failure is a value, not a crash).
- Handler crash → same path; treat as error.

### 4.9 Handler behaviour
```elixir
@callback run(node :: %Tractor.Node{}, context :: map(), run_dir :: Path.t()) ::
  {:ok, outcome :: String.t(), updates :: map()}
  | {:error, reason :: term()}
```
Three implementations: `Start` (no-op success), `Exit` (no-op success), `Codergen` (resolves adapter, interpolates `{{prev_node_id}}` placeholders in `prompt` attr via simple `String.replace`, opens Session under SessionSup, prompts, writes artifacts, stops session, returns outcome).

### 4.10 RunStore
- `$TRACTOR_DATA_DIR/runs/<UTC>-<short_id>/` (default `$XDG_DATA_HOME/tractor` or `~/.tractor`).
- `manifest.json` — pipeline path, goal, start/finish times, resolved provider commands (env redacted), tractor version, final status.
- Per node: `<node_id>/prompt.md`, `<node_id>/response.md`, `<node_id>/status.json`.
- **Atomic writes:** temp file **in the same destination directory** + `:file.sync/1` + `File.rename!/2`. Helper in `Tractor.Paths`. (No cross-FS renames.)
- Manifest shape is designed **after** the first fake-agent round-trip (Phase C) succeeds — avoids guessing at the data we haven't seen yet.

### 4.11 CLI
- `Tractor.CLI.main/1` entry for the escript. `OptionParser` (not Optimus — only one verb this sprint; defer Optimus to sprint 2 when `sow`/`ls`/`show` arrive).
- One verb: `reap PATH [--cwd PATH] [--runs-dir PATH] [--timeout DURATION]`.
- Progress → stderr (one line per phase and per node). Final run directory → stdout.
- **Exit codes (per Codex's taxonomy):**
  - `0` — success
  - `2` — CLI usage / config error
  - `3` — DOT file not found
  - `10` — parse or validation error
  - `20` — agent / protocol / handler runtime failure
  - `130` — SIGINT (best-effort; no graceful checkpoint this sprint)

## 5. Task list (sequenced)

### Phase A — Scaffold (day 1, ~3h)
- [x] Move `IDEA.md`, `LICENSE`, `docs/` aside; `mix new . --sup --app tractor --force`; restore files.
- [x] `.tool-versions` pinning Elixir 1.17.3 / OTP 27.
- [x] `.formatter.exs` defaults; `mix format --check-formatted` target.
- [x] `mix.exs` deps: `{:dotx, "~> 0.3"}`, `{:acpex, "~> 0.1"}`, `{:jason, "~> 1.4"}`, `{:mox, "~> 1.2", only: :test}`, `{:credo, "~> 1.7", only: [:dev, :test]}`.
- [x] `mix.exs` escript config: `escript: [main_module: Tractor.CLI]`.
- [x] Supervision skeleton: `Tractor.Application` with `RunRegistry`, `AgentRegistry`, `HandlerTasks`, `ACP.SessionSup`, `RunSup`. Empty children start fine.
- [x] `README.md` skeleton: intent, install, ACP bridge install notes for all three (including `Xuanwo/acp-claude-code` archived caveat).
- [x] GitHub Actions CI: `mix deps.get && mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict && mix test`. Integration tag excluded in CI.
- [x] First commit.

### Phase B — DOT parse + validate (day 1–2, ~5h)
- [x] `Tractor.Pipeline` / `Tractor.Node` / `Tractor.Edge` structs with typed fields.
- [x] `Tractor.Diagnostic` struct: `code`, `message`, `node_id?`, `edge?`, `path?`.
- [x] `Tractor.DotParser.parse_file/1` via Dotx → `{:ok, %Pipeline{}} | {:error, [%Diagnostic{}]}`. Shape → type mapping, `type=` override, duration coercion for `timeout`.
- [x] `Tractor.Validator.validate/1` — start/exit cardinality, acyclic (`:digraph_utils.is_acyclic/1`), edge endpoint existence, codergen `llm_provider` presence + allowed value, reject unsupported attrs/handlers/graph directives listed in §4.3.
- [x] Fixture set under `test/fixtures/dot/`: `valid_linear.dot`, `valid_three_agents.dot`, `cyclic.dot`, `no_start.dot`, `two_starts.dot`, `no_exit.dot`, `missing_provider.dot`, `unknown_provider.dot`, `rejected_handler.dot`, `edge_to_missing.dot`, `undirected.dot`.
- [x] One assertion per fixture failure mode; parser tests for chained edges, inherited defaults, type override, duration coercion.
- [x] Commit.

### Phase C — ACP wrapper + fake-agent round-trip (day 2–4, ~7h, riskiest)
- [x] **2h spike:** read `lostbean/acpex` source; confirm callback shape, Port framing, and reachability of `session/prompt` + `session/update` + terminal turn. Decide: stay on ACPex or fall back to raw Port. Document the call in `docs/sprints/notes/acp-spike.md`.
- [x] `test/support/fake_acp_agent.exs` — standalone escript/Elixir script that speaks NDJSON JSON-RPC over stdio, supports `initialize`, `session/new`, `session/prompt` → emits 2–3 `session/update` deltas + `stopReason: "end_turn"`; can also be scripted to return errors/timeouts via env var.
- [x] `Tractor.AgentClient` behaviour (`start_session/2`, `prompt/3`, `stop/1`). Mox-defined for engine tests.
- [x] `Tractor.ACP.Session` GenServer (production impl of AgentClient). `trap_exit`, explicit per-call timeout default 5 min, state machine, `terminate/2` cleanup, OS-pid best-effort SIGTERM.
- [x] `Tractor.Agent` behaviour + `Gemini` / `Claude` / `Codex` adapters with env-override resolution.
- [x] **Integration tests (real `Tractor.ACP.Session` ↔ fake agent):** handshake, prompt→final-text round-trip, streaming delta accumulation, `stopReason` terminal, timeout failure, agent crash failure, `{:error, :max_turn_requests}` mapping.
- [x] **Port-leak assertion:** `length(:erlang.ports())` before/after each session test; 50 concurrent echo sessions all resolve with zero port delta.
- [x] `@tag :integration` manual test: one real `gemini --acp` round-trip. Skipped in CI.
- [x] **Checkpoint:** do not start Phase D until a fake-agent prompt cycle runs green through the real `Tractor.ACP.Session`. (This is the best single idea that came out of the critiques.)
- [x] Commit.

### Phase D — RunStore (day 4, ~3h — after Phase C so manifest shape follows real data)
- [x] `Tractor.Paths` — resolve `$TRACTOR_DATA_DIR` / `$XDG_DATA_HOME` defaults; expose `run_dir/1`, `atomic_write!/2`.
- [x] `Tractor.RunStore` — `open/2`, `write_node/3`, `finalize/2`. Writes `manifest.json` + per-node `prompt.md` / `response.md` / `status.json`. Env values redacted in manifest.
- [x] Tests with `tmp_dir`: directory structure, atomic replacement under crash simulation, JSON shape, env redaction.
- [x] Commit.

### Phase E — Handlers + Runner + public API (day 4–5, ~4h)
- [x] `Tractor.Handler` behaviour; `Start`, `Exit`, `Codergen` impls.
- [x] `Tractor.Runner` GenServer: state in §4.8, `:advance` loop, `Task.Supervisor.async_nolink`, `:DOWN` handling, RunStore writes per node.
- [x] `Tractor.Run.start/1` public API: takes `%Pipeline{}` + options, returns `{:ok, run_id}`. `Tractor.Run.await/2` for the CLI to block.
- [x] Engine tests (Mox for `AgentClient`): 4-node pipeline `start → echo × 2 → exit` walks in order; final context contains both outputs. Handler-error propagation. Handler-crash propagation. **Three-provider ordering test:** DOT with `claude → codex → gemini` exercises the right Mox expectation per node.
- [x] **Validation-before-spawn test:** a DOT with a rejection causes exit `10` and starts zero agent subprocesses (asserted via Mox call count).
- [x] Commit.

### Phase F — CLI + example + acceptance (day 5–6, ~3h)
- [x] `Tractor.CLI.main/1` — `reap PATH` with `OptionParser`. Exit codes per §4.11. **Use `System.halt/1`, not `exit/1`** (escript footgun).
- [x] `examples/three_agents.dot`: `start → ask_claude → ask_codex → ask_gemini → exit`. Deterministic, harmless prompts (e.g., "write a one-line haiku about $PREV_OUTPUT"); carries context forward. **No repo edits, no tool calls.**
- [x] CLI tests: build escript, run against temp DOT files with fake agent binary on `$PATH`. Exit-code matrix for success / usage / missing file / validation / agent failure.
- [x] `docs/usage/reap.md`: install, build, run, provider env overrides, Gemini flag-drift guidance, Claude bridge-swap instructions.
- [x] **Manual acceptance run on user's laptop:** `./tractor reap examples/three_agents.dot` exits 0 with real Claude, Codex, Gemini. Inspect run dir — one populated `prompt.md` / `response.md` / `status.json` per agent node.
- [x] Verify no ACP provider process remains after exit (`pgrep gemini|claude|codex`).
- [x] Commit.

### Phase G — Merge gate (day 6–7, ~2h)
- [x] `mix format --check-formatted` clean.
- [x] `mix compile --warnings-as-errors` clean.
- [x] `mix credo --strict` clean (or documented skips).
- [x] `mix test` green. `mix test --include integration` green on laptop.
- [x] `mix escript.build` produces working `./tractor`.
- [x] Fake-agent CLI run exits 0; real multi-agent CLI run exits 0.
- [x] PR opened, reviewed, squash-merged to `main` with green CI.

## 6. Sequencing / dependencies
- A → B → C → D → E → F → G, linear.
- The only branch point is the Phase C spike outcome: ACPex-on-rails vs direct-Port fallback. Either way the `AgentClient` / `Session` API surface stays identical so B, D, E, F are unaffected.
- **Do not start Phase D until the fake-agent round-trip in Phase C runs green through the real `Tractor.ACP.Session`.** Designing RunStore shapes against imagined ACP data wastes Phase D.

## 7. Risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| ACPex 0.1 doesn't cleanly surface the terminal turn or session/prompt completion. | High | 2h Phase C spike. Fallback to direct `Port` + `Jason` NDJSON, same wrapper API. +1 day budget. |
| Per-bridge divergence in `session/update` / `stopReason` / tool-call shapes across Claude/Codex/Gemini. | Med | Fake-agent tests assert Tractor's ACP client handles documented shapes; laptop acceptance run catches per-bridge quirks. Per-adapter shims live in the adapter module, never in the wrapper. |
| `Xuanwo/acp-claude-code` archived upstream. | Known | Config override path for `@zed-industries/claude-code-acp` documented in README; env-var swap requires no code change. |
| Gemini CLI flag drift (`--acp` vs `--acp-mode` vs `--experimental-acp`). | Med | `TRACTOR_ACP_GEMINI_ARGS` override; default tracks current Gemini docs. Documented in `docs/usage/reap.md`. |
| Port leaks on Runner/Session crash → zombie agent processes. | Med | `trap_exit` + `Port.close` in `terminate/2`; best-effort SIGTERM to the OS pid from `Port.info/1`. Phase C port-leak assertion (50 concurrent echo sessions, zero delta). `:stderr_to_stdout` NOT set (would corrupt NDJSON framing). |
| `GenServer.call` 5s default timeout vs multi-minute LLM calls. | High if missed | Explicit per-call timeout on `prompt/3` (default 5 min); configurable per node via `timeout` attr. |
| `dot -Tjson` output-format drift (if fallback triggers). | Low (fallback only) | Dotx is the default; Graphviz shell-out stays a Phase B fallback only if Dotx proves inadequate. |
| Real agents require auth prompts mid-run. | Med | No preflight this sprint (explicit non-goal). Fail fast with the JSON-RPC error + provider name. Document manual `gemini auth login` / Claude auth setup in README. |
| Agent output is nondeterministic → flaky tests. | High if tested wrong | Tests assert protocol behavior, node order, artifact shape, exit codes — never model prose. |
| User is new to Elixir; OTP footguns. | Ongoing | §8 gotchas section. Runner/Session abstract Ports away from handlers. |
| Scope creep (condition edges, resume, UI). | Perpetual | §3 non-goals. Reject anything that touches them. |

## 8. Elixir-specific gotchas to pre-empt

- `Port` does **not** kill the OS process on BEAM death. Track the OS pid via `Port.info(port, :os_pid)` and best-effort `System.cmd("kill", ["-TERM", pid])` from `terminate/2`.
- **Never** set `:stderr_to_stdout` on the ACP Port — it mixes agent stderr into the NDJSON JSON-RPC stream and breaks framing. Keep stderr separate; route to `Logger.debug`.
- `GenServer.call` default is 5 seconds. LLM calls take minutes. Always pass an explicit timeout.
- Escript exit: `System.halt(code)`, not `exit(code)` — otherwise escript prints `** (exit) ...` and returns 0.
- `mix new . --sup` refuses a non-empty directory. Move `IDEA.md` / `LICENSE` / `docs/` aside first (or `--force` and diff).
- Never freeze runtime config in a module attribute: `@thing Application.get_env(...)` reads at compile time. Use `Application.get_env/2` at runtime.
- `Logger.warn/1` is deprecated in 1.17 — use `Logger.warning/1`.
- Charlists ≠ binaries. CLI args and file paths are binaries unless an Erlang API requires charlists.
- Atoms are not garbage-collected: do not convert untrusted DOT strings to atoms via `String.to_atom/1`. Use known-value maps or keep as binaries.
- `File.rename/2` across filesystems is not atomic. Put temp files in the destination directory.

## 9. Acceptance criteria (the merge gate)

- [x] `mix test` green; `mix test --include integration` green on laptop.
- [x] `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict` all clean.
- [x] `mix escript.build` produces a working `./tractor`.
- [x] Production `Tractor.ACP.Session` (not just Mox) is exercised against the fake ACP agent in tests covering: handshake, prompt success, streaming accumulation, timeout, agent crash, max_turn_requests.
- [x] Test suite proves all three providers appear in one DOT graph and are invoked in graph order.
- [x] Port-leak assertion passes (50 concurrent echo sessions, zero port delta).
- [x] `./tractor reap examples/three_agents.dot` exits 0 with fake agent binary on `$PATH`.
- [x] `./tractor reap examples/three_agents.dot` exits 0 on the user's laptop against real Claude, Codex, Gemini bridges.
- [x] The run directory contains `manifest.json` plus a populated `prompt.md` / `response.md` / `status.json` per agent node.
- [x] A validation failure exits `10` and zero agent subprocesses start.
- [x] An agent-runtime failure exits `20`, writes the failing node's `status.json`, cleans up the provider process (no zombies).
- [x] Branch merged to `main` with green CI.

## 10. Sprint-2 seeds (not sprint-1 work — do not expand)

- [x] `# TODO(sprint-2): checkpoint` comment at the top of `Runner.advance/1` where the per-node checkpoint write will land.
- [x] `Tractor.Paths` also exposes a reserved `checkpoint_path/1`, unused in sprint 1, so the sprint-2 resume work grep-finds one module.

## 11. Appendix — what was contested and how the merge resolved it

| Contested call | Decision | Reasoning |
|---|---|---|
| DOT parsing: `Dotx` vs shell `dot -Tjson` | **Dotx** (default); shell is fallback | No runtime Graphviz dep; chained edges + inherited attrs for free; keeps the tool a pure-Elixir escript. Claude conceded. |
| Node provider attr: `llm_provider` vs `agent=` vs `model=` | **`llm_provider`** | Matches Attractor spec. All three critiques converge. |
| Runner: GenServer vs pure engine | **GenServer** | Forward-compatible to sprint-2 crash-resume without rewriting the entry point. Claude's framing wins. |
| CLI parsing: `OptionParser` vs `Optimus` | **`OptionParser`** for sprint 1 | Only one verb; Optimus is sprint-2 work when `sow`/`ls`/`show` arrive. |
| Graph lib: `libgraph` vs stdlib `:digraph` | **`:digraph`** for sprint 1 | Linear happy path doesn't need libgraph; fewer deps for an Elixir newcomer. Revisit in sprint 2 if traversal logic grows. |
| Edge selection rule | **Weight desc, then lexical `to`** | Codex's rule. DOT edges can carry `weight`; "pure lexical" is underspecified once they appear. |
| Exit codes | **0 / 2 / 3 / 10 / 20 / 130** | Codex's split: user can distinguish "fix your DOT" from "look at agent logs." |
| RunStore placement | **Phase D, after ACP Phase C** | Design manifest shape against real ACP response data, not imagined data. Claude flagged this, Codex conceded via its own "first checkpoint" idea. |
| Commit cadence | **Per phase, not per task** | Codex's 8 phase-commits is ceremony. One commit per phase is enough; CI + tests enforce the rigor. |
