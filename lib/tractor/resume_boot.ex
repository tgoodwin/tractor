defmodule Tractor.ResumeBoot do
  @moduledoc """
  Rehydrates in-flight runs with checkpoints when the app boots.
  """

  use Task

  require Logger

  alias Tractor.Run

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      restart: :temporary
    }
  end

  @spec start_link(term()) :: Task.on_start()
  def start_link(_arg) do
    Task.start_link(__MODULE__, :run, [])
  end

  @spec run() :: non_neg_integer()
  def run do
    resume_inflight_runs()
  end

  @spec resume_inflight_runs(Path.t()) :: non_neg_integer()
  def resume_inflight_runs(runs_dir \\ default_runs_dir()) do
    runs_dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.reduce(0, fn run_dir, resumed ->
      if resumable_run?(run_dir) do
        case Run.resume(run_dir) do
          {:ok, _run_id} ->
            resumed + 1

          {:error, reason} ->
            Logger.warning("ResumeBoot failed for #{run_dir}: #{inspect(reason)}")
            resumed
        end
      else
        resumed
      end
    end)
  end

  defp resumable_run?(run_dir) do
    checkpoint_path = Path.join(run_dir, "checkpoint.json")

    File.dir?(run_dir) and
      File.exists?(checkpoint_path) and
      run_status(run_dir) == "running"
  end

  defp run_status(run_dir) do
    status_path = Path.join(run_dir, "status.json")

    with {:ok, raw} <- File.read(status_path),
         {:ok, data} <- Jason.decode(raw) do
      data["status"]
    else
      _ -> nil
    end
  end

  defp default_runs_dir do
    Path.join(Tractor.Paths.data_dir(), "runs")
  end
end
