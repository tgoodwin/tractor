defmodule Tractor.DotFixtureTest do
  use ExUnit.Case, async: true

  alias Tractor.{DotParser, Validator}

  @fixture_dir Path.expand("../fixtures/dot", __DIR__)

  @invalid_fixtures %{
    "cyclic.dot" => :cycle,
    "no_start.dot" => :start_cardinality,
    "two_starts.dot" => :start_cardinality,
    "no_exit.dot" => :exit_cardinality,
    "missing_provider.dot" => :missing_provider,
    "unknown_provider.dot" => :unknown_provider,
    "rejected_handler.dot" => :unsupported_handler,
    "edge_to_missing.dot" => :unknown_edge_endpoint,
    "undirected.dot" => :undirected_graph
  }

  test "valid fixtures parse and validate" do
    for fixture <- ["valid_linear.dot", "valid_three_agents.dot"] do
      assert {:ok, pipeline} = DotParser.parse_file(fixture_path(fixture))
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
