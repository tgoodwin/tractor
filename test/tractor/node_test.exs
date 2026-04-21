defmodule Tractor.NodeTest do
  use ExUnit.Case, async: true

  alias Tractor.{Edge, Node, Pipeline}

  test "exposes recovery target accessors from struct fields" do
    node = %Node{
      id: "ask",
      retry_target: "repair",
      fallback_retry_target: "fallback",
      goal_gate: true,
      allow_partial: true
    }

    assert Node.retry_target(node) == "repair"
    assert Node.fallback_retry_target(node) == "fallback"
    assert Node.goal_gate?(node)
    assert Node.allow_partial?(node)
  end

  test "falls back to attrs when typed fields are absent" do
    node = %Node{
      id: "judge",
      attrs: %{
        "retry_target" => "repair",
        "fallback_retry_target" => "fallback",
        "goal_gate" => "true",
        "allow_partial" => "false"
      }
    }

    assert Node.retry_target(node) == "repair"
    assert Node.fallback_retry_target(node) == "fallback"
    assert Node.goal_gate?(node)
    refute Node.allow_partial?(node)
  end

  test "blank or invalid attrs collapse to disabled defaults" do
    node = %Node{
      id: "judge",
      attrs: %{
        "retry_target" => "   ",
        "fallback_retry_target" => "",
        "goal_gate" => "maybe",
        "allow_partial" => "sometimes"
      }
    }

    assert Node.retry_target(node) == nil
    assert Node.fallback_retry_target(node) == nil
    refute Node.goal_gate?(node)
    refute Node.allow_partial?(node)
  end

  test "tool and wait accessors normalize sprint-0008 attrs" do
    node = %Node{
      id: "tool",
      attrs: %{
        "command" => ["grep", "{{pattern}}"],
        "cwd" => "tmp/work",
        "env" => %{"LC_ALL" => "C"},
        "stdin" => "{{context.pattern}}",
        "max_output_bytes" => "2048",
        "wait_timeout" => "30s",
        "default_edge" => "skip",
        "wait_prompt" => "Choose a path"
      }
    }

    assert Node.command(node) == ["grep", "{{pattern}}"]
    assert Node.cwd(node) == "tmp/work"
    assert Node.env(node) == %{"LC_ALL" => "C"}
    assert Node.stdin(node) == "{{context.pattern}}"
    assert Node.max_output_bytes(node) == 2_048
    assert Node.wait_timeout_ms(node) == 30_000
    assert Node.default_edge(node) == "skip"
    assert Node.wait_prompt(node) == "Choose a path"
  end

  test "outgoing_labels returns distinct non-blank labels" do
    pipeline = %Pipeline{
      edges: [
        %Edge{from: "wait", to: "a", label: "approve"},
        %Edge{from: "wait", to: "b", label: "reject"},
        %Edge{from: "wait", to: "c", label: "approve"},
        %Edge{from: "wait", to: "d"}
      ]
    }

    assert Node.outgoing_labels(%Node{id: "wait"}, pipeline) == ["approve", "reject"]
  end
end
