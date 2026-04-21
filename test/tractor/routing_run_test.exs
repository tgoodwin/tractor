defmodule Tractor.RoutingRunTest do
  use ExUnit.Case, async: false

  import Mox

  alias Tractor.{Edge, Node, Pipeline, Run}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    original = Application.get_env(:tractor, :agent_client)
    Application.put_env(:tractor, :agent_client, Tractor.AgentClientMock)

    on_exit(fn ->
      if original do
        Application.put_env(:tractor, :agent_client, original)
      else
        Application.delete_env(:tractor, :agent_client)
      end
    end)
  end

  @tag :tmp_dir
  test "retries exhausted route to the primary recovery target", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("a", "codergen",
            provider: "codex",
            prompt: "A",
            attrs: retry_attrs(%{"retry_target" => "b"})
          ),
          node("b", "codergen", provider: "codex", prompt: "B"),
          node("exit", "exit")
        ],
        edges: [edge("start", "a"), edge("a", "exit"), edge("b", "exit")]
      )

    expect_codex_sequence([
      {"A", {:error, :timeout}},
      {"A", {:error, :timeout}},
      {"B", {:ok, "recovered"}}
    ])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "route-primary")
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["b"] == "recovered"

    routed_events = events_for(Path.join(tmp_dir, "route-primary"), "a", "retry_routed")

    assert [%{"data" => %{"from_node" => "a", "to_node" => "b", "tier" => "primary"}}] =
             routed_events
  end

  @tag :tmp_dir
  test "fallback routing stays owned by the declaring node", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("a", "codergen",
            provider: "codex",
            prompt: "A",
            attrs:
              retry_attrs(%{
                "retry_target" => "b",
                "fallback_retry_target" => "c"
              })
          ),
          node("b", "codergen",
            provider: "codex",
            prompt: "B",
            attrs: retry_attrs(%{"retry_target" => "d"})
          ),
          node("c", "codergen", provider: "codex", prompt: "C"),
          node("d", "codergen", provider: "codex", prompt: "D"),
          node("exit", "exit")
        ],
        edges: [
          edge("start", "a"),
          edge("a", "exit"),
          edge("b", "exit"),
          edge("c", "exit"),
          edge("d", "exit")
        ]
      )

    expect_codex_sequence([
      {"A", {:error, :timeout}},
      {"A", {:error, :timeout}},
      {"B", {:error, :timeout}},
      {"B", {:error, :timeout}},
      {"C", {:ok, "fallback"}}
    ])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "route-fallback")
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["c"] == "fallback"
    assert events_for(Path.join(tmp_dir, "route-fallback"), "d", "node_started") == []

    routed_events =
      events_for(Path.join(tmp_dir, "route-fallback"), "b", "retry_routed")
      |> Enum.map(& &1["data"]["to_node"])

    assert routed_events == ["c"]
  end

  @tag :tmp_dir
  test "routed provenance is visible to downstream condition evaluation", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("a", "codergen",
            provider: "codex",
            prompt: "A",
            attrs: retry_attrs(%{"retry_target" => "b"})
          ),
          node("b", "codergen", provider: "codex", prompt: "B"),
          node("c", "codergen", provider: "codex", prompt: "C"),
          node("exit", "exit")
        ],
        edges: [
          edge("start", "a"),
          edge("a", "exit"),
          edge("b", "c", condition: "context.__routed_from__=a"),
          edge("b", "exit"),
          edge("c", "exit")
        ]
      )

    expect_codex_sequence([
      {"A", {:error, :timeout}},
      {"A", {:error, :timeout}},
      {"B", {:ok, "repair"}},
      {"C", {:ok, "from route"}}
    ])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "route-context")
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["__routed_from__"] == "a"
    assert result.context["c"] == "from route"
  end

  @tag :tmp_dir
  test "routing resets the target iteration counter without resetting total iterations", %{
    tmp_dir: tmp_dir
  } do
    pipeline =
      pipeline(
        graph_attrs: %{"max_total_iterations" => "5"},
        nodes: [
          node("start", "start"),
          node("b", "codergen", provider: "codex", prompt: "B"),
          node("a", "codergen",
            provider: "codex",
            prompt: "A",
            attrs: %{"retry_target" => "b"}
          ),
          node("c", "codergen", provider: "codex", prompt: "C"),
          node("exit", "exit")
        ],
        edges: [
          edge("start", "b"),
          edge("b", "c", condition: "context.__routed_from__=a"),
          edge("b", "a"),
          edge("a", "exit"),
          edge("c", "exit")
        ]
      )

    expect_codex_sequence([
      {"B", {:ok, "warmup"}},
      {"A", {:error, :timeout}},
      {"B", {:ok, "recovery"}},
      {"C", {:ok, "after route"}}
    ])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "route-iterations")

    assert {:error, {:budget_exhausted, :max_total_iterations, 5, 5}} =
             Run.await(run_id, 2_000)

    run_dir = Path.join(tmp_dir, "route-iterations")
    b_iterations = get_in(read_status(run_dir, "b"), ["iteration"])
    assert b_iterations == 1

    b_entries = get_in(read_context(run_dir), ["iterations", "b"])
    assert Enum.map(b_entries, & &1["seq"]) == [1, 1]
  end

  @tag :tmp_dir
  test "declared retry cycles terminate after one exhaustion of each node", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("a", "codergen",
            provider: "codex",
            prompt: "A",
            attrs: %{"retry_target" => "b"}
          ),
          node("b", "codergen",
            provider: "codex",
            prompt: "B",
            attrs: %{"retry_target" => "a"}
          ),
          node("exit", "exit")
        ],
        edges: [edge("start", "a"), edge("a", "exit"), edge("b", "exit")]
      )

    expect_codex_sequence([{"A", {:error, :timeout}}, {"B", {:error, :timeout}}])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "route-cycle")
    assert {:error, {:retries_exhausted, :timeout}} = Run.await(run_id, 2_000)

    run_dir = Path.join(tmp_dir, "route-cycle")
    assert length(events_for(run_dir, "a", "node_started")) == 1
    assert length(events_for(run_dir, "b", "node_started")) == 1
  end

  defp expect_codex_sequence(steps) do
    expect(Tractor.AgentClientMock, :start_session, length(steps), fn Tractor.Agent.Codex,
                                                                      _opts ->
      {:ok, self()}
    end)

    Enum.each(steps, fn {prompt, result} ->
      expect(Tractor.AgentClientMock, :prompt, fn _pid, ^prompt, 600_000 -> result end)
      expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)
    end)
  end

  defp events_for(run_dir, node_id, kind) do
    path = Path.join(run_dir, "#{node_id}/events.jsonl")

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["kind"] == kind))
    else
      []
    end
  end

  defp read_status(run_dir, node_id) do
    run_dir
    |> Path.join("#{node_id}/status.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp read_context(run_dir) do
    run_dir
    |> Path.join("checkpoint.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("context")
  end

  defp retry_attrs(extra) do
    Map.merge(%{"retries" => "1", "retry_base_ms" => "1", "retry_jitter" => "false"}, extra)
  end

  defp pipeline(opts) do
    nodes =
      opts
      |> Keyword.get(:nodes, [])
      |> Map.new(&{&1.id, &1})

    %Pipeline{
      graph_attrs: Keyword.get(opts, :graph_attrs, %{}),
      nodes: nodes,
      edges: Keyword.get(opts, :edges, [])
    }
  end

  defp node(id, type, opts \\ []) do
    %Node{
      id: id,
      type: type,
      llm_provider: Keyword.get(opts, :provider),
      prompt: Keyword.get(opts, :prompt),
      attrs: Keyword.get(opts, :attrs, %{})
    }
  end

  defp edge(from, to, opts \\ []) do
    condition = Keyword.get(opts, :condition)
    attrs = if condition, do: %{"condition" => condition}, else: %{}
    %Edge{from: from, to: to, condition: condition, attrs: attrs}
  end
end
