defmodule Tractor.DotFixtureTest do
  use ExUnit.Case, async: true

  alias Tractor.{DotParser, Validator}

  @fixture_dir Path.expand("../fixtures/dot", __DIR__)

  @invalid_fixtures %{
    "cyclic.dot" => :unconditional_cycle,
    "no_start.dot" => :start_cardinality,
    "two_starts.dot" => :start_cardinality,
    "no_exit.dot" => :exit_cardinality,
    "missing_provider.dot" => :missing_provider,
    "unknown_provider.dot" => :unknown_provider,
    "rejected_handler.dot" => :unsupported_handler,
    "edge_to_missing.dot" => :unknown_edge_endpoint,
    "undirected.dot" => :undirected_graph,
    "missing_fan_in.dot" => :no_common_fan_in,
    "multiple_fan_ins.dot" => :multiple_common_fan_ins,
    "nested_branch.dot" => :nested_branches_unsupported,
    "invalid_join_policy.dot" => :unsupported_join_policy,
    "invalid_max_parallel.dot" => :invalid_max_parallel,
    "fan_in_without_parallel.dot" => :fan_in_without_parallel
  }

  test "valid fixtures parse and validate" do
    for fixture <- ["valid_linear.dot", "valid_three_agents.dot", "valid_parallel_audit.dot"] do
      assert {:ok, pipeline} = DotParser.parse_file(fixture_path(fixture))
      assert :ok = Validator.validate(pipeline)
    end
  end

  test "example pipelines parse and validate" do
    for example <- [
          "examples/haiku_feedback.dot",
          "examples/haiku_feedback_budget.dot",
          "examples/recovery.dot",
          "examples/resilience.dot",
          "examples/parallel_audit.dot",
          "examples/three_agents.dot",
          "examples/plan_probe.dot"
        ] do
      assert {:ok, pipeline} = DotParser.parse_file(example)
      assert :ok = Validator.validate(pipeline)
    end
  end

  test "invalid fixtures produce expected validation diagnostics" do
    for {fixture, expected_code} <- @invalid_fixtures do
      assert {:ok, pipeline} = DotParser.parse_file(fixture_path(fixture))
      assert {:error, diagnostics} = Validator.validate(pipeline)
      assert expected_code in Enum.map(diagnostics, & &1.code)
    end
  end

  defp fixture_path(name), do: Path.join(@fixture_dir, name)
end
