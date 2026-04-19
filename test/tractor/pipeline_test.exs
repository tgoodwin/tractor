defmodule Tractor.PipelineTest do
  use ExUnit.Case, async: true

  test "pipeline, node, and edge structs expose sprint-one fields" do
    pipeline = %Tractor.Pipeline{
      path: "pipeline.dot",
      goal: "ship",
      nodes: %{"start" => %Tractor.Node{id: "start", type: "start"}},
      edges: [%Tractor.Edge{from: "start", to: "exit", attrs: %{"weight" => "2"}}]
    }

    assert pipeline.path == "pipeline.dot"
    assert pipeline.goal == "ship"
    assert pipeline.nodes["start"].attrs == %{}
    assert pipeline.edges == [%Tractor.Edge{from: "start", to: "exit", attrs: %{"weight" => "2"}}]
  end
end
