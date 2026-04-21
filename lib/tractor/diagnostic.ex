defmodule Tractor.Diagnostic do
  @moduledoc """
  Parse or validation diagnostic with optional source location.
  """

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          node_id: String.t() | nil,
          edge: {String.t(), String.t()} | nil,
          path: String.t() | nil,
          severity: :error | :warning
        }

  defstruct code: nil,
            message: nil,
            node_id: nil,
            edge: nil,
            path: nil,
            severity: :error
end
