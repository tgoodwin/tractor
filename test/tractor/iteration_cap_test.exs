defmodule Tractor.IterationCapTest do
  @moduledoc """
  Covers the max_iterations runtime guard: a cyclic pipeline whose stub judge
  always rejects must fail with :max_iterations_exceeded, emit the
  :iteration_cap_reached event with the attempted iteration + max, and
  persist that info in the failed node's status.json.
  """

  use ExUnit.Case, async: false

  alias Tractor.{Edge, Node, Pipeline, Run}

  @tag :tmp_dir
  test "pipeline fails with :max_iterations_exceeded after stub rejects loop back",
       %{tmp_dir: tmp_dir} do
    pipeline =
      %Pipeline{
        nodes: %{
          "start" => %Node{id: "start", type: "start"},
          "judge" => %Node{
            id: "judge",
            type: "judge",
            attrs: %{
              "judge_mode" => "stub",
              "reject_probability" => "1.0",
              "max_iterations" => "2"
            }
          },
          "exit" => %Node{id: "exit", type: "exit"}
        },
        edges: [
          %Edge{from: "start", to: "judge"},
          %Edge{from: "judge", to: "judge", condition: "reject"},
          %Edge{from: "judge", to: "exit", condition: "accept"}
        ]
      }

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "cap-run")

    assert {:error, {:max_iterations_exceeded, "judge", 2, attempted}} =
             Run.await(run_id, 2_000)

    assert attempted >= 2

    run_dir = Path.join(tmp_dir, "cap-run")
    judge_status = Path.join(run_dir, "judge/status.json") |> File.read!() |> Jason.decode!()

    assert judge_status["status"] == "error"
    assert judge_status["reason"] =~ "max_iterations_exceeded"

    events_path = Path.join(run_dir, "judge/events.jsonl")
    events = events_path |> File.read!() |> String.split("\n", trim: true)
    cap_event = Enum.find(events, &(&1 =~ "iteration_cap_reached"))
    assert cap_event, "expected :iteration_cap_reached event in judge/events.jsonl"

    cap = Jason.decode!(cap_event)
    assert cap["kind"] == "iteration_cap_reached" or cap["event"] == "iteration_cap_reached"
    data = cap["data"] || cap
    assert data["node_id"] == "judge"
    assert data["max_iterations"] == 2
    assert data["attempted_iteration"] >= 2
  end
end
