defmodule TractorWeb.RunIndexTest do
  use ExUnit.Case, async: false

  alias TractorWeb.RunIndex

  @tag :tmp_dir
  test "keeps stale running manifest marked running while owner pid is alive", %{tmp_dir: tmp_dir} do
    run_dir = write_manifest(tmp_dir, "active-long-run", %{"status" => "running"})
    write_pidfile(run_dir, System.pid() |> String.to_integer())
    stale_manifest!(run_dir)

    assert [%{run_id: "active-long-run", status: :running}] = RunIndex.list(tmp_dir)
  end

  @tag :tmp_dir
  test "stale running manifest without an owner still surfaces as errored", %{tmp_dir: tmp_dir} do
    run_dir = write_manifest(tmp_dir, "dead-run", %{"status" => "running"})
    stale_manifest!(run_dir)

    assert [%{run_id: "dead-run", status: :errored}] = RunIndex.list(tmp_dir)
  end

  defp write_manifest(runs_dir, run_id, attrs) do
    run_dir = Path.join(runs_dir, run_id)
    File.mkdir_p!(run_dir)

    manifest =
      Map.merge(
        %{
          "run_id" => run_id,
          "status" => "running",
          "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "dot_path_input" => "examples/test.dot"
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

  defp stale_manifest!(run_dir) do
    path = Path.join(run_dir, "manifest.json")
    :ok = :file.change_time(String.to_charlist(path), {{2020, 1, 1}, {0, 0, 0}})
  end
end
