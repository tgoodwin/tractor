defmodule Tractor.Diagnostic.FormatterTest do
  use ExUnit.Case, async: true

  alias Tractor.Diagnostic
  alias Tractor.Diagnostic.Formatter

  test "formats node and edge diagnostics with severity labels and fix hints" do
    diagnostics = [
      %Diagnostic{
        code: :missing_provider,
        message: "codergen node is missing llm_provider",
        node_id: "ask"
      },
      %Diagnostic{
        code: :retry_target_exists,
        message: "retry target does not exist",
        edge: {"ask", "exit"},
        severity: :warning,
        fix: "Point retry_target at an existing non-terminal node."
      }
    ]

    assert Formatter.format(diagnostics) ==
             "ERROR [missing_provider] (node: ask): codergen node is missing llm_provider\n" <>
               "WARNING [retry_target_exists] (edge: ask -> exit): retry target does not exist\n" <>
               "Fix: Point retry_target at an existing non-terminal node.\n"
  end
end
