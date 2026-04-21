defmodule Tractor.EdgeSelector do
  @moduledoc """
  Attractor-spec edge priority resolution.
  """

  alias Tractor.{Condition, Edge}

  @spec choose([Edge.t()], map(), map()) :: Edge.t() | nil
  def choose(edges, outcome, context \\ %{}) do
    outgoing = Enum.sort_by(edges, & &1.to)

    conditional_match(outgoing, outcome, context) ||
      preferred_label_match(outgoing, outcome) ||
      suggested_next_match(outgoing, outcome) ||
      fallback_match(outgoing)
  end

  @spec normalize_label(String.t() | nil) :: String.t() | nil
  def normalize_label(nil), do: nil

  def normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/^\[[a-z0-9]\]\s*/i, "")
    |> String.replace(~r/^[a-z0-9]\)\s*/i, "")
    |> String.replace(~r/^[a-z0-9]\s*[-:]\s*/i, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp conditional_match(edges, outcome, context) do
    edges
    |> Enum.filter(&(condition?(&1) and Condition.match?(&1.condition, outcome, context)))
    |> Enum.sort_by(fn %Edge{weight: weight, to: to} -> {-weight, to} end)
    |> List.first()
  end

  defp preferred_label_match(edges, outcome) do
    preferred_label = normalize_label(outcome[:preferred_label] || outcome["preferred_label"])

    if preferred_label do
      edges
      |> Enum.filter(&(not condition?(&1) and normalize_label(&1.label) == preferred_label))
      |> Enum.sort_by(fn %Edge{weight: weight, to: to} -> {-weight, to} end)
      |> List.first()
    end
  end

  defp suggested_next_match(edges, outcome) do
    suggestions = outcome[:suggested_next_ids] || outcome["suggested_next_ids"] || []

    suggestions
    |> Enum.find_value(fn node_id ->
      Enum.find(edges, &(not condition?(&1) and &1.to == node_id))
    end)
  end

  defp fallback_match(edges) do
    edges
    |> Enum.filter(&(not condition?(&1)))
    |> Enum.sort_by(fn %Edge{weight: weight, to: to} -> {-weight, to} end)
    |> List.first()
  end

  defp condition?(%Edge{condition: condition}) when is_binary(condition),
    do: String.trim(condition) != ""

  defp condition?(_edge), do: false
end
