defmodule Tractor.Runner.RoutingTest do
  use ExUnit.Case, async: true

  alias Tractor.Node
  alias Tractor.Runner.Routing

  test "routes to the primary recovery target first" do
    node = %Node{id: "ask", retry_target: "repair", fallback_retry_target: "fallback"}

    assert Routing.next_target(node, :primary) == {:route, "repair", :fallback}
  end

  test "routes to fallback only after the primary tier has been exhausted" do
    node = %Node{id: "ask", retry_target: "repair", fallback_retry_target: "fallback"}

    assert Routing.next_target(node, :fallback) == {:route, "fallback", :exhausted}
  end

  test "terminates when no target is configured for the current tier" do
    assert Routing.next_target(%Node{id: "ask"}, :primary) == :terminate
    assert Routing.next_target(%Node{id: "ask", retry_target: "repair"}, :fallback) == :terminate
    assert Routing.next_target(%Node{id: "ask"}, :exhausted) == :terminate
  end

  test "fallback chain ownership stays with the declaring node" do
    declaring = %Node{id: "ask", retry_target: "repair", fallback_retry_target: "fallback"}

    primary_target = %Node{
      id: "repair",
      retry_target: "ignored",
      fallback_retry_target: "also_ignored"
    }

    assert Routing.next_target(declaring, :primary) == {:route, "repair", :fallback}
    assert Routing.next_target(declaring, :fallback) == {:route, "fallback", :exhausted}

    refute Routing.next_target(primary_target, :fallback) == {:route, "fallback", :exhausted}
  end
end
