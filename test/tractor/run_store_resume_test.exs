defmodule Tractor.RunStoreResumeTest do
  use ExUnit.Case, async: false

  alias Tractor.{Pipeline, Run, RunStore}

  @moduletag :tmp_dir

  test "resume/1 resets a terminal manifest back to running without emitting run_finalized",
       %{tmp_dir: tmp_dir} do
    {:ok, store} =
      RunStore.open(%Pipeline{path: "examples/flow.dot", goal: "ship"},
        runs_dir: tmp_dir,
        run_id: "resumable-run"
      )

    started_at = store.manifest["started_at"]
    assert is_binary(started_at)

    :ok =
      Run.finalize(store, %{
        status: "interrupted",
        reason: "manual interrupt"
      })

    manifest_after_finalize = read_manifest(store.run_dir)
    assert manifest_after_finalize["status"] == "interrupted"
    assert is_binary(manifest_after_finalize["finished_at"])
    assert manifest_after_finalize["reason"] == "manual interrupt"

    events_before = read_run_events(store.run_dir)
    finalized_before = Enum.count(events_before, &(&1["kind"] == "run_finalized"))
    assert finalized_before == 1

    assert {:ok, resumed} = RunStore.resume(store.run_dir)

    assert resumed.manifest["status"] == "running"
    refute Map.has_key?(resumed.manifest, "finished_at")
    refute Map.has_key?(resumed.manifest, "reason")
    assert resumed.manifest["started_at"] == started_at

    persisted = read_manifest(store.run_dir)
    assert persisted["status"] == "running"
    refute Map.has_key?(persisted, "finished_at")
    refute Map.has_key?(persisted, "reason")

    events_after = read_run_events(store.run_dir)
    assert Enum.count(events_after, &(&1["kind"] == "run_finalized")) == finalized_before
  end

  defp read_manifest(run_dir) do
    run_dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
  end

  defp read_run_events(run_dir) do
    path = Path.join([run_dir, "_run", "events.jsonl"])

    if File.exists?(path) do
      path |> File.stream!() |> Enum.map(&Jason.decode!/1)
    else
      []
    end
  end
end
