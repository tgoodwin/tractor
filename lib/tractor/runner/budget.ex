defmodule Tractor.Runner.Budget do
  @moduledoc """
  Pure budget checks for runner totals.
  """

  alias Decimal, as: D
  alias Tractor.Pipeline

  @spec check_cost(Pipeline.t(), Decimal.t()) ::
          :ok | {:budget_exhausted, Decimal.t(), Decimal.t()}
  def check_cost(%Pipeline{} = pipeline, %D{} = total_cost_usd) do
    case max_total_cost_usd(pipeline) do
      nil ->
        :ok

      limit ->
        if D.compare(total_cost_usd, limit) == :gt do
          {:budget_exhausted, total_cost_usd, limit}
        else
          :ok
        end
    end
  end

  @spec max_total_cost_usd(Pipeline.t()) :: Decimal.t() | nil
  def max_total_cost_usd(%Pipeline{graph_attrs: attrs}) do
    case Map.fetch(attrs, "max_total_cost_usd") do
      {:ok, value} ->
        case D.parse(value) do
          {decimal, ""} -> decimal
          _other -> nil
        end

      :error ->
        nil
    end
  end
end
