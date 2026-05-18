# Burrito for dev — parked decision

**Decision (2026-05-18 / SPRINT-0015):** continue running `bin/tractor` as
an escript in dev. Do NOT wrap with Burrito for local development.

## What prompted the question

Across SPRINT-0013 and SPRINT-0015 work we hit four classes of "dev-only"
leaks where the escript-wrapped CLI behaved differently from a true
release. Each is summarized below, with the in-place fix that landed.

| Leak | Symptom | In-place fix |
|---|---|---|
| `priv_dir` resolution | Static-asset paths broke when invoked from a working tree where `priv/` was outside the loaded archive. | Centralized via `Tractor.Paths.priv_dir/1`; tests assert the resolved path exists. |
| cwd-relative paths in test fixtures | Tests that invoked the escript from a tmp dir couldn't find shared `examples/*.dot`. | Tests now resolve paths via `Path.expand/2` from `__DIR__`, not from `File.cwd!/0`. |
| Dev-env config bleed | `config/dev.exs` settings (e.g. `:server` endpoint flag) leaked into escript subprocess sessions. | `Tractor.Application` gates endpoint and ResumeBoot children on `cli_boot?/0`, which detects escript and release binaries. |
| ACP-bridge resolution | The escript's `:code.which/1` returns a path inside the bundled archive, which `System.find_executable/1` couldn't follow when looking up provider commands. | Provider command resolution in `Tractor.ACP.Session` checks `Path.type/1` and falls back to PATH-based lookup. |

None of these were Burrito-specific; all four were fixable by tightening
path resolution and config gating inside the existing escript flow.

## What Burrito would have given us

Burrito ships a `mix release`-wrapped binary that bundles BEAM, the OTP
runtime, and the app archive into a single executable. Dev-environment
config bleed and `priv_dir` mis-resolution would have been impossible by
construction, because the runtime is sealed inside the binary.

## Why we're not adopting it for dev

Burrito wraps a `mix release`, and that release rebuild is the load-bearing
cost. Every dev iteration on Tractor — touch a file, run a test, run a
real pipeline — would need to either rebuild the release (10-30s) or
fall back to an unwrapped escript / `mix run`, in which case the wrapper
isn't doing anything. There's no in-between mode where Burrito catches
leaks without the rebuild cost.

The four leaks above were each diagnosable in minutes once a test
surfaced the symptom. Trading "minutes of leak debugging per quarter" for
"10-30s per dev iteration, dozens of times a day" is a bad bargain.

## When to revisit

Re-open this decision when *any* of:

1. A *third* class of leak surfaces that isn't fixable in-place — i.e. a
   genuine environment-isolation issue that the escript can't express.
2. We need to ship a single-file binary to non-developer machines that
   may not have Elixir installed. (Burrito is the right tool for that
   shipping case; it's the dev-loop case where it doesn't pay off.)
3. Dev-time release builds drop to single-digit seconds (e.g. via a
   future BEAM/OTP feature or aggressive build caching).

Until any of those holds, the recommended workflow is:

- `bin/tractor` for everyday CLI use (escript).
- `mix test` / `iex -S mix` for development.
- `mix release` only when packaging for distribution; treat that path
  as production-shaped and reserve Burrito-style sealing for that case.
