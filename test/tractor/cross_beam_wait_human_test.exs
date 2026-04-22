defmodule Tractor.CrossBeamWaitHumanTest do
  use ExUnit.Case, async: false

  alias Tractor.Run

  @tag :tmp_dir
  test "a second BEAM resolves wait.human through the control file transport", %{tmp_dir: tmp_dir} do
    run_id = "cross-beam-wait"
    assert {:ok, ^run_id} = Run.start(wait_pipeline(run_id), runs_dir: tmp_dir, run_id: run_id)

    wait_for_waiting(run_id, "gate")

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        args:
          ebin_args() ++
            [
              Path.expand("../support/cross_beam_submit_wait_choice.exs", __DIR__),
              run_id,
              tmp_dir,
              "gate",
              "approve"
            ]
      ])

    assert_receive {^port, {:exit_status, 0}}, 5_000
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["approved"]["stdout"] == "approved"
    refute File.exists?(Path.join([tmp_dir, run_id, "control", "wait-gate.json"]))
  end

  defp wait_pipeline(run_id) do
    %Tractor.Pipeline{
      path: "#{run_id}.dot",
      nodes:
        Map.new(
          [
            %Tractor.Node{id: "start", type: "start"},
            %Tractor.Node{
              id: "gate",
              type: "wait.human",
              attrs: %{"wait_prompt" => "Approve?"}
            },
            %Tractor.Node{
              id: "approved",
              type: "tool",
              attrs: %{"command" => ["sh", "-c", "printf approved"]}
            },
            %Tractor.Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [
        %Tractor.Edge{from: "start", to: "gate"},
        %Tractor.Edge{from: "gate", to: "approved", label: "approve"},
        %Tractor.Edge{from: "approved", to: "exit"}
      ]
    }
  end

  defp wait_for_waiting(run_id, node_id, attempts \\ 50)

  defp wait_for_waiting(run_id, node_id, 0) do
    flunk("expected #{node_id} to be waiting in run #{run_id}")
  end

  defp wait_for_waiting(run_id, node_id, attempts) do
    waiting =
      case Registry.lookup(Tractor.RunRegistry, run_id) do
        [{pid, _value}] -> :sys.get_state(pid).waiting[node_id]
        [] -> nil
      end

    if waiting do
      waiting
    else
      Process.sleep(20)
      wait_for_waiting(run_id, node_id, attempts - 1)
    end
  end

  defp ebin_args do
    Path.wildcard(Path.expand("../../_build/test/lib/*/ebin", __DIR__))
    |> Enum.flat_map(fn path -> ["-pa", path] end)
  end
end
