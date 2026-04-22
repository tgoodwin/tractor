defmodule Mix.Tasks.Tractor.Reap do
  @shortdoc "Run a Tractor pipeline in the current Mix env (dev = live-reload observer)"

  @moduledoc """
  Mix-task counterpart to `bin/tractor reap`. Runs under the current Mix env so
  `config/dev.exs` applies — meaning the observer boots with `code_reloader`,
  `live_reload`, and `debug_errors` enabled.

      mix tractor.reap examples/haiku_feedback.dot --serve
      mix tractor.reap --resume LATEST --runs-dir /tmp/runs

  In dev, the OTP app already boots `TractorWeb.Endpoint` on app start. If the
  endpoint is already up and `--serve` was passed, this task reuses it (no
  second endpoint spawn, no port conflict) and opens the run URL against the
  running server. Otherwise the call is forwarded verbatim to
  `Tractor.CLI.run(["reap" | args])`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case Tractor.CLI.run(["reap" | args]) do
      {:serve, fun} ->
        fun.()

      {code, stdout, stderr} ->
        unless stdout == "", do: IO.write(stdout)
        unless stderr == "", do: IO.write(:stderr, stderr)
        if code != 0, do: exit({:shutdown, code})
    end
  end
end
