defmodule Tractor.CheckpointTest do
  use ExUnit.Case, async: true

  alias Tractor.{Checkpoint, Edge, Node, Pipeline}

  @tag :tmp_dir
  test "verify! passes when pipeline hash matches checkpoint", %{tmp_dir: tmp_dir} do
    pipeline = sample_pipeline()
    state = state_for(pipeline, tmp_dir)

    Checkpoint.save(state)

    assert {:ok, checkpoint} = Checkpoint.read(tmp_dir)
    assert :ok = Checkpoint.verify!(pipeline, checkpoint)
    assert checkpoint["budgets"]["total_iterations_started"] == 1
    assert checkpoint["budgets"]["total_iterations"] == 1
    assert checkpoint["budgets"]["total_cost_usd"] == "0"
    assert checkpoint["goal_gates_satisfied"] == ["one"]
  end

  @tag :tmp_dir
  test "verify! rejects a pipeline whose semantic graph changed", %{tmp_dir: tmp_dir} do
    pipeline = sample_pipeline()
    state = state_for(pipeline, tmp_dir)

    Checkpoint.save(state)
    {:ok, checkpoint} = Checkpoint.read(tmp_dir)

    mutated =
      update_in(pipeline.nodes["one"], fn node ->
        %{node | prompt: "something else"}
      end)

    assert {:error, :pipeline_changed} = Checkpoint.verify!(mutated, checkpoint)
  end

  @tag :tmp_dir
  test "verify! rejects when node ids are added or removed", %{tmp_dir: tmp_dir} do
    pipeline = sample_pipeline()
    state = state_for(pipeline, tmp_dir)

    Checkpoint.save(state)
    {:ok, checkpoint} = Checkpoint.read(tmp_dir)

    removed = %{pipeline | nodes: Map.delete(pipeline.nodes, "one")}

    assert {:error, reason} = Checkpoint.verify!(removed, checkpoint)
    assert reason in [:pipeline_changed, :node_ids_changed]
  end

  @tag :tmp_dir
  test "read refuses an unsupported schema_version", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "checkpoint.json")
    File.write!(path, Jason.encode!(%{"schema_version" => 99, "run_id" => "x"}))

    assert {:error, :unsupported_checkpoint} = Checkpoint.read(tmp_dir)
  end

  @tag :tmp_dir
  test "read reports missing checkpoint cleanly", %{tmp_dir: tmp_dir} do
    assert {:error, :missing_checkpoint} = Checkpoint.read(tmp_dir)
  end

  test "semantic_hash tolerates attr key ordering" do
    base = sample_pipeline()

    shuffled =
      update_in(base.nodes["one"], fn node ->
        %{node | attrs: Map.new(Enum.reverse(Map.to_list(node.attrs)))}
      end)

    assert Checkpoint.semantic_hash(base) == Checkpoint.semantic_hash(shuffled)
  end

  test "semantic_hash changes when edge condition changes" do
    base = sample_pipeline()

    mutated_edges =
      Enum.map(base.edges, fn
        %Edge{from: "one", to: "exit"} = e -> %{e | condition: "accept"}
        other -> other
      end)

    mutated = %{base | edges: mutated_edges}

    assert Checkpoint.semantic_hash(base) != Checkpoint.semantic_hash(mutated)
  end

  defp sample_pipeline do
    nodes = %{
      "start" => %Node{id: "start", type: "start"},
      "one" => %Node{
        id: "one",
        type: "codergen",
        llm_provider: "codex",
        prompt: "hello",
        attrs: %{"max_iterations" => "3"}
      },
      "exit" => %Node{id: "exit", type: "exit"}
    }

    edges = [
      %Edge{from: "start", to: "one"},
      %Edge{from: "one", to: "exit"}
    ]

    %Pipeline{nodes: nodes, edges: edges, path: "pretend.dot"}
  end

  defp state_for(pipeline, run_dir) do
    %{
      pipeline: pipeline,
      store: %{run_id: "run-checkpoint", run_dir: run_dir},
      agenda: :queue.new(),
      completed: MapSet.new(["start"]),
      goal_gates_satisfied: MapSet.new(["one"]),
      iterations: %{"start" => 1},
      total_iterations_started: 1,
      total_cost_usd: Decimal.new("0"),
      context: %{"hello" => "world"},
      provider_commands: []
    }
  end
end
