# SPRINT-0013 — RunWatcher zombie reconciliation + launcher parent-PID watchdog

Two distinct lifecycle leaks, both root-caused, both leak OS-level resources.

When a Runner BEAM dies abnormally, `manifest.json["status"]` stays `"running"` forever. `Tractor.RunWatcher.running_run?/1` (`lib/tractor/run_watcher.ex:141-151`) believes it, keeps the per-run `Tractor.RunWatcher.Tail` alive, which keeps a `FileSystem` watcher alive, which keeps a `mac_listener` OS process alive. We just cleaned up nine such zombies on this machine. Separately, `test/browser/launcher/launcher.exs` is a long-lived UDS-RPC test fixture that never exits when its parent test process is SIGKILLed — fourteen stale instances had accumulated over six days. This sprint lands a Runner-written PID file plus a watcher reconciliation pass for the first leak, and a parent-PID heartbeat plus inactivity timeout for the second.

## Goals

1. **Reconcile dead-owner `running` records** on RunWatcher startup and on every periodic rescan, flipping them to `"status": "error"` and tearing down the corresponding Tail.
2. **Self-terminate the test launcher** when its parent dies, with an inactivity timeout and stale-instance lockfile as belts and braces.
3. **Harden `Tail.terminate/2`** so an unrelated Tail crash cannot leak its FS watcher.

## Non-goals (do not touch in this sprint)

- FS-watcher supervision *shape* and Runner `:EXIT` observability — already on `chore/audit-fixes` (architecture audit High items #6 and #7).
- The `Template.render` crash at `lib/tractor/handler/codergen.ex:27` — separate bug.
- PR-body polish, demo GIFs.

---

## Mechanism: how RunWatcher detects "owner is dead"

**Decision: a Runner-written PID file at `.tractor/runs/<id>/_runner.pid`, JSON-formatted.**

Schema:

```json
{"os_pid": 12345, "node": "tractor@host", "started_at": "2026-04-28T16:33:09.401622Z"}
```

Liveness check: `System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)` — execs `kill` directly, no shell, no quoting hazard, and is cheaper than `:os.cmd/1`.

Why not `Process.alive?` + name registration: only valid same-BEAM. The headline failure is exactly the cross-BEAM case (a previous `mix phx.server` BEAM died, a fresh one came up, registry empty).

Why not stale-by-mtime: false positives on long-idle runs (e.g. operator-input wait writes nothing) and false negatives on runs mid-LLM call. PID-aliveness has neither.

Why JSON not bare integer: the `node` field lets a future watcher distinguish "different host sharing the runs dir" from "local-and-dead"; the `started_at` field is the future hook for PID-recycle hardening (compare against system uptime). Both are cheap insurance now and cost nothing later.

---

## Phases & sequencing

**The Producer must land before the Consumer.** Otherwise any in-flight run that started under the old code has no pidfile when the new reconciler boots, and "no pidfile = dead" reconciles it. We protect this with both the phase split below and a 30s `started_at`-based grace window in the reconciler.

### Phase 1 — Producer: Runner writes the PID file

- [x] Add `Tractor.RunStore.write_runner_pidfile/1` in `lib/tractor/run_store.ex` next to the existing `write_run_status/2` helper. Writes JSON `{"os_pid", "node", "started_at"}` atomically via `Tractor.Paths.atomic_write!/2` to `<run_dir>/_runner.pid`. Use `System.pid()` for the OS pid and `node()` for the BEAM identity.
- [x] Add `Tractor.RunStore.delete_runner_pidfile/1` (best-effort `File.rm/1`, ignores `:enoent`) in the same file.
- [x] Call `RunStore.write_runner_pidfile(store)` from `Tractor.Runner.init/1` (`lib/tractor/runner.ex`) immediately after the manifest is opened, before any LLM work begins.
- [x] Call `RunStore.delete_runner_pidfile(store)` from `Tractor.Runner.terminate/2` so cleanup is single-edit-point and runs on both normal and crash termination paths.
- [x] Resume path: `Tractor.RunStore.resume/1` (`lib/tractor/run_store.ex:46-63`) must call `write_runner_pidfile/1` after re-opening the manifest, so a freshly resumed run is not immediately reconciled away.
- [ ] Land Phase 1 as its own commit and let it bake before Phase 2 lands. Any in-flight runs at deploy time will be missing pidfiles; the Phase 2 grace window protects them.

### Phase 2 — Reconciler module

- [ ] New module `Tractor.RunWatcher.Reconcile` at `lib/tractor/run_watcher/reconcile.ex`.
- [ ] `reconcile_dead_runs(runs_dir)` — public entry point. Lists run dirs whose `manifest.json["status"] == "running"`, applies the dead-owner test below, returns `[{run_id, run_dir, reason}]` for those that should be reconciled. Skips any run whose status is already non-`running` (invariant guard required by the intent — assert and comment explicitly).
- [ ] `alive?(os_pid)` — calls `System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)` and returns `true` iff exit status is 0. Guard against non-integer pids.
- [ ] Grace window: if `_runner.pid` is missing AND `manifest["started_at"]` is within 30s of now, do NOT reconcile — assume the runner is mid-init. After 30s, treat as dead with `reason: "reconciled: pidfile missing"`.
- [ ] Cache alive-results for 5 seconds keyed by `os_pid` so a 1-Hz rescan over N running runs is N forks per 5s, not N forks per second.
- [ ] `mark_reconciled!(store, reason)` — calls `Tractor.RunStore.finalize/2` with `%{status: "error"}`, plus a `reason` field merged into the manifest. If `finalize/2` does not currently accept a free-form `reason`, extend its `attrs` whitelist to accept it and write it next to `finished_at`. Keep the change minimal — one new key.
- [ ] After flipping the manifest, emit `Tractor.RunEvents.emit(run_id, "_run", :run_reconciled, %{"reason" => reason, "owner_pid" => pid_or_nil})` so the reconciliation appears in `events.jsonl` for the Observer "ask the run" assistant to surface.

### Phase 3 — Wire reconciler into RunWatcher

- [ ] In `Tractor.RunWatcher.init/1` (`lib/tractor/run_watcher.ex:28-41`), call `Tractor.RunWatcher.Reconcile.reconcile_dead_runs(runs_dir)` *before* `discover_runs(state)`, so the very first scan only sees correct statuses.
- [ ] In `Tractor.RunWatcher.discover_runs/1` (`lib/tractor/run_watcher.ex:80-105`), call the same reconciler before the wildcard expansion. Cheap on the no-op path.
- [ ] Add `stop_tails_for(state, reconciled_run_ids)` and call it after each reconciliation pass. The existing `stop_tail/2` (`lib/tractor/run_watcher.ex:99-104`) only fires when the run dir disappears; here the dir still exists but the manifest has flipped, so we need an explicit sweep over `state.runs` keyed by the reconciled set.

### Phase 4 — Tail terminate hardening

- [ ] In `Tractor.RunWatcher.Tail.terminate/2` (`lib/tractor/run_watcher/tail.ex:86-89`), after `flush_offsets/1`, explicitly stop the FS watcher PID stored in `state.watcher`:
  ```elixir
  if is_pid(state.watcher) and Process.alive?(state.watcher) do
    try do
      GenServer.stop(state.watcher, :normal, 1_000)
    catch
      :exit, _ -> :ok
    end
  end
  ```
- [ ] Verify the `start_fs_watcher/1` return shape at `lib/tractor/run_watcher/tail.ex:376-393` already covers the `nil` case so the new stop call no-ops safely. (It does — `:ignore` and `{:error, _}` both return `nil` on lines 384/391.)

### Phase 5 — Launcher parent-PID watchdog + lockfile

All edits in `test/browser/launcher/launcher.exs`.

- [ ] New module `TestLauncher.ParentWatchdog` (GenServer):
  - Reads `TRACTOR_BROWSER_LAUNCHER_PARENT_PID` from env; falls back to `:os.getppid/0`.
  - `handle_info(:tick, state)` polls every 2 s with `System.cmd("kill", ["-0", parent_pid_str], stderr_to_stdout: true)`. On non-zero exit, logs a final line and calls `System.halt(0)`.
- [ ] Inactivity timeout: track `last_activity_ms` in `TestLauncher.Server` state. Update on every inbound `{:request, _}` and on `{:job_started, _, _, _}` / `{:job_finished, _, _, _, _, _}`. If 5 minutes elapse with no activity, the watchdog calls `System.halt(0)`. (Single timer in the watchdog reading `Server.last_activity_ms/0` is simpler than a timer per request.)
- [ ] Lockfile (in-scope, not bonus): `TestLauncher.CLI.main/1` writes its `System.pid()` to `Path.join(log_dir, "launcher.lock")` on startup. If the lockfile already exists and points to a live process (`kill -0`), abort with a clear message. If the lockfile is stale, clobber it. Delete the lockfile on graceful shutdown.
- [ ] Start `TestLauncher.ParentWatchdog` from `TestLauncher.CLI.main/1` (around `test/browser/launcher/launcher.exs:580-619`) right after `TestLauncher.Server.start_link/1` and before `Process.sleep(:infinity)`.
- [ ] Update the ExUnit harness env block in `test/browser/launcher/launcher_test.exs` (around line 124, function `launcher_env/2`) to export `TRACTOR_BROWSER_LAUNCHER_PARENT_PID` using `System.pid()`.
- [ ] Update `test/browser/run-all.sh` (function `tractor_launcher_start`, around lines 52-75 — env block at line 67) so the real shell harness exports `TRACTOR_BROWSER_LAUNCHER_PARENT_PID="$$"`. The subshell PID is the correct watchdog target because the subshell `exec`s the launcher as its child — when the subshell dies, the launcher's parent is gone. Add a one-line comment explaining the choice.

### Phase 6 — Tests

- [ ] `test/tractor/run_watcher/reconcile_test.exs` (new). Four cases over a tmp `runs_dir`:
  - **dead owner**: status=running, pidfile contains `999999`. Assert manifest flips to `error` with `reason: "reconciled: ..."` and `finished_at` set.
  - **alive owner**: pidfile contains `System.pid()`. Assert no change.
  - **non-running already**: status=`ok`, pidfile contains a dead pid. Assert untouched (the intent's required invariant).
  - **pidfile missing, post-grace**: no pidfile, status=running, `started_at` is 60s ago. Assert reconciled with `reason: "reconciled: pidfile missing"`.
  - **pidfile missing, in-grace**: no pidfile, status=running, `started_at` is 5s ago. Assert NOT reconciled (grace window).
- [ ] `test/tractor/run_watcher_integration_test.exs` (new). Boots a real `Tractor.RunWatcher` against a tmp dir. Plant a stale `running` run with a dead pidfile, also start a real `Tail` for it via `start_tail/3`. Wait one rescan tick. Assert: (1) manifest is now `error`, (2) the Tail PID is not alive, (3) the FS watcher PID owned by that Tail is not alive.
- [ ] `test/browser/launcher/parent_watchdog_test.exs` (new). Spawn the launcher as a child of a `bash -c 'sleep 3600 & echo $! ; wait'` wrapper with `TRACTOR_BROWSER_LAUNCHER_PARENT_PID=$$`, capture the launcher's OS pid via `op=status`, then `kill -9` the wrapper. Within 5 s, assert the launcher's OS pid is no longer alive (`kill -0` returns nonzero). Cap the test at 10 s wall.
- [ ] `test/browser/launcher/lockfile_test.exs` (new, small). Start a launcher; while it runs, attempt to start a second launcher with the same `TRACTOR_BROWSER_LOG_DIR`. Assert the second exits non-zero and the first is unaffected. Then halt the first cleanly and assert the lockfile is removed.

### Phase 7 — Migration & smoke

- [ ] **No data migration needed.** The 9 hand-reconciled records from this session's cleanup are already at `status: "error"` with `reason: "reconciled: BEAM died before run completed (zombie cleanup)"`. The Phase 2 reconciler's "skip non-running" invariant leaves them alone.
- [ ] Manual smoke: start `mix phx.server`, kick off any pipeline, `kill -9` the BEAM, restart `mix phx.server`. Within ~1 rescan tick, expect to see a `_run/run_reconciled` event in the killed run's `events.jsonl` and `manifest["status"] == "error"`.

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Reconciler ships before producer; pre-existing `running` runs have no pidfile and get killed. | Phase 1 lands separately and bakes; Phase 2's 30s `started_at` grace window covers any leftovers. |
| `kill -0` cost under load (one fork per running run per rescan). | 5s alive-cache in `Tractor.RunWatcher.Reconcile` (Phase 2). 50 runs × 1 Hz × `System.cmd` (no shell) is fine even uncached; cache is belt-and-braces. |
| PID recycle: OS reuses a dead PID for an unrelated process; `kill -0` succeeds. | `started_at` lives in the pidfile schema so a future sprint can compare to system uptime without a schema migration. Accept the risk this sprint. |
| Race between Runner.init opening the manifest and writing the pidfile. | Pidfile is written immediately after manifest open; window is microseconds. The 30s grace window swallows any race anyway. |
| Watchdog kills the launcher under CI scheduling pressure. | `kill -0` is a syscall — an unscheduled-but-live parent still answers. The 5min inactivity floor is well above any single test step. |
| `TRACTOR_BROWSER_LAUNCHER_PARENT_PID="$$"` in `run-all.sh` captures the subshell, not the outer harness. | Correct by design: the subshell `exec`s the launcher as its child, so subshell exit ⇒ launcher's parent is gone ⇒ launcher halts. Documented inline in `run-all.sh`. |
| Tail-terminate hardening triggers double-stop on a watcher already exiting. | `Process.alive?` precheck + `try/catch :exit` around `GenServer.stop/3`. |
| `RunStore.finalize/2` does not currently accept a `reason` field; extending its whitelist could ripple. | One-key whitelist extension is local; existing call sites are unaffected because they don't pass `:reason`. |

---

## Acceptance criteria

- [ ] Every code change above lands at the cited file (or closest equivalent if surrounding code shifted) with the cited identifiers.
- [ ] `mix test test/tractor/run_watcher/reconcile_test.exs` passes; covers all five cases in Phase 6 (dead / alive / non-running / pidfile-missing-post-grace / pidfile-missing-in-grace).
- [ ] `mix test test/tractor/run_watcher_integration_test.exs` passes and proves the Tail and its FS watcher are torn down after reconciliation.
- [ ] `mix test test/browser/launcher/parent_watchdog_test.exs` passes and proves the launcher halts within 5 s of its parent's death.
- [ ] `mix test test/browser/launcher/lockfile_test.exs` passes and proves a second launcher cannot start while the first holds the lock.
- [ ] Manual smoke (Phase 7) shows a `_run/run_reconciled` event in the killed run's `events.jsonl` after `mix phx.server` restart.
- [ ] Records whose `manifest["status"]` is already non-`running` are not touched by the reconciler (test invariant + explicit guard in Phase 2).
- [ ] After this sprint, `ps -ax | grep mac_listener` shows zero orphans after a Ctrl-C of `mix phx.server` followed by a restart.
- [ ] `ps -ax | grep launcher.exs` shows zero orphans after the parent test harness is SIGKILLed.
