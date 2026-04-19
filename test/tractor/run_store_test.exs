defmodule Tractor.RunStoreTest do
  use ExUnit.Case, async: true

  alias Tractor.{Pipeline, RunStore}

  @tag :tmp_dir
  test "opens a run directory and writes node artifacts", %{tmp_dir: tmp_dir} do
    pipeline = %Pipeline{path: "examples/flow.dot", goal: "ship"}

    assert {:ok, store} = RunStore.open(pipeline, runs_dir: tmp_dir, run_id: "run-1")
    assert store.run_dir == Path.join(tmp_dir, "run-1")

    assert :ok =
             RunStore.write_node(store, "ask", %{
               prompt: "Prompt",
               response: "Response",
               status: %{"status" => "ok", "duration_ms" => 12}
             })

    assert File.read!(Path.join(store.run_dir, "ask/prompt.md")) == "Prompt"
    assert File.read!(Path.join(store.run_dir, "ask/response.md")) == "Response"

    status = read_json(Path.join(store.run_dir, "ask/status.json"))
    assert status["status"] == "ok"
    assert status["duration_ms"] == 12
  end

  @tag :tmp_dir
  test "finalizes manifest with redacted provider env", %{tmp_dir: tmp_dir} do
    pipeline = %Pipeline{path: "examples/flow.dot", goal: "ship"}
    {:ok, store} = RunStore.open(pipeline, runs_dir: tmp_dir, run_id: "run-2")

    assert :ok =
             RunStore.finalize(store, %{
               status: "ok",
               provider_commands: [
                 %{provider: "codex", command: "codex-acp", args: [], env: [{"TOKEN", "secret"}]}
               ]
             })

    manifest = read_json(Path.join(store.run_dir, "manifest.json"))

    assert manifest["pipeline_path"] == "examples/flow.dot"
    assert manifest["goal"] == "ship"
    assert manifest["status"] == "ok"

    assert manifest["provider_commands"] == [
             %{
               "provider" => "codex",
               "command" => "codex-acp",
               "args" => [],
               "env" => %{"TOKEN" => "[REDACTED]"}
             }
           ]
  end

  @tag :tmp_dir
  test "node status replacement is atomic and leaves no temp files", %{tmp_dir: tmp_dir} do
    {:ok, store} = RunStore.open(%Pipeline{}, runs_dir: tmp_dir, run_id: "run-3")

    :ok = RunStore.write_node(store, "ask", %{status: %{"status" => "started"}})
    :ok = RunStore.write_node(store, "ask", %{status: %{"status" => "ok"}})

    assert %{"status" => "ok"} = read_json(Path.join(store.run_dir, "ask/status.json"))
    assert [] = Path.wildcard(Path.join(store.run_dir, "ask/.status.json.*.tmp"))
  end

  defp read_json(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end
end
