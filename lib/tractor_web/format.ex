defmodule TractorWeb.Format do
  @moduledoc """
  Small display formatting helpers for the observer UI.
  """

  alias Decimal, as: D

  @spec duration_ms(non_neg_integer() | nil) :: String.t()
  def duration_ms(nil), do: "n/a"
  def duration_ms(ms) when ms < 1_000, do: "#{max(ms, 0)}ms"

  def duration_ms(ms) when ms < 60_000 do
    seconds = ms / 1_000
    "#{compact_decimal(seconds)}s"
  end

  def duration_ms(ms) when ms < 3_600_000 do
    total_seconds = div(ms, 1_000)
    "#{div(total_seconds, 60)}m #{rem(total_seconds, 60)}s"
  end

  def duration_ms(ms) do
    total_minutes = div(ms, 60_000)
    "#{div(total_minutes, 60)}h #{rem(total_minutes, 60)}m"
  end

  @spec token_count(non_neg_integer() | nil) :: String.t()
  def token_count(nil), do: "n/a"
  def token_count(count) when count < 1_000, do: Integer.to_string(count)
  def token_count(count) when count < 1_000_000, do: compact_scaled(count, 1_000, "k")
  def token_count(count), do: compact_scaled(count, 1_000_000, "M")

  @spec humanize_bytes(non_neg_integer() | nil) :: String.t()
  def humanize_bytes(nil), do: "n/a"
  def humanize_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  def humanize_bytes(bytes) when bytes < 1_048_576, do: compact_scaled(bytes, 1_024, "KB")
  def humanize_bytes(bytes) when bytes < 1_073_741_824, do: compact_scaled(bytes, 1_048_576, "MB")
  def humanize_bytes(bytes), do: compact_scaled(bytes, 1_073_741_824, "GB")

  @spec truncate(binary() | nil, pos_integer()) :: String.t()
  def truncate(nil, _max_length), do: ""
  def truncate(text, max_length) when byte_size(text) <= max_length, do: text
  def truncate(_text, max_length) when max_length <= 0, do: ""
  def truncate(_text, max_length) when max_length <= 3, do: binary_part("...", 0, max_length)
  def truncate(text, max_length), do: binary_part(text, 0, max_length - 3) <> "..."

  @spec usd(String.t() | number() | nil) :: String.t()
  def usd(nil), do: "n/a"
  def usd(value) when value in ["", "n/a"], do: "n/a"
  def usd(%D{} = value), do: "$" <> D.to_string(D.normalize(value), :normal)
  def usd(value) when is_integer(value), do: value |> D.new() |> usd()
  def usd(value) when is_float(value), do: value |> D.from_float() |> usd()

  def usd(value) when is_binary(value) do
    case D.parse(value) do
      {decimal, ""} -> usd(decimal)
      _other -> "$" <> value
    end
  end

  defp compact_scaled(value, divisor, suffix) do
    value
    |> Kernel./(divisor)
    |> compact_decimal()
    |> Kernel.<>(suffix)
  end

  defp compact_decimal(value) do
    rounded = Float.round(value, 1)

    if rounded == trunc(rounded) do
      Integer.to_string(trunc(rounded))
    else
      :erlang.float_to_binary(rounded, decimals: 1)
    end
  end
end
