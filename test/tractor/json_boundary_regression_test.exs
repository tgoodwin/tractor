defmodule Tractor.JSONBoundaryRegressionTest do
  use ExUnit.Case, async: false

  alias Tractor.{Pipeline, RunEvents, RunStore}

  @moduletag :tmp_dir

  test "RunEvents.emit survives an agent_message_chunk whose text ends in <<0xE2>>",
       %{tmp_dir: tmp_dir} do
    # Repro for commit `aee9eaa`: byte-truncated multibyte string from an LLM
    # bridge crashed Jason.encode! in EventLog.append, taking out the runner.
    {:ok, store} =
      RunStore.open(%Pipeline{path: "examples/flow.dot", goal: "ship"},
        runs_dir: tmp_dir,
        run_id: "encoding-regression"
      )

    truncated = <<"chunk ending mid-emdash ", 0xE2>>

    assert :ok =
             RunEvents.emit(store.run_id, "node-a", :agent_message_chunk, %{
               "text" => truncated
             })

    events_path = Path.join([store.run_dir, "node-a", "events.jsonl"])
    raw = File.read!(events_path)

    # Row is valid JSON, valid UTF-8, and the chunk text was sanitized into a
    # recognizable string.
    [row | _] = String.split(raw, "\n", trim: true)
    decoded = Jason.decode!(row)
    assert String.valid?(row)
    assert decoded["kind"] == "agent_message_chunk"
    assert is_binary(decoded["data"]["text"])
    assert decoded["data"]["text"] =~ "chunk ending mid-emdash"
  end
end
