defmodule Tractor.RunWatcher.ReconcileTest do
  use ExUnit.Case, async: false

  alias Tractor.RunWatcher.Reconcile

  @dead_pid 999_999

  @tag :tmp_dir
  test "reconciles a running run whose owner pid is dead", %{tmp_dir: tmp_dir} do
    run_dir = write_manifest(tmp_dir, "dead-owner", %{"status" => "running"})
    write_pidfile(run_dir, @dead_pid)

    assert [{"dead-owner", ^run_dir, reason}] = Reconcile.reconcile_dead_runs(tmp_dir)
    assert reason =~ "reconciled:"

    manifest = read_manifest(run_dir)
    assert manifest["status"] == "interrupted"
    assert manifest["reason"] == reason
    assert is_binary(manifest["finished_at"])
  end

  @tag :tmp_dir
  test "leaves a running run alone when its owner pid is alive", %{tmp_dir: tmp_dir} do
    run_dir = write_manifest(tmp_dir, "alive-owner", %{"status" => "running"})
    write_pidfile(run_dir, System.pid() |> String.to_integer())

    assert [] = Reconcile.reconcile_dead_runs(tmp_dir)

    manifest = read_manifest(run_dir)
    assert manifest["status"] == "running"
    refute Map.has_key?(manifest, "reason")
    refute Map.has_key?(manifest, "finished_at")
  end

  @tag :tmp_dir
  test "leaves non-running manifests untouched even with a dead pidfile", %{tmp_dir: tmp_dir} do
    run_dir = write_manifest(tmp_dir, "already-ok", %{"status" => "ok"})
    write_pidfile(run_dir, @dead_pid)

    before = read_manifest(run_dir)

    assert [] = Reconcile.reconcile_dead_runs(tmp_dir)
    assert read_manifest(run_dir) == before
  end

  @tag :tmp_dir
  test "reconciles a missing pidfile after the startup grace window", %{tmp_dir: tmp_dir} do
    started_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    run_dir = write_manifest(tmp_dir, "missing-post-grace", %{"started_at" => started_at})

    assert [{"missing-post-grace", ^run_dir, "reconciled: pidfile missing"}] =
             Reconcile.reconcile_dead_runs(tmp_dir)

    manifest = read_manifest(run_dir)
    assert manifest["status"] == "interrupted"
    assert manifest["reason"] == "reconciled: pidfile missing"
    assert is_binary(manifest["finished_at"])
  end

  @tag :tmp_dir
  test "does not reconcile a missing pidfile during the startup grace window", %{tmp_dir: tmp_dir} do
    started_at = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.to_iso8601()
    run_dir = write_manifest(tmp_dir, "missing-in-grace", %{"started_at" => started_at})

    assert [] = Reconcile.reconcile_dead_runs(tmp_dir)

    manifest = read_manifest(run_dir)
    assert manifest["status"] == "running"
    refute Map.has_key?(manifest, "reason")
    refute Map.has_key?(manifest, "finished_at")
  end

  defp write_manifest(runs_dir, run_id, attrs) do
    run_dir = Path.join(runs_dir, run_id)
    File.mkdir_p!(run_dir)

    manifest =
      Map.merge(
        %{
          "run_id" => run_id,
          "status" => "running",
          "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        attrs
      )

    File.write!(Path.join(run_dir, "manifest.json"), Jason.encode!(manifest))
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
end
