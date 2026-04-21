defmodule Tractor.ConditionTest do
  use ExUnit.Case, async: true

  alias Tractor.Condition

  test "accept, reject, and partial_success shorthand remain routable" do
    assert Condition.match?("accept", %{preferred_label: "accept"}, %{})
    assert Condition.match?("reject", %{preferred_label: "reject"}, %{})
    assert Condition.match?("partial_success", %{status: :partial_success}, %{})

    refute Condition.match?("accept", %{preferred_label: "reject"}, %{})
    refute Condition.match?("partial_success", %{status: :success}, %{})
  end

  test "parses operator precedence and parentheses" do
    assert {:ok,
            {:or, {:cmp, :eq, "a", 1.0}, {:and, {:cmp, :eq, "b", 2.0}, {:cmp, :eq, "c", 3.0}}}} =
             Condition.parse("a=1 || b=2 && c=3")

    assert {:ok,
            {:and, {:or, {:cmp, :eq, "a", 1.0}, {:cmp, :eq, "b", 2.0}}, {:cmp, :eq, "c", 3.0}}} =
             Condition.parse("(a=1 || b=2) && c=3")
  end

  test "normalizes double negation and handles contains" do
    assert {:ok, {:cmp, :eq, "x", 1.0}} = Condition.parse("!!x=1")

    assert Condition.match?(
             "context.error contains \"timeout\"",
             %{},
             %{"error" => "request timeout after 30s"}
           )

    refute Condition.match?("context.error contains \"timeout\"", %{}, %{"error" => "ok"})
  end

  test "supports numeric comparisons against context values" do
    context = %{"score" => 0.81}

    assert Condition.match?("context.score >= 0.8", %{}, context)
    refute Condition.match?("context.score > 1.0", %{}, context)
    refute Condition.match?("context.missing >= 0.8", %{}, context)
    refute Condition.match?("context.score >= nope", %{}, context)
  end

  test "matches exact dotted keys before traversal" do
    context = %{"foo.bar" => "exact", "foo" => %{"bar" => "nested"}}

    assert Condition.match?("context.foo.bar=exact", %{}, context)
    refute Condition.match?("context.foo.bar=nested", %{}, context)
  end

  test "invalid syntax is rejected" do
    for condition <- ["a = ", "(", "x ?? y"] do
      assert {:error, :invalid_condition} = Condition.parse(condition)
      refute Condition.valid?(condition)
    end
  end
end
