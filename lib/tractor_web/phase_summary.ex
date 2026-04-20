defmodule TractorWeb.PhaseSummary do
  @moduledoc """
  Derives the six attractor-spec execution-lifecycle phases for a single run
  from its on-disk artifacts: `manifest.json` + per-node `status.json` +
  `events.jsonl` streams.

  The engine does not currently emit explicit phase events, so PARSE,
  TRANSFORM, and VALIDATE lack timings — they just report "ok" when the run
  got far enough for a manifest to exist. INITIALIZE, EXECUTE, and FINALIZE
  derive timings from observable data.

  The spec's six phases are:
    PARSE → TRANSFORM → VALIDATE → INITIALIZE → EXECUTE → FINALIZE
  """

  alias TractorWeb.Format

  @type phase_status :: :ok | :running | :failed | :pending | :skipped

  @type phase :: %{
          name: String.t(),
          status: phase_status(),
          duration_ms: non_neg_integer() | nil,
          note: String.t() | nil
        }

  @phase_order ~w(PARSE TRANSFORM VALIDATE INITIALIZE EXECUTE FINALIZE)

  @spec summarize(Path.t()) :: [phase()]
  def summarize(run_dir) do
    manifest = read_manifest(run_dir)
    node_stats = read_node_stats(run_dir)

    started_at = parse_ts(manifest["started_at"])
    finished_at = parse_ts(manifest["finished_at"])
    first_node_started_at = first_node_started(node_stats)
    last_node_finished_at = last_node_finished(node_stats)
    overall_status = manifest["status"]

    %{
      started_at: started_at,
      finished_at: finished_at,
      first_node_started_at: first_node_started_at,
      last_node_finished_at: last_node_finished_at,
      overall: overall_status,
      any_node_started?: not is_nil(first_node_started_at),
      any_failed?: Enum.any?(node_stats, &(&1.status == "failed")),
      manifest_exists?: manifest != %{}
    }
    |> build_phases()
  end

  @spec phase_duration(phase()) :: String.t()
  def phase_duration(%{duration_ms: nil}), do: "—"
  def phase_duration(%{duration_ms: ms}), do: Format.duration_ms(ms)

  @spec phase_status_label(phase()) :: String.t()
  def phase_status_label(%{status: :ok}), do: "ok"
  def phase_status_label(%{status: :running}), do: "running"
  def phase_status_label(%{status: :failed}), do: "failed"
  def phase_status_label(%{status: :pending}), do: "pending"
  def phase_status_label(%{status: :skipped}), do: "—"

  defp build_phases(ctx) do
    @phase_order
    |> Enum.map(&build_phase(&1, ctx))
  end

  defp build_phase("PARSE", ctx), do: preflight_phase("PARSE", ctx)
  defp build_phase("TRANSFORM", ctx), do: preflight_phase("TRANSFORM", ctx)
  defp build_phase("VALIDATE", ctx), do: preflight_phase("VALIDATE", ctx)

  defp build_phase("INITIALIZE", ctx) do
    status =
      cond do
        not ctx.manifest_exists? -> :pending
        ctx.any_node_started? -> :ok
        ctx.overall == "error" -> :failed
        true -> :running
      end

    %{
      name: "INITIALIZE",
      status: status,
      duration_ms: duration_between(ctx.started_at, ctx.first_node_started_at),
      note: nil
    }
  end

  defp build_phase("EXECUTE", ctx) do
    status =
      cond do
        not ctx.any_node_started? -> :pending
        ctx.any_failed? -> :failed
        not is_nil(ctx.last_node_finished_at) -> :ok
        true -> :running
      end

    duration =
      duration_between(ctx.first_node_started_at, ctx.last_node_finished_at || DateTime.utc_now())

    %{name: "EXECUTE", status: status, duration_ms: duration, note: nil}
  end

  defp build_phase("FINALIZE", ctx) do
    status =
      cond do
        is_nil(ctx.last_node_finished_at) -> :pending
        is_nil(ctx.finished_at) -> :running
        ctx.overall == "error" -> :failed
        true -> :ok
      end

    %{
      name: "FINALIZE",
      status: status,
      duration_ms: duration_between(ctx.last_node_finished_at, ctx.finished_at),
      note: nil
    }
  end

  defp preflight_phase(name, ctx) do
    status =
      cond do
        ctx.manifest_exists? -> :ok
        true -> :pending
      end

    %{name: name, status: status, duration_ms: nil, note: nil}
  end

  defp duration_between(%DateTime{} = a, %DateTime{} = b) do
    DateTime.diff(b, a, :millisecond) |> max(0)
  end

  defp duration_between(_a, _b), do: nil

  defp read_manifest(run_dir) do
    path = Path.join(run_dir, "manifest.json")

    with true <- File.exists?(path),
         {:ok, data} <- File.read(path),
         {:ok, manifest} <- Jason.decode(data) do
      manifest
    else
      _ -> %{}
    end
  end

  defp read_node_stats(run_dir) do
    case File.ls(run_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(run_dir, &1)))
        |> Enum.map(&node_stat(run_dir, &1))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp node_stat(run_dir, node_id) do
    status_path = Path.join([run_dir, node_id, "status.json"])

    with true <- File.exists?(status_path),
         {:ok, raw} <- File.read(status_path),
         {:ok, status} <- Jason.decode(raw) do
      %{
        node_id: node_id,
        status: status["status"],
        started_at: parse_ts(status["started_at"]),
        finished_at: parse_ts(status["finished_at"])
      }
    else
      _ -> nil
    end
  end

  defp first_node_started(stats) do
    stats
    |> Enum.map(& &1.started_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp last_node_finished(stats) do
    stats
    |> Enum.map(& &1.finished_at)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      list -> Enum.max(list, DateTime)
    end
  end

  defp parse_ts(nil), do: nil

  defp parse_ts(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end
end
