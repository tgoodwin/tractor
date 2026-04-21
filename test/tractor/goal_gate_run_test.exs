defmodule Tractor.GoalGateRunTest do
  use ExUnit.Case, async: false

  import Mox

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
  test "goal gate failure finalizes without invoking exit", %{tmp_dir: tmp_dir} do
    pipeline =
      dot_pipeline(
        tmp_dir,
        "goal_gate_failure.dot",
        """
        digraph {
          start [shape=Mdiamond]
          gate [shape=box, llm_provider=codex, prompt="Gate", goal_gate=true]
          exit [shape=Msquare]

          start -> gate
          gate -> exit
        }
        """
      )

    expect_codex_sequence([{"Gate", {:error, :timeout}}])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "goal-gate-fail")
    assert {:error, {:goal_gate_failed, "gate"}} = Run.await(run_id, 2_000)

    run_dir = Path.join(tmp_dir, "goal-gate-fail")
    assert events_for(run_dir, "_run", "goal_gate_failed") != []
    assert events_for(run_dir, "exit", "node_started") == []
  end

  @tag :tmp_dir
  test "satisfied goal gates still allow exit to run", %{tmp_dir: tmp_dir} do
    pipeline =
      dot_pipeline(
        tmp_dir,
        "goal_gate_success.dot",
        """
        digraph {
          start [shape=Mdiamond]
          gate [shape=box, llm_provider=codex, prompt="Gate", goal_gate=true]
          exit [shape=Msquare]

          start -> gate
          gate -> exit
        }
        """
      )

    expect_codex_sequence([{"Gate", {:ok, "passed"}}])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "goal-gate-pass")
    assert {:ok, _result} = Run.await(run_id, 2_000)

    run_dir = Path.join(tmp_dir, "goal-gate-pass")
    assert events_for(run_dir, "exit", "node_started") != []
  end

  @tag :tmp_dir
  test "goal gate satisfaction persists across resume", %{tmp_dir: tmp_dir} do
    pipeline =
      dot_pipeline(
        tmp_dir,
        "goal_gate_resume.dot",
        """
        digraph {
          start [shape=Mdiamond]
          gate [shape=box, llm_provider=codex, prompt="Gate", goal_gate=true]
          after_gate [shape=box, llm_provider=codex, prompt="After gate"]
          exit [shape=Msquare]

          start -> gate
          gate -> after_gate
          after_gate -> exit
        }
        """
      )

    expect_codex_sequence([{"Gate", {:ok, "passed"}}, {"After gate", {:error, :timeout}}])

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "goal-gate-resume")
    assert {:error, {:retries_exhausted, :timeout}} = Run.await(run_id, 2_000)

    run_dir = Path.join(tmp_dir, run_id)
    checkpoint = run_dir |> Path.join("checkpoint.json") |> File.read!() |> Jason.decode!()
    assert checkpoint["goal_gates_satisfied"] == ["gate"]

    expect_codex_sequence([{"After gate", {:ok, "resumed"}}])

    Process.sleep(5_100)
    assert {:ok, resumed_run_id} = Run.resume(run_dir)
    assert resumed_run_id == run_id
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["after_gate"] == "resumed"

    run_dir = Path.join(tmp_dir, run_id)
    assert events_for(run_dir, "gate", "node_started") |> length() == 1
    assert events_for(run_dir, "exit", "node_started") != []
  end

  defp dot_pipeline(tmp_dir, filename, dot) do
    path = Path.join(tmp_dir, filename)
    File.write!(path, dot)
    {:ok, pipeline} = DotParser.parse_file(path)
    pipeline
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
end
