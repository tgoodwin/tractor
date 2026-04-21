defmodule Tractor.Runner.Routing do
  @moduledoc """
  Declaring-node recovery target selection.
  """

  alias Tractor.Node

  @type recovery_tier :: :primary | :fallback | :exhausted

  @spec next_target(Node.t(), recovery_tier()) ::
          {:route, String.t(), recovery_tier()} | :terminate
  def next_target(%Node{} = node, :primary) do
    case Node.retry_target(node) do
      nil -> :terminate
      target_id -> {:route, target_id, :fallback}
    end
  end

  def next_target(%Node{} = node, :fallback) do
    case Node.fallback_retry_target(node) do
      nil -> :terminate
      target_id -> {:route, target_id, :exhausted}
    end
  end

  def next_target(%Node{}, :exhausted), do: :terminate
end
