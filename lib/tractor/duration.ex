defmodule Tractor.Duration do
  @moduledoc """
  Parses unit-suffixed durations into milliseconds.
  """

  @spec parse(non_neg_integer() | String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, :invalid_duration}
  def parse(value) when is_integer(value) and value >= 0, do: {:ok, value}

  def parse(value) when is_binary(value) do
    case Regex.run(~r/^(\d+)(ms|s|m|h)?$/, String.trim(value)) do
      [_, amount] -> {:ok, String.to_integer(amount)}
      [_, amount, ""] -> {:ok, String.to_integer(amount)}
      [_, amount, "ms"] -> {:ok, String.to_integer(amount)}
      [_, amount, "s"] -> {:ok, String.to_integer(amount) * 1_000}
      [_, amount, "m"] -> {:ok, String.to_integer(amount) * 60_000}
      [_, amount, "h"] -> {:ok, String.to_integer(amount) * 3_600_000}
      _other -> {:error, :invalid_duration}
    end
  end

  def parse(_value), do: {:error, :invalid_duration}
end
