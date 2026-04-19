# Sprint 0004 Observer Refresh

## Goals

- [x] Keep Sprint-1 CLI behavior intact.
- [x] Capture ACP token usage from updates and prompt results.
- [x] Move runtime graph state to the `GraphBoard` hook.
- [x] Add pan/zoom without a build pipeline.
- [x] Render the observer shell with a cool neutral cutting-mat surface.
- [x] Replace node sidebar fragments with a streamed timeline.
- [x] Render browser-side duration and token badges on completed graph nodes.
- [x] Add keyboard/accessibility polish for the graph and timeline.

## Demo

![Sprint 0004 demo](docs/sprints/notes/sprint-0004-demo.gif)

## Flagged Choices

- Palette hex values: the shell uses `#f1f3f1` surface, `#e8ece8` rail, `#252a25` dividers, muted green grid rgba values, and `#d97706` as the only live amber accent.
- Tool-call formatting style: tags are text-only (`[READ]`, `[EDIT]`, `[WRITE]`, `[BASH]`, `[GREP]`, `[GLOB]`, `[FETCH]`, `[TOOL]`) with concise summaries and raw JSON in expanded timeline bodies.
- Badge placement heuristic: badges are two-line labels centered above each Graphviz node, measured with `getBBox()` while the badge group is temporarily hidden to avoid placement drift.
