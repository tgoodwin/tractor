defmodule Tractor.RunBus do
  @moduledoc """
  PubSub wrapper for run observer events.
  """

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(run_id) do
    Phoenix.PubSub.subscribe(Tractor.PubSub, run_topic(run_id))
  end

  @spec subscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(run_id, node_id) do
    Phoenix.PubSub.subscribe(Tractor.PubSub, node_topic(run_id, node_id))
  end

  @spec broadcast(String.t(), String.t(), map()) :: :ok
  def broadcast(run_id, node_id, event) do
    message = {:run_event, node_id, event}
    Phoenix.PubSub.broadcast(Tractor.PubSub, run_topic(run_id), message)
    Phoenix.PubSub.broadcast(Tractor.PubSub, node_topic(run_id, node_id), message)
    :ok
  end

  defp run_topic(run_id), do: "run:#{run_id}"
  defp node_topic(run_id, node_id), do: "run:#{run_id}:node:#{node_id}"
end
