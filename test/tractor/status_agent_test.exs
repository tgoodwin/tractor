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

  @tag :tmp_dir
  test "sanitizes invalid UTF-8 output digests before prompting", %{tmp_dir: tmp_dir} do
    run_id = "status-invalid-utf8"
    run_dir = Path.join(tmp_dir, run_id)
    File.mkdir_p!(run_dir)
    Tractor.RunEvents.register_run(run_id, run_dir)

    invalid_digest = binary_part("prefix—tail", 0, 7)
    refute String.valid?(invalid_digest)

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Claude, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, prompt, 30_000 ->
      assert String.valid?(prompt)
      assert prompt =~ "Output digest:"
      assert prompt =~ "\\xE2"
      assert Jason.encode!(%{"prompt" => prompt})

      {:ok, %Tractor.ACP.Turn{response_text: "safe summary"}}
    end)

    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert :ok = StatusAgent.start_run(run_id, run_dir, "claude")
    StatusAgent.observe(run_id, payload("one", output_digest: invalid_digest))

    assert [%{"data" => %{"summary" => "safe summary"}}] =
             eventually_events(run_dir, "status_update")

    StatusAgent.stop_run(run_id)
  end

  @tag :tmp_dir
  test "prompt exceptions are reflected as status_update_failed", %{tmp_dir: tmp_dir} do
    run_id = "status-prompt-exception"
    run_dir = Path.join(tmp_dir, run_id)
    File.mkdir_p!(run_dir)
    Tractor.RunEvents.register_run(run_id, run_dir)

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Claude, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, _prompt, 30_000 ->
      raise "status prompt boom"
    end)

    assert :ok = StatusAgent.start_run(run_id, run_dir, "claude")
    StatusAgent.observe(run_id, payload("one"))

    assert [%{"data" => %{"reason" => reason}}] =
             eventually_events(run_dir, "status_update_failed")

    assert reason =~ "status prompt boom"

    StatusAgent.stop_run(run_id)
  end

  @tag :tmp_dir
  test "stop_run drains an in-flight observation before shutdown", %{tmp_dir: tmp_dir} do
    run_id = "status-drain"
    run_dir = Path.join(tmp_dir, run_id)
    File.mkdir_p!(run_dir)
    Tractor.RunEvents.register_run(run_id, run_dir)
    parent = self()

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Claude, _opts ->
      send(parent, :status_agent_started)
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, _prompt, 30_000 ->
      send(parent, {:status_agent_prompted, self()})

      receive do
        :release_status_agent -> {:ok, %Tractor.ACP.Turn{response_text: "final summary"}}
      end
    end)

    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert :ok = StatusAgent.start_run(run_id, run_dir, "claude")
    StatusAgent.observe(run_id, payload("one"))
    assert_receive :status_agent_started, 1_000
    assert_receive {:status_agent_prompted, task_pid}, 1_000

    StatusAgent.stop_run(run_id)
    send(task_pid, :release_status_agent)

    assert [%{"data" => %{"summary" => "final summary"}}] =
             eventually_events(run_dir, "status_update")

    assert [%{"kind" => "status_agent_stopped"}] =
             eventually_events(run_dir, "status_agent_stopped")
  end

  defp payload(node_id, overrides \\ []) do
    %{
      node_id: node_id,
      iteration: 1,
      output_digest: "output",
      verdict: nil,
      critique: nil,
      per_node_iteration_counts: %{},
      total_iterations: 1
    }
    |> Map.merge(Map.new(overrides))
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
