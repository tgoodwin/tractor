# Sprint 0004 Agent Browser Notes

Confirmed CLI:

```sh
agent-browser --help
agent-browser skills get core --full
```

Current-observer smoke run used for Phase A:

```sh
mkdir -p docs/sprints/notes/sprint-0004-before tmp/sprint-0004-before-runs

MIX_ENV=dev \
TRACTOR_ACP_CODEX_COMMAND="$(command -v elixir)" \
TRACTOR_ACP_CODEX_ARGS='["--erl","-kernel logger_level emergency","-pa","/Users/tgoodwin/projects/tractor/_build/dev/lib/jason/ebin","/Users/tgoodwin/projects/tractor/test/support/fake_acp_agent.exs"]' \
TRACTOR_ACP_CODEX_ENV_JSON='{"TRACTOR_FAKE_ACP_MODE":"timeout"}' \
mix run --no-halt -e '
{:ok, pipeline} = Tractor.DotParser.parse_file("test/fixtures/dot/valid_linear.dot")
:ok = Tractor.Validator.validate(pipeline)
{:ok, _pid} = DynamicSupervisor.start_child(Tractor.WebSup, {TractorWeb.Server, port: 4404})
{:ok, run_id} = Tractor.Run.start(pipeline, runs_dir: "tmp/sprint-0004-before-runs", run_id: "sprint-0004-before")
IO.puts("URL=http://127.0.0.1:4404/runs/#{run_id}")
Process.sleep(:infinity)
'
```

Screenshot + snapshot invocation:

```sh
agent-browser --session sprint0004-before set viewport 1440 900
agent-browser --session sprint0004-before open http://127.0.0.1:4404/runs/sprint-0004-before
agent-browser --session sprint0004-before wait 1000
agent-browser --session sprint0004-before screenshot docs/sprints/notes/sprint-0004-before/current-observer-1440x900.png
agent-browser --session sprint0004-before snapshot -i -d 4
```

Captured artifact:

- `docs/sprints/notes/sprint-0004-before/current-observer-1440x900.png`

Notes:

- Use named sessions per phase (`--session sprint0004-phase-d`, etc.) so browser state is isolated.
- Set viewport before opening the page for repeatable visual checks.
- For visual checks later in the sprint, collect both a screenshot and `agent-browser console` after full runs.
