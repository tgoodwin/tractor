# SPRINT-0012 — `tractor validate` CLI + Moab-spec rule parity

## Intent

Ship `tractor validate PATH` as a first-class CLI subcommand that runs tractor's existing validator plus new rules adapted from the Moab validate spec at `/Users/tgoodwin/projects/tractor/validation-spec.md`. Validation stays on the lowered `Tractor.Pipeline` struct — no new AST layer. One shared validation path owns parse → lower → validate; both `tractor validate` and `tractor reap` route through it and emit diagnostics through a single shared formatter. Exit codes preserve tractor's convention: 10 on any error-severity diagnostic, 0 otherwise, and reap keeps 20 for runtime failure. The work is mostly additive inside `lib/tractor/validator.ex` plus one focused refactor: extract the shared path and move formatting out of `Tractor.CLI`.

## Goals

- `tractor validate PATH` runs the shared validation path and prints diagnostics in a Moab-shaped format.
- `tractor reap PATH` routes validation through the same path and uses the same formatter — unified output.
- Close the gap vs. `lib/tractor/validator.ex` today by adding the Moab warnings that make sense for tractor.
- Land one `validate-prompt` reference doc adapted to tractor's real providers and handler types.
- Add a `fix` field to `Tractor.Diagnostic` so new rules can carry remediation hints (Moab-style).
- Keep existing validator behavior intact: callers of `Validator.validate/1` and `Validator.warnings/1` keep working as compatibility wrappers over the unified path.

## Non-goals

- NO AST layer changes to `Tractor.DotParser`.
- NO `agent_stylesheet` feature.
- NO `$config.NAME` substitution feature.
- NO `class` attribute or stylesheet selectors.
- NO model allowlist (`known_models`) — tractor's provider set is `claude`/`codex`/`gemini` and doesn't maintain a model list.
- NO exit-code changes beyond preserving tractor's existing convention.
- NO multi-file skill framework for `validate-prompt` — one doc.
- NO reclassification of currently-supported attrs (e.g. `status_agent` is a live feature, not deprecated) as warnings.

## Task list

### Phase A — Shared validation path and formatter

- [x] Add `Tractor.Diagnostic.fix :: String.t() | nil` field to the struct and update `@type t` accordingly.
- [x] Add a shared path-owning entrypoint in `lib/tractor/validator.ex` (e.g. `validate_path/1`) that accepts a DOT file path, calls `Tractor.DotParser.parse_file/1`, runs validation, and returns `{:ok, pipeline, diagnostics}` or `{:error, diagnostics}` with parse errors surfaced as diagnostics (not raw tuples).
- [x] Add a single full-diagnostics function for lowered `Pipeline` structs (e.g. `diagnostics/1`) that runs both error rules and warning rules in one pass, in deterministic order.
- [x] Reshape `Validator.validate/1` and `Validator.warnings/1` into thin compatibility wrappers over `diagnostics/1` so existing callers (`Tractor.CLI.run(["reap" | _])`, `Tractor.CLI.run(["validate", _])`) keep their current signatures during migration.
- [x] Extract the current `Tractor.CLI.format_diagnostics/1` private logic into a shared module — `Tractor.Diagnostic.Formatter` is a reasonable home. Must render `SEVERITY [code] (node: X)` / `(edge: A -> B)` context and a trailing `Fix: …` line when the diagnostic has a `fix`.
- [x] Make diagnostic ordering stable: sort by `(severity, code, node_id || edge_from, node_id || edge_to)` so CLI tests do not flap as the rule set grows.
- [x] Update `Tractor.CLI.@usage` so `tractor validate PATH` appears alongside the `reap` forms.

### Phase B — CLI routing and exit-code unification

- [x] Replace the current `run(["validate", path_input])` branch in `lib/tractor/cli.ex` with a single call to `Validator.validate_path/1` + `Diagnostic.Formatter.format/1`.
- [x] Route `run(["reap" | args])` through the same `validate_path/1` after parse/lower and before `run_once` / `serve_reap`, and print any diagnostics (errors and warnings) through the shared formatter.
- [x] Preserve current reap behavior: warning-only output does not block execution; error-severity blocks with exit 10.
- [x] Preserve current reap exit codes: 0 on success, 10 on validation error, 20 on runtime failure — confirm with a regression test that runtime failure still exits 20 even in the presence of warnings.
- [x] `tractor validate` exits 10 on any error-severity diagnostic, 0 otherwise (including warning-only).
- [x] `tractor validate` prints `No issues found.` on a clean graph so users can distinguish success from a silent error; warning-only and error cases end with a summary line `N diagnostic(s): E error(s), W warning(s)` (Moab spec §1).
- [x] stdout/stderr discipline: `tractor validate` writes diagnostics to stdout (linter convention); `tractor reap` writes validation diagnostics to stderr so they do not pollute any future captured stdout. Decide once, assert in CLI tests.

### Phase C — Shared semantic helpers (prerequisites for new rules)

- [x] Extract the shape-to-type mapping currently in `Tractor.DotParser` (`@shape_types`) into `Tractor.Node.implied_type_from_shape/1` or equivalent, and have `DotParser.normalize_node/1` use it. This is the single source of truth for `type_shape_mismatch`.
- [x] Define `Tractor.Validator`-internal helper predicates for the node families new rules depend on:
  - [x] `agent_capable?/1` — covers `codergen` and `judge` (both invoke an LLM). Excludes `parallel.fan_in` for this sprint: whether it invokes an LLM depends on runtime configuration, which is not statically determinable from node type. A comment should record the decision and the reason.
  - [x] `instant_only?/1` — covers `start`, `exit`, `conditional`, `parallel` (pure fan-out router).
  - [x] `tool?/1`, `wait_human?/1` — thin wrappers for consistency.
- [x] Where the Moab rule name says "agent" but tractor's runtime type differs, add an inline comment mapping the intent.

### Phase D — New warning rules in `lib/tractor/validator.ex`

All new rules go through the unified diagnostics pipeline in Phase A. Every rule authors a `fix` hint where Moab's spec provides one, adapted to tractor vocabulary. **Every rule specifies its exact message string in the code it adds** — message text is part of the test assertion surface, so leaving it unspecified causes later drift between rule and test. Use Moab's message text (adapted to tractor vocabulary) as the starting point and diverge only with reason.

- [x] **Precondition for `type_shape_mismatch`:** verify `shape` survives lowering in `attrs["shape"]`. `DotParser.normalize_node/1` currently uses shape to resolve `node.type` — if the raw shape attr is dropped from `attrs` after resolution, this rule is detectable only by passing both raw-AST and lowered pipeline to the validator (which the sprint rules out). If shape does not survive, drop the rule from scope and note it in the PR description.
- [x] `type_shape_mismatch` — node with both `attrs["type"]` and `attrs["shape"]` where explicit type disagrees with `Node.implied_type_from_shape/1`. Only if the precondition holds.
- [x] `tool_command_on_non_tool` — `command` attr present on any non-`tool` node.
- [x] `prompt_on_tool_node` — `tool` node with `prompt` attr set.
- [x] `goal_gate_on_non_agent` — `goal_gate=true` on a node where `agent_capable?/1` is false.
- [x] `agent_on_non_agent` — `llm_provider` or `llm_model` attached to a node outside `agent_capable?/1` (covers `start`, `exit`, `conditional`, `parallel`, and likely `tool`, `wait.human`, `fan_in` depending on Phase C decisions).
- [x] `timeout_on_instant_node` — `timeout` set where `instant_only?/1` is true.
- [x] `allow_partial_without_retries` — uses `Tractor.Node.retry_config(node, pipeline.graph_attrs)["retries"]` (verified to exist at `lib/tractor/node.ex:152`) to get *effective* retries. The attr key is `"retries"` (not Moab's `max_retries`) — confirmed in `validator.ex:668`. Warn if effective retries is 0.
- [x] `retry_target_exists` — `retry_target` or `fallback_retry_target` references a non-existent node. **Split the current `validate_retry_target_attr/7`**: missing-target becomes this warning; self-target, terminal-target, and parallel-block-target remain hard errors. Do not downgrade the illegal cases.
- [x] `two_way_edge` — A→B and B→A both exist. Deduplicate by sorted `(from, to)` pair so each pair is reported once.
- [x] `human_gate_warning` — every `wait.human` node (principle warning: pipelines should run autonomously).
- [x] `tool_node_warning` — every `tool` node (principle warning: prefer agent nodes that can diagnose and fix errors).
- [x] Deprecation audit — walk `@unsupported_graph_attrs` (`model_stylesheet`, `default-fidelity`, `default_fidelity`) and `@unsupported_attr_aliases` (`max_retries`, `default_max_retries`, `status_agent_prompt`) in `lib/tractor/validator.ex`. For each, decide: "deprecated" (warning with migration `fix` hint) vs "unsupported" (hard error, unchanged). The aliases in particular look like renames (tractor now uses `retries`/`default_retries`) and are strong candidates for deprecation. Document each decision in the PR description. **Do not reclassify `status_agent` or any other currently-live graph attribute.**

### Phase E — Tests

- [x] Per-rule unit coverage in `test/tractor/validator_test.exs` for every new rule in Phase D. Each test asserts code, severity, and key message content (`contains/2`-style).
- [x] Regression test for the retry-target split: missing target warns, self-target still errors, terminal-target still errors, parallel-block-target still errors. Same graph structure, four diagnostics, correct severities.
- [x] Regression test that `Validator.validate/1` and `Validator.warnings/1` wrappers return the same results they did before the refactor for a representative set of graphs drawn from `examples/*.dot`.
- [x] `test/tractor/cli_test.exs`: `tractor validate PATH` — success case (exit 0, no diagnostics printed), warning-only case (exit 0, warnings on stdout), error case (exit 10).
- [x] `test/tractor/cli_test.exs`: `tractor reap PATH` — validation error case (exit 10, formatted through the shared formatter, run does not start), runtime failure case (exit 20 even with warnings present).
- [x] `test/tractor/cli_test.exs`: **same-output assertion** — `tractor validate` and `tractor reap` render byte-identical diagnostic text for the same invalid graph.
- [x] CI: update `.github/workflows/*.yml` (or the mix alias the CI runs) to execute `tractor validate` against every `examples/*.dot`. Zero error-severity diagnostics across the examples set is the gate. Warnings are reported, not blocking.

### Phase F — `validate-prompt` reference doc

- [x] Create `docs/usage/validate-prompt.md`, adapted from Moab spec §8 but rewritten for tractor.
- [x] Scope the doc to tractor's real providers: `claude`, `codex`, `gemini`. No `claude-code`/`gemini-cli` aliases; no model allowlists.
- [x] Scope the doc to tractor's real handler types: `start`, `exit`, `codergen`, `tool`, `wait.human`, `conditional`, `judge`, `parallel`, `parallel.fan_in`.
- [x] Remove every Moab-only reference that would mislead an author: `agent_stylesheet`, `class`, `$config.*`, `status_agent_stylesheet`, `companion_agent_stylesheet`, model allowlist, `fidelity` discussion if tractor doesn't use it.
- [x] Include the principles that motivated the new warnings in Phase D: avoid human gates in production, prefer agents over direct tool nodes, avoid two-way review loops, don't let a node validate its own work.
- [x] Write the doc **after** Phase D so it reflects what tractor actually enforces, not Moab aspirations.

## Sequencing

Critical path: **A → B → C → D**. E runs alongside D (tests land with each rule). F is last so the doc reflects shipped behavior.

1. **Phase A** — Extract the shared validation path and formatter first. This is the architectural move; everything else is additive on top.
2. **Phase B** — Wire both CLI commands to the shared path. Existing behavior preserved; prepares the ground for new rules to flow through both commands for free.
3. **Phase C** — Shared semantic helpers (shape-to-type, node families). Must land before Phase D rules that depend on these decisions.
4. **Phase D** — New warning rules. Author fix hints as each rule lands.
5. **Phase E** — Tests track Phase D rule-by-rule. CLI tests + CI integration land after B+D are in.
6. **Phase F** — Documentation at the end.

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Retry-target split accidentally downgrades illegal targets (self / terminal / parallel-block) from error to warning | High | Split `validate_retry_target_attr/7` surgically: missing → warning is a new branch; existing branches for illegal targets remain errors. Phase E regression test asserts all four severities on one graph. |
| Tractor's "agent" mapping is ambiguous across `codergen` / `judge` / `parallel.fan_in` | High | Phase C defines `agent_capable?/1` *before* any rule uses it, with a code comment documenting the decision. Rules consume the predicate, not open-coded type lists. |
| Formatter drift between `validate` and `reap` | High | Phase A extracts formatting to `Tractor.Diagnostic.Formatter`; Phase E same-output CLI test locks the invariant. |
| Deprecation audit accidentally reclassifies a live attr (`status_agent` is the obvious trap) | Med | Explicit audit task in Phase D walks `@unsupported_graph_attrs` and `@unsupported_attr_aliases` and requires a documented decision per attr in the PR description. |
| `Validator.warnings/1` behavior changes for existing callers | Med | Keep it as a thin wrapper returning warning-severity diagnostics from `diagnostics/1`; Phase E has a regression test over `examples/*.dot`. |
| Reap runtime failure path regresses to exit 10 when warnings are present | Med | Phase B explicit test: graph with warnings + runtime failure exits 20, not 10. |
| `fix` field churns every rule-emission call site | Low | `fix:` is optional (`nil` default) via struct default; new rules add hints, existing rules untouched unless they already had a natural fix to surface. |
| `fix` field is scope creep without a testable contract | Med | Keep `fix` strictly informational for this sprint (no IDE integration, no auto-apply). Acceptance criterion requires only that new Phase D warnings with a Moab-provided fix hint set the field — not that every existing rule backfills. |
| `type_shape_mismatch` turns out to be undetectable (shape attr dropped during lowering) | Med | Phase D precondition task verifies this up front; if shape does not survive, the rule is dropped from scope and the PR explains why. Alternative is a DotParser change, which is a non-goal. |
| Shape-to-type extraction breaks `DotParser.normalize_node/1` | Low | Pure refactor; existing parser tests cover the surface. Extract first, consume from validator second. |
| Adding warnings flaps CLI tests because ordering is implicit | Med | Phase A mandates deterministic ordering; all new rules exercise that ordering in their tests. |

## Acceptance criteria

- [x] `tractor validate PATH` runs through the shared validation path, prints diagnostics in the unified format, and exits 10 on error / 0 otherwise.
- [x] `tractor reap PATH` routes validation through the same path and formatter; exit codes preserved (0 success, 10 validation error, 20 runtime failure).
- [x] Warning-only output does not block `tractor reap` execution.
- [x] `tractor validate` and `tractor reap` render byte-identical diagnostic body text for the same invalid graph (asserted in CLI tests). Allowed variance is stream (stdout for validate, stderr for reap) and summary-line presence.
- [x] `tractor validate` on a clean graph prints `No issues found.` and exits 0.
- [x] `Tractor.Diagnostic` has a `fix` field; every new warning in Phase D authors a fix hint where appropriate.
- [x] All rules in Phase D land with matching unit tests in `test/tractor/validator_test.exs`.
- [x] The retry-target split is covered by a regression test that proves missing-target warns while self/terminal/parallel-block targets still error.
- [x] `Validator.validate/1` and `Validator.warnings/1` remain available as compatibility wrappers with unchanged external behavior.
- [x] CI runs `tractor validate` over every `examples/*.dot`; zero error-severity diagnostics.
- [x] `docs/usage/validate-prompt.md` exists and references only tractor-supported providers (`claude`, `codex`, `gemini`) and handler types — no Moab-only features (`agent_stylesheet`, `$config.*`, `class`, model allowlist).
- [x] No AST layer added; `DotParser` changes limited to the shape-to-type helper extraction.
- [x] No currently-supported graph attribute (e.g. `status_agent`) is reclassified as deprecated.
