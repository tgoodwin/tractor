defmodule Tractor.Runner.Adjudication do
  @moduledoc """
  Centralizes node outcome acceptance rules.
  """

  alias Tractor.Node

  @type decision :: :continue | :fail
  @type normalized_status :: :success | :partial_success | :fail | :retry | :unknown

  @spec classify(Node.t(), map() | atom() | String.t() | nil, map()) ::
          {decision(), map(), map()}
  def classify(%Node{} = node, raw_outcome, handler_return \\ %{}) do
    normalized_outcome =
      raw_outcome
      |> normalize_outcome()
      |> merge_handler_metadata(handler_return)

    {decision, reason} = classify_status(node, normalized_outcome.status)

    metadata = %{
      allow_partial: Node.allow_partial?(node),
      continuation?: decision == :continue,
      reason: reason
    }

    {decision, normalized_outcome, metadata}
  end

  defp classify_status(_node, :success), do: {:continue, :success}

  defp classify_status(node, :partial_success) do
    cond do
      node.type == "parallel.fan_in" -> {:continue, :fan_in_partial_success}
      Node.allow_partial?(node) -> {:continue, :allowed_partial_success}
      true -> {:fail, :partial_success_not_allowed}
    end
  end

  defp classify_status(_node, :fail), do: {:fail, :fail}
  defp classify_status(_node, :retry), do: {:fail, :retry}
  defp classify_status(_node, :unknown), do: {:fail, :unknown_status}

  defp normalize_outcome(%{} = outcome) do
    status = normalize_status(Map.get(outcome, :status) || Map.get(outcome, "status"))

    outcome
    |> Enum.into(%{})
    |> Map.put(:status, status)
  end

  defp normalize_outcome(status) do
    %{status: normalize_status(status)}
  end

  defp merge_handler_metadata(outcome, handler_return) when map_size(handler_return) == 0,
    do: outcome

  defp merge_handler_metadata(outcome, handler_return) do
    Map.update(
      outcome,
      :handler_return,
      Map.new(handler_return),
      &Map.merge(&1, Map.new(handler_return))
    )
  end

  defp normalize_status(status) when status in ["ok", :ok, "success", :success], do: :success

  defp normalize_status(status) when status in ["partial_success", :partial_success],
    do: :partial_success

  defp normalize_status(status)
       when status in ["error", :error, "fail", :fail, "failed", :failed],
       do: :fail

  defp normalize_status(status) when status in ["retry", :retry], do: :retry
  defp normalize_status(_status), do: :unknown
end
