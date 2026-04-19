defmodule Tractor.Engine.BranchExecutor do
  @moduledoc """
  Sprint-2 branch executor contract.

  Branches are validated to exactly one node in this sprint, so the Runner owns
  task scheduling and calls handlers directly for the single entry node.
  """

  @spec run_until(function(), Tractor.Node.t(), map(), Path.t(), String.t()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def run_until(handler_fun, node, context, run_dir, _fan_in_id)
      when is_function(handler_fun, 3) do
    handler_fun.(node, context, run_dir)
  end
end
