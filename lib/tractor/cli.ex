defmodule Tractor.CLI do
  @moduledoc """
  Escript entrypoint for Tractor.
  """

  # credo:disable-for-this-file Credo.Check.Refactor.Nesting

  alias Tractor.{DotParser, Run, Validator}

  @usage "Usage: tractor reap PATH [--cwd PATH] [--runs-dir PATH] [--timeout DURATION] [--serve] [--port N] [--no-open]\n       tractor reap --resume RUN_ID_OR_DIR [--runs-dir PATH] [--timeout DURATION]\n"

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case run(args) do
      {:serve, fun} ->
        fun.()

      {code, stdout, stderr} ->
        finish(code, stdout, stderr)
    end
  end

  defp finish(code, stdout, stderr) do
    unless stdout == "" do
      IO.write(stdout)
    end

    unless stderr == "" do
      IO.write(:stderr, stderr)
    end

    System.halt(code)
  end

  @spec run([String.t()]) :: {non_neg_integer(), String.t(), String.t()}
  def run(["reap", "--resume"]) do
    resume_once([resume: :latest], 300_000)
  end

  def run(["reap" | args]) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          cwd: :string,
          runs_dir: :string,
          timeout: :string,
          serve: :boolean,
          port: :integer,
          no_open: :boolean,
          resume: :string
        ],
        aliases: []
      )

    with :ok <- validate_options(invalid, positional, opts),
         {:resume, false} <- {:resume, is_binary(opts[:resume])},
         [path] <- positional,
         :ok <- ensure_file(path),
         :ok <- progress("parse: #{path}"),
         {:ok, pipeline} <- DotParser.parse_file(path),
         :ok <-
           progress(
             "parse: ok (#{map_size(pipeline.nodes)} nodes, #{length(pipeline.edges)} edges)"
           ),
         :ok <- Validator.validate(pipeline),
         :ok <- progress("validate: ok"),
         {:ok, timeout} <- timeout_ms(opts[:timeout]) do
      if opts[:serve] do
        case TractorWeb.GraphRenderer.probe_dot() do
          :ok -> {:serve, fn -> serve_reap(pipeline, opts, timeout) end}
          {:error, message} -> {2, "", message <> "\n"}
        end
      else
        run_once(pipeline, opts, timeout)
      end
    else
      {:usage, message} -> {2, "", message}
      {:missing_file, path} -> {3, "", "DOT file not found: #{path}\n"}
      {:error, diagnostics} when is_list(diagnostics) -> {10, "", format_diagnostics(diagnostics)}
      {:error, reason} -> {20, "", "agent runtime failure: #{inspect(reason)}\n"}
      {:resume, true} -> resume_once(opts, timeout_ms!(opts[:timeout]))
      _other -> {2, "", @usage}
    end
  end

  def run(["validate", path]) do
    with :ok <- ensure_file(path),
         {:ok, pipeline} <- DotParser.parse_file(path),
         warnings <- Validator.warnings(pipeline),
         :ok <- Validator.validate(pipeline) do
      warning_text = format_diagnostics(warnings)
      {0, "validate: ok\n", warning_text}
    else
      {:missing_file, path} -> {3, "", "DOT file not found: #{path}\n"}
      {:error, diagnostics} when is_list(diagnostics) -> {10, "", format_diagnostics(diagnostics)}
      {:error, reason} -> {20, "", "validation failure: #{inspect(reason)}\n"}
    end
  end

  def run(_args), do: {2, "", @usage}

  defp validate_options([], [], opts) do
    if is_binary(Keyword.get(opts, :resume)), do: :ok, else: {:usage, @usage}
  end

  defp validate_options([], [_path], opts) do
    if is_nil(Keyword.get(opts, :resume)), do: :ok, else: {:usage, @usage}
  end

  defp validate_options(invalid, _positional, _opts) when invalid != [], do: {:usage, @usage}
  defp validate_options(_invalid, _positional, _opts), do: {:usage, @usage}

  defp ensure_file(path) do
    if File.regular?(path), do: :ok, else: {:missing_file, path}
  end

  defp progress(message) do
    IO.puts(:stderr, message)
  end

  defp run_opts(opts) do
    []
    |> maybe_put(:runs_dir, opts[:runs_dir])
    |> maybe_put(:cwd, opts[:cwd])
  end

  defp run_once(pipeline, opts, timeout) do
    with {:ok, run_id} <- Run.start(pipeline, run_opts(opts)),
         :ok <- progress("run: #{run_id}"),
         {:ok, result} <- Run.await(run_id, timeout) do
      {0, result.run_dir <> "\n", ""}
    else
      {:error, reason} -> {20, "", "agent runtime failure: #{inspect(reason)}\n"}
    end
  end

  defp resume_once(opts, timeout) do
    run_dir = resolve_resume_dir(opts[:resume], opts)

    with {:ok, run_id} <- Run.resume(run_dir, run_opts(opts)),
         :ok <- progress("resume: #{run_id}"),
         {:ok, result} <- Run.await(run_id, timeout) do
      {0, result.run_dir <> "\n", ""}
    else
      {:error, :unsupported_checkpoint} ->
        {20, "", "resume failed: unsupported checkpoint schema\n"}

      {:error, :pipeline_changed} ->
        {20, "", "resume failed: pipeline graph changed since checkpoint\n"}

      {:error, :node_ids_changed} ->
        {20, "", "resume failed: node IDs changed since checkpoint\n"}

      {:error, reason} ->
        {20, "", "resume failed: #{inspect(reason)}\n"}
    end
  end

  defp resolve_resume_dir(value, opts) do
    if value == :latest do
      newest_run_dir(opts)
    else
      do_resolve_resume_dir(value, opts)
    end
  end

  defp do_resolve_resume_dir(value, opts) do
    expanded = Path.expand(value)

    if File.dir?(expanded) do
      expanded
    else
      runs_dir = opts[:runs_dir] || Path.join(Tractor.Paths.data_dir(), "runs")
      Path.join(runs_dir, value)
    end
  end

  defp newest_run_dir(opts) do
    runs_dir = opts[:runs_dir] || Path.join(Tractor.Paths.data_dir(), "runs")

    runs_dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.max_by(&File.stat!(&1).mtime, fn -> Path.join(runs_dir, "__missing__") end)
  end

  defp serve_reap(pipeline, opts, _timeout) do
    port = Keyword.get(opts, :port, 0)
    run_id = new_run_id()

    with {:ok, endpoint_pid} <-
           DynamicSupervisor.start_child(Tractor.WebSup, {TractorWeb.Server, port: port}),
         {:ok, base_url} <- server_base_url() do
      url = "#{base_url}/runs/#{run_id}"
      IO.puts(:stderr, "Serving observer at #{url}")
      maybe_open(url, opts)

      case Run.start(pipeline, Keyword.put(run_opts(opts), :run_id, run_id)) do
        {:ok, ^run_id} ->
          progress("run: #{run_id}")

          case Run.await(run_id, :infinity) do
            {:ok, result} ->
              IO.puts(result.run_dir)
              IO.puts(:stderr, "Serving post-mortem at #{url} (Ctrl-C to exit)")
              trap_sigint(endpoint_pid)
              :timer.sleep(:infinity)

            {:error, reason} ->
              Supervisor.stop(endpoint_pid)
              finish(20, "", "agent runtime failure: #{inspect(reason)}\n")
          end

        {:error, reason} ->
          Supervisor.stop(endpoint_pid)
          finish(20, "", "agent runtime failure: #{inspect(reason)}\n")
      end
    else
      {:error, message} when is_binary(message) ->
        finish(2, "", message <> "\n")

      {:error, reason} ->
        finish(2, "", "failed to start observer: #{inspect(reason)}\n")
    end
  end

  defp server_base_url do
    case TractorWeb.Endpoint.server_info(:http) do
      {:ok, {{127, 0, 0, 1}, port}} -> {:ok, "http://127.0.0.1:#{port}"}
      other -> {:error, {:unexpected_endpoint_info, other}}
    end
  end

  defp maybe_open(_url, no_open: true), do: :ok

  defp maybe_open(url, _opts) do
    Task.start(fn ->
      cond do
        match?({_, 0}, System.cmd("uname", [])) and :os.type() == {:unix, :darwin} ->
          System.cmd("open", [url], stderr_to_stdout: true)

        System.find_executable("xdg-open") ->
          System.cmd("xdg-open", [url], stderr_to_stdout: true)

        true ->
          :ok
      end
    end)

    :ok
  rescue
    _error -> :ok
  end

  defp trap_sigint(endpoint_pid) do
    System.trap_signal(:sigint, fn ->
      Supervisor.stop(endpoint_pid)
      System.halt(0)
    end)
  rescue
    _error -> :ok
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp new_run_id do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    short_id = Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)
    "#{timestamp}-#{short_id}"
  end

  defp timeout_ms(nil), do: {:ok, 300_000}

  defp timeout_ms(value) do
    case Regex.run(~r/^(\d+)(ms|s|m|h)?$/, value) do
      [_, amount, nil] -> {:ok, String.to_integer(amount)}
      [_, amount, "ms"] -> {:ok, String.to_integer(amount)}
      [_, amount, "s"] -> {:ok, String.to_integer(amount) * 1_000}
      [_, amount, "m"] -> {:ok, String.to_integer(amount) * 60_000}
      [_, amount, "h"] -> {:ok, String.to_integer(amount) * 3_600_000}
      _other -> {:usage, @usage}
    end
  end

  defp timeout_ms!(value) do
    case timeout_ms(value) do
      {:ok, timeout} -> timeout
      _other -> 300_000
    end
  end

  defp format_diagnostics(diagnostics) do
    Enum.map_join(diagnostics, "", fn diagnostic ->
      prefix = if diagnostic.severity == :warning, do: "warning ", else: ""
      "#{prefix}#{diagnostic.code}: #{diagnostic.message}\n"
    end)
  end
end
