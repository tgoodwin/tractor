defmodule Tractor.RunWatcherTest do
  use ExUnit.Case, async: false

  alias Tractor.RunBus
  alias Tractor.RunWatcher
  alias Tractor.RunWatcher.Tail

  setup do
    start_supervised!(
      {DynamicSupervisor, strategy: :one_for_one, name: Tractor.RunWatcher.TailSupervisor}
    )

    :ok
  end

  @tag :tmp_dir
  test "RunWatcher discovers running runs on init and relays appended events", %{tmp_dir: tmp_dir} do
    run_id = "watch-run"
    run_dir = write_running_manifest(tmp_dir, run_id)
    File.mkdir_p!(Path.join(run_dir, "ask"))
    RunBus.reset_run(run_id)
    :ok = RunBus.subscribe(run_id)

    start_supervised!({RunWatcher, runs_dir: tmp_dir})

    tail_pid = wait_for_tail(run_id)

    append_event(run_dir, "ask", %{
      "ts" => "2026-04-21T10:00:00Z",
      "seq" => 1,
      "kind" => "node_started",
      "data" => %{}
    })

    send(tail_pid, :rescan)

    assert_receive {:run_event, "ask", %{"kind" => "node_started", "seq" => 1}}, 1_000

    send(tail_pid, :flush_offsets)

    offset_path = Path.join(run_dir, "ask/.watcher-offset")
    wait_for_file(offset_path)

    offset =
      offset_path
      |> File.read!()
      |> String.trim()
      |> String.to_integer()

    assert offset > 0

    send(tail_pid, :rescan)
    refute_receive {:run_event, "ask", %{"seq" => 1}}, 250
  end

  @tag :tmp_dir
  test "RunWatcher.Tail drops duplicate seq when local bus already broadcast it", %{
    tmp_dir: tmp_dir
  } do
    run_id = "co-located-run"
    run_dir = write_running_manifest(tmp_dir, run_id)
    File.mkdir_p!(Path.join(run_dir, "ask"))
    RunBus.reset_run(run_id)
    :ok = RunBus.subscribe(run_id)

    tail_pid =
      start_supervised!({Tail, run_id: run_id, run_dir: run_dir, notify: self()})

    event = %{
      "ts" => "2026-04-21T11:00:00Z",
      "seq" => 1,
      "kind" => "node_started",
      "data" => %{}
    }

    :ok = RunBus.broadcast(run_id, "ask", event)
    assert_receive {:run_event, "ask", %{"kind" => "node_started", "seq" => 1}}, 1_000

    append_event(run_dir, "ask", event)
    send(tail_pid, :rescan)

    refute_receive {:run_event, "ask", %{"seq" => 1}}, 250
  end

  defp write_running_manifest(runs_dir, run_id) do
    run_dir = Path.join(runs_dir, run_id)
    File.mkdir_p!(run_dir)

    File.write!(
      Path.join(run_dir, "manifest.json"),
      Jason.encode!(%{
        "run_id" => run_id,
        "status" => "running",
        "pipeline_path" => Path.expand("examples/wait_human_review.dot"),
        "dot_path" => Path.expand("examples/wait_human_review.dot"),
        "dot_path_input" => "examples/wait_human_review.dot"
      })
    )

    run_dir
  end

  defp wait_for_tail(run_id) do
    deadline = System.monotonic_time(:millisecond) + 1_000

    do_wait_for_tail(run_id, deadline)
  end

  defp do_wait_for_tail(run_id, deadline) do
    pid =
      Tractor.RunWatcher.TailSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.find_value(fn
        {:undefined, pid, :worker, [Tail]} when is_pid(pid) -> pid
        _other -> nil
      end)

    cond do
      pid ->
        pid

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for tail for #{run_id}")

      true ->
        Process.sleep(20)
        do_wait_for_tail(run_id, deadline)
    end
  end

  defp append_event(run_dir, node_id, event) do
    path = Path.join([run_dir, node_id, "events.jsonl"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, [Jason.encode!(event), "\n"], [:append])
  end

  defp wait_for_file(path, deadline \\ System.monotonic_time(:millisecond) + 1_000)

  defp wait_for_file(path, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for #{path}")

      true ->
        Process.sleep(20)
        wait_for_file(path, deadline)
    end
  end
end
