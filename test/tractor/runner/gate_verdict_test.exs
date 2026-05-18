defmodule Tractor.Runner.GateVerdictTest do
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
  test "labeled edges drive the verdict explicitly (accept)", %{tmp_dir: tmp_dir} do
    pipeline = pipeline_with_labels()

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "accepted-path", _to -> {:ok, "ok"} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "gate-accept-label")
    assert {:ok, result} = Run.await(run_id, 1_000)

    events = read_events(result.run_dir, "gate")

    gate_verdict =
      Enum.find(events, &(&1["kind"] == "gate_verdict")) ||
        flunk("no gate_verdict event for labeled-accept run; got: #{inspect(events)}")

    assert gate_verdict["data"]["verdict"] == "accept"
    assert gate_verdict["data"]["routed_to"] == "accepted_branch"
    assert gate_verdict["data"]["label"] == "accept"

    # gate_verdict is distinct from node_succeeded AND edge_taken.
    assert Enum.any?(events, &(&1["kind"] == "node_succeeded"))
    assert Enum.any?(events, &(&1["kind"] == "edge_taken"))
  end

  @tag :tmp_dir
  test "verbose condition without a label derives 'reject' from substring", %{tmp_dir: tmp_dir} do
    # `context.start != "fail"` parses cleanly, evaluates truthy (start node
    # output is "", not "fail"), and contains the "fail" keyword that the
    # derive_gate_verdict fallback recognizes as a reject signal.
    pipeline = pipeline_with_verbose_conditions(~s|context.start != "fail"|)

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "rejected-path", _to -> {:ok, "ok"} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "gate-substr-reject")
    assert {:ok, _result} = Run.await(run_id, 1_000)

    events = read_events(tmp_dir |> Path.join("gate-substr-reject"), "gate")

    gate_verdict = Enum.find(events, &(&1["kind"] == "gate_verdict"))
    assert gate_verdict, "expected gate_verdict event; got: #{inspect(events)}"
    assert gate_verdict["data"]["verdict"] == "reject"
    assert gate_verdict["data"]["label"] in [nil, ""]
  end

  @tag :tmp_dir
  test "ambiguous condition produces verdict 'unknown'", %{tmp_dir: tmp_dir} do
    # Truthy condition with no verdict-keyword substring → "unknown".
    pipeline = pipeline_with_verbose_conditions(~s|context.start = ""|)

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "rejected-path", _to -> {:ok, "ok"} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "gate-substr-unknown")
    assert {:ok, _result} = Run.await(run_id, 1_000)

    events = read_events(tmp_dir |> Path.join("gate-substr-unknown"), "gate")

    gate_verdict = Enum.find(events, &(&1["kind"] == "gate_verdict"))
    assert gate_verdict, "expected gate_verdict event; got: #{inspect(events)}"
    assert gate_verdict["data"]["verdict"] == "unknown"
  end

  @tag :tmp_dir
  test "non-conditional node routing does NOT emit gate_verdict", %{tmp_dir: tmp_dir} do
    pipeline = %Pipeline{
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [%Edge{from: "start", to: "exit"}]
    }

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "no-gate-emission")
    assert {:ok, _result} = Run.await(run_id, 1_000)

    events = read_events(tmp_dir |> Path.join("no-gate-emission"), "start")

    refute Enum.any?(events, &(&1["kind"] == "gate_verdict"))
  end

  defp pipeline_with_labels do
    %Pipeline{
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{id: "gate", type: "conditional"},
            %Node{
              id: "accepted_branch",
              type: "codergen",
              llm_provider: "codex",
              prompt: "accepted-path"
            },
            %Node{
              id: "rejected_branch",
              type: "codergen",
              llm_provider: "codex",
              prompt: "rejected-path"
            },
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [
        %Edge{from: "start", to: "gate"},
        %Edge{
          from: "gate",
          to: "accepted_branch",
          condition: "context.start = \"\"",
          label: "accept"
        },
        %Edge{
          from: "gate",
          to: "rejected_branch",
          condition: "context.start != \"\"",
          label: "reject"
        },
        %Edge{from: "accepted_branch", to: "exit"},
        %Edge{from: "rejected_branch", to: "exit"}
      ]
    }
  end

  defp pipeline_with_verbose_conditions(condition_taken) do
    %Pipeline{
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{id: "gate", type: "conditional"},
            %Node{
              id: "rejected_branch",
              type: "codergen",
              llm_provider: "codex",
              prompt: "rejected-path"
            },
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [
        %Edge{from: "start", to: "gate"},
        %Edge{from: "gate", to: "rejected_branch", condition: condition_taken},
        %Edge{from: "rejected_branch", to: "exit"}
      ]
    }
  end

  defp read_events(run_dir, node_id) do
    path = Path.join([run_dir, node_id, "events.jsonl"])

    if File.exists?(path) do
      path |> File.stream!() |> Enum.map(&Jason.decode!/1)
    else
      []
    end
  end
end
