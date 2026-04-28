defmodule Tractor.CLI do
  @moduledoc """
  Escript entrypoint for Tractor.

  Exit codes:
  - `0` success
  - `2` usage / observer boot preflight failure
  - `3` DOT file missing
  - `4` requested `--port` is busy with a non-Tractor process
  - `5` adopted observer disappeared before the run could start
  - `6` observer `runs_dir` does not match the CLI `--runs-dir`
  - `10` validation failure
  - `20` runtime failure
  """

  # credo:disable-for-this-file Credo.Check.Refactor.Nesting

  alias Tractor.{Diagnostic.Formatter, Init, Run, Validator}

  @probe_timeout_ms 500
  @usage "Usage: tractor reap PATH [--cwd PATH] [--runs-dir PATH] [--timeout DURATION] [--serve] [--port N] [--no-open]\n       tractor reap --resume RUN_ID_OR_DIR [--runs-dir PATH] [--timeout DURATION]\n       tractor validate PATH\n       tractor init [claude|codex|gemini] [--force]\n"

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

  @spec run([String.t()]) ::
          {:serve, (-> no_return())} | {non_neg_integer(), String.t(), String.t()}
  def run(["reap", "--resume"]) do
    resume_once(normalize_opts(resume: :latest), 300_000)
  end

  def run(["reap" | args]) do
    {parsed_opts, positional, invalid} =
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

    opts = normalize_opts(parsed_opts)

    with :ok <- validate_options(invalid, positional, opts),
         {:resume, false} <- {:resume, is_binary(opts[:resume])},
         [path_input] <- positional,
         path = Path.expand(path_input),
         :ok <- ensure_file(path),
         :ok <- progress("parse: #{path}"),
         {:ok, pipeline, diagnostics} <- Validator.validate_path(path),
         :ok <-
           progress(
             "parse: ok (#{map_size(pipeline.nodes)} nodes, #{length(pipeline.edges)} edges)"
           ),
         :ok <- maybe_progress_validation(diagnostics),
         {:ok, timeout} <- timeout_ms(opts[:timeout]) do
      opts = Keyword.put(opts, :dot_path_input, path_input)
      validation_output = format_diagnostics(diagnostics)

      if opts[:serve] do
        case TractorWeb.GraphRenderer.probe_dot() do
          :ok ->
            unless validation_output == "" do
              IO.write(:stderr, validation_output)
            end

            {:serve, fn -> serve_reap(pipeline, opts, timeout) end}

          {:error, message} -> {2, "", message <> "\n"}
        end
      else
        run_once(pipeline, opts, timeout, validation_output)
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

  def run(["init" | args]) do
    {parsed, positional, invalid} =
      OptionParser.parse(args, strict: [force: :boolean], aliases: [])

    cond do
      invalid != [] ->
        {2, "", @usage}

      length(positional) > 1 ->
        {2, "", @usage}

      true ->
        run_init(positional, Keyword.get(parsed, :force, false))
    end
  end

  def run(["validate", path_input]) do
    path = Path.expand(path_input)

    with :ok <- ensure_file(path),
         result <- Validator.validate_path(path) do
      validate_result(result)
    else
      {:missing_file, path} -> {3, "", "DOT file not found: #{path}\n"}
      {:error, reason} -> {20, "", "validation failure: #{inspect(reason)}\n"}
    end
  end

  def run(_args), do: {2, "", @usage}

  @spec probe_observer(keyword()) ::
          :own
          | {:adopt, map()}
          | {:error, :port_conflict | :runs_dir_mismatch, map()}
  def probe_observer(opts) do
    port = Keyword.fetch!(opts, :port)
    runs_dir = Keyword.fetch!(opts, :runs_dir)

    if port == 0 do
      :own
    else
      :ok = ensure_httpc_started()
      url = ~c"http://127.0.0.1:" ++ Integer.to_charlist(port) ++ ~c"/api/health"

      case :httpc.request(
             :get,
             {url, []},
             [connect_timeout: @probe_timeout_ms, timeout: @probe_timeout_ms],
             body_format: :binary
           ) do
        {:ok, {{_http_version, 200, _reason}, _headers, body}} ->
          decode_probe_response(body, port, runs_dir)

        {:ok, {{_http_version, status, _reason}, _headers, _body}} ->
          {:error, :port_conflict, %{port: port, status: status}}

        {:error, reason} ->
          classify_probe_error(reason, port)
      end
    end
  end

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

  defp normalize_opts(opts) do
    opts
    |> normalize_path_opt(:cwd)
    |> normalize_path_opt(:runs_dir)
    |> Keyword.put_new(:runs_dir, Tractor.Paths.runs_dir())
  end

  defp normalize_path_opt(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) -> Keyword.put(opts, key, Path.expand(value))
      _other -> opts
    end
  end

  defp run_opts(opts) do
    []
    |> maybe_put(:runs_dir, opts[:runs_dir])
    |> maybe_put(:cwd, opts[:cwd])
    |> maybe_put(:dot_path_input, opts[:dot_path_input])
  end

  defp run_once(pipeline, opts, timeout, validation_output) do
    with {:ok, run_id} <- Run.start(pipeline, run_opts(opts)),
         :ok <- progress("run: #{run_id}"),
         {:ok, result} <- Run.await(run_id, timeout) do
      {0, result.run_dir <> "\n", validation_output}
    else
      {:error, reason} ->
        {20, "", validation_output <> "agent runtime failure: #{inspect(reason)}\n"}
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
      Path.join(opts[:runs_dir] || Tractor.Paths.runs_dir(), value)
    end
  end

  defp newest_run_dir(opts) do
    runs_dir = opts[:runs_dir] || Tractor.Paths.runs_dir()

    runs_dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.max_by(&File.stat!(&1).mtime, fn -> Path.join(runs_dir, "__missing__") end)
  end

  defp serve_reap(pipeline, opts, _timeout) do
    port = Keyword.get(opts, :port, 4000)
    run_id = new_run_id()

    case probe_observer(port: port, runs_dir: opts[:runs_dir]) do
      {:adopt, observer} ->
        case probe_observer(port: port, runs_dir: opts[:runs_dir]) do
          {:adopt, _confirmed} ->
            run_with_observer(pipeline, opts, run_id, observer, :adopt, nil)

          _other ->
            finish(5, "", "observer on port #{port} disappeared before the run could start\n")
        end

      :own ->
        own_observer(pipeline, opts, run_id, port)

      {:error, :runs_dir_mismatch, %{expected: expected, observed: observed, port: port}} ->
        finish(
          6,
          "",
          "observer runs_dir mismatch on port #{port}: expected #{expected}, got #{observed}\n"
        )

      {:error, :port_conflict, %{port: port}} ->
        finish(
          4,
          "",
          "port #{port} busy, not a tractor observer; pass `--port N` or stop the other process.\n"
        )
    end
  end

  defp own_observer(pipeline, opts, run_id, port) do
    with {:ok, endpoint_pid} <-
           DynamicSupervisor.start_child(
             Tractor.WebSup,
             {TractorWeb.Server, port: port, runs_dir: opts[:runs_dir]}
           ),
         {:ok, base_url} <- server_base_url() do
      observer = %{base_url: base_url, port: port}
      run_with_observer(pipeline, opts, run_id, observer, :own, endpoint_pid)
    else
      {:error, message} when is_binary(message) ->
        finish(2, "", message <> "\n")

      {:error, reason} ->
        finish(2, "", "failed to start observer: #{inspect(reason)}\n")
    end
  end

  defp run_with_observer(pipeline, opts, run_id, observer, mode, endpoint_pid) do
    url = "#{observer.base_url}/runs/#{run_id}"
    announce_observer(mode, url)
    maybe_open(url, opts)

    case Run.start(pipeline, run_opts(opts) |> Keyword.put(:run_id, run_id)) do
      {:ok, ^run_id} ->
        progress("run: #{run_id}")

        case Run.await(run_id, :infinity) do
          {:ok, result} ->
            stop_observer(endpoint_pid)
            finish(0, result.run_dir <> "\n", "")

          {:error, reason} ->
            stop_observer(endpoint_pid)
            finish(20, "", "agent runtime failure: #{inspect(reason)}\n")
        end

      {:error, reason} ->
        stop_observer(endpoint_pid)
        finish(20, "", "agent runtime failure: #{inspect(reason)}\n")
    end
  end

  defp announce_observer(:adopt, url), do: IO.puts(:stderr, "adopting observer at #{url}")
  defp announce_observer(:own, url), do: IO.puts(:stderr, "serving observer at #{url}")

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

  defp ensure_httpc_started do
    case Application.ensure_all_started(:inets) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise "failed to start :inets for observer probe: #{inspect(reason)}"
    end
  end

  defp decode_probe_response(body, port, expected_runs_dir) do
    with {:ok, json} <- Jason.decode(body),
         true <- json["ok"] == true,
         observed_runs_dir when is_binary(observed_runs_dir) <- json["runs_dir"] do
      observed_runs_dir = Path.expand(observed_runs_dir)

      if observed_runs_dir == expected_runs_dir do
        {:adopt,
         %{
           base_url: "http://127.0.0.1:#{port}",
           port: port,
           runs_dir: observed_runs_dir,
           version: to_string(json["version"] || "")
         }}
      else
        {:error, :runs_dir_mismatch,
         %{port: port, expected: expected_runs_dir, observed: observed_runs_dir}}
      end
    else
      _other -> {:error, :port_conflict, %{port: port}}
    end
  end

  defp classify_probe_error(reason, port) do
    if connection_refused?(reason) do
      :own
    else
      {:error, :port_conflict, %{port: port, reason: reason}}
    end
  end

  defp connection_refused?(reason) do
    inspect(reason) =~ "econnrefused"
  end

  defp stop_observer(nil), do: :ok

  defp stop_observer(endpoint_pid) when is_pid(endpoint_pid) do
    if Process.alive?(endpoint_pid) do
      try do
        Supervisor.stop(endpoint_pid)
      catch
        :exit, _reason -> :ok
      end
    else
      :ok
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp new_run_id, do: Tractor.Paths.new_run_id()

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

  defp validate_result({:ok, _pipeline, []}), do: {0, "No issues found.\n", ""}

  defp validate_result({:ok, _pipeline, diagnostics}) do
    {if(has_errors?(diagnostics), do: 10, else: 0), render_validate_output(diagnostics), ""}
  end

  defp validate_result({:error, diagnostics}) when is_list(diagnostics) do
    {10, render_validate_output(diagnostics), ""}
  end

  defp maybe_progress_validation(diagnostics) do
    if has_errors?(diagnostics) do
      {:error, diagnostics}
    else
      progress("validate: ok")
    end
  end

  defp render_validate_output(diagnostics) do
    format_diagnostics(diagnostics) <> diagnostic_summary(diagnostics)
  end

  defp diagnostic_summary(diagnostics) do
    error_count = Enum.count(diagnostics, &(&1.severity == :error))
    warning_count = Enum.count(diagnostics, &(&1.severity == :warning))
    "#{length(diagnostics)} diagnostic(s): #{error_count} error(s), #{warning_count} warning(s)\n"
  end

  defp has_errors?(diagnostics), do: Enum.any?(diagnostics, &(&1.severity == :error))

  defp format_diagnostics(diagnostics) do
    Formatter.format(diagnostics)
  end

  defp run_init(positional, force?) do
    target_root = File.cwd!()

    case resolve_init_agent(positional) do
      {:ok, agent} -> do_install(agent, target_root, force?)
      {:error, :no_tty} -> {2, "", "tractor init needs an agent (claude|codex|gemini)\n"}
      {:error, {:unknown_agent, agent}} -> {2, "", unknown_agent_message(agent)}
    end
  end

  defp resolve_init_agent([agent]) do
    if agent in Init.supported_agents(),
      do: {:ok, agent},
      else: {:error, {:unknown_agent, agent}}
  end

  defp resolve_init_agent([]), do: prompt_for_agent()

  defp prompt_for_agent do
    IO.write("Install create-pipeline skill for which agent? [claude|codex|gemini] ")

    case IO.gets("") do
      :eof ->
        {:error, :no_tty}

      {:error, _reason} ->
        {:error, :no_tty}

      input when is_binary(input) ->
        normalized = input |> String.trim() |> String.downcase()

        if normalized in Init.supported_agents(),
          do: {:ok, normalized},
          else: {:error, {:unknown_agent, normalized}}
    end
  end

  defp do_install(agent, target_root, force?) do
    case Init.install(agent, target_root, force: force?) do
      {:ok, paths} ->
        bundle_dir = Init.bundle_dir(agent, target_root)
        relative = Path.relative_to_cwd(bundle_dir)

        body = [
          "Installed create-pipeline skill for #{agent} at #{relative}/\n"
          | Enum.map(paths, fn path -> "  #{Path.relative_to(path, bundle_dir)}\n" end)
        ]

        {0, IO.iodata_to_binary(body), ""}

      {:error, {:bundle_exists, dir}} ->
        relative = Path.relative_to_cwd(dir)

        {2, "",
         "create-pipeline skill already installed at #{relative}/ — pass --force to overwrite\n"}

      {:error, {:write_failed, path, reason}} ->
        {20, "", "failed to write #{path}: #{inspect(reason)}\n"}

      {:error, {:unknown_agent, agent}} ->
        {2, "", unknown_agent_message(agent)}
    end
  end

  defp unknown_agent_message(agent) do
    supported = Enum.join(Init.supported_agents(), "|")
    "unknown agent #{inspect(agent)} — must be one of: #{supported}\n"
  end
end
