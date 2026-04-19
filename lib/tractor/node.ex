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
end
