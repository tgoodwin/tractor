# Testing

## Browser Harness

Run the browser suites with:

```bash
bash test/browser/run-all.sh
```

The harness starts one Phoenix observer and one resident launcher for the whole run. Browser-triggered `tractor_reap` calls route through the launcher by default, but the observer still never executes pipelines in-process.

Use the repeat gate with:

```bash
bash test/browser/run-all-repeat.sh
```

That script runs five full passes and forces iteration 3 onto the subprocess path with `TRACTOR_BROWSER_NO_LAUNCHER=1`.

## Browser Harness Env Vars

- `TRACTOR_BROWSER_NO_LAUNCHER=1`: disable the launcher and force `bin/tractor reap`.
- `TRACTOR_BROWSER_SKIP_LOAD_GUARD=1`: skip ambient-load checks entirely.
- `TRACTOR_BROWSER_FORCE=1`: keep the load guard warnings but bypass aborts.
- `TRACTOR_BROWSER_LOAD_WARN=<n>`: warning threshold, default `6`.
- `TRACTOR_BROWSER_LOAD_ABORT=<n>`: abort threshold, default `10`.
- `TRACTOR_BROWSER_PORT=<port>`: observer port for the harness.
- `TRACTOR_BROWSER_LAUNCHER_SOCK=<path>`: override launcher socket location.

## Load Guard

`run-all.sh` checks ambient load before starting Phoenix or the launcher. Each suite re-checks with thresholds bumped by `+2` and aborts with exit code `77` if load has climbed far enough that the run is likely to flake.

Known CPU hogs are called out in guard output when present: Backblaze, Time Machine / `backupd`, `mds_stores`, `mdworker`, Xcode, and Simulator processes.

For CI or other environments where load averages are not meaningful, prefer `TRACTOR_BROWSER_SKIP_LOAD_GUARD=1`. For a one-off local override that still preserves warnings, use `TRACTOR_BROWSER_FORCE=1`.
