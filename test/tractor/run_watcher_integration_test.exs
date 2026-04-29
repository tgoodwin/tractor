defmodule Tractor.RunWatcherIntegrationTest do
  use ExUnit.Case, async: false

  alias Tractor.RunWatcher
  alias Tractor.RunWatcher.Tail

  @dead_pid 999_999

  setup do
    start_supervised!(
      {DynamicSupervisor, strategy: :one_for_one, name: Tractor.RunWatcher.TailSupervisor}
    )

    :ok
  end

  @tag :tmp_dir
  test "RunWatcher reconciles a dead-owner run and stops its Tail watcher", %{tmp_dir: tmp_dir} do
    run_id = "reconcile-integration"
    run_dir = write_running_manifest(tmp_dir, run_id)
    write_pidfile(run_dir, System.pid() |> String.to_integer())

    watcher_pid = start_supervised!({RunWatcher, runs_dir: tmp_dir})
    tail_pid = wait_for_tail()
    tail_ref = Process.monitor(tail_pid)
    fs_watcher_pid = :sys.get_state(tail_pid).watcher
    assert is_pid(fs_watcher_pid)

    write_pidfile(run_dir, @dead_pid)
    send(watcher_pid, :rescan_runs)

    wait_until(fn -> read_manifest(run_dir)["status"] == "error" end)
    assert read_manifest(run_dir)["reason"] =~ "reconciled:"
    assert_receive {:DOWN, ^tail_ref, :process, ^tail_pid, _reason}, 1_000
    refute Process.alive?(tail_pid)
    refute Process.alive?(fs_watcher_pid)
  end

  defp write_running_manifest(runs_dir, run_id) do
    run_dir = Path.join(runs_dir, run_id)
    File.mkdir_p!(run_dir)

    File.write!(
      Path.join(run_dir, "manifest.json"),
      Jason.encode!(%{
        "run_id" => run_id,
        "status" => "running",
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    )

    run_dir
  end

  defp write_pidfile(run_dir, os_pid) do
    File.write!(
      Path.join(run_dir, "_runner.pid"),
      Jason.encode!(%{
        "os_pid" => os_pid,
        "node" => Atom.to_string(node()),
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    )
  end

  defp read_manifest(run_dir) do
    run_dir
    |> Path.join("manifest.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp wait_for_tail(deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    pid =
      Tractor.RunWatcher.TailSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.find_value(fn
        {:undefined, pid, :worker, [Tail]} when is_pid(pid) -> pid
        _other -> nil
      end)

    cond do
      is_pid(pid) ->
        pid

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for tail")

      true ->
        Process.sleep(20)
        wait_for_tail(deadline)
    end
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition was not met before deadline")

      true ->
        Process.sleep(20)
        wait_until(fun, deadline)
    end
  end
end
