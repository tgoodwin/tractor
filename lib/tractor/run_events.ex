defmodule Tractor.RunEvents do
  @moduledoc """
  Disk-first run event emission with PubSub broadcast.
  """

  use GenServer

  alias Tractor.EventLog

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec register_run(String.t(), Path.t()) :: :ok
  def register_run(run_id, run_dir) do
    GenServer.call(__MODULE__, {:register_run, run_id, run_dir})
  end

  @spec emit(String.t(), String.t(), atom() | String.t(), map()) :: :ok | {:error, term()}
  def emit(run_id, node_id, kind, data \\ %{}) do
    GenServer.call(__MODULE__, {:emit, run_id, node_id, kind, data})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:register_run, run_id, run_dir}, _from, state) do
    {:reply, :ok, Map.put(state, {:run_dir, run_id}, run_dir)}
  end

  def handle_call({:emit, run_id, node_id, kind, data}, _from, state) do
    with {:ok, run_dir} <- fetch_run_dir(state, run_id),
         {:ok, log, state} <- fetch_log(state, run_id, node_id, run_dir),
         :ok <- EventLog.append(log, kind, data) do
      event = :sys.get_state(log).last_event
      Tractor.RunBus.broadcast(run_id, node_id, event)
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fetch_run_dir(state, run_id) do
    case Map.fetch(state, {:run_dir, run_id}) do
      {:ok, run_dir} -> {:ok, run_dir}
      :error -> {:error, :run_not_registered}
    end
  end

  defp fetch_log(state, run_id, node_id, run_dir) do
    key = {:log, run_id, node_id}

    case Map.fetch(state, key) do
      {:ok, log} ->
        {:ok, log, state}

      :error ->
        node_dir = Path.join(run_dir, node_id)

        with {:ok, log} <- EventLog.open(node_dir) do
          {:ok, log, Map.put(state, key, log)}
        end
    end
  end

end
