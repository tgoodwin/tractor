defmodule Tractor.ACP.WireReplayTest do
  use ExUnit.Case, async: false

  @fixtures_dir Path.expand("../../fixtures/acp/wire_logs", __DIR__)

  setup do
    System.put_env("TRACTOR_TEST_ELIXIR", System.find_executable("elixir"))
    :ok
  end

  test "claude-happy-prompt.jsonl: no acp_unhandled events fire on the happy path" do
    {:ok, %{events: events, telemetry: telemetry, prompt_result: prompt_result}} =
      ACPWireReplay.run_fixture(Path.join(@fixtures_dir, "claude-happy-prompt.jsonl"))

    assert match?({:ok, _turn}, prompt_result)

    unhandled =
      Enum.filter(events, fn {kind, _data} ->
        kind |> Atom.to_string() |> String.starts_with?("acp_unhandled")
      end)

    assert unhandled == [], "expected zero acp_unhandled_* events, got: #{inspect(unhandled)}"
    assert telemetry == [], "expected zero unhandled telemetry, got: #{inspect(telemetry)}"

    chunks = Enum.filter(events, fn {kind, _data} -> kind == :agent_message_chunk end)

    assert length(chunks) == 3
    assert Enum.any?(events, fn {kind, _} -> kind == :tool_call end)
    assert Enum.any?(events, fn {kind, _} -> kind == :tool_call_update end)
  end

  test "codex-noeol-and-usage.jsonl: unknown sessionUpdate becomes acp_unknown_update; usage parsed" do
    # Force split_at small so the long agent_thought chunk crosses the boundary
    # multiple times; the session line buffer must rejoin into a single line.
    {:ok, %{events: events}} =
      ACPWireReplay.run_fixture(
        Path.join(@fixtures_dir, "codex-noeol-and-usage.jsonl"),
        split_at: 256
      )

    # No FunctionClauseError / crash means the session is still alive after
    # all frames — the test reaches this point.

    assert Enum.any?(events, fn {kind, data} ->
             kind == :acp_context_window and data["used"] == 162
           end)

    assert Enum.any?(events, fn {kind, data} ->
             kind == :acp_unknown_update and data["updateKind"] == "experimental_plan_v2"
           end)

    # Buffer rejoined the long thought chunk back into a single agent_thought_chunk.
    assert Enum.any?(events, fn {kind, data} ->
             kind == :agent_thought_chunk and is_binary(data["text"]) and
               byte_size(data["text"]) > 256
           end)

    # Subsequent agent_message_chunk after the unknown update still arrives —
    # parser didn't get stuck on the unknown frame.
    assert Enum.any?(events, fn {kind, data} ->
             kind == :agent_message_chunk and data["text"] == "done"
           end)
  end
end
