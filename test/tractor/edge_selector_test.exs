defmodule Tractor.EdgeSelectorTest do
  use ExUnit.Case, async: true

  alias Tractor.{Edge, EdgeSelector}

  test "priority matrix: condition, label, suggestions, weight, lexical" do
    edges = [
      edge("a", "z", weight: 100),
      edge("a", "label", label: "[Y] Fix"),
      edge("a", "suggested"),
      edge("a", "conditional", condition: "outcome=success", weight: 1)
    ]

    assert EdgeSelector.choose(edges, %{status: :success, preferred_label: "fix"}, %{}).to ==
             "conditional"

    assert EdgeSelector.choose(edges, %{preferred_label: "Y - Fix"}, %{}).to == "label"

    assert EdgeSelector.choose(edges, %{suggested_next_ids: ["suggested", "z"]}, %{}).to ==
             "suggested"

    assert EdgeSelector.choose(edges, %{}, %{}).to == "z"
  end

  test "conditional-only no-match returns nil" do
    assert EdgeSelector.choose([edge("a", "b", condition: "reject")], %{preferred_label: "accept"}) ==
             nil
  end

  test "extended condition syntax routes through the selector" do
    edges = [
      edge("judge", "fallback",
        condition: "context.score >= 0.8 || context.error contains \"timeout\""
      ),
      edge("judge", "exit")
    ]

    assert EdgeSelector.choose(edges, %{status: :success}, %{"score" => 0.81}).to == "fallback"

    assert EdgeSelector.choose(edges, %{status: :success}, %{"error" => "request timeout"}).to ==
             "fallback"

    assert EdgeSelector.choose(edges, %{status: :success}, %{"score" => 0.2}).to == "exit"
  end

  test "partial_success shorthand is routable" do
    edges = [
      edge("judge", "partial", condition: "partial_success"),
      edge("judge", "reject", condition: "reject")
    ]

    assert EdgeSelector.choose(edges, %{status: :partial_success}, %{}).to == "partial"
  end

  test "label normalization strips accelerator prefixes" do
    assert EdgeSelector.normalize_label("[Y] Continue now") == "continue now"
    assert EdgeSelector.normalize_label("Y) Continue now") == "continue now"
    assert EdgeSelector.normalize_label("Y - Continue now") == "continue now"
    assert EdgeSelector.normalize_label("Y: Continue now") == "continue now"
  end

  defp edge(from, to, opts \\ []) do
    %Edge{
      from: from,
      to: to,
      label: Keyword.get(opts, :label),
      condition: Keyword.get(opts, :condition),
      weight: Keyword.get(opts, :weight, 0.0)
    }
  end
end
