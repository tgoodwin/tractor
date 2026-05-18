defmodule Tractor.JSON do
  @moduledoc """
  The single Tractor → Jason boundary.

  `encode!/2` and `encode_to_iodata!/2` recursively walk the payload via
  `sanitize_payload/2` and replace any invalid-UTF-8 binary with a
  `Tractor.Text.sanitize/2` rendering before delegating to Jason. This makes
  a byte-truncated multibyte string from an LLM bridge incapable of crashing
  the encoder — historically the failure mode papered over by ad-hoc
  sanitization at individual prompt sites (`commit aee9eaa`).

  Production code outside this module MUST NOT call `Jason.encode!/1` or
  `Jason.encode_to_iodata!/1` directly. The CI gate added in phase B.3 of
  SPRINT-0015 enforces this.

  Sanitization is structural: maps stay maps, lists stay lists, structs are
  left untouched (so `DateTime`/`Decimal` keep their Jason.Encoder
  implementations). Only raw binary leaves are coerced.
  """

  @spec encode!(term(), keyword()) :: String.t()
  def encode!(term, opts \\ []) do
    term |> sanitize_payload(opts) |> Jason.encode!(opts)
  end

  @spec encode_to_iodata!(term(), keyword()) :: iodata()
  def encode_to_iodata!(term, opts \\ []) do
    term |> sanitize_payload(opts) |> Jason.encode_to_iodata!(opts)
  end

  @spec sanitize_payload(term(), keyword()) :: term()
  def sanitize_payload(term, opts \\ [])
  def sanitize_payload(bin, opts) when is_binary(bin), do: Tractor.Text.sanitize(bin, opts)

  def sanitize_payload(list, opts) when is_list(list),
    do: Enum.map(list, &sanitize_payload(&1, opts))

  def sanitize_payload(map, opts) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {sanitize_payload(k, opts), sanitize_payload(v, opts)} end)
  end

  def sanitize_payload(other, _opts), do: other
end
