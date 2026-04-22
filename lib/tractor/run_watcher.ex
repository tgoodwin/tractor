defmodule Tractor.RunWatcher do
  @moduledoc """
  Watches the runs directory and tails on-disk event logs into the local RunBus.
  """

  use GenServer

  require Logger

  alias Tractor.RunWatcher.Tail

  @rescan_ms 1_000

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    runs_dir = Keyword.get(opts, :runs_dir, Tractor.Paths.runs_dir()) |> Path.expand()
    File.mkdir_p!(runs_dir)

    state = %{
      runs_dir: runs_dir,
      watcher: start_fs_watcher(runs_dir),
      runs: %{},
      finished_runs: MapSet.new()
    }

    {:ok, schedule_rescan(discover_runs(state))}
  end

  @impl true
  def handle_info(:rescan_runs, state) do
    {:noreply, state |> discover_runs() |> schedule_rescan()}
  end

  def handle_info({:file_event, watcher, _event}, %{watcher: watcher} = state) do
    {:noreply, discover_runs(state)}
  end

  def handle_info({:run_watcher_terminal, run_id}, state) do
    state =
      case Map.pop(state.runs, run_id) do
        {nil, runs} ->
          %{state | runs: runs, finished_runs: MapSet.put(state.finished_runs, run_id)}

        {%{pid: pid}, runs} ->
          if Process.alive?(pid) do
            DynamicSupervisor.terminate_child(Tractor.RunWatcher.TailSupervisor, pid)
          end

          %{state | runs: runs, finished_runs: MapSet.put(state.finished_runs, run_id)}
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    runs =
      state.runs
      |> Enum.reject(fn {_run_id, entry} -> entry.pid == pid end)
      |> Map.new()

    {:noreply, %{state | runs: runs}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp discover_runs(state) do
    running_runs =
      state.runs_dir
      |> Path.join("*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.filter(&running_run?/1)
      |> Map.new(fn run_dir -> {Path.basename(run_dir), run_dir} end)

    state =
      Enum.reduce(running_runs, state, fn {run_id, run_dir}, state ->
        if Map.has_key?(state.runs, run_id) do
          state
        else
          start_tail(state, run_id, run_dir)
        end
      end)

    stale_run_ids =
      state.runs
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(running_runs, &1))

    Enum.reduce(stale_run_ids, state, &stop_tail/2)
  end

  defp start_tail(state, run_id, run_dir) do
    case DynamicSupervisor.start_child(
           Tractor.RunWatcher.TailSupervisor,
           {Tail, run_id: run_id, run_dir: run_dir, notify: self()}
         ) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        put_in(state.runs[run_id], %{pid: pid, ref: ref, run_dir: run_dir})

      {:error, {:already_started, pid}} ->
        ref = Process.monitor(pid)
        put_in(state.runs[run_id], %{pid: pid, ref: ref, run_dir: run_dir})

      {:error, reason} ->
        Logger.warning("RunWatcher failed to start tail for #{run_dir}: #{inspect(reason)}")
        state
    end
  end

  defp stop_tail(run_id, state) do
    case Map.pop(state.runs, run_id) do
      {nil, runs} ->
        %{state | runs: runs}

      {%{pid: pid}, runs} ->
        if Process.alive?(pid) do
          DynamicSupervisor.terminate_child(Tractor.RunWatcher.TailSupervisor, pid)
        end

        %{state | runs: runs, finished_runs: MapSet.put(state.finished_runs, run_id)}
    end
  end

  defp running_run?(run_dir) do
    manifest_path = Path.join(run_dir, "manifest.json")

    with true <- File.regular?(manifest_path),
         {:ok, raw} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(raw) do
      manifest["status"] == "running"
    else
      _other -> false
    end
  end

  defp schedule_rescan(state) do
    Process.send_after(self(), :rescan_runs, @rescan_ms)
    state
  end

  defp start_fs_watcher(runs_dir) do
    case FileSystem.start_link(dirs: [runs_dir]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        pid

      :ignore ->
        Logger.warning("RunWatcher file_system unavailable for #{runs_dir}: :ignore")
        nil

      {:error, reason} ->
        Logger.warning("RunWatcher file_system unavailable for #{runs_dir}: #{inspect(reason)}")
        nil
    end
  end
end
