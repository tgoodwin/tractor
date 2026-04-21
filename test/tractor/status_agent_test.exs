defmodule Tractor.StatusAgentTest do
  use ExUnit.Case, async: false

  import Mox

  alias Tractor.StatusAgent

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
  test "drops oldest observations after bounded queue fills", %{tmp_dir: tmp_dir} do
    run_id = "status-drop"
    run_dir = Path.join(tmp_dir, run_id)
    File.mkdir_p!(run_dir)
    Tractor.RunEvents.register_run(run_id, run_dir)
    parent = self()

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Claude, _opts ->
      send(parent, :status_agent_started)
      Process.sleep(:infinity)
    end)

    assert :ok = StatusAgent.start_run(run_id, run_dir, "claude")
    StatusAgent.observe(run_id, payload("first"))
    assert_receive :status_agent_started, 1_000

    Enum.each(1..22, fn index ->
      StatusAgent.observe(run_id, payload("queued-#{index}"))
    end)

    events = eventually_events(run_dir, "status_agent_dropped")
    assert [%{"data" => %{"node_id" => "queued-1", "iteration" => 1}} | _rest] = events

    StatusAgent.stop_run(run_id)
  end

  @tag :tmp_dir
  test "timeout failures emit status_update_failed and do not crash caller", %{tmp_dir: tmp_dir} do
    run_id = "status-timeout"
    run_dir = Path.join(tmp_dir, run_id)
    File.mkdir_p!(run_dir)
    Tractor.RunEvents.register_run(run_id, run_dir)

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Claude, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, _prompt, 30_000 -> {:error, :timeout} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert :ok = StatusAgent.start_run(run_id, run_dir, "claude")
    StatusAgent.observe(run_id, payload("one"))

    assert [%{"data" => %{"reason" => "timeout"}}] =
             eventually_events(run_dir, "status_update_failed")

    StatusAgent.stop_run(run_id)
  end

  defp payload(node_id) do
    %{
      node_id: node_id,
      iteration: 1,
      output_digest: "output",
      verdict: nil,
      critique: nil,
      per_node_iteration_counts: %{},
      total_iterations: 1
    }
  end

  defp eventually_events(run_dir, kind) do
    Enum.find_value(1..50, fn _attempt ->
      events =
        run_dir
        |> Path.join("_run/events.jsonl")
        |> read_events()
        |> Enum.filter(&(&1["kind"] == kind))

      case events do
        [] ->
          Process.sleep(20)
          nil

        events ->
          events
      end
    end) || []
  end

  defp read_events(path) do
    if File.exists?(path) do
      path |> File.stream!() |> Enum.map(&Jason.decode!/1)
    else
      []
    end
  end
end
