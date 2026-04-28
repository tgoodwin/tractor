# Loop Patterns

Reusable graph topologies for Tractor pipelines. These are *not* prescriptive — most pipelines start linear and add a loop only where verification or iteration earns its keep. Use this doc when designing a new loop or reviewing one for soundness.

For syntax, see `pipeline-reference.md`. For broader design guidance, see `validate-prompt.md`. Both live in this directory.

## When to Reach for a Loop

The default is a linear chain. Reach for a loop when one of:

- **Implement → verify → fix** is the natural shape of the work and the agent can plausibly converge in a few iterations.
- **Independent perspectives** materially reduce the chance of missing something (audit/review work where one reviewer is insufficient).
- The work is **inherently iterative** (test-suite convergence, spec compliance) and a one-shot agent will silently skip cases.

If none of those apply, ship the linear pipeline. Loops cost tokens, fail more, and are harder to reason about.

## Pattern 1 — Implement/Test Loop

Three nodes: an implementor does the work, a reviewer checks it, a diamond gate routes back on failure.

```
implementor → reviewer → gate → implementor   (on reject)
                              → next_phase   (on accept)
```

This is the canonical Tractor feedback loop and the topology you should reach for first whenever a step needs verification before downstream work consumes it.

### Why three nodes, not two

A two-node loop (`implementor ↔ reviewer`) collapses generation and adjudication into one round-trip — the validator flags it with `two_way_edge` because a node ends up validating its own work or the loop has no clear exit point. Splitting the gate out to a `diamond` makes routing explicit and lets the validator/observer reason about the loop.

### Why not use `judge` here

`judge` collapses the reviewer and the gate into one node. It works, but it forces the same `two_way_edge` shape (reviewer-judge ↔ implementor) and it's on a deprecation path. Prefer the spec-aligned 3-node form.

### Wiring

```dot
implement [
  shape=box,
  llm_provider=claude,
  max_iterations=10,
  prompt="{{goal}}\n\nImplement the feature. Previous critique (if any): {{review.last_output}}"
]

review [
  shape=box,
  llm_provider=codex,
  max_iterations=10,
  prompt="{{goal}}\n\nReview the implementation. Output exactly one line beginning with 'VERDICT: accept' or 'VERDICT: reject'. If you reject, follow with a one-line critique on the next line."
]

gate [shape=diamond]

implement -> review
review -> gate
gate -> implement   [condition="context.review.last_output contains \"VERDICT: reject\""]
gate -> next_phase  [condition="context.review.last_output contains \"VERDICT: accept\""]
```

`examples/haiku_feedback.dot` is the reference — it chains three of these loops back to back.

### How pass/fail signals work

The reviewer's prompt asks the LLM to emit a structured verdict line in its response (`VERDICT: accept` or `VERDICT: reject`, plus an optional critique). The diamond gate's outgoing-edge `condition` strings then `contains`-match against `context.<reviewer>.last_output` to decide which way to route. This is Tractor's equivalent of marker-based status signaling — flexible (any verdict vocabulary works), per-edge (different gates can match different patterns), and built on the existing condition machinery without special parsing.

The vocabulary doesn't have to be `VERDICT: accept`. Pick whatever is unambiguous and tell the LLM to emit it; the `contains` match in the gate just needs to agree. Be deliberate about choosing strings that won't appear in the body of a normal response by accident — `VERDICT:` is a good prefix because it's unlikely to show up in prose review text.

### Implementor prompt — first-visit vs fix-iteration

The implementor handles both first-visit (build from scratch) and subsequent visits (fix the issues the reviewer flagged). The prompt uses the reviewer's last critique as the signal:

```
{{goal}}

You are an implementation engineer.

Previous reviewer critique (empty on first visit): {{review.last_output}}

If a critique exists above, this is a fix iteration:
  - Read the critique carefully and address every issue raised.
  - Do not weaken or remove the requirement to make it pass.
  - Commit after each substantive fix.

If no critique exists, this is your first visit:
  - Implement [feature description].
  - Requirements:
    1. [concrete, verifiable requirement]
    2. [concrete, verifiable requirement]

PRE-COMPLETION CHECKLIST:
[ ] Every requirement is implemented
[ ] No TODOs or placeholders remain
[ ] All changes are committed
```

The implementor doesn't need to look at "is this the first visit" via any special flag — checking whether `{{review.last_output}}` is empty (it will literally render as `{{review.last_output}}` if the key isn't in context yet) is sufficient. Tractor leaves unresolved placeholders in the rendered prompt verbatim by design, so the implementor's prompt should explicitly tolerate that case.

### Reviewer prompt

```
{{goal}}

You are a verification engineer. Your only job is to review and report.
You do not modify code or fix anything.

Implementation under review: {{implement.last_output}}

Verify each requirement:
1. [requirement 1]
2. [requirement 2]
...

For each requirement: identify the verification method, run it, record PASS or FAIL with specific evidence.

OUTPUT: A short report describing what you checked and what you found. End with exactly one of:

VERDICT: accept
VERDICT: reject

If you reject, follow with a one-line critique under 80 characters that names the worst remaining issue.
```

### Setting the iteration budget

Set `max_iterations` on the implementor and reviewer to the maximum number of cycles the loop should run before giving up. The default is 3, which is too low for real implementation loops — bump it to 10 or 20 depending on the work. When the budget is exhausted the runner stops re-entering the node and the pipeline either fails or routes through `retry_target` if configured.

### Failure modes to watch for

- **Reviewer is too lenient.** Test passes quickly but downstream consumers find gaps. Tighten the reviewer prompt with a strict structured output requirement and per-requirement evidence.
- **Reviewer is too strict (nit-picking).** Loop never converges because the reviewer flags trivial issues. Tell the reviewer in its prompt to FAIL only on issues that materially affect correctness.
- **Implementor weakens the spec to pass.** Forbid this explicitly: "Do not weaken, skip, or remove any requirement to make it pass."
- **Loop exhausts iteration budget.** Either the requirements are ambiguous (two reasonable agents disagree on what "correct" means) or the implementor isn't getting the critique. Check that the reviewer is producing concrete, actionable critiques and the implementor's prompt actually surfaces them.

### Anti-patterns

- Letting the reviewer also fix things. It biases its own reporting and the loop's signal degrades.
- Using a separate `fix` node distinct from the implementor. The implementor has the design context — a separate fix node loses that context and tends to produce shallow patches. Keep fix-mode and first-visit-mode in one node.
- Two-way edges between the same pair (`implement ↔ review`). The validator flags this. Always route through a diamond gate.

## Pattern 2 — Audit/Fix Loop

The heavy-duty verification pattern. Multiple independent reviewers examine the same artifact in parallel, their findings are consolidated with a unanimity rule, and a fix node addresses any failures before the cycle repeats.

```
preparer → fan_out → reviewer_a    → fan_in → verdict → gate → fix → preparer  (on reject)
                  → reviewer_b   ↗                                   → next     (on accept)
                  → reviewer_c   ↗
```

### When to use

- Phase-level quality gates after multiple features have landed.
- Spec-compliance or conformance checking where one reviewer's blind spot is a real risk.
- Final validation before exit — when getting it wrong is expensive.

For per-feature verification inside a phase, prefer Pattern 1 — Audit/Fix is overkill and 3× the token cost.

### Why a preparer

The preparer node runs whatever shared setup the reviewers need: build the artifact, run the test suite, generate fixtures. Its output (a results document, a built binary, a test report) becomes the substrate the reviewers read. This way:

- Reviewers don't redundantly re-run expensive setup.
- Reviewers don't conflict on shared mutable state (concurrent test runs, lock contention).
- Every cycle starts with fresh evidence — when the fix loops back to the preparer, the next round of reviewers works against the latest fix.

If reviewers genuinely need no shared setup, you can omit the preparer and fan out from a regular node. But this is rare in practice.

### Why three reviewers, why unanimity

Three reviewers running independently catch more ground than one — different agents, different prompts, different angles. The unanimity rule (any FAIL → FAIL) ensures no reviewer's concerns are silently overridden by majority vote. Two-of-three would let a real issue slip when two reviewers happen to share a blind spot. One reviewer is just Pattern 1 with extra ceremony.

For model diversity, point each reviewer at a different `llm_provider` (`claude`, `codex`, `gemini`). This is cheap to set up and meaningfully widens the coverage.

### Wiring

```dot
preparer [
  shape=box,
  llm_provider=claude,
  prompt="{{goal}}\n\nRun the test suite and write a results report to {{run_dir}}/TEST_RESULTS.md..."
]

audit [shape=component, max_parallel=3]

audit_a [shape=box, llm_provider=claude, prompt="..."]
audit_b [shape=box, llm_provider=codex,  prompt="..."]
audit_c [shape=box, llm_provider=gemini, prompt="..."]

audit_join [shape=tripleoctagon, prompt="Consolidate these three audit reports..."]

verdict [shape=box, llm_provider=claude, prompt="..."]

gate [shape=diamond]

fix [
  shape=box,
  llm_provider=claude,
  max_iterations=20,
  prompt="{{goal}}\n\nRead the consolidated verdict at {{run_dir}}/AUDIT_MERGED.md..."
]

preparer -> audit
audit -> audit_a
audit -> audit_b
audit -> audit_c
audit_a -> audit_join
audit_b -> audit_join
audit_c -> audit_join
audit_join -> verdict
verdict -> gate
gate -> next_phase [condition="context.verdict.last_output contains \"VERDICT: accept\""]
gate -> fix         [condition="context.verdict.last_output contains \"VERDICT: reject\""]
fix -> preparer
```

`examples/parallel_audit.dot` shows the fan-out + fan-in mechanics; it's a one-shot audit (no fix loop) but the fan/join wiring is the same.

### Reviewer prompts

Each reviewer should be told that:

- It is one of three independent reviewers.
- It does not coordinate with the others or defer to anyone.
- It assumes the work is broken until each requirement is proven with evidence.
- It writes its findings to a per-reviewer artifact path under `{{run_dir}}/`.
- It ends with exactly one of `VERDICT: accept` or `VERDICT: reject`, plus a structured findings list.

Critical guidance: tell each reviewer to aim for a Pareto-optimal outcome — FAIL only on issues that materially affect correctness, completeness, or quality. Without this, reviewers nit-pick endlessly and the audit loop never converges.

```
{{goal}}

You are an independent auditor — Reviewer A. You do not coordinate
with or defer to any other reviewer. Form your own judgment.

Read the prepared evidence at {{run_dir}}/TEST_RESULTS.md.
For code-level checks, inspect the source directly.

Aim for a Pareto-optimal outcome: FAIL a requirement only when the issue
materially affects correctness, completeness, or quality. Do NOT fail
over minor stylistic, cosmetic, or trivial issues.

Audit the following requirements:
1. [requirement 1]
2. [requirement 2]
...

OUTPUT: Write {{run_dir}}/AUDIT_A.md containing per-requirement findings
with evidence. End the file with exactly one of:

VERDICT: accept
VERDICT: reject

If you reject, follow with a list of failed requirements (one per line).
```

Reviewers B and C are identical except for the file name (`AUDIT_B.md`, `AUDIT_C.md`). Optionally point each at a different provider (`llm_provider=claude` / `codex` / `gemini`) for model diversity.

### Verdict consolidator (fan-in)

The `tripleoctagon` fan-in node merges the three reviewer reports into a single verdict document. It runs as a normal codergen node when given an `llm_provider` and prompt — the special behavior of `parallel.fan_in` is just that it gathers per-branch results into the context as `{{branch:audit_a}}`, `{{branch:audit_b}}`, `{{branch:audit_c}}` and `{{branch_responses}}`.

```
{{goal}}

You are the audit verdict consolidator.

Read the three reviewer reports:
{{branch:audit_a}}
{{branch:audit_b}}
{{branch:audit_c}}

Apply the unanimity rule:
- ANY reviewer reporting VERDICT: reject → final verdict is reject
- ALL reviewers reporting VERDICT: accept → final verdict is accept

Write {{run_dir}}/AUDIT_MERGED.md containing:
1. Final verdict
2. Deduplicated findings (merge overlapping, preserve unique)
3. For each finding, evidence and which reviewer(s) flagged it

When merging, discard nit-picks that have negligible real-world impact.
Only escalate findings that materially affect correctness, completeness,
or quality.

End with exactly one of:

VERDICT: accept
VERDICT: reject
```

The verdict node downstream of the fan-in is what the gate matches against. If you don't need a separate verdict node, the fan-in's own output works — but a verdict step gives you a clean place to apply the unanimity rule and curate findings before the gate sees them.

### Fix node

The fix node reads the consolidated audit, prioritizes by impact, and addresses the highest-impact finding fully before moving to the next. It loops back to the preparer, not directly to the audit fan-out — this guarantees fresh evidence on every cycle.

```
{{goal}}

You are a debugging engineer. Address the findings in the consolidated
audit report.

Read {{run_dir}}/AUDIT_MERGED.md carefully.

Prioritize findings by impact. Pick the highest-impact finding and fully
resolve it. Then move to the next. It is better to fully resolve 3
findings than to partially address 10.

Aim for a Pareto-optimal outcome: focus effort where it materially
improves correctness or quality. Do not chase diminishing returns on
minor or cosmetic issues — if remaining findings are trivial, the work
is done.

After fixing, run the full test suite to confirm fixes work and
previously-passing requirements still pass.

Commit after each substantive fix.
```

### Audit/Fix anti-patterns

- **Letting reviewers see each other's reports.** Defeats independence. They write to separate files.
- **Skipping the unanimity rule.** A single dissenting reviewer often catches a real issue. Letting majority vote silence it costs you the value of having three.
- **Loop never converges (nit-picking).** Reviewers and the fix node both need the Pareto-optimal guidance in their prompts. Without it, the loop spirals on cosmetic issues.
- **Fix loops back to fan-out, not preparer.** Skips the fresh-evidence step. Reviewers end up auditing stale state and may pass a regression.
- **One reviewer with three names.** All three pointing at the same provider+model still helps a little (different prompts, different randomness) but the diversity-of-models case is much stronger.

## What's Not Yet a Pattern

The Moab project documents a third "parallel implementation with worktrees" pattern: multiple implementors building independent features simultaneously in separate git worktrees, then merging in order. **Tractor doesn't currently support worktrees** — branches inside parallel blocks must be exactly one node and there's no merge node abstraction. Track this as a roadmap item if your pipeline genuinely needs parallel feature development; today, run feature development sequentially or in separate pipeline runs.

## Composition

Real pipelines combine these. A typical multi-phase shape:

```
spec_expansion → impl_loop_feature_a → impl_loop_feature_b → impl_loop_feature_c → audit_fix_phase → exit
```

- An optional spec-expansion stage (a single codergen node that produces a written specification consumed by every downstream prompt) gives the rest of the pipeline something concrete to verify against.
- One Implement/Test loop per feature.
- An Audit/Fix loop at the end of each phase to catch integration issues that per-feature loops miss.

When a pipeline grows beyond ~10 nodes, sketch it in a diagram before composing the .dot — DOT files are easy to lose the shape of in text form. The observer (`mix phx.server`) renders the live graph; running `dot -Tpng pipeline.dot -o pipeline.png` works for offline review.
