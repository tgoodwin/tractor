defmodule Mix.Tasks.Tractor.CheckEncoding do
  @moduledoc """
  Fails when production code calls Jason or Phoenix.LiveView push_event/3
  outside the sanitizing boundary modules.

  Enforced after SPRINT-0015 phase B. Two rules:

  - **Jason boundary**: `Jason.encode!`, `Jason.encode_to_iodata!`,
    `Jason.encode/1`, and `Jason.encode_to_iodata/1` may only appear inside
    `lib/tractor/json.ex`. All other production code MUST go through
    `Tractor.JSON.encode!/2` or `Tractor.JSON.encode_to_iodata!/2`.

  - **LiveView push boundary**: `Phoenix.LiveView.push_event/3` (fully
    qualified) may only appear inside `lib/tractor_web/safe_push.ex`. Any
    LiveView module that uses the unqualified `push_event(...)` form must
    also `import TractorWeb.SafePush, only: [push_event: 3]` so the call
    routes through the sanitizer.

  Run as part of CI alongside `mix compile --warnings-as-errors` and `mix
  test`. Exit code is non-zero on violation; offending lines are printed.
  """

  use Mix.Task

  @shortdoc "Enforce Tractor.JSON / TractorWeb.SafePush boundaries"

  @jason_allowlist ["lib/tractor/json.ex"]
  @push_event_allowlist ["lib/tractor_web/safe_push.ex"]
  @lib_roots ["lib/tractor", "lib/tractor_web"]

  @impl Mix.Task
  def run(_args) do
    violations =
      []
      |> check_jason_callers()
      |> check_phoenix_push_callers()
      |> check_unqualified_push_event_imports()

    case violations do
      [] ->
        :ok

      _ ->
        IO.puts(:stderr, "\nmix tractor.check_encoding: violations found\n")
        Enum.each(violations, &IO.puts(:stderr, "  " <> &1))
        IO.puts(:stderr, "")
        Mix.raise("encoding/push_event boundary violated; see above")
    end
  end

  defp check_jason_callers(acc) do
    pattern = ~r/Jason\.encode(_to_iodata)?!?\(/

    files = production_files()

    Enum.reduce(files, acc, fn path, acc ->
      if path in @jason_allowlist do
        acc
      else
        scan_lines(path, pattern, "calls Jason.encode* directly; use Tractor.JSON") ++ acc
      end
    end)
  end

  defp check_phoenix_push_callers(acc) do
    pattern = ~r/Phoenix\.LiveView\.push_event\(/

    Enum.reduce(production_files(), acc, fn path, acc ->
      if path in @push_event_allowlist do
        acc
      else
        scan_lines(
          path,
          pattern,
          "calls Phoenix.LiveView.push_event/3 directly; use TractorWeb.SafePush"
        ) ++ acc
      end
    end)
  end

  defp check_unqualified_push_event_imports(acc) do
    pattern = ~r/(^|\s)push_event\(/

    Enum.reduce(production_files(), acc, fn path, acc ->
      if path in @push_event_allowlist or not File.exists?(path) do
        acc
      else
        source = File.read!(path)
        calls = Regex.scan(pattern, source)

        cond do
          calls == [] ->
            acc

          String.contains?(source, "import TractorWeb.SafePush") ->
            acc

          true ->
            ["#{path}: unqualified push_event/3 without `import TractorWeb.SafePush`"] ++ acc
        end
      end
    end)
  end

  defp production_files do
    @lib_roots
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp scan_lines(path, pattern, label) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, n} ->
        if Regex.match?(pattern, line) do
          ["#{path}:#{n}: #{label}: #{String.trim(line)}"]
        else
          []
        end
      end)
    else
      []
    end
  end
end
