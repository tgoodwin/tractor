defmodule Tractor.CLI do
  @moduledoc """
  Escript entrypoint for Tractor.
  """

  alias Tractor.{DotParser, Run, Validator}

  @usage "Usage: tractor reap PATH [--cwd PATH] [--runs-dir PATH] [--timeout DURATION]\n"

  @spec main([String.t()]) :: no_return()
  def main(args) do
    {code, stdout, stderr} = run(args)

    unless stdout == "" do
      IO.write(stdout)
    end

    unless stderr == "" do
      IO.write(:stderr, stderr)
    end

    System.halt(code)
  end

  @spec run([String.t()]) :: {non_neg_integer(), String.t(), String.t()}
  def run(["reap" | args]) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [cwd: :string, runs_dir: :string, timeout: :string],
        aliases: []
      )

    with :ok <- validate_options(invalid, positional),
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
         {:ok, run_id} <- Run.start(pipeline, run_opts(opts)),
         :ok <- progress("run: #{run_id}"),
         {:ok, timeout} <- timeout_ms(opts[:timeout]),
         {:ok, result} <- Run.await(run_id, timeout) do
      {0, result.run_dir <> "\n", ""}
    else
      {:usage, message} -> {2, "", message}
      {:missing_file, path} -> {3, "", "DOT file not found: #{path}\n"}
      {:error, diagnostics} when is_list(diagnostics) -> {10, "", format_diagnostics(diagnostics)}
      {:error, reason} -> {20, "", "agent runtime failure: #{inspect(reason)}\n"}
      _other -> {2, "", @usage}
    end
  end

  def run(_args), do: {2, "", @usage}

  defp validate_options([], [_path]), do: :ok
  defp validate_options(invalid, _positional) when invalid != [], do: {:usage, @usage}
  defp validate_options(_invalid, _positional), do: {:usage, @usage}

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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

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

  defp format_diagnostics(diagnostics) do
    Enum.map_join(diagnostics, "", fn diagnostic ->
      "#{diagnostic.code}: #{diagnostic.message}\n"
    end)
  end
end
