defmodule Tractor.Run do
  @moduledoc """
  Public API for starting and awaiting Tractor runs.
  """

  alias Tractor.{Pipeline, Runner, RunStore}

  @spec start(Pipeline.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start(%Pipeline{} = pipeline, opts \\ []) do
    with {:ok, store} <- RunStore.open(pipeline, opts),
         {:ok, _pid} <-
           DynamicSupervisor.start_child(Tractor.RunSup, {Runner, {pipeline, opts, store}}) do
      {:ok, store.run_id}
    end
  end

  @spec await(String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def await(run_id, timeout \\ 300_000) do
    Runner.await(run_id, timeout)
  end
end
