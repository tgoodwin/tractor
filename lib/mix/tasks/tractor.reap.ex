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

  alias Tractor.{DotParser, Run, Validator}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    if "--serve" in args and endpoint_running?() do
      serve_via_running_endpoint(args)
    else
      forward_to_cli(args)
    end
  end

  defp endpoint_running?, do: Process.whereis(TractorWeb.Endpoint) != nil

  defp serve_via_running_endpoint(args) do
    {opts, positional} = parse_reap_opts(args)

    with [path] <- positional,
         :ok <- ensure_file(path),
         {:ok, pipeline} <- DotParser.parse_file(path),
         :ok <- Validator.validate(pipeline),
         {:ok, run_id} <- Run.start(pipeline, run_opts(opts)) do
      url = "#{endpoint_base_url()}/runs/#{run_id}"
      Mix.shell().info([:green, "observer: ", :bright, url, :reset])
      maybe_open(url, opts)

      case Run.await(run_id, :infinity) do
        {:ok, result} ->
          Mix.shell().info(result.run_dir)
          Mix.shell().info([:faint, "post-mortem at #{url} (Ctrl-C to exit)", :reset])
          Process.sleep(:infinity)

        {:error, reason} ->
          Mix.shell().error("agent runtime failure: #{inspect(reason)}")
          exit({:shutdown, 20})
      end
    else
      [] ->
        Mix.shell().error("missing DOT path")
        exit({:shutdown, 2})

      {:missing_file, path} ->
        Mix.shell().error("DOT file not found: #{path}")
        exit({:shutdown, 3})

      {:error, diagnostics} when is_list(diagnostics) ->
        Mix.shell().error(Enum.map_join(diagnostics, "\n", & &1.message))
        exit({:shutdown, 10})

      {:error, reason} ->
        Mix.shell().error("failure: #{inspect(reason)}")
        exit({:shutdown, 20})
    end
  end

  defp forward_to_cli(args) do
    case Tractor.CLI.run(["reap" | args]) do
      {:serve, fun} ->
        fun.()

      {code, stdout, stderr} ->
        unless stdout == "", do: IO.write(stdout)
        unless stderr == "", do: IO.write(:stderr, stderr)
        if code != 0, do: exit({:shutdown, code})
    end
  end

  defp parse_reap_opts(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          cwd: :string,
          runs_dir: :string,
          timeout: :string,
          serve: :boolean,
          port: :integer,
          no_open: :boolean
        ]
      )

    {opts, positional}
  end

  defp run_opts(opts) do
    []
    |> maybe_put(:runs_dir, opts[:runs_dir])
    |> maybe_put(:cwd, opts[:cwd])
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp ensure_file(path), do: if(File.regular?(path), do: :ok, else: {:missing_file, path})

  defp endpoint_base_url do
    case TractorWeb.Endpoint.server_info(:http) do
      {:ok, {{127, 0, 0, 1}, port}} -> "http://127.0.0.1:#{port}"
      _other -> TractorWeb.Endpoint.url()
    end
  end

  defp maybe_open(_url, %{no_open: true}), do: :ok
  defp maybe_open(url, opts), do: do_open(url, opts[:no_open])

  defp do_open(_url, true), do: :ok

  defp do_open(url, _no_open) do
    case opener() do
      nil -> :ok
      cmd -> spawn(fn -> System.cmd(cmd, [url], stderr_to_stdout: true) end) && :ok
    end
  end

  defp opener do
    case :os.type() do
      {:unix, :darwin} -> "open"
      {:unix, _} -> "xdg-open"
      _ -> nil
    end
  end
end
