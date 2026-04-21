defmodule Tractor.Edge do
  @moduledoc """
  Normalized directed edge owned by Tractor.
  """

  @type t :: %__MODULE__{
          from: String.t(),
          to: String.t(),
          label: String.t() | nil,
          condition: String.t() | nil,
          weight: float(),
          attrs: %{String.t() => Tractor.Node.attr_value()}
        }

  defstruct from: nil,
            to: nil,
            label: nil,
            condition: nil,
            weight: 0.0,
            attrs: %{}
end
