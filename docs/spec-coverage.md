# Tractor Spec Coverage

Manual audit of Tractor coverage against the upstream specs. Update this file in the same commits that land feature work; it is not generated.

Legend: `- [x]` shipped, `- [~]` partial / constrained / Tractor-only extension, `- [ ]` not implemented.

Specs:
- Attractor: https://raw.githubusercontent.com/strongdm/attractor/main/attractor-spec.md
- ACP: https://agentclientprotocol.com
- Unified LLM: https://raw.githubusercontent.com/strongdm/attractor/main/unified-llm-spec.md

## Handler types
- [x] `start` and `exit` DOT shapes normalize to runnable handler types. — `lib/tractor/dot_parser.ex`
- [x] `codergen` nodes run through provider adapters for Claude, Codex, and Gemini. — `lib/tractor/handler/codergen.ex`
- [x] `judge` nodes support `stub` and `llm` modes with verdict parsing. — `lib/tractor/handler/judge.ex`, `SPRINT-0005`, `SPRINT-0007`
- [x] `parallel` and `parallel.fan_in` blocks execute with branch aggregation. — `lib/tractor/runner.ex`, `lib/tractor/handler/fan_in.ex`, `SPRINT-0002`
- [x] `conditional` nodes route through the shared edge selector with a no-op handler. — `lib/tractor/handler/conditional.ex`, `lib/tractor/runner.ex`, `SPRINT-0008`
- [x] `tool` handlers execute literal argv commands with bounded capture and retry-aware failures. — `lib/tractor/handler/tool.ex`, `lib/tractor/runner.ex`, `SPRINT-0008`
- [x] `wait.human` handlers suspend the runner until an operator choice or timeout resolves a labeled edge. — `lib/tractor/handler/wait_human.ex`, `lib/tractor/runner.ex`, `SPRINT-0008`
- [ ] `stack.manager_loop` remains unsupported. — `lib/tractor/validator.ex`

## Graph attrs
- [x] `goal` is parsed and carried on the pipeline. — `lib/tractor/dot_parser.ex`
- [x] Retry defaults via graph attrs (`retries`, `retry_backoff`, `retry_base_ms`, `retry_cap_ms`, `retry_jitter`) flow into node retry config. — `lib/tractor/node.ex`, `SPRINT-0006`
- [x] `max_total_iterations` is enforced as a lifetime run budget. — `lib/tractor/runner.ex`, `lib/tractor/runner/budget.ex`, `SPRINT-0005`, `SPRINT-0007`
- [x] `max_wall_clock` is validated and enforced between nodes. — `lib/tractor/validator.ex`, `lib/tractor/runner/budget.ex`, `SPRINT-0006`
- [x] `max_total_cost_usd` is validated and enforced between nodes with checkpoint persistence. — `lib/tractor/validator.ex`, `lib/tractor/runner.ex`, `lib/tractor/runner/budget.ex`, `SPRINT-0007`
- [x] `status_agent` supports `claude`, `codex`, `gemini`, and `off`. — `lib/tractor/validator.ex`, `lib/tractor/status_agent.ex`, `SPRINT-0006`
- [ ] `model_stylesheet`, `default_fidelity`, and `default-fidelity` are unsupported. — `lib/tractor/validator.ex`
- [ ] Attractor alias attrs `max_retries`, `default_max_retries`, and `status_agent_prompt` are rejected. — `lib/tractor/validator.ex`, `SPRINT-0006`

## Node attrs
- [x] Core node attrs `prompt`, `llm_provider`, `llm_model`, and `timeout` are parsed and surfaced to handlers. — `lib/tractor/dot_parser.ex`, `lib/tractor/node.ex`
- [x] `max_iterations` is supported per node. — `lib/tractor/node.ex`, `lib/tractor/runner.ex`, `SPRINT-0005`
- [x] `retry_target` and `fallback_retry_target` are parsed, validated, and routed at runtime. — `lib/tractor/node.ex`, `lib/tractor/runner/routing.ex`, `lib/tractor/validator.ex`, `SPRINT-0007`
- [x] `goal_gate` and `allow_partial` are parsed as booleans and enforced centrally. — `lib/tractor/node.ex`, `lib/tractor/runner/adjudication.ex`, `lib/tractor/runner.ex`, `SPRINT-0007`
- [x] Tool attrs `command`, `cwd`, `env`, `stdin`, and `max_output_bytes` are parsed and surfaced through typed node accessors. — `lib/tractor/dot_parser.ex`, `lib/tractor/node.ex`, `SPRINT-0008`
- [x] Wait attrs `wait_timeout`, `default_edge`, and `wait_prompt` are parsed and surfaced through typed node accessors. — `lib/tractor/node.ex`, `SPRINT-0008`
- [x] Judge-specific attrs such as `judge_mode`, `reject_probability`, and critique keys are supported. — `lib/tractor/handler/judge.ex`
- [~] `join_policy` exists only for `parallel` nodes and is currently limited to `wait_all`. — `lib/tractor/node.ex`, `lib/tractor/validator.ex`

## Edge attrs
- [x] `label` is parsed and used for preferred-label routing. — `lib/tractor/dot_parser.ex`, `lib/tractor/edge_selector.ex`
- [x] `condition` is parsed and evaluated for conditional routing. — `lib/tractor/dot_parser.ex`, `lib/tractor/condition.ex`, `lib/tractor/edge_selector.ex`
- [x] `weight` is parsed and used as a deterministic tie-breaker among matching edges. — `lib/tractor/dot_parser.ex`, `lib/tractor/edge_selector.ex`
- [ ] `fidelity`, `thread_id`, and `loop_restart` remain unsupported edge attrs. — `lib/tractor/validator.ex`

## Edge priority
- [x] Matching conditional edges are chosen before label or fallback routing. — `lib/tractor/edge_selector.ex`, `SPRINT-0001`
- [x] Conditional and fallback ties prefer higher `weight`, then lexical `to` ordering for stability. — `lib/tractor/edge_selector.ex`
- [x] `preferred_label` is honored after conditional matches and before unconditional fallback. — `lib/tractor/edge_selector.ex`, `SPRINT-0001`
- [x] `suggested_next_ids` is honored before unconditional fallback when present in handler output. — `lib/tractor/edge_selector.ex`, `SPRINT-0001`
- [x] Unconditional fallback remains the last-resort route choice. — `lib/tractor/edge_selector.ex`

## Condition DSL
- [x] Equality and inequality comparisons (`=` / `!=`) remain supported for existing graphs. — `lib/tractor/condition.ex`, `SPRINT-0001`
- [x] Shorthand verdicts `accept`, `reject`, and `partial_success` are supported. — `lib/tractor/condition.ex`, `SPRINT-0005`, `SPRINT-0007`
- [~] Tractor extension: `||`, prefix `!`, `contains`, parenthesized grouping, and numeric `< <= > >=` on `context.*` keys. — `lib/tractor/condition.ex`, `lib/tractor/validator.ex`, `SPRINT-0007`
- [x] Missing context keys evaluate as empty-string / false instead of raising. — `lib/tractor/condition.ex`
- [x] Invalid syntax, unsupported numeric key comparisons, and trailing junk reject as `:invalid_condition`. — `lib/tractor/condition.ex`, `lib/tractor/validator.ex`
- [~] The richer operators above are not claimed as upstream Attractor coverage; they are Tractor-only extensions while upstream grammar lags. — `SPRINT-0007`

## Runtime semantics
- [x] Node retries use table-driven transient/permanent failure classification plus backoff/jitter. — `lib/tractor/runner.ex`, `lib/tractor/runner/failure.ex`, `SPRINT-0006`
- [x] Failure routing follows declaring-node ownership for `retry_target` and `fallback_retry_target`. — `lib/tractor/runner.ex`, `lib/tractor/runner/routing.ex`, `SPRINT-0007`
- [x] Goal gates terminate runs as `{:goal_gate_failed, node_id}` without invoking `exit`. — `lib/tractor/runner.ex`, `SPRINT-0007`
- [x] Partial-success continuation is centralized in `Runner.Adjudication`, with a `parallel.fan_in` carveout. — `lib/tractor/runner/adjudication.ex`, `SPRINT-0007`
- [x] Global budgets cover total iterations, wall clock, and total token cost. — `lib/tractor/runner/budget.ex`, `lib/tractor/runner.ex`, `SPRINT-0005`, `SPRINT-0006`, `SPRINT-0007`
- [x] `exit` does not finalize the run while any `wait.human` node is still pending. — `lib/tractor/runner.ex`, `SPRINT-0008`
- [x] Nested cycles and cycles that cross `parallel` / `parallel.fan_in` boundaries are rejected by validation. — `lib/tractor/validator.ex`, `SPRINT-0005`

## Checkpoint / resume
- [x] Runs persist JSON checkpoints with semantic-hash verification against the DOT graph. — `lib/tractor/checkpoint.ex`, `lib/tractor/run.ex`, `SPRINT-0005`
- [x] Resume rehydrates agenda, context, completed nodes, iteration counts, and provider command metadata. — `lib/tractor/checkpoint.ex`, `lib/tractor/runner.ex`
- [x] SPRINT-0007 persists `goal_gates_satisfied`, `total_iterations_started`, and `total_cost_usd`. — `lib/tractor/checkpoint.ex`, `lib/tractor/runner.ex`
- [x] Cost history resumes only from the current `run_dir` checkpoint state; there is no external spend ledger. — `lib/tractor/checkpoint.ex`, `SPRINT-0007`
- [ ] Automatic supervisor-driven runner restarts from checkpoint are not implemented. — `SPRINT-0007`

## Observer UI
- [x] Run detail pages render phases, timeline, node statuses, and status-agent output. — `lib/tractor_web/run_live/show.ex`, `lib/tractor_web/run_live/timeline.ex`, `lib/tractor_web/run_live/status_feed.ex`
- [x] Timeline rendering includes retry, timeout, and usage-event activity from run artifacts. — `lib/tractor_web/run_live/timeline.ex`, `SPRINT-0004`, `SPRINT-0006`
- [~] SPRINT-0007 adds new runtime states (`goal_gate_failed`, cost budget exhaustion), but the run-show audit is still being finished for dedicated pills / totals. — `SPRINT-0007`
- [ ] Observer write controls such as cancel, retry, or live budget overrides are not implemented. — `SPRINT-0007`

## ACP integration
- [x] ACP sessions are started per attempt with provider-specific adapters and streamed event sinks. — `lib/tractor/acp/session.ex`, `lib/tractor/handler/codergen.ex`, `lib/tractor/handler/judge.ex`
- [x] Claude, Codex, and Gemini bridges are first-class providers. — `lib/tractor/agent/claude.ex`, `lib/tractor/agent/codex.ex`, `lib/tractor/agent/gemini.ex`
- [x] Token-usage snapshots are captured from ACP turn data and runtime events. — `lib/tractor/acp/turn.ex`, `lib/tractor/handler/codergen.ex`, `lib/tractor/handler/judge.ex`, `SPRINT-0004`, `SPRINT-0007`
- [~] Retries intentionally create fresh ACP sessions; session reuse is not part of the runtime contract. — `lib/tractor/runner.ex`, `SPRINT-0006`, `SPRINT-0007`

## Coding-agent-loop features
- [x] Graph-authored codergen/judge loops support iterative refinement with deterministic edge routing. — `lib/tractor/runner.ex`, `lib/tractor/edge_selector.ex`, `SPRINT-0001`, `SPRINT-0005`
- [x] Parallel branch fan-out / fan-in is available for multi-agent style workflows. — `lib/tractor/runner.ex`, `lib/tractor/handler/fan_in.ex`, `SPRINT-0002`
- [x] Status-agent observations provide an out-of-band monitoring loop without mutating main node output. — `lib/tractor/status_agent.ex`, `SPRINT-0006`
- [~] Stub-judge deterministic seeding is a Tractor testing/runtime extension, not an upstream coding-agent-loop spec item. — `lib/tractor/handler/judge.ex`, `SPRINT-0005`
- [x] Human-in-the-loop waiting is available through `wait.human` nodes, checkpoint resume, and observer-side resolution controls. — `lib/tractor/handler/wait_human.ex`, `lib/tractor/runner.ex`, `lib/tractor_web/run_live/show.ex`, `SPRINT-0008`
- [x] Generic tool-call handlers execute locally without ACP sessions or token metering. — `lib/tractor/handler/tool.ex`, `lib/tractor/runner.ex`, `SPRINT-0008`

## Unified-LLM features
- [x] Provider/model metadata is preserved on codergen and judge LLM paths for pricing and observer artifacts. — `lib/tractor/handler/codergen.ex`, `lib/tractor/handler/judge.ex`, `SPRINT-0007`
- [x] Provider-reported token usage is accumulated with delta accounting against cumulative snapshots. — `lib/tractor/runner.ex`, `lib/tractor/cost.ex`, `SPRINT-0004`, `SPRINT-0007`
- [x] Static provider pricing lives in config and resolves through `Tractor.Cost`. — `config/config.exs`, `lib/tractor/cost.ex`
- [~] Tractor has unified-LLM-style cost tracking without a unified direct client; pricing depends on provider-reported usage. — `lib/tractor/runner.ex`, `SPRINT-0007`
- [ ] Fidelity modes, thread reuse, and a true unified-LLM client are not implemented. — `lib/tractor/validator.ex`, `SPRINT-0007`
