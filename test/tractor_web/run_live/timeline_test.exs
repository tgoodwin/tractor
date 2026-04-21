defmodule TractorWeb.RunLive.TimelineTest do
  use ExUnit.Case, async: true

  alias TractorWeb.RunLive.Timeline

  @tag :tmp_dir
  test "from_disk orders synthesized and event-backed entries", %{tmp_dir: tmp_dir} do
    node_dir = node_dir(tmp_dir)
    File.write!(Path.join(node_dir, "prompt.md"), "Prompt text\nsecond line")
    File.write!(Path.join(node_dir, "response.md"), "Final response")
    File.write!(Path.join(node_dir, "stderr.log"), "stderr text")

    write_events(node_dir, [
      event(1, "node_started", %{}, "2026-04-19T10:00:00Z"),
      event(2, "agent_thought_chunk", %{"text" => "thinking"}, "2026-04-19T10:00:01Z"),
      event(
        3,
        "tool_call",
        %{
          "kind" => "read",
          "toolCallId" => "tc_1",
          "rawInput" => %{"path" => "/tmp/file.ex"}
        },
        "2026-04-19T10:00:02Z"
      ),
      event(
        4,
        "tool_call_update",
        %{"toolCallId" => "tc_1", "status" => "done"},
        "2026-04-19T10:00:03Z"
      ),
      event(5, "agent_message_chunk", %{"text" => "chunk"}, "2026-04-19T10:00:04Z"),
      event(6, "usage", %{"total_tokens" => 168}, "2026-04-19T10:00:05Z")
    ])

    File.write!(
      Path.join(node_dir, "status.json"),
      Jason.encode!(%{"status" => "ok", "finished_at" => "2026-04-19T10:00:06Z"})
    )

    entries = Timeline.from_disk(tmp_dir, "node")

    assert Enum.map(entries, & &1.type) == [
             :prompt,
             :lifecycle,
             :thinking,
             :tool_call,
             :response,
             :usage,
             :lifecycle,
             :stderr
           ]

    assert Enum.find(entries, &(&1.id == "prompt")).body == "Prompt text\nsecond line"
    assert Enum.find(entries, &(&1.id == "response")).body == "Final response"

    tool = Enum.find(entries, &(&1.id == "tool-tc_1"))
    assert tool.title == "[READ]"
    assert tool.summary == "file.ex"
    assert tool.body["updates"] == [%{"toolCallId" => "tc_1", "status" => "done"}]

    assert Enum.find(entries, &(&1.type == :usage)).summary == "168 tokens"
    assert Enum.find(entries, &(&1.id == "lifecycle-status")).tone == :success
    assert Enum.find(entries, &(&1.id == "stderr")).body == "stderr text"
  end

  test "from_disk collapses message chunks into one response entry" do
    node_dir = node_dir()

    write_events(node_dir, [
      event(1, "agent_message_chunk", %{"text" => "hello "}, "2026-04-19T10:00:00Z"),
      event(2, "agent_message_chunk", %{"text" => "world"}, "2026-04-19T10:00:01Z")
    ])

    entries = Timeline.from_disk(Path.dirname(node_dir), Path.basename(node_dir))

    assert [%{type: :response, body: "hello world"}] = entries
  end

  test "insert appends response chunks and returns replacement position" do
    first = event(2, "agent_message_chunk", %{"text" => "hello"}, "2026-04-19T10:00:01Z")
    second = event(3, "agent_message_chunk", %{"text" => " world"}, "2026-04-19T10:00:02Z")

    {0, response} = Timeline.insert([], first)
    {0, updated} = Timeline.insert([response], second)

    assert updated.id == "response"
    assert updated.body == "hello world"
  end

  test "insert tie-breaks by timestamp then sequence" do
    entries = [
      lifecycle_entry("one", "2026-04-19T10:00:00Z", 1),
      lifecycle_entry("three", "2026-04-19T10:00:00Z", 3)
    ]

    new_event = event(2, "branch_started", %{}, "2026-04-19T10:00:00Z")

    assert {1, %{seq: 2}} = Timeline.insert(entries, new_event)
  end

  test "insert groups tool call updates under the original tool call" do
    call =
      event(
        1,
        "tool_call",
        %{"kind" => "glob", "toolCallId" => "tc_1", "rawInput" => %{"pattern" => "*.ex"}},
        "2026-04-19T10:00:00Z"
      )

    update =
      event(
        2,
        "tool_call_update",
        %{"toolCallId" => "tc_1", "status" => "done"},
        "2026-04-19T10:00:01Z"
      )

    {0, entry} = Timeline.insert([], call)
    {0, updated} = Timeline.insert([entry], update)

    assert updated.id == "tool-tc_1"
    assert updated.type == :tool_call
    assert updated.body["updates"] == [%{"toolCallId" => "tc_1", "status" => "done"}]
  end

  test "insert renders runtime tool events distinctly" do
    invoked =
      event(
        1,
        "tool_invoked",
        %{"command" => ["grep", "foo"], "exit_status" => 0},
        "2026-04-19T10:00:00Z"
      )

    truncated =
      event(
        2,
        "tool_output_truncated",
        %{"stream" => "stdout", "limit" => 20},
        "2026-04-19T10:00:01Z"
      )

    {0, invoked_entry} = Timeline.insert([], invoked)
    {1, truncated_entry} = Timeline.insert([invoked_entry], truncated)

    assert invoked_entry.type == :tool_runtime
    assert invoked_entry.title == "[TOOL] invoked"
    assert truncated_entry.type == :tool_runtime
    assert truncated_entry.title == "[TOOL] output truncated"
  end

  test "insert renders wait runtime events distinctly" do
    pending =
      event(
        1,
        "wait_human_pending",
        %{"wait_prompt" => "Choose", "outgoing_labels" => ["approve", "reject"]},
        "2026-04-19T10:00:00Z"
      )

    resolved =
      event(
        2,
        "wait_human_resolved",
        %{"label" => "approve", "source" => "operator"},
        "2026-04-19T10:00:01Z"
      )

    {0, pending_entry} = Timeline.insert([], pending)
    {1, resolved_entry} = Timeline.insert([pending_entry], resolved)

    assert pending_entry.type == :wait_runtime
    assert pending_entry.title == "[WAIT] pending"
    assert resolved_entry.type == :wait_runtime
    assert resolved_entry.title == "[WAIT] resolved"
  end

  defp node_dir(tmp_dir \\ nil) do
    tmp_dir =
      tmp_dir ||
        Path.join(System.tmp_dir!(), "tractor-timeline-#{System.unique_integer([:positive])}")

    node_dir = Path.join(tmp_dir, "node")
    File.mkdir_p!(node_dir)
    node_dir
  end

  defp write_events(node_dir, events) do
    body = Enum.map_join(events, "\n", &Jason.encode!/1)
    File.write!(Path.join(node_dir, "events.jsonl"), body <> "\n")
  end

  defp event(seq, kind, data, ts) do
    %{"seq" => seq, "kind" => kind, "data" => data, "ts" => ts}
  end

  defp lifecycle_entry(id, ts, seq) do
    %{
      id: id,
      ts: DateTime.from_iso8601(ts) |> elem(1),
      seq: seq,
      type: :lifecycle,
      title: "Lifecycle",
      summary: id,
      body: %{},
      collapsed_by_default?: true,
      tone: :muted
    }
  end
end
