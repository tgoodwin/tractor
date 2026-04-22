defmodule Tractor.RunBus do
  @moduledoc """
  PubSub wrapper for run observer events.
  """

  @seq_table :tractor_run_bus_seen_seq

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(run_id) do
    Phoenix.PubSub.subscribe(Tractor.PubSub, run_topic(run_id))
  end

  @spec subscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(run_id, node_id) do
    Phoenix.PubSub.subscribe(Tractor.PubSub, node_topic(run_id, node_id))
  end

  @spec reset_run(String.t()) :: :ok
  def reset_run(run_id) do
    ensure_seq_table!()
    :ets.match_delete(@seq_table, {{run_id, :_, :_}})
    :ok
  end

  @spec broadcast(String.t(), String.t(), map()) :: :ok
  def broadcast(run_id, node_id, event) do
    if should_broadcast?(run_id, node_id, event) do
      message = {:run_event, node_id, event}
      Phoenix.PubSub.broadcast(Tractor.PubSub, run_topic(run_id), message)
      Phoenix.PubSub.broadcast(Tractor.PubSub, node_topic(run_id, node_id), message)
    end

    :ok
  end

  defp should_broadcast?(run_id, node_id, %{"seq" => seq}) when is_integer(seq) do
    ensure_seq_table!()
    :ets.insert_new(@seq_table, {{run_id, node_id, seq}})
  end

  defp should_broadcast?(_run_id, _node_id, _event), do: true

  defp ensure_seq_table! do
    case :ets.whereis(@seq_table) do
      :undefined ->
        try do
          :ets.new(@seq_table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @seq_table
        end

      _tid ->
        @seq_table
    end
  end

  defp run_topic(run_id), do: "run:#{run_id}"
  defp node_topic(run_id, node_id), do: "run:#{run_id}:node:#{node_id}"
end
