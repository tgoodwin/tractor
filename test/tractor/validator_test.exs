defmodule Tractor.ValidatorTest do
  use ExUnit.Case, async: true

  alias Tractor.{Edge, Node, Pipeline, Validator}

  test "accepts a linear start to codergen to exit pipeline" do
    assert :ok =
             Validator.validate(
               pipeline(
                 nodes: [
                   node("start", "start"),
                   node("ask", "codergen", llm_provider: "claude"),
                   node("exit", "exit")
                 ],
                 edges: [edge("start", "ask"), edge("ask", "exit")]
               )
             )
  end

  test "rejects start and exit cardinality violations" do
    assert_codes(
      pipeline(nodes: [node("a", "codergen", llm_provider: "codex"), node("exit", "exit")]),
      [:start_cardinality]
    )

    assert_codes(
      pipeline(nodes: [node("start", "start"), node("a", "exit"), node("b", "exit")]),
      [:exit_cardinality]
    )
  end

  test "rejects cycles and missing edge endpoints" do
    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "codergen", llm_provider: "gemini"),
          node("exit", "exit")
        ],
        edges: [edge("start", "ask"), edge("ask", "start")]
      ),
      [:cycle, :unreachable_exit]
    )

    assert_codes(
      pipeline(
        nodes: [node("start", "start"), node("exit", "exit")],
        edges: [edge("start", "missing")]
      ),
      [:unknown_edge_endpoint]
    )
  end

  test "rejects disconnected nodes" do
    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "codergen", llm_provider: "codex"),
          node("exit", "exit")
        ],
        edges: [edge("start", "ask")]
      ),
      [:missing_outgoing, :missing_incoming]
    )
  end

  test "rejects codergen nodes without a supported provider" do
    assert_codes(
      pipeline(nodes: [node("start", "start"), node("ask", "codergen"), node("exit", "exit")]),
      [:missing_provider]
    )

    assert_codes(
      pipeline(
        nodes: [
          node("start", "start"),
          node("ask", "codergen", llm_provider: "llama"),
          node("exit", "exit")
        ]
      ),
      [:unknown_provider]
    )
  end

  test "rejects unsupported handlers and attrs" do
    assert_codes(
      pipeline(nodes: [node("start", "start"), node("wait", "wait.human"), node("exit", "exit")]),
      [:unsupported_handler]
    )

    assert_codes(
      pipeline(
        graph_attrs: %{"model_stylesheet" => "x"},
        nodes: [
          node("start", "start"),
          node("ask", "codergen", llm_provider: "codex"),
          node("exit", "exit")
        ],
        edges: [edge("start", "ask", attrs: %{"condition" => "ok"}), edge("ask", "exit")]
      ),
      [:unsupported_graph_attr, :unsupported_edge_attr]
    )
  end

  test "rejects undirected and strict graphs" do
    assert_codes(
      pipeline(graph_type: :graph, nodes: [node("start", "start"), node("exit", "exit")]),
      [:undirected_graph]
    )

    assert_codes(
      pipeline(strict?: true, nodes: [node("start", "start"), node("exit", "exit")]),
      [:strict_graph]
    )
  end

  defp assert_codes(pipeline, expected_codes) do
    assert {:error, diagnostics} = Validator.validate(pipeline)
    assert expected_codes -- Enum.map(diagnostics, & &1.code) == []
  end

  defp pipeline(opts) do
    nodes =
      opts
      |> Keyword.get(:nodes, [])
      |> Map.new(&{&1.id, &1})

    %Pipeline{
      graph_type: Keyword.get(opts, :graph_type, :digraph),
      strict?: Keyword.get(opts, :strict?, false),
      graph_attrs: Keyword.get(opts, :graph_attrs, %{}),
      nodes: nodes,
      edges: Keyword.get(opts, :edges, [])
    }
  end

  defp node(id, type, opts \\ []) do
    attrs = Keyword.get(opts, :attrs, %{})

    %Node{
      id: id,
      type: type,
      llm_provider: Keyword.get(opts, :llm_provider),
      attrs: attrs
    }
  end

  defp edge(from, to, opts \\ []) do
    %Edge{from: from, to: to, attrs: Keyword.get(opts, :attrs, %{})}
  end
end
