defmodule Tractor.RunEventsTest do
  use ExUnit.Case, async: false

  alias Tractor.ACP.Session
  alias Tractor.{Pipeline, RunBus, RunEvents, RunStore}

  defmodule FakeAgent do
    def command(opts) do
      {
        System.fetch_env!("TRACTOR_TEST_ELIXIR"),
        ["--erl", "-kernel logger_level emergency", "-pa", jason_ebin_path(), fake_agent_path()],
        Keyword.get(opts, :env, [])
      }
    end

    defp fake_agent_path do
      Path.expand("../support/fake_acp_agent.exs", __DIR__)
    end

    defp jason_ebin_path do
      Path.expand("../../_build/test/lib/jason/ebin", __DIR__)
    end
  end

  setup do
    System.put_env("TRACTOR_TEST_ELIXIR", System.find_executable("elixir"))
    :ok
  end

  @tag :tmp_dir
  test "session sink writes events to disk first and broadcasts them", %{tmp_dir: tmp_dir} do
    {:ok, store} = RunStore.open(%Pipeline{}, runs_dir: tmp_dir, run_id: "run-events")
    :ok = RunBus.subscribe(store.run_id)

    sink = fn %{kind: kind, data: data} ->
      RunEvents.emit(store.run_id, "ask", kind, data)
    end

    {:ok, pid} =
      Session.start_link(FakeAgent,
        cwd: File.cwd!(),
        event_sink: sink,
        env: [{"FAKE_ACP_EVENTS", "full"}]
      )

    assert {:ok, _turn} = Session.prompt(pid, "hello", 5_000)
    assert :ok = Session.stop(pid)

    disk_kinds =
      store.run_dir
      |> Path.join("ask/events.jsonl")
      |> read_events()
      |> Enum.map(& &1["kind"])

    assert [
             "agent_thought_chunk",
             "tool_call",
             "tool_call_update",
             "agent_message_chunk",
             "agent_message_chunk",
             "agent_message_chunk"
           ] = disk_kinds

    live_kinds = receive_kinds(length(disk_kinds))
    assert live_kinds == disk_kinds
  end

  @tag :tmp_dir
  test "usage events land in events jsonl and broadcast stream", %{tmp_dir: tmp_dir} do
    {:ok, store} = RunStore.open(%Pipeline{}, runs_dir: tmp_dir, run_id: "run-usage-events")
    :ok = RunBus.subscribe(store.run_id)

    sink = fn %{kind: kind, data: data} ->
      RunEvents.emit(store.run_id, "ask", kind, data)
    end

    {:ok, pid} =
      Session.start_link(FakeAgent,
        cwd: File.cwd!(),
        event_sink: sink,
        env: [{"TRACTOR_FAKE_ACP_MODE", "usage_update"}]
      )

    assert {:ok, _turn} = Session.prompt(pid, "hello", 5_000)
    assert :ok = Session.stop(pid)

    events = store.run_dir |> Path.join("ask/events.jsonl") |> read_events()
    usage = Enum.find(events, &(&1["kind"] == "usage"))

    assert %{
             "data" => %{
               "input_tokens" => 123,
               "output_tokens" => 45,
               "total_tokens" => 168
             }
           } = usage

    live_kinds = receive_kinds(length(events))
    assert live_kinds == Enum.map(events, & &1["kind"])
  end

  @tag :tmp_dir
  test "late reader rebuilds node state from status and events", %{tmp_dir: tmp_dir} do
    {:ok, store} = RunStore.open(%Pipeline{}, runs_dir: tmp_dir, run_id: "run-rebuild")
    :ok = RunBus.subscribe(store.run_id)

    :ok = RunStore.mark_node_running(store, "ask", "2026-04-19T12:00:00Z")
    :ok = RunEvents.emit(store.run_id, "ask", :node_started, %{})
    :ok = RunStore.mark_node_succeeded(store, "ask", %{"provider" => "codex"})
    :ok = RunEvents.emit(store.run_id, "ask", :node_succeeded, %{"provider" => "codex"})

    live_kinds = receive_kinds(2)

    status = store.run_dir |> Path.join("ask/status.json") |> File.read!() |> Jason.decode!()

    disk_kinds =
      store.run_dir |> Path.join("ask/events.jsonl") |> read_events() |> Enum.map(& &1["kind"])

    assert status["status"] == "ok"
    assert disk_kinds == live_kinds
  end

  defp read_events(path) do
    path
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end

  defp receive_kinds(count) do
    Enum.map(1..count, fn _index ->
      assert_receive {:run_event, _node_id, %{"kind" => kind}}, 1_000
      kind
    end)
  end
end
