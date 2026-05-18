defmodule Tractor.RunWatcher.Reconcile do
  @moduledoc false

  alias Tractor.RunStore

  @alive_cache_ms 5_000
  @alive_cache_table __MODULE__.AliveCache
  @pidfile_grace_seconds 30

  @spec reconcile_dead_runs(Path.t()) :: [{String.t(), Path.t(), String.t()}]
  def reconcile_dead_runs(runs_dir) do
    runs_dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&load_running_store/1)
    |> Enum.flat_map(fn store ->
      case dead_owner(store) do
        {:dead, reason, owner_pid} ->
          mark_reconciled!(store, reason, owner_pid)
          [{store.run_id, store.run_dir, reason}]

        :alive ->
          []
      end
    end)
  end

  @spec alive?(term()) :: boolean()
  def alive?(os_pid) when is_integer(os_pid) and os_pid > 0 do
    now_ms = System.monotonic_time(:millisecond)

    case cached_alive?(os_pid, now_ms) do
      {:ok, alive?} ->
        alive?

      :miss ->
        {_output, status} =
          System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

        alive? = status == 0
        :ets.insert(cache_table(), {os_pid, alive?, now_ms})
        alive?
    end
  rescue
    _error -> false
  end

  def alive?(_os_pid), do: false

  @spec mark_reconciled!(RunStore.t(), String.t()) :: :ok
  def mark_reconciled!(%RunStore{} = store, reason) when is_binary(reason) do
    owner_pid =
      case read_pidfile(store.run_dir) do
        {:ok, %{"os_pid" => os_pid}} when is_integer(os_pid) -> os_pid
        _other -> nil
      end

    mark_reconciled!(store, reason, owner_pid)
  end

  defp mark_reconciled!(%RunStore{} = store, reason, owner_pid) do
    # A reconciled run is one whose orchestrator (tractor reap) died without
    # finalizing — Ctrl-C, parent SIGTERM, hard crash. Nodes didn't fail; the
    # supervisor went away. That's interrupted, not errored.
    Tractor.Run.finalize(store, %{
      status: "interrupted",
      reason: reason,
      source: :reconciler,
      owner_pid: owner_pid
    })
  end

  defp load_running_store(run_dir) do
    with {:ok, raw} <- File.read(Path.join(run_dir, "manifest.json")),
         {:ok, manifest} <- Jason.decode(raw),
         true <- running_manifest?(manifest) do
      [
        %RunStore{
          run_id: manifest["run_id"] || Path.basename(run_dir),
          run_dir: run_dir,
          manifest: manifest
        }
      ]
    else
      _other -> []
    end
  end

  defp running_manifest?(%{"status" => "running"}), do: true

  defp running_manifest?(_manifest) do
    # Reconciliation is allowed to mutate only active runs; terminal manifests
    # are historical records and must be left untouched.
    false
  end

  defp dead_owner(%RunStore{manifest: %{"status" => "running"}} = store) do
    case read_pidfile(store.run_dir) do
      {:ok, %{"os_pid" => os_pid}} when is_integer(os_pid) ->
        if alive?(os_pid) do
          :alive
        else
          {:dead, "reconciled: owner pid #{os_pid} not alive", os_pid}
        end

      {:ok, _pidfile} ->
        {:dead, "reconciled: invalid pidfile", nil}

      {:error, :enoent} ->
        if within_pidfile_grace?(store.manifest) do
          :alive
        else
          {:dead, "reconciled: pidfile missing", nil}
        end

      {:error, _reason} ->
        {:dead, "reconciled: invalid pidfile", nil}
    end
  end

  defp read_pidfile(run_dir) do
    case File.read(Path.join(run_dir, "_runner.pid")) do
      {:ok, raw} -> Jason.decode(raw)
      {:error, reason} -> {:error, reason}
    end
  end

  defp within_pidfile_grace?(manifest) do
    with started_at when is_binary(started_at) <- manifest["started_at"],
         {:ok, started_at, _offset} <- DateTime.from_iso8601(started_at) do
      DateTime.diff(DateTime.utc_now(), started_at, :second) < @pidfile_grace_seconds
    else
      _other -> false
    end
  end

  defp cached_alive?(os_pid, now_ms) do
    case :ets.lookup(cache_table(), os_pid) do
      [{^os_pid, alive?, checked_at_ms}] when now_ms - checked_at_ms <= @alive_cache_ms ->
        {:ok, alive?}

      _other ->
        :miss
    end
  end

  defp cache_table do
    case :ets.whereis(@alive_cache_table) do
      :undefined ->
        :ets.new(@alive_cache_table, [:named_table, :public, read_concurrency: true])

      table ->
        table
    end
  rescue
    ArgumentError -> @alive_cache_table
  end
end
