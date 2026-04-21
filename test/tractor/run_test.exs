defmodule Tractor.RunTest do
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
  test "runs a minimal start to exit pipeline", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [node("start", "start"), node("exit", "exit")],
        edges: [edge("start", "exit")]
      )

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-minimal")
    assert run_id == "run-minimal"

    assert {:ok, result} = Run.await(run_id, 1_000)
    assert result.context["start"] == ""
    assert result.context["exit"] == ""
    assert get_in(result.context, ["iterations", "start"]) |> length() == 1
    assert get_in(result.context, ["iterations", "exit"]) |> length() == 1
    assert File.exists?(Path.join(result.run_dir, "manifest.json"))
    assert File.exists?(Path.join(result.run_dir, "start/status.json"))
    assert File.exists?(Path.join(result.run_dir, "exit/status.json"))
  end

  @tag :tmp_dir
  test "runs a four-node pipeline in order and carries context", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("one", "codergen", provider: "codex", prompt: "First"),
          node("two", "codergen", provider: "gemini", prompt: "Second {{one}}"),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "two"), edge("two", "exit")]
      )

    expect_session(Tractor.Agent.Codex, "First", "one out")
    expect_session(Tractor.Agent.Gemini, "Second one out", "two out")

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-context")
    assert {:ok, result} = Run.await(run_id, 1_000)

    assert result.context["one"] == "one out"
    assert result.context["two"] == "two out"
  end

  @tag :tmp_dir
  test "writes codergen token usage to node status json", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("one", "codergen", provider: "codex", prompt: "First"),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    usage = %{input_tokens: 12, output_tokens: 8, total_tokens: 20, raw: %{"totalTokens" => 20}}

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 ->
      {:ok, %Tractor.ACP.Turn{response_text: "one out", token_usage: usage}}
    end)

    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-token-usage")
    assert {:ok, result} = Run.await(run_id, 1_000)

    status = read_json(Path.join(result.run_dir, "one/status.json"))

    assert status["token_usage"] == %{
             "input_tokens" => 12,
             "output_tokens" => 8,
             "total_tokens" => 20,
             "raw" => %{"totalTokens" => 20}
           }
  end

  @tag :tmp_dir
  test "propagates handler errors", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("one", "codergen", provider: "codex", prompt: "First"),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 -> {:error, :timeout} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-error")
    assert {:error, {:retries_exhausted, :timeout}} = Run.await(run_id, 1_000)

    status = read_json(Path.join(tmp_dir, "run-error/one/status.json"))
    assert status["status"] == "error"
    assert status["reason"] =~ ":timeout"
  end

  @tag :tmp_dir
  test "retries transient handler errors inside one semantic iteration", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("one", "codergen",
            provider: "codex",
            prompt: "First",
            attrs: %{"retries" => "2", "retry_base_ms" => "1", "retry_jitter" => "false"}
          ),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    expect(Tractor.AgentClientMock, :start_session, 3, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 -> {:error, :timeout} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)
    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 -> {:error, :timeout} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)
    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 -> {:ok, "ok"} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-retry-success")
    assert {:ok, result} = Run.await(run_id, 1_000)

    events = read_events(result.run_dir, "one")
    assert count_events(events, "iteration_started") == 1
    assert count_events(events, "retry_attempted") == 2
    assert count_events(events, "iteration_completed") == 1
    assert get_in(result.context, ["iterations", "one"]) |> length() == 1
  end

  @tag :tmp_dir
  test "exhausted retries preserve the original transient reason", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("one", "codergen",
            provider: "codex",
            prompt: "First",
            attrs: %{"retries" => "2", "retry_base_ms" => "1", "retry_jitter" => "false"}
          ),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    expect(Tractor.AgentClientMock, :start_session, 3, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, 3, fn _pid, "First", 600_000 ->
      {:error, :timeout}
    end)

    expect(Tractor.AgentClientMock, :stop, 3, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-retry-exhausted")
    assert {:error, {:retries_exhausted, :timeout}} = Run.await(run_id, 1_000)

    status = read_json(Path.join(tmp_dir, "run-retry-exhausted/one/status.json"))
    assert status["reason"] =~ "retries_exhausted"
    assert status["reason"] =~ ":timeout"
  end

  @tag :tmp_dir
  test "permanent errors do not retry", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("one", "codergen",
            provider: "codex",
            prompt: "First",
            attrs: %{"retries" => "2", "retry_base_ms" => "1"}
          ),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 ->
      {:error, :judge_parse_error}
    end)

    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-permanent")
    assert {:error, :judge_parse_error} = Run.await(run_id, 1_000)

    events = read_events(Path.join(tmp_dir, "run-permanent"), "one")
    assert count_events(events, "retry_attempted") == 0
  end

  @tag :tmp_dir
  test "node timeout kills a hung handler and routes through retry failure", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("one", "codergen",
            provider: "codex",
            prompt: "First",
            timeout: 50,
            attrs: %{"timeout" => "50ms"}
          ),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 50 ->
      Process.sleep(:infinity)
    end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-timeout")
    started_at = System.monotonic_time(:millisecond)
    assert {:error, {:retries_exhausted, :node_timeout}} = Run.await(run_id, 1_000)
    assert System.monotonic_time(:millisecond) - started_at < 550

    events = read_events(Path.join(tmp_dir, "run-timeout"), "one")
    assert count_events(events, "node_timeout") == 1
  end

  @tag :tmp_dir
  test "seeded jitter produces deterministic retry backoff sequence", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("one", "codergen",
            provider: "codex",
            prompt: "First",
            attrs: %{"retries" => "2", "retry_base_ms" => "10", "retry_cap_ms" => "100"}
          ),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    expect(Tractor.AgentClientMock, :start_session, 3, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 -> {:error, :timeout} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)
    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 -> {:error, :timeout} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)
    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 -> {:ok, "ok"} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-jitter")
    assert {:ok, result} = Run.await(run_id, 1_000)

    backoffs =
      result.run_dir
      |> read_events("one")
      |> Enum.filter(&(&1["kind"] == "retry_attempted"))
      |> Enum.map(&get_in(&1, ["data", "backoff_ms"]))

    assert backoffs == [
             jitter("run-jitter", "one", 1, 1, 10),
             jitter("run-jitter", "one", 1, 2, 20)
           ]
  end

  @tag :tmp_dir
  test "graph retry fallback applies and node retry override wins", %{tmp_dir: tmp_dir} do
    fallback =
      pipeline(
        graph_attrs: %{"retries" => "1", "retry_base_ms" => "1", "retry_jitter" => "false"},
        nodes: [
          node("start", "start"),
          node("one", "codergen", provider: "codex", prompt: "First"),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    expect(Tractor.AgentClientMock, :start_session, 2, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 -> {:error, :timeout} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)
    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 -> {:ok, "ok"} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(fallback, runs_dir: tmp_dir, run_id: "run-graph-retry")
    assert {:ok, _result} = Run.await(run_id, 1_000)

    override =
      pipeline(
        graph_attrs: %{"retries" => "1", "retry_base_ms" => "1", "retry_jitter" => "false"},
        nodes: [
          node("start", "start"),
          node("one", "codergen",
            provider: "codex",
            prompt: "First",
            attrs: %{"retries" => "0"}
          ),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 -> {:error, :timeout} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(override, runs_dir: tmp_dir, run_id: "run-node-retry")
    assert {:error, {:retries_exhausted, :timeout}} = Run.await(run_id, 1_000)
  end

  @tag :tmp_dir
  test "total iteration budget halts before starting the next node", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        graph_attrs: %{"max_total_iterations" => "1"},
        nodes: [
          node("start", "start"),
          node("one", "codergen", provider: "codex", prompt: "First"),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-total-budget")
    assert {:error, {:budget_exhausted, :max_total_iterations, 1, 1}} = Run.await(run_id, 1_000)

    events = read_events(Path.join(tmp_dir, "run-total-budget"), "_run")

    assert [%{"data" => %{"observed" => 1, "limit" => 1}}] =
             Enum.filter(events, &(&1["kind"] == "budget_exhausted"))
  end

  @tag :tmp_dir
  test "wall-clock budget is checked between nodes", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        graph_attrs: %{"max_wall_clock" => "50ms"},
        nodes: [
          node("start", "start"),
          node("one", "codergen", provider: "codex", prompt: "First"),
          node("two", "codergen", provider: "codex", prompt: "Second"),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "two"), edge("two", "exit")]
      )

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 ->
      Process.sleep(80)
      {:ok, "one"}
    end)

    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-wall-budget")
    assert {:error, {:budget_exhausted, :max_wall_clock, observed, 50}} = Run.await(run_id, 1_000)
    assert observed >= 50
  end

  @tag :tmp_dir
  test "resume computes wall-clock budget from original wall start", %{tmp_dir: tmp_dir} do
    dot_path = Path.join(tmp_dir, "resume_budget.dot")

    File.write!(dot_path, """
    digraph {
      graph [goal="resume budget", max_wall_clock="1s"]

      start [shape=Mdiamond]
      one [shape=box, prompt="First", llm_provider=codex]
      exit [shape=Msquare]

      start -> one
      one -> exit
    }
    """)

    assert {:ok, parsed} = Tractor.DotParser.parse_file(dot_path)

    run_dir = Path.join(tmp_dir, "run-resume-budget")
    File.mkdir_p!(run_dir)

    started_at_wall_iso =
      DateTime.utc_now()
      |> DateTime.add(-2, :second)
      |> DateTime.to_iso8601()

    File.write!(
      Path.join(run_dir, "manifest.json"),
      Jason.encode!(%{
        "run_id" => "run-resume-budget",
        "pipeline_path" => dot_path,
        "started_at" => started_at_wall_iso,
        "status" => "running",
        "provider_commands" => []
      })
    )

    Tractor.Checkpoint.save(%{
      pipeline: parsed,
      store: %{run_id: "run-resume-budget", run_dir: run_dir},
      agenda: :queue.in("one", :queue.new()),
      completed: MapSet.new(["start"]),
      iterations: %{"start" => 1},
      context: %{"start" => "", "iterations" => %{"start" => []}},
      provider_commands: [],
      started_at_wall_iso: started_at_wall_iso
    })

    assert {:ok, run_id} = Run.resume(run_dir)

    assert {:error, {:budget_exhausted, :max_wall_clock, observed, 1_000}} =
             Run.await(run_id, 1_000)

    assert observed >= 1_000
  end

  @tag :tmp_dir
  test "persists ACP plan updates to the active node event log", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("one", "codergen", provider: "codex", prompt: "First"),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, opts ->
      opts[:event_sink].(%{
        kind: :plan_update,
        data: %{
          "entries" => [
            %{"content" => "Sketch", "priority" => "high", "status" => "pending"},
            %{"content" => "Draft", "priority" => "medium", "status" => "in_progress"},
            %{"content" => "Polish", "priority" => "low", "status" => "completed"}
          ],
          "raw" => %{"sessionUpdate" => "plan"}
        }
      })

      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 ->
      {:ok, %Tractor.ACP.Turn{response_text: "ok"}}
    end)

    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-plan")
    assert {:ok, result} = Run.await(run_id, 1_000)

    assert [
             %{
               "data" => %{
                 "entries" => entries,
                 "iteration" => 1,
                 "raw" => %{"sessionUpdate" => "plan"}
               }
             }
           ] = result.run_dir |> read_events("one") |> Enum.filter(&(&1["kind"] == "plan_update"))

    assert Enum.map(entries, & &1["status"]) == ["pending", "in_progress", "completed"]
  end

  @tag :tmp_dir
  test "status_agent off does not start an observer or emit status updates", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        graph_attrs: %{"status_agent" => "off"},
        nodes: [
          node("start", "start"),
          node("one", "codergen", provider: "codex", prompt: "First"),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    expect_session(Tractor.Agent.Codex, "First", "ok")

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-status-off")
    assert {:ok, result} = Run.await(run_id, 1_000)

    assert Registry.lookup(Tractor.StatusAgentRegistry, run_id) == []
    refute result.run_dir |> read_events("_run") |> Enum.any?(&(&1["kind"] == "status_update"))
  end

  @tag :tmp_dir
  test "status_agent emits status updates with coalesced id artifacts", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        graph_attrs: %{"status_agent" => "claude"},
        nodes: [
          node("start", "start"),
          node("one", "codergen", provider: "codex", prompt: "First"),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    expect_session(Tractor.Agent.Codex, "First", "node output")

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Claude, opts ->
      opts[:event_sink].(%{kind: :agent_message_chunk, data: %{"text" => "live "}})
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, prompt, 30_000 ->
      assert prompt =~ "node output"
      {:ok, %Tractor.ACP.Turn{response_text: "live summary"}}
    end)

    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-status-agent")
    assert {:ok, result} = Run.await(run_id, 1_000)

    events =
      eventually(fn ->
        result.run_dir |> read_events("_run") |> Enum.filter(&(&1["kind"] == "status_update"))
      end)

    ids = events |> Enum.map(&get_in(&1, ["data", "status_update_id"])) |> Enum.uniq()

    assert ids == ["status-1"]
    assert File.exists?(Path.join([result.run_dir, "_status_agent", "1", "prompt.md"]))
    assert File.exists?(Path.join([result.run_dir, "_status_agent", "1", "response.md"]))
    assert File.exists?(Path.join([result.run_dir, "_status_agent", "1", "status.json"]))
  end

  @tag :tmp_dir
  @tag :capture_log
  test "propagates handler crashes", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("one", "codergen", provider: "codex", prompt: "First"),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 600_000 -> raise "boom" end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-crash")

    assert {:error,
            {:retries_exhausted, {:handler_crash, {%RuntimeError{message: "boom"}, _stack}}}} =
             Run.await(run_id, 1_000)
  end

  @tag :tmp_dir
  test "runs claude, codex, then gemini providers in graph order", %{tmp_dir: tmp_dir} do
    test_pid = self()

    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("claude", "codergen", provider: "claude", prompt: "Claude"),
          node("codex", "codergen", provider: "codex", prompt: "Codex {{claude}}"),
          node("gemini", "codergen", provider: "gemini", prompt: "Gemini {{codex}}"),
          node("exit", "exit")
        ],
        edges: [
          edge("start", "claude"),
          edge("claude", "codex"),
          edge("codex", "gemini"),
          edge("gemini", "exit")
        ]
      )

    expect_ordered_session(test_pid, Tractor.Agent.Claude, :claude, "Claude", "c1")
    expect_ordered_session(test_pid, Tractor.Agent.Codex, :codex, "Codex c1", "c2")
    expect_ordered_session(test_pid, Tractor.Agent.Gemini, :gemini, "Gemini c2", "c3")

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-providers")
    assert {:ok, _result} = Run.await(run_id, 1_000)

    assert_receive {:provider, :claude}
    assert_receive {:provider, :codex}
    assert_receive {:provider, :gemini}
  end

  defp pipeline(opts) do
    nodes =
      opts
      |> Keyword.fetch!(:nodes)
      |> Map.new(&{&1.id, &1})

    %Pipeline{
      nodes: nodes,
      edges: Keyword.fetch!(opts, :edges),
      graph_attrs: Keyword.get(opts, :graph_attrs, %{})
    }
  end

  defp node(id, type, opts \\ []) do
    %Node{
      id: id,
      type: type,
      llm_provider: Keyword.get(opts, :provider),
      prompt: Keyword.get(opts, :prompt),
      timeout: Keyword.get(opts, :timeout),
      attrs: Keyword.get(opts, :attrs, %{})
    }
  end

  defp edge(from, to), do: %Edge{from: from, to: to}

  defp expect_session(adapter, prompt, response) do
    expect(Tractor.AgentClientMock, :start_session, fn ^adapter, _opts -> {:ok, self()} end)
    expect(Tractor.AgentClientMock, :prompt, fn _pid, ^prompt, 600_000 -> {:ok, response} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)
  end

  defp expect_ordered_session(test_pid, adapter, provider, prompt, response) do
    expect(Tractor.AgentClientMock, :start_session, fn ^adapter, _opts ->
      send(test_pid, {:provider, provider})
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, ^prompt, 600_000 -> {:ok, response} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()

  defp read_events(run_dir, node_id) do
    run_dir
    |> Path.join("#{node_id}/events.jsonl")
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end

  defp count_events(events, kind), do: Enum.count(events, &(&1["kind"] == kind))

  defp jitter(run_id, node_id, iteration, attempt, delay) do
    <<a::32, b::32, c::32>> =
      :crypto.hash(:sha256, "#{run_id}:#{node_id}:#{iteration}:#{attempt}")
      |> binary_part(0, 12)

    seed_state = :rand.seed_s(:exsplus, {a, b, c})
    {value, _seed_state} = :rand.uniform_s(delay, seed_state)
    value
  end

  defp eventually(fun) do
    Enum.find_value(1..50, fn _attempt ->
      case fun.() do
        [] ->
          Process.sleep(20)
          nil

        value ->
          value
      end
    end) || []
  end
end
