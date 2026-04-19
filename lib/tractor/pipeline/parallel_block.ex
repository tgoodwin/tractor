defmodule Tractor.Pipeline.ParallelBlock do
  @moduledoc """
  Discovered structured parallel region.
  """

  defstruct parallel_node_id: nil,
            branches: [],
            fan_in_id: nil,
            max_parallel: 4,
            join_policy: "wait_all"
end
