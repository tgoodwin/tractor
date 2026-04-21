defmodule Tractor.ConditionalRunTest do
  use ExUnit.Case, async: false

  import Mox

  alias Tractor.{Edge, Node, Pipeline, Run}

  setup :set_mox_global
  setup :verify_on_exit!

  @tag :tmp_dir
  test "conditional nodes route via the existing edge selector", %{tmp_dir: tmp_dir} do
    pipeline = %Pipeline{
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{id: "route", type: "conditional"},
            %Node{id: "high", type: "codergen", llm_provider: "codex", prompt: "high"},
            %Node{id: "low", type: "codergen", llm_provider: "codex", prompt: "low"},
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [
        %Edge{from: "start", to: "route"},
        %Edge{from: "route", to: "high", condition: "context.start = \"\""},
        %Edge{from: "route", to: "low", condition: "context.start != \"\""},
        %Edge{from: "high", to: "exit"},
        %Edge{from: "low", to: "exit"}
      ]
    }

    original = Application.get_env(:tractor, :agent_client)
    Application.put_env(:tractor, :agent_client, Tractor.AgentClientMock)

    on_exit(fn ->
      if original do
        Application.put_env(:tractor, :agent_client, original)
      else
        Application.delete_env(:tractor, :agent_client)
      end
    end)

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "high", 600_000 -> {:ok, "taken"} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "conditional-route")
    assert {:ok, result} = Run.await(run_id, 1_000)

    route_events =
      result.run_dir
      |> Path.join("route/events.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(route_events, fn event ->
             event["kind"] == "edge_taken" and event["data"]["to"] == "high"
           end)

    refute Enum.any?(route_events, fn event ->
             event["kind"] == "edge_taken" and event["data"]["to"] == "low"
           end)
  end
end
