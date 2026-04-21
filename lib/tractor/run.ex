defmodule Tractor.Run do
  @moduledoc """
  Public API for starting and awaiting Tractor runs.
  """

  alias Tractor.{Checkpoint, DotParser, Pipeline, Runner, RunStore, Validator}

  @spec start(Pipeline.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start(%Pipeline{} = pipeline, opts \\ []) do
    with {:ok, store} <- RunStore.open(pipeline, opts),
         {:ok, _pid} <-
           DynamicSupervisor.start_child(Tractor.RunSup, {Runner, {pipeline, opts, store}}) do
      {:ok, store.run_id}
    end
  end

  @spec resume(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resume(run_dir, opts \\ []) do
    with {:ok, store} <- RunStore.resume(run_dir),
         {:ok, checkpoint} <- Checkpoint.read(run_dir),
         pipeline_path when is_binary(pipeline_path) <- checkpoint["pipeline_path"],
         {:ok, pipeline} <- DotParser.parse_file(pipeline_path),
         :ok <- Validator.validate(pipeline),
         :ok <- Checkpoint.verify!(pipeline, checkpoint),
         {:ok, _pid} <-
           DynamicSupervisor.start_child(
             Tractor.RunSup,
             {Runner, {pipeline, Keyword.put(opts, :resume_state, checkpoint), store}}
           ) do
      {:ok, store.run_id}
    else
      nil -> {:error, :missing_pipeline_path}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec await(String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def await(run_id, timeout \\ 300_000) do
    Runner.await(run_id, timeout)
  end

  @spec info(String.t()) :: {:ok, map()} | {:error, term()}
  def info(run_id) do
    Runner.info(run_id)
  end

  @spec submit_wait_choice(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def submit_wait_choice(run_id, node_id, label) do
    Runner.submit_wait_choice(run_id, node_id, label)
  end
end
