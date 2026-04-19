defmodule Tractor.DiagnosticTest do
  use ExUnit.Case, async: true

  test "diagnostic carries code, message, and optional location fields" do
    diagnostic = %Tractor.Diagnostic{
      code: :missing_provider,
      message: "codergen node is missing llm_provider",
      node_id: "ask",
      edge: {"ask", "exit"},
      path: "workflow.dot"
    }

    assert diagnostic.code == :missing_provider
    assert diagnostic.message =~ "missing"
    assert diagnostic.node_id == "ask"
    assert diagnostic.edge == {"ask", "exit"}
    assert diagnostic.path == "workflow.dot"
  end
end
