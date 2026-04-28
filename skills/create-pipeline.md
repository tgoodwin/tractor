---
name: create-pipeline
description: Use when authoring a new Tractor DOT pipeline graph from scratch. Collaboratively discovers features, explores topology trade-offs, and produces a validated .dot file.
---

# Create Pipeline

## Scope

This skill creates new Tractor pipelines from scratch through collaborative feature discovery.

**In scope:** understanding the goal, discovering features, proposing topologies, composing the .dot file, reviewing, and validating.

**Out of scope:** improving existing pipelines (use `edit-pipeline` if/when it exists), Tractor runtime internals.

## Context

Before doing any work, read these reference documents:

- `docs/usage/pipeline-reference.md` — DOT subset, attribute tables, condition syntax, template variables, run directory layout
- `docs/usage/validate-prompt.md` — design principles, prompt design rules, common failure modes, review checklist
- `docs/usage/loop-patterns.md` — canonical Implement/Test and Audit/Fix loop topologies with worked examples and prompt templates

<HARD-GATE>
Do NOT write ANY .dot file or pipeline code until you have completed feature discovery with the human partner and they have approved the goal, feature list, and topology. This applies to every pipeline regardless of perceived simplicity.
</HARD-GATE>

<HARD-GATE>
ONE STEP AT A TIME. Complete each phase fully, present your output, and wait for the human partner to confirm before proceeding to the next phase. Do not bundle multiple phases into one response. If the human gives feedback on the current phase, iterate on it until they're satisfied — do not advance.
</HARD-GATE>

## Checklist

<CRITICAL>
BEFORE doing ANY work, track ALL 9 tasks below — one task per item. Create the full list up front, then work through it in order. Do NOT create tasks one at a time as you go. Use your agent's task-tracking facility (TaskCreate in Claude Code) if it has one; otherwise keep a written checklist.
</CRITICAL>

1. **Explore project context** — read relevant files, docs, specs, recent commits
2. **Understand the goal** — ask clarifying questions one at a time
3. **Discover features** — proactively suggest capabilities; present as multiple-choice
4. **Propose topology** — present 2-3 options with trade-offs and your recommendation
5. **Present feature list** — organized by phase; get human partner approval
6. **Compose the .dot file** — using canonical topologies from `docs/usage/loop-patterns.md`
7. **Review pipeline logic** — using the review checklist from `docs/usage/validate-prompt.md`
8. **Fix review findings** — fix all issues; skip if none found
9. **Validate structure** — run `./bin/tractor validate <file>` and fix all errors and warnings

## Process Flow

```
explore → goal → discover features → propose topology → present feature list
                       ↑                  ↑                  ↑
                       └──────────────────┴──────────────────┘
                              (loop until human approves)
                                              │
                       compose .dot ←─────────┘
                              │
                       review logic ──fail──► fix findings ──┐
                              │                              │
                              └──────────────────────────────┘
                              │
                       tractor validate ──fail──► fix findings ──┐
                              │                                   │
                              └───────────────────────────────────┘
                              │
                              ▼
                            done
```

## Phase 1: Explore Project Context

Read existing specs, docs, and recent commits before asking the human partner anything. Don't ask what you can learn from the repo.

For Tractor pipelines specifically, also check:

- Are there existing `.dot` files in the repo (e.g. under `examples/` or a project-local `pipelines/` folder)? Read 1-2 to understand established conventions.
- Does the project have a CLAUDE.md or similar that describes domain context?

## Phase 2: Understand the Goal

Ask questions **one at a time**. Prefer multiple-choice when possible:

- What is the human partner building? What does "done" look like?
- What constraints exist (out-of-scope items, performance bars, compatibility requirements)?
- Is there a reference implementation, spec, or external standard?
- What's the input and output? What signals "the pipeline succeeded"?

If the request describes something very large (multiple independent subsystems), flag this immediately and help decompose into sub-pipelines.

**Identify reference materials** — specs, design docs, reference implementations that agents will need to read in their prompts. If none exist and the work is substantial, recommend a spec-expansion phase (see `docs/usage/validate-prompt.md` "Spec Expansion").

The output of this phase is a draft `goal` graph attribute. It should fit on one or two lines:

```
Make mosort pass all GCSORT test cases except the three Not Supported features.
EXCLUDED: NS-1 (IX/ISAM), NS-2 (SQMF), NS-3 (E15/E35 exits).
```

## Phase 3: Discover Features

Your job is to be the human partner's **pipeline design partner** — helping them think through capabilities they may not have considered.

**One topic per message.** Explore one category, get feedback, move on. Probe in this order:

**Phase boundaries.** What are the natural phases of this work? What depends on what? Pipelines that try to do everything in one phase are hard to debug; pipelines split into 3-5 phases (setup → core implementation → validation, say) are easier to reason about and easier to retry from a partial state.

**Verification strategy.** Every implementation feature gets an Implement/Test loop by default (implementor → reviewer → diamond gate, looping back to implementor on reject). For critical phases, ask:
> "Would you like a parallel audit for this phase? Three independent reviewers with a unanimity rule — stronger than a single reviewer but costs roughly 3× more tokens. See `docs/usage/loop-patterns.md` Pattern 2."

**Completion criteria.** For each feature, what does "100% done" look like? Each requirement must be something a reviewer or auditor can verify concretely. "Handle edge cases" is not a requirement; "Return error on empty input, nested quotes, and UTF-8 multibyte characters" is.

**Reference materials.** Is there a spec, reference implementation, or standard the agents need to read? If not and the project is substantial, suggest a spec-expansion node as the very first stage. Without a spec, reviewers have nothing concrete to verify against and feedback loops drift.

**Setup needs.** Does the project need a tool node for environment setup (build a Docker image, generate fixtures, prepare a reference dataset) before agent work begins? Or can each codergen node handle its own setup?

**Agent strategy.** Tractor supports `claude`, `codex`, and `gemini` providers. Different phases or different parallel reviewers can use different providers for diversity. Ask:
> "Should reviewers use a different provider from the implementor? Different providers catch different kinds of bugs — claude+codex+gemini auditors gives the strongest coverage."

**Feature granularity.** If a feature has more than ~7 requirements, split it into sub-features with their own loops. Big features make ambiguous reviewer reports and loops that don't converge.

**Iteration budgets.** `max_iterations` defaults to 3 — too low for real loops. Ask:
> "How many iterations should each loop allow before giving up? For implementation loops, 10-20 is typical. Setting it too low causes premature failure; setting it too high masks runaway loops."

**Status agent.** Tractor's optional status agent gives a running narrative of progress. Ask:
> "Would you like the status agent enabled? It's a separate LLM that summarizes node outputs as the pipeline runs and surfaces them in the observer. Configured via `graph [status_agent=claude]`."

**Retrospective node.** Optional final codergen node that reads `events.jsonl` and produces a post-run report. Ask:
> "Would you like a retrospective report after each run? A final codergen node reads the event log and produces RETROSPECTIVE.md — covering what went well, what failed, and recommendations for improving the pipeline."

**Pipelines are fully autonomous by default.** Do not add `wait.human` gates unless the human partner explicitly asks for one (debugging during development, or genuine operator-in-the-loop external actions).

## Phase 4: Propose Topology

Present 2-3 pipeline structures:

- **Option A — Simplest.** Linear with Implement/Test loops per feature. Cheapest, most likely to converge. Use when verification is straightforward and you trust a single reviewer.
- **Option B — Robust.** Implement/Test loops per feature plus an Audit/Fix loop at the end of each phase. More tokens, much stronger guarantee. Use when integration risk between features is real or when getting the phase wrong is expensive.
- **Option C — Multi-phase + parallel audits with diverse providers.** Use when the project is large and spec-compliance matters more than cost.

For each option, explain what it covers, rough relative token cost (1×, 2-3×, 4-5×), where it might fail, and your recommendation.

## Phase 5: Present and Approve

Present the final feature list organized by pipeline phase. **This is the last checkpoint before composing.**

```
Goal: [the goal text approved in Phase 2]
EXCLUDED: [explicit out-of-scope items]

Reference materials: [spec, design doc, reference repo, etc.]

Phase 1: Setup
  - [feature]: [what the node does]

Phase 2: Core Implementation [verification: Implement/Test loop / Audit/Fix loop]
  - [feature]: [what the node does]
    Requirements:
    1. [concrete, verifiable requirement]
    2. [concrete, verifiable requirement]

Phase N: Validation
  - ...

Topology: [option A / B / C]
Status agent: [enabled / off]
Retrospective: [enabled / off]
Iteration budgets: [implement loops: N, audit loops: N]
```

**Deriving requirements:** You are responsible for extracting concrete requirements from the project's specs, docs, and codebase. Don't wait for the human partner to enumerate them — propose specific, verifiable requirements and ask for confirmation. Vague requirements lead to feedback loops that don't converge.

Get explicit human partner approval before writing any .dot code.

## Phase 6: Compose

Write the .dot file. Reference `docs/usage/pipeline-reference.md` for syntax and `docs/usage/loop-patterns.md` for canonical topologies and prompt templates.

**Conventions:**

- Save the spec (if you produced one) and the pipeline in a project-conventional path. If the project doesn't have one, default to `pipelines/NN-name.md` and `pipelines/NN-name.dot` where `NN` is a two-digit ordinal. Confirm the path with the human partner if you're unsure.
- Set the `goal` graph attribute to the text approved in Phase 2.
- Every codergen prompt starts with `{{goal}}` (or, until that feature ships, repeats the goal text inline).
- Every reviewer prompt requires the LLM to emit `VERDICT: accept` or `VERDICT: reject` on a line by itself, plus a critique on the next line if rejecting.
- Diamond gates `contains`-match against `context.<reviewer>.last_output` — see Pattern 1 in `docs/usage/loop-patterns.md`.
- Inter-node artifacts (test reports, audit documents, specs) go under `{{run_dir}}/<artifact>.md`. Downstream nodes read them by path.
- Set `max_iterations` deliberately on every codergen node inside a loop. Default 3 is too low; pick the value approved in Phase 5.
- Do NOT add `timeout` attributes unless the human partner asked for them.
- Do NOT use `judge` for routing — use a `box` reviewer + `diamond` gate instead. `judge` is on a deprecation path.
- Do NOT use `wait.human` unless the human partner asked for one.
- Do NOT use `tool` nodes for work a codergen could do. Reserve `tool` for genuinely deterministic gating.

## Phase 7: Review

Apply the review checklist from `docs/usage/validate-prompt.md`. Walk through every item. Cross-check the prompt design principles too — every codergen prompt should:

- start with `{{goal}}` (or inline goal text for now)
- declare a role
- list reference materials before the task
- include numbered requirements
- end with a pre-completion checklist (implementation/fix nodes) or a structured-output requirement (reviewer/audit nodes)
- include anti-gaming clauses (implementation nodes)
- include the Pareto-optimal clause (reviewer/audit nodes)
- handle both first-visit and fix-iteration explicitly (nodes inside loops)

Cross-reference the failure-mode catalog in `docs/usage/validate-prompt.md`. For every loop, ask:

- Can the implementor actually fix every failure the reviewer might report? If a reviewer checks for something the implementor can't change in the current phase, the loop will spin.
- Does the reviewer prompt enumerate the same requirements as the implementor?
- Will the diamond gate's outgoing-edge conditions exhaustively cover the reviewer's possible verdicts?

## Phase 8: Fix Review Findings

Fix every issue found in Phase 7. Re-review until clean. Skip if Phase 7 found nothing.

## Phase 9: Validate

Run the validator and fix all errors and warnings:

```sh
mix cli   # if not built yet
./bin/tractor validate path/to/pipeline.dot
```

Errors block (`tractor validate` exits 10). Warnings are advisory but the pipeline should aim for zero warnings. If a warning flags an intentional design choice (e.g. a `wait.human` for development debugging, a `tool` node for a genuinely deterministic step), confirm with the human partner — either resolve the warning or get their explicit approval to keep it.

Once the validator is clean, the pipeline is ready to run with `./bin/tractor reap path/to/pipeline.dot`.
