# Moab Validate — Implementation Specification

This document specifies `moab validate` in sufficient detail to reimplement it from scratch. It covers the CLI interface, the six-phase validation pipeline, every lint rule (with exact semantics, severity, and fix hints), the condition expression grammar, the agent stylesheet grammar, the AST-level attribute type system, the `validate-prompt` design-review skill, and the testing strategy.

---

## 1. CLI Interface

### Usage

```
moab validate <dotfile> [--config <path>]
```

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `dotfile` | yes | Path to a `.dot` pipeline file |
| `--config` | no | Path to a TOML file containing config parameter key-value pairs |

### Behavior

1. Read `dotfile` from disk. If the file cannot be read, print an error to stderr and exit with code 1.
2. If `--config` is provided, parse the TOML file into a `HashMap<String, String>` of config values.
3. Run the full six-phase validation pipeline (see Section 3).
4. Print each diagnostic to stdout in the format:

```
SEVERITY [rule_name] LINE:COL (location): message
  Fix: fix_hint
```

Where:
- `SEVERITY` is `ERROR`, `WARNING`, or `INFO`
- `LINE:COL` is present only if the diagnostic has a source span
- `(location)` is either `(node: id)` or `(edge: from -> to)` if applicable
- `Fix:` line is printed only if the diagnostic includes a fix hint

5. Print a summary line: `N diagnostic(s): E error(s), W warning(s)`
6. If zero diagnostics, print `No issues found.`
7. Exit with code 1 if any diagnostic has `Severity::Error`. Exit with code 0 otherwise.

### Integration with `moab run`

The `moab run` command also calls `validate_full` before executing a pipeline. If any errors are found, it prints diagnostics to stderr and exits with code 1 without starting the engine.

---

## 2. Core Data Structures

### Diagnostic

Every validation finding is represented as a `Diagnostic`:

```
Diagnostic {
    rule: String,          // Machine-readable rule identifier (e.g., "start_node")
    severity: Severity,    // Error | Warning | Info
    message: String,       // Human-readable description
    span: Option<Span>,    // Source location {line, col} if available
    node_id: Option<String>,   // Node context if applicable
    edge: Option<(String, String)>,  // Edge context (from, to) if applicable
    fix: Option<String>,   // Suggested fix text
}
```

### Severity

```
enum Severity {
    Error,    // Prevents execution; exit code 1
    Warning,  // Advisory; does not block execution
    Info,     // Informational
}
```

### LintRule Trait

All graph-level rules implement:

```
trait LintRule: Send + Sync {
    fn name(&self) -> &str;
    fn apply(&self, graph: &Graph) -> Vec<Diagnostic>;
}
```

### AstLintRule Trait

AST-level rules implement:

```
trait AstLintRule: Send + Sync {
    fn name(&self) -> &str;
    fn apply(&self, ast: &AstGraph) -> Vec<Diagnostic>;
}
```

---

## 3. Six-Phase Validation Pipeline

The `validate_full(source, config_values)` function runs six phases in sequence. Each phase may produce diagnostics. Some phases are "fatal" — if they fail, later phases are skipped.

### Phase 1: Parse (fatal)

Lex and parse the DOT source into an AST.

**Parse-time diagnostic rules:**

| Rule | Severity | Trigger | Fix hint |
|------|----------|---------|----------|
| `dot_syntax` | Error | Lexer or parser syntax error | (none) |
| `dot_undirected_edge` | Error | `--` edge operator in a digraph | `use '->' for directed edges` |
| `dot_not_digraph` | Error | `graph` keyword instead of `digraph` | `change 'graph' to 'digraph'` |
| `dot_strict_modifier` | Error | `strict` keyword present | `remove 'strict' keyword` |
| `dot_multiple_graphs` | Error | Tokens remain after the closing `}` | `remove everything after the closing '}'` |

If the lexer or parser fails (no AST produced), return early with the parse diagnostics. The `dot_multiple_graphs` rule is non-fatal — the first graph's AST is still returned.

`dot_syntax` diagnostics include a `span` with line and column when available (parser syntax errors always have one; unexpected-EOF and other errors may not).

### Phase 2: AST Validation

Run lint rules on the raw AST before lowering. This catches issues that are lost during the AST-to-Graph lowering step.

**2a. Value quoting (`value_quoting`)**

Walk all AST attributes. If a value is parsed as a bare `Duration` (e.g., `1800s` without quotes) or bare `Bool` (e.g., `true` without quotes), emit:

| Rule | Severity | Message |
|------|----------|---------|
| `value_quoting` | Warning | `bare {kind} value '{raw}' for attribute '{key}' should be quoted: {key}="{raw}"` |

This is a compatibility warning — Moab's parser accepts bare durations and booleans, but standard Graphviz DOT does not.

**2b. Unknown attribute rules**

Three rules check that attributes are recognized. Each has two allowlists: known Moab attributes and known Graphviz passthrough attributes. Passthroughs are matched case-insensitively.

| Rule | Severity | Scope |
|------|----------|-------|
| `unknown_graph_attr` | Warning | Graph-level attributes |
| `unknown_node_attr` | Warning | Node attributes and `node [...]` defaults |
| `unknown_edge_attr` | Warning | Edge attributes and `edge [...]` defaults |

All three recurse into subgraphs.

**Known graph attributes:**
`goal`, `label`, `config`, `agent_stylesheet`, `status_agent_stylesheet`, `companion_agent_stylesheet`, `default_max_retries`, `default_max_visits`, `retry_target`, `fallback_retry_target`, `default_fidelity`, `tool_hooks.pre`, `tool_hooks.post`, `rankdir`, `default_status_prompt_extra`, `default_agent` (deprecated), `status_agent` (deprecated), `companion_agent` (deprecated)

**Known node attributes:**
`label`, `shape`, `type`, `prompt`, `agent`, `model`, `max_retries`, `max_visits`, `goal_gate`, `retry_target`, `fallback_retry_target`, `fidelity`, `thread_id`, `class`, `timeout`, `reasoning_effort`, `auto_status`, `allow_partial`, `tool_command`, `join_policy`, `max_parallel`, `human.default_choice`, `tool_hooks.pre`, `tool_hooks.post`, `status_prompt_extra`

**Known edge attributes:**
`label`, `condition`, `weight`, `fidelity`, `thread_id`

**Graphviz passthrough attributes** (accepted on any element without warning, case-insensitive):
`color`, `fillcolor`, `fontcolor`, `fontname`, `fontsize`, `style`, `penwidth`, `width`, `height`, `fixedsize`, `tooltip`, `URL`, `target`, `rank`, `group`, `dir`, `arrowhead`, `arrowtail`, `arrowsize`, `headlabel`, `taillabel`, `labelfontsize`, `labelfontcolor`, `constraint`, `minlen`, `xlabel`, `bgcolor`, `margin`, `pad`, `nodesep`, `ranksep`, `splines`, `overlap`, `concentrate`

**2c. Attribute type rule (`attr_type`)**

Checks that typed attributes have values of the correct type:

| Category | Attributes | Expected type | Severity |
|----------|-----------|---------------|----------|
| Integer | `max_retries`, `max_visits`, `weight`, `default_max_retries`, `default_max_visits` | Integer (or string parseable as i64) | Error |
| Boolean | `goal_gate`, `auto_status`, `allow_partial` | Boolean (`true`/`false`/`yes`/`no`/`1`/`0`, case-insensitive) | Error |
| Duration | `timeout` | Duration: bare integer (seconds), or digits + suffix `ms`/`s`/`m`/`h`/`d` | Error |

Values are validated against AST value types:
- `AstValue::Int` is always valid for Integer attrs
- `AstValue::Bool` is always valid for Boolean attrs
- `AstValue::Duration` is always valid for Duration attrs
- `AstValue::Str` and `AstValue::Bare` are valid if their string content parses correctly
- Any other combination (e.g., `Bool` for an Integer attr) is an error

### Phase 3: Lower (fatal)

Lower the AST into a runtime `Graph` (nodes, edges, attributes). If lowering fails, emit a `dot_lowering` diagnostic with `Severity::Error` and return early.

### Phase 4: Config Validation (pre-transform)

Run config rules **before** config expansion replaces `$config.*` references. This is the only phase that can detect undeclared or unused config keys.

**Rules:**

| Rule | Severity | Description |
|------|----------|-------------|
| `config_undeclared_ref` | Error | A `$config.NAME` reference appears in a graph goal, node label, node prompt, or node tool_command, but `NAME` is not declared in the graph-level `config` attribute |
| `config_unused` | Warning | A key is declared in `config` but never referenced as `$config.KEY` anywhere |

`$config.NAME` references are scanned with prefix matching: find `$config.`, then read `[a-zA-Z0-9_]+` as the key name.

### Phase 5: Transform (fatal)

Apply transforms (stylesheet application, variable expansion, config expansion). If transforms fail, emit a `transform` diagnostic with `Severity::Error` and return early.

### Phase 6: Graph Validation

Run the full suite of graph-level lint rules against the transformed graph.

---

## 4. Graph-Level Lint Rules

Rules are organized into categories and run in order. All rules implement the `LintRule` trait.

### 4.1 Structural ERROR Rules

These rules check fundamental graph structure. Any violation is an error that blocks execution.

#### Rule: `start_node`

The graph must have **exactly one** start node. A start node is identified by:
1. Shape `Mdiamond` (case-insensitive), OR
2. Node ID `start` or `Start`

If both criteria match the same node, it counts once (deduplicated).

| Count | Severity | Message |
|-------|----------|---------|
| 0 | Error | `graph has no start node (need exactly one node with shape=Mdiamond or id start/Start)` |
| 1 | (none) | Valid |
| N>1 | Error | `graph has N start nodes (need exactly one): id1, id2, ...` |

Fix: `add a node with shape=Mdiamond` / `remove extra start nodes so only one remains`

#### Rule: `terminal_node`

The graph must have **exactly one** exit node. An exit node is identified by:
1. Shape `Msquare` (case-insensitive), OR
2. Node ID matching one of: `exit`, `Exit`, `end`, `End`, `done`, `Done`

| Count | Severity | Message |
|-------|----------|---------|
| 0 | Error | `graph has no exit node (need exactly one node with shape=Msquare or id exit/end/done)` |
| 1 | (none) | Valid |
| N>1 | Error | `graph has N exit nodes (need exactly one): id1, id2, ...` |

#### Rule: `reachability`

Every node must be reachable from the start node via directed edges (BFS). Only runs if exactly one start node exists. For each unreachable node:

| Severity | Message |
|----------|---------|
| Error | `node 'X' is not reachable from start node 'S'` |

Fix: `add an edge path from 'S' to 'X'`

Includes the node's source span if available.

#### Rule: `edge_target_exists`

Every edge must reference existing nodes on both endpoints. Checks both `from` and `to` independently:

| Severity | Message |
|----------|---------|
| Error | `edge references non-existent source node 'X'` |
| Error | `edge references non-existent target node 'X'` |

#### Rule: `start_no_incoming`

The start node must have zero incoming edges. Only runs if exactly one start node exists.

| Severity | Message |
|----------|---------|
| Error | `start node 'S' has N incoming edge(s) — start must have none` |

#### Rule: `exit_no_outgoing`

The exit node must have zero outgoing edges. Only runs if exactly one exit node exists.

| Severity | Message |
|----------|---------|
| Error | `exit node 'E' has N outgoing edge(s) — exit must have none` |

#### Rule: `condition_syntax`

Every edge with a non-empty `condition` attribute must parse successfully as a condition expression (see Section 5). Skips edges with empty conditions.

| Severity | Message |
|----------|---------|
| Error | `invalid condition 'EXPR' on edge A -> B: PARSE_ERROR` |

Fix: `fix condition to use key=value or key!=value syntax with valid keys`

#### Rule: `stylesheet_syntax`

If the graph has an `agent_stylesheet` attribute, validate its syntax:
1. Balanced braces
2. Valid selectors: `*`, `#id`, `.class`, or a known shape name (`box`, `mdiamond`, `msquare`, `diamond`, `hexagon`, `component`, `tripleoctagon`, `parallelogram`, `ellipse`, `circle`, `rect`, `record`)
3. Valid properties: `agent`, `model`, `reasoning_effort`
4. Property declarations must follow `property: value;` format

| Severity | Message |
|----------|---------|
| Error | `stylesheet error: DETAIL` |

### 4.2 Semantic WARNING Rules

#### Rule: `condition_semantics`

Semantic checks on syntactically valid conditions. Skips edges that fail `condition_syntax`.

| Check | Message |
|-------|---------|
| `outcome` compared to `true` or `false` | `condition compares 'outcome' to boolean 'X' — outcome values are strings like 'success' or 'fail'` |
| `outcome` compared to unknown value | `outcome compared to 'X' — expected one of: success, fail, partial_success, error` |
| `preferred_label` value doesn't match any edge label in the graph | `preferred_label compared to 'X' but no edge in the graph has that label` |

Valid outcome values: `success`, `fail`, `partial_success`, `error`

#### Rule: `agent_configured`

Every agent node must have an agent configured via one of:
1. Explicit `agent` attribute on the node
2. Graph-level `default_agent` attribute
3. Node has a `class` AND graph has an `agent_stylesheet`

Only checks nodes where `resolve_handler_type(node) == "agent"`.

| Severity | Message |
|----------|---------|
| Warning | `agent node 'X' has no agent configured (no explicit agent, no agent_stylesheet)` |

Results are sorted by node ID for deterministic output.

#### Rule: `type_known`

If a node has an explicit `type` attribute, it must be one of the known types:
`start`, `exit`, `agent`, `tool`, `wait.human`, `conditional`, `parallel`, `parallel.fan_in`

| Severity | Message |
|----------|---------|
| Warning | `node 'X' has unknown type 'Y' — expected one of: ...` |

#### Rule: `fidelity_valid`

Node and edge `fidelity` attributes must be one of:
`full`, `truncate`, `compact`, `summary:low`, `summary:medium`, `summary:high`

| Severity | Message |
|----------|---------|
| Warning | `node 'X' has invalid fidelity 'Y' — expected one of: ...` |
| Warning | `edge A -> B has invalid fidelity 'Y' — expected one of: ...` |

#### Rule: `retry_target_exists`

If a node has a `retry_target` or `fallback_retry_target`, the referenced node must exist in the graph.

| Severity | Message |
|----------|---------|
| Warning | `node 'X' has retry_target 'Y' which does not exist` |
| Warning | `node 'X' has fallback_retry_target 'Y' which does not exist` |

Results sorted by node ID.

#### Rule: `goal_gate_has_retry`

If a node has `goal_gate=true`, it must have a retry target configured at either node level (`retry_target` or `fallback_retry_target`) or graph level (`default_retry_target` or `default_fallback_retry_target`).

| Severity | Message |
|----------|---------|
| Warning | `node 'X' has goal_gate=true but no retry_target or fallback_retry_target (node or graph level)` |

Results sorted by node ID.

#### Rule: `prompt_on_agent_nodes`

Agent nodes should have either a non-empty `prompt` or a `label` that differs from the node ID. Only checks nodes where `resolve_handler_type(node) == "agent"`.

| Severity | Message |
|----------|---------|
| Warning | `agent node 'X' has no prompt and no meaningful label` |

Results sorted by node ID.

### 4.3 Value Range Rules

#### Rule: `shape_known`

If a node has a non-empty `shape`, it must map to a known handler type via `HandlerType::from_shape()`.

Known shapes: `mdiamond`, `msquare`, `box`, `hexagon`, `diamond`, `component`, `tripleoctagon`, `parallelogram`

| Severity | Message |
|----------|---------|
| Warning | `node 'X' has unknown shape 'Y' — expected one of: mdiamond, msquare, box, hexagon, diamond, component, tripleoctagon, parallelogram` |

#### Rule: `reasoning_effort_valid`

Agent nodes with a `reasoning_effort` attribute must use one of: `low`, `medium`, `high`

| Severity | Message |
|----------|---------|
| Warning | `agent node 'X' has invalid reasoning_effort 'Y' — expected one of: low, medium, high` |

#### Rule: `agent_known`

If a node has an `agent` attribute, it must be one of the known agents: `claude-code`, `codex`, `gemini-cli`

| Severity | Message |
|----------|---------|
| Warning | `node 'X' has unknown agent 'Y' — known agents: claude-code, codex, gemini-cli` |

#### Rule: `model_known`

If a node has a `model` attribute:

1. **Unknown model**: If the model ID is not in the known models list, warn. The fix hint includes agent-specific model suggestions if the node has a known agent, otherwise shows a generic sample.

| Severity | Message |
|----------|---------|
| Warning | `node 'X' has unknown model 'Y'` |

2. **Agent/model mismatch**: If the model is known but the node's agent doesn't match the expected agent for that model prefix, warn.

| Severity | Message |
|----------|---------|
| Warning | `node 'X' has model 'M' which expects agent 'A1', but agent is 'A2'` |

**Known models by agent:**
- `claude-code`: `claude-opus-4.6`, `claude-opus-4.6-fast`, `claude-sonnet-4.6`
- `codex`: `gpt-5.4`, `gpt-5.4-pro`, `gpt-5.4-mini`, `gpt-5.4-nano`, `gpt-5.3-codex`, `gpt-5.3-chat`
- `gemini-cli`: `gemini-3.1-pro-preview`, `gemini-3.1-pro-preview-customtools`, `gemini-3.1-flash-lite-preview`, `gemini-3-flash-preview`

**Agent inference from model prefix:** `claude-*` → `claude-code`, `gpt-*` → `codex`, `gemini-*` → `gemini-cli`

### 4.4 Semantic Consistency Rules

These rules catch attribute combinations that are contradictory or meaningless.

#### Rule: `type_shape_mismatch`

If a node has both an explicit `type` and a shape that maps to a different handler type, warn.

| Severity | Message |
|----------|---------|
| Warning | `node 'X' has type='Y' but shape 'Z' implies type 'W' — these disagree` |

#### Rule: `tool_command_on_non_tool`

If a node has `tool_command` but its resolved handler type is not `tool`, warn.

| Severity | Message |
|----------|---------|
| Warning | `node 'X' has tool_command but resolved type is 'Y', not 'tool'` |

#### Rule: `prompt_on_tool_node`

If a node has a `prompt` and its resolved handler type is `tool`, warn. Tool nodes use `tool_command`, not `prompt`.

| Severity | Message |
|----------|---------|
| Warning | `node 'X' is a tool node but has a prompt — tool nodes use tool_command, not prompt` |

#### Rule: `goal_gate_on_non_agent`

If a node has `goal_gate=true` but its resolved handler type is not `agent`, warn.

| Severity | Message |
|----------|---------|
| Warning | `node 'X' has goal_gate=true but resolved type is 'Y', not 'agent'` |

#### Rule: `agent_on_non_agent_node`

If a node has an `agent` attribute but its resolved type is one of: `start`, `exit`, `conditional`, `parallel`, `parallel.fan_in`, warn. The `agent` attribute is ignored on these types.

| Severity | Message |
|----------|---------|
| Warning | `node 'X' has agent attribute but resolved type is 'Y' — agent attribute is ignored on Y nodes` |

#### Rule: `timeout_on_instant_node`

If a node has a `timeout` but its resolved type is one of: `start`, `exit`, `conditional`, warn. These nodes execute instantly.

| Severity | Message |
|----------|---------|
| Warning | `node 'X' has timeout but resolved type is 'Y' — Y nodes execute instantly` |

#### Rule: `allow_partial_without_retries`

If a node has `allow_partial=true` but its effective `max_retries` is 0, warn. `allow_partial` has no effect without retries. Effective retries = node's `max_retries` if set, otherwise graph's `default_max_retries`.

| Severity | Message |
|----------|---------|
| Warning | `node 'X' has allow_partial=true but effective max_retries is 0 — allow_partial has no effect without retries` |

#### Rule: `fidelity_full_orphan_thread`

If a node uses `fidelity="full"` with a `thread_id`, and no other node in the graph shares that `thread_id`, warn. On the first visit, `fidelity="full"` tries to resume a session that doesn't exist yet, causing a runtime error.

| Severity | Message |
|----------|---------|
| Warning | `node 'X' uses fidelity="full" with thread_id="T" but no other node shares this thread_id — the first visit will fail because no session exists to resume` |

### 4.5 Graph-Level Config Warnings

#### Rule: `default_agent`

Warns about deprecated graph-level agent configuration attributes:

| Attribute | Message | Fix |
|-----------|---------|-----|
| `default_agent` | `default_agent is deprecated` | `remove default_agent and use agent_stylesheet="* { agent: VALUE; }"` |
| `status_agent` | `status_agent is deprecated` | `remove status_agent and use status_agent_stylesheet="agent: VALUE;"` |
| `companion_agent` | `companion_agent is deprecated` | `remove companion_agent and use companion_agent_stylesheet="agent: VALUE;"` |

#### Rule: `status_agent`

If no status agent is configured (via `status_agent_stylesheet` or deprecated `status_agent`):

| Severity | Message |
|----------|---------|
| Warning | `no status agent configured — the viz will not show status summaries` |

Fix: `add status_agent_stylesheet="agent: claude-code;" to the graph attributes`

### 4.6 Principle Warnings

Advisory warnings about pipeline design principles.

#### Rule: `human_gate_warning`

Any node with resolved type `wait.human` (shape `hexagon`):

| Severity | Message |
|----------|---------|
| Warning | `node 'X' is a human gate — pipelines should run autonomously` |

Fix: `human gates should only be used for debugging during pipeline development — replace with an agent node for production use`

#### Rule: `tool_node_warning`

Any node with resolved type `tool` (shape `parallelogram`):

| Severity | Message |
|----------|---------|
| Warning | `node 'X' is a tool node running a shell command directly` |

Fix: `prefer an agent node — agents run commands and can diagnose and fix errors`

#### Rule: `two_way_edge_warning`

If two nodes have edges in both directions (A→B and B→A), warn. Only reports each pair once (using sorted pair deduplication).

| Severity | Message |
|----------|---------|
| Warning | `nodes 'A' and 'B' have edges in both directions` |

Fix: `two-way edges are a potential smell of a malformed loop — a node should not validate its own work`

---

## 5. Condition Expression Grammar

Condition expressions appear on edge `condition` attributes and control routing at conditional (diamond) nodes.

### Syntax

```
condition := clause ("&&" clause)*
clause    := key operator value
operator  := "=" | "!="
key       := "outcome" | "preferred_label" | "context." identifier
value     := quoted_string | bare_word
```

Rules:
- `&&` is the only logical operator (conjunction)
- Whitespace around operators and `&&` is trimmed
- Keys must be exactly `outcome`, `preferred_label`, or start with `context.`
- Values can be quoted (`"value"`) or bare — quotes are stripped during parsing
- Empty keys, empty values, missing operators, and unknown keys are parse errors

### Parse Errors (Severity: Error)

| Condition | Error message |
|-----------|---------------|
| Empty clause (e.g., trailing `&&`) | `empty clause in condition` |
| No `=` or `!=` operator | `clause 'X' has no '=' or '!=' operator` |
| Missing key (e.g., `=value`) | `missing key in clause 'X'` |
| Missing value (e.g., `key=`) | `missing value in clause 'X'` |
| Unknown key | `invalid condition key 'K' — must be 'outcome', 'preferred_label', or start with 'context.'` |
| Unbalanced quotes | `unbalanced quotes in value: V` |

### Semantic Warnings (Severity: Warning)

After successful parsing, semantic checks produce warnings:

| Check | Warning |
|-------|---------|
| `outcome` compared to boolean string | `condition compares 'outcome' to boolean 'X' — outcome values are strings like 'success' or 'fail'` |
| `outcome` compared to unknown value | `outcome compared to 'X' — expected one of: success, fail, partial_success, error` |
| `preferred_label` value not found in edge labels | `preferred_label compared to 'X' but no edge in the graph has that label` |

---

## 6. Handler Type Resolution

The handler type determines what the engine does when executing a node. It is resolved with this precedence:

1. **Explicit `type` attribute** — takes precedence over everything
2. **Shape-to-handler mapping** (from the spec):

| Shape | Handler Type |
|-------|-------------|
| `mdiamond` | `start` |
| `msquare` | `exit` |
| `box` | `agent` |
| `hexagon` | `wait.human` |
| `diamond` | `conditional` |
| `component` | `parallel` |
| `tripleoctagon` | `parallel.fan_in` |
| `parallelogram` | `tool` |

3. **Fallback** — unrecognized shapes default to `agent`

Shape matching is case-insensitive. The default node shape is `box` (→ `agent`).

---

## 7. Agent Stylesheet Grammar

The stylesheet is a graph-level attribute (`agent_stylesheet`) that assigns agent configuration to nodes via CSS-like selectors.

### Syntax

```
stylesheet  := rule_block*
rule_block  := selector "{" declarations "}"
selector    := "*" | "#" id | "." class | shape_name
declarations := (declaration ";")*
declaration := property ":" value
property    := "agent" | "model" | "reasoning_effort"
```

### Selectors

| Selector | Matches |
|----------|---------|
| `*` | All nodes |
| `#node_id` | Node with that exact ID |
| `.class_name` | Nodes with that `class` attribute |
| `box`, `diamond`, etc. | Nodes with that shape (case-insensitive, must be a known shape) |

### Validation

The stylesheet validator checks:
1. **Balanced braces** — opening and closing `{`/`}` counts must match
2. **Valid selectors** — must be `*`, `#id`, `.class`, or a known shape name
3. **Valid properties** — only `agent`, `model`, `reasoning_effort`
4. **Declaration format** — each declaration must contain a `:` separator

---

## 8. Pipeline Authoring Guidance

Pipeline-authoring guidance (canonical topologies, prompt design, common failure modes, review checklist) lives in `docs/usage/`:

- `docs/usage/validate-prompt.md` — design principles, prompt design rules, common failure modes, review checklist.
- `docs/usage/loop-patterns.md` — Implement/Test and Audit/Fix loop topologies with worked DOT and prompt templates.
- `docs/usage/pipeline-reference.md` — DOT subset, attribute tables, condition syntax, template variables, run directory layout.
- `skills/create-pipeline.md` — the workflow skill that loads the three docs above as shared context when an agent is authoring a new pipeline.

This section previously embedded a copy of that guidance keyed to Moab's conventions (agent stylesheets, STATUS markers, fidelity, auto_status). Tractor uses different idioms — see the docs above for the current authoritative content.

> **Validator alignment note:** Section 7 (Agent Stylesheet Grammar) and the parts of Section 4 referencing `agent_stylesheet`, `default_agent`, and stylesheet selectors describe Moab features that are NOT planned for Tractor. The Tractor validator currently still warns on a couple of these (`unsupported_graph_attr` for `model_stylesheet`, etc.) but should eventually drop the stylesheet sections entirely. Tracked as a follow-up cleanup.

---

## 9. API Surface

### Public Functions

```rust
// Run all phases. Returns (graph_if_successful, all_diagnostics, resolved_config).
fn validate_full(
    source: &str,
    config_values: &HashMap<String, String>,
) -> (Option<Graph>, Vec<Diagnostic>, HashMap<String, String>)

// Run graph-level rules only (phase 6).
fn validate(graph: &Graph) -> Vec<Diagnostic>

// Run graph rules plus custom user-supplied rules.
fn validate_with_rules(graph: &Graph, extra_rules: &[Box<dyn LintRule>]) -> Vec<Diagnostic>

// Run graph rules, return Err if any Error-severity diagnostics exist.
fn validate_or_raise(graph: &Graph) -> Result<Vec<Diagnostic>, Vec<Diagnostic>>

// Run config rules only (phase 4, pre-transform).
fn validate_config(graph: &Graph) -> Vec<Diagnostic>

// Run AST rules only (phase 2).
fn validate_ast(ast: &AstGraph) -> Vec<Diagnostic>
```

### Extensibility

The `validate_with_rules` function accepts user-supplied rules that implement `LintRule`. Custom rules are applied after all built-in rules.

---

## 10. Testing Strategy

### Test Architecture

Tests are organized into four layers, corresponding to the validation system's structure:

**Layer 1: Unit tests (inline `#[cfg(test)]` modules)**

Located in the source files themselves:
- `src/validation/rules.rs` — tests for condition parsing, stylesheet validation, selector validation, bare value flagging, handler type resolution, config rules, principle warning rules
- `src/validation/condition.rs` — tests for condition expression parsing and semantic checks
- `src/validation/ast_rules.rs` — tests for passthrough matching, attribute allowlist checks, type validation helpers
- `src/model/known_models.rs` — tests for model lookup functions

**Layer 2: Graph-level integration tests (`tests/validation_tests.rs`)**

Tests each lint rule against programmatically constructed `Graph` structs (not parsed DOT). Uses a `minimal_valid_graph()` helper that builds a start→work→exit graph with default_agent set.

Testing patterns:
- **Positive test**: construct a graph that triggers the rule, assert the rule name and severity appear in diagnostics
- **Negative test**: construct a valid graph, assert the rule does NOT fire
- **Edge case tests**: multiple start nodes, start by ID not shape, exit by ID (`done`/`end`), compound conditions

**Layer 3: End-to-end tests (`tests/validation_new_rules_tests.rs`)**

Tests rules through `validate_full()` with DOT source strings. Organized into modules:

- `ast_rule_tests` — unknown attr warnings, passthrough acceptance, known attr acceptance
- `value_range_tests` — unknown shape, bad reasoning effort, unknown agent
- `semantic_tests` — type/shape mismatch, tool_command on non-tool, prompt on tool, goal_gate on non-agent, agent on non-agent, timeout on instant, allow_partial without retries
- `attr_type_tests` — integer/boolean/duration type validation errors
- `condition_tests` — semantic warnings for bad outcomes, boolean outcomes, preferred_label mismatches
- `integration_tests` — complex valid graphs, multi-issue graphs, all-phases-run verification

**Layer 4: Parse-time diagnostic tests (in `tests/validation_tests.rs`)**

Tests that `validate_full()` produces correct diagnostics for parse-level issues:
- Undirected graph (`graph G`)
- Strict modifier (`strict digraph`)
- Multiple graphs
- Syntax errors (with span verification)
- Undirected edges (`--`)

### Test Patterns

1. **Helper graph construction**: `minimal_valid_graph()` returns a known-good graph. Tests mutate it to introduce exactly one issue.

2. **Rule isolation**: Each test filters diagnostics by `rule == "rule_name"` to verify only the rule under test, ignoring diagnostics from other rules.

3. **Deterministic output**: Rules that iterate over `HashMap` values sort their results by `node_id` for deterministic test assertions.

4. **Severity verification**: Tests assert both the rule name AND the expected severity level.

5. **Message content verification**: Tests use `contains()` on messages to verify key details (node IDs, invalid values) appear in the diagnostic.

6. **Span verification**: The `unreachable_node_has_span` test verifies that diagnostics include correct source locations.

7. **Custom rule test**: Verifies the `validate_with_rules` extension point works by injecting an `AlwaysWarn` rule.

### CI Pipeline

The validation tests run in the `test` job of `.github/workflows/ci.yml`:
- `cargo fmt --check` — formatting
- `cargo clippy --tests -- -D warnings` — linting (warnings are errors)
- `cargo test` — runs all unit and integration tests
- `npm test` — runs frontend visualization tests (Vitest)

All four jobs must pass. The test job configures git user info (required by some integration tests that create commits).

