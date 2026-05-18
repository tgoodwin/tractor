defmodule Tractor.RunFinalizeTest do
  use ExUnit.Case, async: false

  alias Tractor.{Pipeline, Run, RunStore}

  @moduletag :tmp_dir

  describe "Tractor.Run.finalize/2" do
    test "ok: writes terminal manifest + run_completed + run_finalized", %{tmp_dir: tmp_dir} do
      store = open_store(tmp_dir, "ok-run")

      :ok = Run.finalize(store, %{status: "ok"})

      manifest = read_manifest(store)
      assert manifest["status"] == "ok"
      assert is_binary(manifest["finished_at"])

      events = read_events(store)
      assert event_kind?(events, "run_completed")
      assert event_kind?(events, "run_finalized")
      assert event_data(events, "run_finalized", "status") == "ok"
      assert event_data(events, "run_finalized", "source") == "runner"
    end

    test "error: terminal_event override carries reason payload", %{tmp_dir: tmp_dir} do
      store = open_store(tmp_dir, "err-run")

      :ok =
        Run.finalize(store, %{
          status: "error",
          reason: {:retries_exhausted, :timeout},
          terminal_event: {:run_failed, %{"reason" => inspect({:retries_exhausted, :timeout})}}
        })

      manifest = read_manifest(store)
      assert manifest["status"] == "error"
      assert manifest["reason"] == inspect({:retries_exhausted, :timeout})

      events = read_events(store)
      assert event_kind?(events, "run_failed")
      assert event_data(events, "run_failed", "reason") =~ "retries_exhausted"
      assert event_kind?(events, "run_finalized")
      assert event_data(events, "run_finalized", "status") == "error"
    end

    test "interrupted (runner source): stock event", %{tmp_dir: tmp_dir} do
      store = open_store(tmp_dir, "int-runner")

      :ok = Run.finalize(store, %{status: "interrupted"})

      events = read_events(store)
      assert event_kind?(events, "run_interrupted")
      assert event_kind?(events, "run_finalized")
      assert event_data(events, "run_finalized", "source") == "runner"
      refute event_kind?(events, "run_reconciled")
    end

    test "interrupted (reconciler source): run_reconciled + run_interrupted + run_finalized",
         %{tmp_dir: tmp_dir} do
      store = open_store(tmp_dir, "int-recon")

      :ok =
        Run.finalize(store, %{
          status: "interrupted",
          reason: "reconciled: owner pid 999 not alive",
          source: :reconciler,
          owner_pid: 999
        })

      events = read_events(store)
      assert event_kind?(events, "run_reconciled")
      assert event_kind?(events, "run_interrupted")
      assert event_kind?(events, "run_finalized")
      assert event_data(events, "run_reconciled", "owner_pid") == 999
      assert event_data(events, "run_reconciled", "reason") =~ "reconciled:"
      assert event_data(events, "run_finalized", "source") == "reconciler"
      assert event_data(events, "run_finalized", "reason") =~ "reconciled:"
    end

    test "goal_gate_failed: terminal_event override preserves node_id", %{tmp_dir: tmp_dir} do
      store = open_store(tmp_dir, "ggf-run")

      :ok =
        Run.finalize(store, %{
          status: "goal_gate_failed",
          reason: :missing_tool,
          terminal_event:
            {:goal_gate_failed, %{"node_id" => "tool", "reason" => inspect(:missing_tool)}}
        })

      events = read_events(store)
      assert event_data(events, "goal_gate_failed", "node_id") == "tool"
      assert event_kind?(events, "run_finalized")
      assert event_data(events, "run_finalized", "status") == "goal_gate_failed"
    end

    test "idempotency: second call is a no-op", %{tmp_dir: tmp_dir} do
      store = open_store(tmp_dir, "idem-run")

      :ok = Run.finalize(store, %{status: "ok"})
      events_after_first = read_events(store)
      :ok = Run.finalize(store, %{status: "ok"})
      events_after_second = read_events(store)

      assert events_after_first == events_after_second
      assert count_kind(events_after_second, "run_finalized") == 1
      assert count_kind(events_after_second, "run_completed") == 1
    end

    test "ensure-register safety: re-registers events table if missing", %{tmp_dir: tmp_dir} do
      store = open_store(tmp_dir, "noreg-run")

      # Simulate the "fresh observer BEAM never saw this run" scenario by
      # creating a parallel store on disk without registering it.
      fresh_store = %RunStore{
        run_id: "unregistered-run",
        run_dir: Path.join(tmp_dir, "unregistered-run"),
        manifest: %{"run_id" => "unregistered-run", "status" => "running"}
      }

      File.mkdir_p!(fresh_store.run_dir)

      File.write!(
        Path.join(fresh_store.run_dir, "manifest.json"),
        Jason.encode!(fresh_store.manifest)
      )

      assert :ok =
               Run.finalize(fresh_store, %{
                 status: "interrupted",
                 reason: "no-op",
                 source: :reconciler
               })

      events = read_events(fresh_store)
      assert event_kind?(events, "run_finalized")
      _ = store
    end
  end

  defp open_store(tmp_dir, run_id) do
    {:ok, store} =
      RunStore.open(%Pipeline{path: "examples/flow.dot", goal: "ship"},
        runs_dir: tmp_dir,
        run_id: run_id
      )

    store
  end

  defp read_manifest(store) do
    store.run_dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
  end

  defp read_events(store) do
    path = Path.join([store.run_dir, "_run", "events.jsonl"])

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
    else
      []
    end
  end

  defp event_kind?(events, kind), do: Enum.any?(events, &(&1["kind"] == kind))

  defp event_data(events, kind, key) do
    case Enum.find(events, &(&1["kind"] == kind)) do
      nil -> nil
      event -> get_in(event, ["data", key])
    end
  end

  defp count_kind(events, kind), do: Enum.count(events, &(&1["kind"] == kind))
end
