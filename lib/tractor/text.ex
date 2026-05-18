defmodule Tractor.Text do
  @moduledoc false

  @spec sanitize(binary() | nil, keyword()) :: String.t()
  def sanitize(text, opts \\ [])
  def sanitize(nil, _opts), do: ""

  def sanitize(text, opts) when is_binary(text) do
    if String.valid?(text) do
      text
    else
      printable_limit = Keyword.get(opts, :printable_limit, 4_096)
      inspect(text, binaries: :as_strings, printable_limit: printable_limit)
    end
  end

  @spec truncate_after(binary() | nil, non_neg_integer(), String.t()) :: String.t()
  def truncate_after(text, byte_limit, marker \\ "...")
  def truncate_after(nil, _byte_limit, _marker), do: ""
  def truncate_after(_text, byte_limit, _marker) when byte_limit <= 0, do: ""

  def truncate_after(text, byte_limit, marker) when is_binary(text) do
    text = sanitize(text, printable_limit: byte_limit)

    if byte_size(text) <= byte_limit do
      text
    else
      valid_prefix(text, byte_limit) <> marker
    end
  end

  @spec truncate_middle(binary() | nil, non_neg_integer(), String.t()) :: String.t()
  def truncate_middle(text, byte_limit, marker \\ "\n\n[truncated]\n\n")
  def truncate_middle(nil, _byte_limit, _marker), do: ""
  def truncate_middle(_text, byte_limit, _marker) when byte_limit <= 0, do: ""

  def truncate_middle(text, byte_limit, marker) when is_binary(text) do
    text = sanitize(text, printable_limit: byte_limit)

    if byte_size(text) <= byte_limit do
      text
    else
      half = max(div(byte_limit, 2), 1)
      valid_prefix(text, half) <> marker <> valid_suffix(text, half)
    end
  end

  @spec valid_prefix(binary(), non_neg_integer()) :: String.t()
  def valid_prefix(_text, byte_limit) when byte_limit <= 0, do: ""

  def valid_prefix(text, byte_limit) when is_binary(text) do
    text = sanitize(text, printable_limit: byte_limit)

    text
    |> binary_part(0, min(byte_size(text), byte_limit))
    |> trim_invalid_suffix()
  end

  @spec valid_suffix(binary(), non_neg_integer()) :: String.t()
  def valid_suffix(_text, byte_limit) when byte_limit <= 0, do: ""

  def valid_suffix(text, byte_limit) when is_binary(text) do
    text = sanitize(text, printable_limit: byte_limit)
    size = byte_size(text)
    length = min(size, byte_limit)

    text
    |> binary_part(size - length, length)
    |> trim_invalid_prefix()
  end

  defp trim_invalid_suffix(""), do: ""

  defp trim_invalid_suffix(text) do
    if String.valid?(text) do
      text
    else
      text
      |> binary_part(0, byte_size(text) - 1)
      |> trim_invalid_suffix()
    end
  end

  defp trim_invalid_prefix(""), do: ""

  defp trim_invalid_prefix(text) do
    if String.valid?(text) do
      text
    else
      text
      |> binary_part(1, byte_size(text) - 1)
      |> trim_invalid_prefix()
    end
  end
end
