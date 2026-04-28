defmodule TractorWeb.RunIndex do
  @moduledoc """
  Reads the list of runs under a data directory for the left-side navigator.

  Each entry mirrors a subdirectory of `<data_dir>/runs/` whose `manifest.json`
  could be parsed. Runs are sorted newest-first by `started_at`.
  """

  alias TractorWeb.Format

  @type status :: :running | :completed | :errored | :goal_gate_failed | :interrupted | :unknown

  @type entry :: %{
          run_id: String.t(),
          run_dir: Path.t(),
          pipeline_name: String.t(),
          pipeline_path: String.t(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil,
          status: status()
        }

  @spec list(Path.t()) :: [entry()]
  def list(runs_dir) do
    case File.ls(runs_dir) do
      {:ok, names} ->
        names
        |> Enum.map(&entry_for(runs_dir, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

      _ ->
        []
    end
  end

  @spec duration_label(entry()) :: String.t()
  def duration_label(%{duration_ms: nil}), do: "—"
  def duration_label(%{duration_ms: ms}), do: Format.duration_ms(ms)

  @spec status_label(status()) :: String.t()
  def status_label(:running), do: "running"
  def status_label(:completed), do: "completed"
  def status_label(:errored), do: "errored"
  def status_label(:goal_gate_failed), do: "goal gate failed"
  def status_label(:interrupted), do: "interrupted"
  def status_label(:unknown), do: "unknown"

  defp entry_for(runs_dir, name) do
    run_dir = Path.join(runs_dir, name)
    manifest_path = Path.join(run_dir, "manifest.json")

    with true <- File.dir?(run_dir),
         {:ok, raw} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(raw) do
      started_at = parse_ts(manifest["started_at"])
      finished_at = parse_ts(manifest["finished_at"])

      %{
        run_id: manifest["run_id"] || name,
        run_dir: run_dir,
        pipeline_path: manifest["dot_path_input"] || manifest["pipeline_path"] || "",
        pipeline_name: pipeline_name(manifest["dot_path_input"] || manifest["pipeline_path"]),
        started_at: started_at,
        finished_at: finished_at,
        duration_ms: duration_ms(started_at, finished_at),
        status: classify_status(manifest, finished_at, run_dir)
      }
    else
      _ -> nil
    end
  end

  defp pipeline_name(nil), do: "unknown"
  defp pipeline_name(""), do: "unknown"

  defp pipeline_name(path) do
    path |> Path.basename() |> Path.rootname()
  end

  defp parse_ts(nil), do: nil

  defp parse_ts(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp duration_ms(%DateTime{} = started, %DateTime{} = finished) do
    DateTime.diff(finished, started, :millisecond) |> max(0)
  end

  defp duration_ms(_started, _finished), do: nil

  # Manifest "status" after finalize: "ok" | "error" | "running" | "interrupted".
  # When manifest still says "running" but no node is waiting and the manifest
  # hasn't been touched in a while, the run died silently. We disambiguate
  # `:interrupted` (operator-initiated SIGINT) from `:errored` (crash / silent
  # failure) by reading the `_run` event log: only an explicit run_interrupted
  # event earns the :interrupted label. Everything else is a failure.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp classify_status(manifest, finished_at, run_dir) do
    case {manifest["status"], finished_at} do
      {"ok", _} ->
        :completed

      {"error", _} ->
        :errored

      {"goal_gate_failed", _} ->
        :goal_gate_failed

      {"interrupted", _} ->
        :interrupted

      {"running", nil} ->
        cond do
          any_waiting_node?(run_dir) -> :running
          stale_run?(run_dir) -> classify_stale_run(run_dir)
          true -> :running
        end

      {"running", %DateTime{}} ->
        :completed

      {nil, _} ->
        :unknown

      _ ->
        :unknown
    end
  end

  defp classify_stale_run(run_dir) do
    case terminal_run_event(run_dir) do
      :run_interrupted -> :interrupted
      :run_completed -> :completed
      # `run_failed` or no terminal event at all both mean the run did not end
      # cleanly; surface it as an error so the operator notices.
      _ -> :errored
    end
  end

  defp terminal_run_event(run_dir) do
    path = Path.join([run_dir, "_run", "events.jsonl"])

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.reduce(nil, fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{"kind" => "run_interrupted"}} -> :run_interrupted
          {:ok, %{"kind" => "run_failed"}} -> :run_failed
          {:ok, %{"kind" => "run_completed"}} -> :run_completed
          _ -> acc
        end
      end)
    end
  end

  defp stale_run?(run_dir) do
    manifest = Path.join(run_dir, "manifest.json")

    case File.stat(manifest, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        System.system_time(:second) - mtime > 30

      _ ->
        true
    end
  end

  # A wait.human node intentionally idles on disk while blocked for operator
  # input. Treat any node with `status: "waiting"` as a signal that the run
  # is alive but suspended, so the run index doesn't mark it `:interrupted`.
  defp any_waiting_node?(run_dir) do
    case File.ls(run_dir) do
      {:ok, entries} ->
        Enum.any?(entries, fn entry ->
          path = Path.join([run_dir, entry, "status.json"])

          with true <- File.regular?(path),
               {:ok, body} <- File.read(path),
               {:ok, json} <- Jason.decode(body) do
            json["status"] == "waiting"
          else
            _ -> false
          end
        end)

      _ ->
        false
    end
  end
end
