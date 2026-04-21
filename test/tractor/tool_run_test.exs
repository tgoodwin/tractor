defmodule Tractor.ToolRunTest do
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
  test "tool retries exhaust as {:retries_exhausted, {:tool_failed, status}}", %{
    tmp_dir: tmp_dir
  } do
    pipeline = %Pipeline{
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{
              id: "tool",
              type: "tool",
              attrs: %{
                "command" => ["sh", "-c", "exit 17"],
                "retries" => "2",
                "retry_base_ms" => "1",
                "retry_jitter" => "false"
              }
            },
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [%Edge{from: "start", to: "tool"}, %Edge{from: "tool", to: "exit"}]
    }

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "tool-retry-exhausted")
    assert {:error, {:retries_exhausted, {:tool_failed, 17}}} = Run.await(run_id, 2_000)

    events =
      tmp_dir
      |> Path.join("tool-retry-exhausted/tool/events.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    assert Enum.count(events, &(&1["kind"] == "retry_attempted")) == 2
    assert Enum.count(events, &(&1["kind"] == "tool_invoked")) == 3
  end

  @tag :tmp_dir
  test "tool retry_target routes to a backup tool node after exhaustion", %{tmp_dir: tmp_dir} do
    pipeline = %Pipeline{
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{
              id: "primary",
              type: "tool",
              attrs: %{
                "command" => ["sh", "-c", "exit 9"],
                "retries" => "1",
                "retry_base_ms" => "1",
                "retry_jitter" => "false",
                "retry_target" => "backup"
              }
            },
            %Node{
              id: "backup",
              type: "tool",
              attrs: %{"command" => ["sh", "-c", "printf backup"]}
            },
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [
        %Edge{from: "start", to: "primary"},
        %Edge{from: "primary", to: "exit"},
        %Edge{from: "backup", to: "exit"}
      ]
    }

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "tool-retry-route")
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["backup"]["stdout"] == "backup"
  end

  @tag :tmp_dir
  test "tool retries can succeed on the third attempt", %{tmp_dir: tmp_dir} do
    script = """
    count_file=counter
    count=$(cat "$count_file" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf %s "$count" > "$count_file"
    if [ "$count" -lt 3 ]; then
      exit 17
    fi
    printf success
    """

    pipeline = %Pipeline{
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{
              id: "tool",
              type: "tool",
              attrs: %{
                "command" => ["sh", "-c", script],
                "retries" => "2",
                "retry_base_ms" => "1",
                "retry_jitter" => "false"
              }
            },
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [%Edge{from: "start", to: "tool"}, %Edge{from: "tool", to: "exit"}]
    }

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "tool-retry-success")
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["tool"]["stdout"] == "success"
  end

  @tag :tmp_dir
  test "goal_gate tool_not_found finalizes as goal_gate_failed", %{tmp_dir: tmp_dir} do
    pipeline = %Pipeline{
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{
              id: "tool",
              type: "tool",
              goal_gate: true,
              attrs: %{"goal_gate" => "true", "command" => ["nonexistent-binary-tractor-xyz"]}
            },
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [%Edge{from: "start", to: "tool"}, %Edge{from: "tool", to: "exit"}]
    }

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "tool-goal-gate")
    assert {:error, {:goal_gate_failed, "tool"}} = Run.await(run_id, 2_000)
  end

  @tag :tmp_dir
  test "tool_not_found is permanent and does not retry", %{tmp_dir: tmp_dir} do
    pipeline = %Pipeline{
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{
              id: "tool",
              type: "tool",
              attrs: %{
                "command" => ["nonexistent-binary-tractor-xyz"],
                "retries" => "2",
                "retry_base_ms" => "1",
                "retry_jitter" => "false"
              }
            },
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [%Edge{from: "start", to: "tool"}, %Edge{from: "tool", to: "exit"}]
    }

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "tool-not-found")

    assert {:error, {:tool_not_found, "nonexistent-binary-tractor-xyz"}} =
             Run.await(run_id, 2_000)

    events =
      tmp_dir
      |> Path.join("tool-not-found/tool/events.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    assert not Enum.any?(events, &(&1["kind"] == "retry_attempted"))
  end

  @tag :tmp_dir
  test "tool nodes do not contribute to total cost or cost_unknown events", %{tmp_dir: tmp_dir} do
    pipeline = %Pipeline{
      graph_attrs: %{"max_total_cost_usd" => "0.01"},
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{
              id: "tool",
              type: "tool",
              attrs: %{"command" => ["sh", "-c", "printf costless"]}
            },
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [%Edge{from: "start", to: "tool"}, %Edge{from: "tool", to: "exit"}]
    }

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "tool-costless")
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["tool"]["stdout"] == "costless"

    manifest =
      tmp_dir
      |> Path.join("tool-costless/manifest.json")
      |> File.read!()
      |> Jason.decode!()

    run_events =
      tmp_dir
      |> Path.join("tool-costless/_run/events.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    assert manifest["total_cost_usd"] == "0"
    refute Enum.any?(run_events, &(&1["kind"] == "cost_unknown"))
  end

  @tag :tmp_dir
  test "downstream llm cost accrues after a tool node while tool cost stays zero", %{
    tmp_dir: tmp_dir
  } do
    usage = %{input_tokens: 100, output_tokens: 20, total_tokens: 120}

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "after tool", 600_000 ->
      {:ok, %Tractor.ACP.Turn{response_text: "llm", token_usage: usage}}
    end)

    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    pipeline = %Pipeline{
      graph_attrs: %{"max_total_cost_usd" => "0.50"},
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{id: "tool", type: "tool", attrs: %{"command" => ["sh", "-c", "printf bridge"]}},
            %Node{
              id: "llm",
              type: "codergen",
              llm_provider: "codex",
              llm_model: "gpt-5",
              prompt: "after tool"
            },
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [
        %Edge{from: "start", to: "tool"},
        %Edge{from: "tool", to: "llm"},
        %Edge{from: "llm", to: "exit"}
      ]
    }

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "tool-llm-cost")
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["tool"]["stdout"] == "bridge"
    assert result.context["llm"] == "llm"

    manifest =
      tmp_dir
      |> Path.join("tool-llm-cost/manifest.json")
      |> File.read!()
      |> Jason.decode!()

    tool_events =
      tmp_dir
      |> Path.join("tool-llm-cost/tool/events.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    run_events =
      tmp_dir
      |> Path.join("tool-llm-cost/_run/events.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    refute Enum.any?(tool_events, &(&1["kind"] == "token_usage"))
    refute Enum.any?(run_events, &(&1["kind"] == "cost_unknown"))
    refute manifest["total_cost_usd"] == "0"
  end

  @tag :tmp_dir
  test "real grep and wc binaries compose through tool stdout chaining", %{tmp_dir: tmp_dir} do
    pipeline = %Pipeline{
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{
              id: "grep",
              type: "tool",
              attrs: %{
                "command" => ["grep", "-rn", "defmodule", "lib/tractor"],
                "cwd" => File.cwd!()
              }
            },
            %Node{
              id: "count",
              type: "tool",
              attrs: %{"command" => ["wc", "-l"], "stdin" => "{{grep.stdout}}"}
            },
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [
        %Edge{from: "start", to: "grep"},
        %Edge{from: "grep", to: "count"},
        %Edge{from: "count", to: "exit"}
      ]
    }

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "tool-grep-wc")
    assert {:ok, result} = Run.await(run_id, 2_000)

    count =
      result.context["count"]["stdout"]
      |> String.trim()
      |> String.to_integer()

    assert count > 0
  end

  @tag :tmp_dir
  test "yes with timeout emits node_timeout without exhausting memory", %{tmp_dir: tmp_dir} do
    pipeline = %Pipeline{
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{
              id: "tool",
              type: "tool",
              timeout: 50,
              attrs: %{
                "command" => ["yes"],
                "max_output_bytes" => "1024",
                "timeout" => "50ms"
              }
            },
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [%Edge{from: "start", to: "tool"}, %Edge{from: "tool", to: "exit"}]
    }

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "tool-timeout")
    assert {:error, {:retries_exhausted, :node_timeout}} = Run.await(run_id, 2_000)

    events =
      tmp_dir
      |> Path.join("tool-timeout/tool/events.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(events, &(&1["kind"] == "node_timeout"))
  end
end
