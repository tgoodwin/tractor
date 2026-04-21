defmodule Tractor.Pipeline do
  @moduledoc """
  Normalized Tractor pipeline parsed from a DOT graph.
  """

  alias Tractor.{Edge, Node}

  @type t :: %__MODULE__{
          path: String.t() | nil,
          goal: String.t() | nil,
          strict?: boolean(),
          graph_type: :digraph | :graph | nil,
          graph_attrs: %{String.t() => Node.attr_value()},
          nodes: %{String.t() => Node.t()},
          edges: [Edge.t()],
          parallel_blocks: %{String.t() => Tractor.Pipeline.ParallelBlock.t()}
        }

  defstruct path: nil,
            goal: nil,
            strict?: false,
            graph_type: nil,
            graph_attrs: %{},
            nodes: %{},
            edges: [],
            parallel_blocks: %{}
end
