defmodule TractorWeb.GraphRendererTest do
  use ExUnit.Case, async: false

  alias Tractor.{Edge, Node, Pipeline}
  alias TractorWeb.GraphRenderer

  test "concurrent renders succeed for the same pipeline" do
    pipeline = %Pipeline{
      path: "graph-renderer-race-#{System.unique_integer([:positive])}.dot",
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [%Edge{from: "start", to: "exit"}]
    }

    results =
      1..8
      |> Task.async_stream(fn _ -> GraphRenderer.render(pipeline) end,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok, {:ok, svg}} -> svg =~ "data-testid=\"node-start\""
             _other -> false
           end)
  end

  test "render injects edge metadata for HTML-escaped edge titles" do
    pipeline = %Pipeline{
      path: "graph-renderer-edges-#{System.unique_integer([:positive])}.dot",
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{id: "draft", type: "tool"},
            %Node{id: "review", type: "wait.human"},
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [
        %Edge{from: "start", to: "draft"},
        %Edge{from: "draft", to: "review"},
        %Edge{from: "review", to: "exit", label: "approve"},
        %Edge{from: "review", to: "draft", label: "revise", condition: "preferred_label=revise"}
      ]
    }

    assert {:ok, svg} = GraphRenderer.render(pipeline)
    assert svg =~ ~s(data-from="review")
    assert svg =~ ~s(data-to="draft")
    assert svg =~ "tractor-edge-back"
  end
end
