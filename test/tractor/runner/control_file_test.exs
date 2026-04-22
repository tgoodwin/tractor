defmodule Tractor.Runner.ControlFileTest do
  use ExUnit.Case, async: false

  alias Tractor.{Checkpoint, Pipeline, Run}
  alias Tractor.Runner
  alias Tractor.Runner.ControlFile

  @tag :tmp_dir
  test "Run.submit_wait_choice/3 writes a control file when the runner is in another BEAM", %{
    tmp_dir: tmp_dir
  } do
    run_id = "control-file-fallback"
    run_dir = Path.join(tmp_dir, run_id)
    File.mkdir_p!(run_dir)
    original_runs_dir = Application.get_env(:tractor, :runs_dir)
    Application.put_env(:tractor, :runs_dir, tmp_dir)

    on_exit(fn ->
      Application.put_env(:tractor, :runs_dir, original_runs_dir)
    end)

    write_wait_checkpoint(run_dir, run_id, 3)

    assert :ok = Run.submit_wait_choice(run_id, "gate", "approve")

    assert {:ok, control} = ControlFile.load(ControlFile.path(run_dir, "gate"))
    assert control["run_id"] == run_id
    assert control["node_id"] == "gate"
    assert control["attempt"] == 3
    assert control["label"] == "approve"
    assert control["submitted_by"] == "observer"
  end

  test "apply_control_file/2 flags stale attempts for archival" do
    state = %Runner{
      store: %{run_id: "run-1"},
      waiting: %{"gate" => %{attempt: 2}}
    }

    assert {:archive, :attempt_mismatch} =
             Runner.apply_control_file(state, %{
               "run_id" => "run-1",
               "node_id" => "gate",
               "attempt" => 1,
               "label" => "approve"
             })
  end

  defp write_wait_checkpoint(run_dir, run_id, attempt) do
    Checkpoint.save(%{
      pipeline: %Pipeline{
        path: Path.expand("examples/wait_human_review.dot"),
        nodes: %{},
        edges: []
      },
      store: %{run_id: run_id, run_dir: run_dir},
      agenda: :queue.new(),
      completed: MapSet.new(),
      goal_gates_satisfied: MapSet.new(),
      iterations: %{},
      context: %{},
      waiting: %{
        "gate" => %{
          node_id: "gate",
          waiting_since: DateTime.utc_now(),
          wait_prompt: "Approve?",
          outgoing_labels: ["approve", "reject"],
          wait_timeout_ms: nil,
          default_edge: "approve",
          attempt: attempt,
          branch_id: nil,
          parallel_id: nil,
          iteration: 1,
          declaring_node_id: "gate",
          origin_node_id: "gate",
          recovery_tier: :primary,
          routed_from: nil,
          max_iterations: 1,
          started_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      },
      branch_contexts: %{},
      parallel_state: %{},
      provider_commands: [],
      started_at_wall_iso: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
