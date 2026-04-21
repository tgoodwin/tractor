defmodule Tractor.CostBudgetRunTest do
  use ExUnit.Case, async: false

  import Mox

  alias Decimal, as: D
  alias Tractor.{DotParser, Run}

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
  test "cost budget halts after the triggering node completes and before the next node runs",
       %{tmp_dir: tmp_dir} do
    pipeline =
      dot_pipeline(
        tmp_dir,
        "cost_halt.dot",
        """
        digraph {
          graph [max_total_cost_usd="0.01"]

          start [shape=Mdiamond]
          ask [shape=box, llm_provider=codex, llm_model="gpt-5", prompt="Ask"]
          next [shape=box, llm_provider=codex, llm_model="gpt-5", prompt="Next"]
          exit [shape=Msquare]

          start -> ask -> next -> exit
        }
        """
      )

    expect_codex_turns([
      {"Ask",
       %Tractor.ACP.Turn{
         response_text: "expensive",
         token_usage: %{input_tokens: 20_000, output_tokens: 0, total_tokens: 20_000}
       }}
    ])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "cost-halt")

    assert {:error, {:budget_exhausted, :max_total_cost_usd, observed, "0.01"}} =
             Run.await(run_id, 2_000)

    assert observed == "0.025"
    run_dir = Path.join(tmp_dir, "cost-halt")
    assert events_for(run_dir, "next", "node_started") == []
  end

  @tag :tmp_dir
  test "unknown pricing emits cost_unknown once and does not crash the run", %{tmp_dir: tmp_dir} do
    pipeline =
      dot_pipeline(
        tmp_dir,
        "cost_unknown.dot",
        """
        digraph {
          start [shape=Mdiamond]
          one [shape=box, llm_provider=claude, llm_model="claude-opus-5", prompt="One"]
          two [shape=box, llm_provider=claude, llm_model="claude-opus-5", prompt="Two"]
          exit [shape=Msquare]

          start -> one -> two -> exit
        }
        """
      )

    usage = %{input_tokens: 1_000, output_tokens: 100, total_tokens: 1_100}

    expect_codexless_turns([
      {"One", usage, "done one"},
      {"Two", usage, "done two"}
    ])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "cost-unknown")
    assert {:ok, _result} = Run.await(run_id, 2_000)

    run_dir = Path.join(tmp_dir, "cost-unknown")
    assert length(events_for(run_dir, "_run", "cost_unknown")) == 1
  end

  @tag :tmp_dir
  test "checkpoint resume preserves accumulated total_cost_usd", %{tmp_dir: tmp_dir} do
    pipeline =
      dot_pipeline(
        tmp_dir,
        "cost_resume.dot",
        """
        digraph {
          graph [max_total_cost_usd="0.02"]

          start [shape=Mdiamond]
          one [shape=box, llm_provider=codex, llm_model="gpt-5", prompt="One"]
          two [shape=box, llm_provider=codex, llm_model="gpt-5", prompt="Two"]
          exit [shape=Msquare]

          start -> one -> two -> exit
        }
        """
      )

    expect_codex_turns([
      {"One",
       %Tractor.ACP.Turn{
         response_text: "first",
         token_usage: %{input_tokens: 7_200, output_tokens: 0, total_tokens: 7_200}
       }},
      {"Two", {:error, :timeout}}
    ])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "cost-resume")
    assert {:error, {:retries_exhausted, :timeout}} = Run.await(run_id, 2_000)

    run_dir = Path.join(tmp_dir, run_id)
    checkpoint = run_dir |> Path.join("checkpoint.json") |> File.read!() |> Jason.decode!()
    assert checkpoint["budgets"]["total_cost_usd"] == "0.009"

    expect_codex_turns([
      {"Two",
       %Tractor.ACP.Turn{
         response_text: "second",
         token_usage: %{input_tokens: 10_000, output_tokens: 0, total_tokens: 10_000}
       }}
    ])

    Process.sleep(5_100)
    assert {:ok, ^run_id} = Run.resume(run_dir)

    assert {:error, {:budget_exhausted, :max_total_cost_usd, "0.0215", "0.02"}} =
             Run.await(run_id, 2_000)
  end

  @tag :tmp_dir
  test "judge llm paths contribute to total cost", %{tmp_dir: tmp_dir} do
    pipeline =
      dot_pipeline(
        tmp_dir,
        "judge_cost.dot",
        """
        digraph {
          start [shape=Mdiamond]
          judge [shape=ellipse, type=judge, llm_provider=codex, llm_model="gpt-5", prompt="Judge"]
          exit [shape=Msquare]

          start -> judge
          judge -> exit [condition="accept"]
          judge -> exit [condition="reject", label="reject"]
        }
        """
      )

    expect_codex_turns([
      {"Judge",
       %Tractor.ACP.Turn{
         response_text: "{\"verdict\":\"accept\",\"critique\":\"ok\"}",
         token_usage: %{input_tokens: 8_000, output_tokens: 0, total_tokens: 8_000}
       }}
    ])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "judge-cost")
    assert {:ok, _result} = Run.await(run_id, 2_000)

    judge_status = read_json(Path.join(tmp_dir, "judge-cost/judge/status.json"))
    run_status = read_json(Path.join(tmp_dir, "judge-cost/status.json"))

    assert judge_status["total_cost_usd"] == "0.01"
    assert run_status["total_cost_usd"] == "0.01"
  end

  @tag :tmp_dir
  test "fan-in llm paths contribute to total cost", %{tmp_dir: tmp_dir} do
    pipeline =
      dot_pipeline(
        tmp_dir,
        "fan_in_cost.dot",
        """
        digraph {
          start [shape=Mdiamond]
          audit [shape=component, max_parallel=2]
          a [shape=box, llm_provider=codex, llm_model="gpt-5-mini", prompt="a"]
          b [shape=box, llm_provider=codex, llm_model="gpt-5-mini", prompt="b"]
          consolidate [shape=tripleoctagon, llm_provider=codex, llm_model="gpt-5", prompt="Summarize {{branch_responses}}"]
          exit [shape=Msquare]

          start -> audit
          audit -> a
          audit -> b
          a -> consolidate
          b -> consolidate
          consolidate -> exit
        }
        """
      )

    stub(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, opts ->
      {:ok, %{event_sink: Keyword.fetch!(opts, :event_sink)}}
    end)

    stub(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    stub(Tractor.AgentClientMock, :prompt, fn %{event_sink: sink}, prompt, _timeout ->
      zero_usage = %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

      summary_usage = %{
        input_tokens: 8_000,
        output_tokens: 0,
        total_tokens: 8_000
      }

      case prompt do
        "a" ->
          sink.(%{kind: :usage, data: zero_usage})

          {:ok, %Tractor.ACP.Turn{response_text: "branch a", token_usage: zero_usage}}

        "b" ->
          sink.(%{kind: :usage, data: zero_usage})

          {:ok, %Tractor.ACP.Turn{response_text: "branch b", token_usage: zero_usage}}

        rendered ->
          assert String.starts_with?(rendered, "Summarize ")
          sink.(%{kind: :usage, data: summary_usage})

          {:ok, %Tractor.ACP.Turn{response_text: "summary", token_usage: summary_usage}}
      end
    end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "fan-in-cost")
    assert {:ok, _result} = Run.await(run_id, 2_000)

    consolidate_status = read_json(Path.join(tmp_dir, "fan-in-cost/consolidate/status.json"))
    run_status = read_json(Path.join(tmp_dir, "fan-in-cost/status.json"))

    assert consolidate_status["total_cost_usd"] == "0.01"
    assert run_status["total_cost_usd"] == "0.01"
  end

  @tag :tmp_dir
  test "mixed-provider cumulative usage snapshots are costed by delta", %{tmp_dir: tmp_dir} do
    pipeline =
      dot_pipeline(
        tmp_dir,
        "mixed_provider_cost.dot",
        """
        digraph {
          start [shape=Mdiamond]
          claude_step [shape=box, llm_provider=claude, llm_model="claude-sonnet-4-6", prompt="Claude"]
          codex_step [shape=box, llm_provider=codex, llm_model="gpt-5", prompt="Codex"]
          gemini_step [shape=box, llm_provider=gemini, llm_model="gemini-3-pro", prompt="Gemini"]
          exit [shape=Msquare]

          start -> claude_step -> codex_step -> gemini_step -> exit
        }
        """
      )

    expect_snapshot_turns([
      {Tractor.Agent.Claude, "Claude",
       [
         %{input_tokens: 400, output_tokens: 0, total_tokens: 400},
         %{input_tokens: 1_000, output_tokens: 0, total_tokens: 1_000}
       ],
       %Tractor.ACP.Turn{
         response_text: "claude ok",
         token_usage: %{input_tokens: 1_000, output_tokens: 0, total_tokens: 1_000}
       }},
      {Tractor.Agent.Codex, "Codex",
       [
         %{input_tokens: 1_200, output_tokens: 0, total_tokens: 1_200},
         %{input_tokens: 2_000, output_tokens: 0, total_tokens: 2_000}
       ],
       %Tractor.ACP.Turn{
         response_text: "codex ok",
         token_usage: %{input_tokens: 2_000, output_tokens: 0, total_tokens: 2_000}
       }},
      {Tractor.Agent.Gemini, "Gemini",
       [
         %{input_tokens: 1_000, output_tokens: 200, total_tokens: 1_200},
         %{input_tokens: 2_500, output_tokens: 500, total_tokens: 3_000}
       ],
       %Tractor.ACP.Turn{
         response_text: "gemini ok",
         token_usage: %{input_tokens: 2_500, output_tokens: 500, total_tokens: 3_000}
       }}
    ])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "mixed-provider-cost")
    assert {:ok, _result} = Run.await(run_id, 2_000)

    run_status = read_json(Path.join(tmp_dir, "mixed-provider-cost/status.json"))
    total = D.new(run_status["total_cost_usd"])

    expected = D.new("0.0125")
    delta = D.abs(D.sub(total, expected))

    assert D.compare(delta, D.new("0.01")) in [:lt, :eq]
  end

  @tag :tmp_dir
  test "late token usage after run_finalized is warned once and ignored", %{tmp_dir: tmp_dir} do
    pipeline =
      dot_pipeline(
        tmp_dir,
        "late_usage.dot",
        """
        digraph {
          start [shape=Mdiamond]
          ask [shape=box, llm_provider=codex, llm_model="gpt-5", prompt="Ask"]
          exit [shape=Msquare]

          start -> ask -> exit
        }
        """
      )

    expect_codex_turns([
      {"Ask",
       %Tractor.ACP.Turn{
         response_text: "done",
         token_usage: %{input_tokens: 1_000, output_tokens: 0, total_tokens: 1_000}
       }}
    ])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "late-usage")
    assert {:ok, _result} = Run.await(run_id, 2_000)

    [{pid, _}] = Registry.lookup(Tractor.RunRegistry, run_id)

    late_snapshot = %{
      node_id: "ask",
      iteration: 1,
      attempt: 1,
      provider: "codex",
      model: "gpt-5",
      usage: %{input_tokens: 2_000, output_tokens: 0}
    }

    send(pid, {:token_usage_snapshot, late_snapshot})
    send(pid, {:token_usage_snapshot, late_snapshot})
    Process.sleep(50)

    run_dir = Path.join(tmp_dir, "late-usage")
    assert length(events_for(run_dir, "_run", "late_token_usage")) == 1
  end

  defp dot_pipeline(tmp_dir, filename, dot) do
    path = Path.join(tmp_dir, filename)
    File.write!(path, dot)
    {:ok, pipeline} = DotParser.parse_file(path)
    pipeline
  end

  defp expect_codex_turns(turns) do
    expect(Tractor.AgentClientMock, :start_session, length(turns), fn Tractor.Agent.Codex,
                                                                      _opts ->
      {:ok, self()}
    end)

    Enum.each(turns, fn
      {prompt, {:error, reason}} ->
        expect(Tractor.AgentClientMock, :prompt, fn _pid, ^prompt, timeout
                                                    when timeout in [300_000, 600_000] ->
          {:error, reason}
        end)

        expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

      {prompt, %Tractor.ACP.Turn{} = turn} ->
        expect(Tractor.AgentClientMock, :prompt, fn _pid, ^prompt, timeout
                                                    when timeout in [300_000, 600_000] ->
          {:ok, turn}
        end)

        expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)
    end)
  end

  defp expect_codexless_turns(turns) do
    expect(Tractor.AgentClientMock, :start_session, length(turns), fn _adapter, _opts ->
      {:ok, self()}
    end)

    Enum.each(turns, fn {prompt, usage, response} ->
      expect(Tractor.AgentClientMock, :prompt, fn _pid, ^prompt, 600_000 ->
        {:ok, %Tractor.ACP.Turn{response_text: response, token_usage: usage}}
      end)

      expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)
    end)
  end

  defp expect_snapshot_turns(turns) do
    expect(Tractor.AgentClientMock, :start_session, length(turns), fn adapter, opts ->
      {:ok, %{adapter: adapter, event_sink: Keyword.fetch!(opts, :event_sink)}}
    end)

    Enum.each(turns, fn {adapter, prompt, snapshots, turn} ->
      expect_single_turn(adapter, prompt, snapshots, turn)
    end)
  end

  defp expect_single_turn(adapter, prompt, snapshots, turn) do
    expect(
      Tractor.AgentClientMock,
      :prompt,
      fn %{adapter: ^adapter, event_sink: sink}, ^prompt, _timeout ->
        Enum.each(snapshots, &sink.(%{kind: :usage, data: &1}))
        {:ok, turn}
      end
    )

    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)
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

  defp read_json(path) do
    path |> File.read!() |> Jason.decode!()
  end
end
