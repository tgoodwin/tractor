defmodule Tractor.Edge do
  @moduledoc """
  Normalized directed edge owned by Tractor.
  """

  @type t :: %__MODULE__{
          from: String.t(),
          to: String.t(),
          label: String.t() | nil,
          weight: float(),
          attrs: %{String.t() => String.t()}
        }

  defstruct from: nil,
            to: nil,
            label: nil,
            weight: 1.0,
            attrs: %{}
end
