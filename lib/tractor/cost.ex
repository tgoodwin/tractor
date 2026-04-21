defmodule Tractor.Cost do
  @moduledoc """
  Provider/model token cost estimation from configured pricing rates.
  """

  alias Decimal, as: D

  @million D.new("1000000")

  @spec estimate(String.t() | nil, String.t() | nil, map()) :: Decimal.t() | nil
  def estimate(provider, model, usage)

  def estimate(provider, model, usage)
      when is_binary(provider) and is_binary(model) and is_map(usage) do
    pricing = Application.get_env(:tractor, :provider_pricing, %{})
    key = {canonical(provider), canonical(model)}

    case Map.get(pricing, key) do
      %{input_per_mtok: input_rate, output_per_mtok: output_rate} ->
        input_tokens = token_count(usage, :input_tokens)
        output_tokens = token_count(usage, :output_tokens)

        input_cost = prorate(input_rate, input_tokens)
        output_cost = prorate(output_rate, output_tokens)

        D.add(input_cost, output_cost)

      _other ->
        nil
    end
  end

  def estimate(_provider, _model, _usage), do: nil

  defp prorate(_rate, 0), do: D.new(0)

  defp prorate(rate, tokens) do
    rate
    |> decimal()
    |> D.mult(D.new(tokens))
    |> D.div(@million)
  end

  defp token_count(usage, key) do
    usage
    |> Map.get(key, Map.get(usage, to_string(key), 0))
    |> case do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp decimal(%D{} = decimal), do: decimal
  defp decimal(value) when is_integer(value), do: D.new(value)
  defp decimal(value) when is_float(value), do: D.from_float(value)
  defp decimal(value) when is_binary(value), do: D.new(value)

  defp canonical(value) do
    value
    |> String.trim()
    |> String.downcase()
  end
end
