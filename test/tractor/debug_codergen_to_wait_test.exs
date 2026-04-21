defmodule Tractor.DebugCodergenToWaitTest do
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
  test "codergen then wait.human suspends without crashing", %{tmp_dir: tmp_dir} do
    pipeline = %Pipeline{
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{
              id: "draft",
              type: "codergen",
              llm_provider: "claude",
              prompt: "write haiku"
            },
            %Node{
              id: "review",
              type: "wait.human",
              attrs: %{"wait_prompt" => "approve?"}
            },
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [
        %Edge{from: "start", to: "draft"},
        %Edge{from: "draft", to: "review"},
        %Edge{from: "review", to: "exit", label: "approve", attrs: %{"label" => "approve"}},
        %Edge{from: "review", to: "exit", label: "reject", attrs: %{"label" => "reject"}}
      ]
    }

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Claude, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, _prompt, _timeout ->
      {:ok, %Tractor.ACP.Turn{response_text: "lonely haiku", token_usage: nil}}
    end)

    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "debug-wait")

    # Wait for suspension
    :timer.sleep(500)

    status =
      tmp_dir
      |> Path.join("debug-wait/review/status.json")
      |> File.read!()
      |> Jason.decode!()

    assert status["status"] == "waiting", "got: #{inspect(status)}"
  end
end
