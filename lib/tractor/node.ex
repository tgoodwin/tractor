defmodule Tractor.Node do
  @moduledoc """
  Normalized DOT node owned by Tractor.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t() | nil,
          label: String.t() | nil,
          prompt: String.t() | nil,
          llm_provider: String.t() | nil,
          llm_model: String.t() | nil,
          timeout: timeout_ms(),
          attrs: %{String.t() => String.t()}
        }

  @type timeout_ms :: non_neg_integer() | nil

  defstruct id: nil,
            type: nil,
            label: nil,
            prompt: nil,
            llm_provider: nil,
            llm_model: nil,
            timeout: nil,
            attrs: %{}

  @spec join_policy(t()) :: String.t()
  def join_policy(%__MODULE__{attrs: attrs}) do
    Map.get(attrs, "join_policy", "wait_all")
  end

  @spec max_parallel(t()) :: pos_integer()
  def max_parallel(%__MODULE__{attrs: attrs}) do
    case Integer.parse(Map.get(attrs, "max_parallel", "4")) do
      {value, ""} -> value
      _other -> 4
    end
  end
end
