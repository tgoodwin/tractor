defmodule Tractor.DotParserTest do
  use ExUnit.Case, async: true

  alias Tractor.DotParser

  @tag :tmp_dir
  test "parses a linear digraph into Tractor structs", %{tmp_dir: tmp_dir} do
    path =
      dot_file(tmp_dir, "linear.dot", """
      digraph {
        graph [goal="ship tractor"]
        start [shape=Mdiamond]
        ask [shape=box, prompt="Say hi", llm_provider=codex, timeout="2m"]
        exit [shape=Msquare]

        start -> ask [weight=2.5]
        ask -> exit [label=done]
      }
      """)

    assert {:ok, pipeline} = DotParser.parse_file(path)

    assert pipeline.path == path
    assert pipeline.goal == "ship tractor"
    assert pipeline.nodes["start"].type == "start"
    assert pipeline.nodes["ask"].type == "codergen"
    assert pipeline.nodes["ask"].prompt == "Say hi"
    assert pipeline.nodes["ask"].llm_provider == "codex"
    assert pipeline.nodes["ask"].timeout == 120_000
    assert pipeline.nodes["exit"].type == "exit"

    assert [
             %Tractor.Edge{from: "start", to: "ask", weight: 2.5},
             %Tractor.Edge{from: "ask", to: "exit", label: "done", weight: 1.0}
           ] = pipeline.edges
  end

  @tag :tmp_dir
  test "flattens chained edges and spreads inherited node attributes", %{tmp_dir: tmp_dir} do
    path =
      dot_file(tmp_dir, "chained.dot", """
      digraph {
        node [llm_provider=gemini]
        start [shape=Mdiamond]
        one [shape=box, prompt="one"]
        two [shape=box, prompt="two"]
        exit [shape=Msquare]

        start -> one -> two -> exit
      }
      """)

    assert {:ok, pipeline} = DotParser.parse_file(path)

    assert Enum.map(pipeline.edges, &{&1.from, &1.to}) == [
             {"start", "one"},
             {"one", "two"},
             {"two", "exit"}
           ]

    assert pipeline.nodes["one"].llm_provider == "gemini"
    assert pipeline.nodes["two"].llm_provider == "gemini"
  end

  @tag :tmp_dir
  test "explicit type overrides shape mapping", %{tmp_dir: tmp_dir} do
    path =
      dot_file(tmp_dir, "override.dot", """
      digraph {
        start [shape=Mdiamond]
        wait [shape=box, type="wait.human"]
        exit [shape=Msquare]
        start -> wait -> exit
      }
      """)

    assert {:ok, pipeline} = DotParser.parse_file(path)
    assert pipeline.nodes["wait"].type == "wait.human"
  end

  @tag :tmp_dir
  test "maps component and tripleoctagon shapes", %{tmp_dir: tmp_dir} do
    path =
      dot_file(tmp_dir, "parallel.dot", """
      digraph {
        start [shape=Mdiamond]
        audit [shape=component, join_policy=wait_all, max_parallel=2]
        one [shape=box, llm_provider=codex]
        join [shape=tripleoctagon]
        exit [shape=Msquare]
        start -> audit -> one -> join -> exit
      }
      """)

    assert {:ok, pipeline} = DotParser.parse_file(path)
    assert pipeline.nodes["audit"].type == "parallel"
    assert Tractor.Node.join_policy(pipeline.nodes["audit"]) == "wait_all"
    assert Tractor.Node.max_parallel(pipeline.nodes["audit"]) == 2
    assert pipeline.nodes["join"].type == "parallel.fan_in"
  end

  @tag :tmp_dir
  test "parse errors return diagnostics", %{tmp_dir: tmp_dir} do
    path = dot_file(tmp_dir, "bad.dot", "digraph { start -> }")

    assert {:error, [%Tractor.Diagnostic{code: :parse_error, path: ^path}]} =
             DotParser.parse_file(path)
  end

  defp dot_file(tmp_dir, name, contents) do
    path = Path.join(tmp_dir, name)
    File.write!(path, contents)
    path
  end
end
