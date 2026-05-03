#!/usr/bin/env elixir

defmodule Tractor.FakeACPAgent do
  @moduledoc false

  def run do
    mode = System.get_env("TRACTOR_FAKE_ACP_MODE", "ok")
    event_mode = System.get_env("FAKE_ACP_EVENTS", "basic")
    maybe_spawn_child(mode)
    loop(%{mode: mode, event_mode: event_mode, session_id: "fake-session"})
  end

  defp maybe_spawn_child("spawn_child") do
    sleep = System.find_executable("sleep")
    port = Port.open({:spawn_executable, sleep}, [:binary, :exit_status, args: ["60"]])
    {:os_pid, pid} = Port.info(port, :os_pid)
    File.write!(System.fetch_env!("TRACTOR_FAKE_ACP_CHILD_PID_FILE"), Integer.to_string(pid))
  end

  defp maybe_spawn_child(_mode), do: :ok

  defp loop(state) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        line
        |> String.trim()
        |> handle_line(state)
        |> loop()
    end
  end

  defp handle_line("", state), do: state

  defp handle_line(line, state) do
    message = Jason.decode!(line)

    case message["method"] do
      "initialize" ->
        reply(message["id"], %{
          "protocolVersion" => 1,
          "agentCapabilities" => %{"promptCapabilities" => %{"text" => true}}
        })

        state

      "session/new" ->
        reply(message["id"], %{"sessionId" => state.session_id})
        state

      "session/set_mode" ->
        case System.get_env("TRACTOR_FAKE_ACP_SET_MODE", "ok") do
          "method_not_found" -> error(message["id"], -32_601, "method not found")
          _other -> reply(message["id"], %{})
        end

        state

      "session/prompt" ->
        handle_prompt(message, state)

      _other ->
        error(message["id"], -32_601, "method not found")
        state
    end
  end

  defp handle_prompt(_message, %{mode: "crash"}) do
    System.halt(42)
  end

  defp handle_prompt(_message, %{mode: "timeout"} = state) do
    state
  end

  defp handle_prompt(message, %{mode: "jsonrpc_error"} = state) do
    error(message["id"], -32_000, "scripted jsonrpc error")
    state
  end

  defp handle_prompt(message, %{mode: "max_turn_requests"} = state) do
    send_delta(state.session_id, "partial before max turn")
    reply(message["id"], %{"stopReason" => "max_turn_requests"})
    state
  end

  defp handle_prompt(message, %{mode: "noisy_stdout"} = state) do
    IO.write("INFO fake provider stdout log\n")
    handle_prompt(message, %{state | mode: "ok"})
  end

  defp handle_prompt(message, %{mode: "telemetry_stdout"} = state) do
    IO.write(
      ~s(2026-04-29T04:34:42Z  INFO codex_otel::otel_manager: event.name="codex.sse_event" user.account_id="abc" user.email="person@example.com"\n)
    )

    IO.write(
      ~s(2026-04-29T04:34:43Z  INFO feedback_tags: model="gpt-5.5" approval_policy=OnRequest\n)
    )

    IO.write(
      ~s(2026-04-29T04:34:44Z  INFO codex_core::stream_events_utils: ToolCall: shell {"command":["rg","TODO"]} user.email="person@example.com"\n)
    )

    IO.write("[... telemetry preview truncated ...]\n")

    IO.write(
      "2026-04-29T04:34:45Z  INFO codex_rmcp_client::rmcp_client: MCP server stderr (npx): noisy init\n"
    )

    IO.write("2026-04-29T04:34:46Z  INFO serve_inner: rmcp::service: Service initialized\n")

    IO.write(
      "\e[2m2026-04-29T17:02:23.848630Z\e[0m \e[32m INFO\e[0m \e[1mserve_inner\e[0m \e[2m:\e[0m \e[2mrmcp::service\e[0m \e[2m:\e[0m Service initialized as client\n"
    )

    IO.write(
      ~s(2026-04-29T04:34:47Z  INFO useful_provider_log: user.email="person@example.com" conversation.id=abc123\n)
    )

    handle_prompt(message, %{state | mode: "ok"})
  end

  defp handle_prompt(message, %{mode: "tool_update"} = state) do
    notify("session/update", %{
      "sessionId" => state.session_id,
      "update" => %{
        "sessionUpdate" => "tool_call_update",
        "content" => [
          %{"type" => "content", "content" => %{"type" => "text", "text" => "tool output"}}
        ]
      }
    })

    handle_prompt(message, %{state | mode: "ok"})
  end

  defp handle_prompt(message, %{mode: "unknown_update"} = state) do
    notify("session/update", %{
      "sessionId" => state.session_id,
      "update" => %{"type" => "unknown_shape", "content" => %{"text" => "ignored"}}
    })

    handle_prompt(message, %{state | mode: "ok"})
  end

  defp handle_prompt(message, %{mode: "plan"} = state) do
    send_plan(state.session_id, [
      %{"content" => "Sketch", "priority" => "high", "status" => "pending"},
      %{"content" => "Draft", "priority" => "medium", "status" => "in_progress"},
      %{"content" => "Polish", "priority" => "low", "status" => "completed"}
    ])

    handle_prompt(message, %{state | mode: "ok"})
  end

  defp handle_prompt(message, %{mode: "plan_replace"} = state) do
    send_plan(state.session_id, [
      %{"content" => "Sketch", "priority" => "high", "status" => "pending"},
      %{"content" => "Draft", "priority" => "medium", "status" => "in_progress"},
      %{"content" => "Polish", "priority" => "low", "status" => "completed"}
    ])

    send_plan(state.session_id, [
      %{"content" => "Ship", "priority" => "high", "status" => "in_progress"},
      %{"content" => "Verify", "priority" => nil, "status" => "completed"}
    ])

    handle_prompt(message, %{state | mode: "ok"})
  end

  defp handle_prompt(message, %{mode: "timeline_rich"} = state) do
    IO.write(:stderr, "fake stderr line one\nfake stderr line two\n")
    handle_prompt(message, %{state | mode: "usage_result", event_mode: "full"})
  end

  defp handle_prompt(message, %{mode: "plan_unknown"} = state) do
    send_plan(state.session_id, [
      %{"content" => "Mystery", "priority" => nil, "status" => "blocked"}
    ])

    handle_prompt(message, %{state | mode: "ok"})
  end

  defp handle_prompt(message, %{mode: "permission_request"} = state) do
    request_permission(1000, state.session_id)

    case read_response(1000) do
      {:ok, %{"result" => %{"outcome" => %{"outcome" => "selected"}}}} ->
        handle_prompt(message, %{state | mode: "ok"})

      other ->
        error(message["id"], -32_000, "permission not approved: #{inspect(other)}")
        state
    end
  end

  defp handle_prompt(message, %{mode: "unknown_client_request"} = state) do
    request(1001, "client/unknown", %{"sessionId" => state.session_id})

    case read_response(1001) do
      {:ok, %{"error" => %{"code" => -32_601}}} ->
        handle_prompt(message, %{state | mode: "ok"})

      other ->
        error(message["id"], -32_000, "unexpected unknown request response: #{inspect(other)}")
        state
    end
  end

  defp handle_prompt(message, state) do
    prompt_text =
      message
      |> get_in(["params", "prompt"])
      |> List.wrap()
      |> Enum.map_join("", &Map.get(&1, "text", ""))

    if state.event_mode == "full" do
      send_full_events(state.session_id)
    end

    maybe_send_usage_update(state)
    send_delta(state.session_id, "fake ")
    send_delta(state.session_id, "response: ")
    send_session_delta(state.session_id, prompt_text)
    reply(message["id"], prompt_result(state))

    state
  end

  defp maybe_send_usage_update(%{mode: mode, session_id: session_id})
       when mode in ["usage_update", "usage_merge"] do
    notify("session/update", %{
      "sessionId" => session_id,
      "update" => %{
        "type" => "model_usage",
        "usage" => %{
          "inputTokens" => 123,
          "outputTokens" => 45,
          "totalTokens" => 168
        }
      }
    })
  end

  defp maybe_send_usage_update(%{mode: "usage_content", session_id: session_id}) do
    notify("session/update", %{
      "sessionId" => session_id,
      "update" => %{
        "type" => "agent_progress",
        "content" => %{
          "usage" => %{
            "prompt_tokens" => 321,
            "completion_tokens" => 54,
            "total_tokens" => 375
          }
        }
      }
    })
  end

  defp maybe_send_usage_update(%{mode: "usage_malformed", session_id: session_id}) do
    notify("session/update", %{
      "sessionId" => session_id,
      "update" => %{"type" => "model_usage", "usage" => ["not", "a", "map"]}
    })
  end

  defp maybe_send_usage_update(_state), do: :ok

  defp prompt_result(%{mode: "usage_result"}) do
    %{
      "stopReason" => "end_turn",
      "usage" => %{
        "prompt_tokens" => 200,
        "completion_tokens" => 50,
        "total_tokens" => 250
      }
    }
  end

  defp prompt_result(%{mode: "usage_merge"}) do
    %{
      "stopReason" => "end_turn",
      "usage" => %{
        "output_tokens" => 88,
        "total_tokens" => 211
      }
    }
  end

  defp prompt_result(_state), do: %{"stopReason" => "end_turn"}

  defp send_delta(session_id, text) do
    notify("session/update", %{
      "sessionId" => session_id,
      "update" => %{
        "type" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      }
    })
  end

  defp send_session_delta(session_id, text) do
    notify("session/update", %{
      "sessionId" => session_id,
      "update" => %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      }
    })
  end

  defp send_plan(session_id, entries) do
    notify("session/update", %{
      "sessionId" => session_id,
      "update" => %{
        "sessionUpdate" => "plan",
        "entries" => entries
      }
    })
  end

  defp send_full_events(session_id) do
    notify("session/update", %{
      "sessionId" => session_id,
      "update" => %{
        "type" => "agent_thought_chunk",
        "content" => %{"type" => "text", "text" => "thinking "}
      }
    })

    notify("session/update", %{
      "sessionId" => session_id,
      "update" => %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "tool-1",
        "title" => "Read file",
        "kind" => "read",
        "status" => "pending",
        "content" => %{"type" => "text", "text" => "input"},
        "locations" => [],
        "rawInput" => %{"path" => "README.md"}
      }
    })

    notify("session/update", %{
      "sessionId" => session_id,
      "update" => %{
        "type" => "tool_call_update",
        "toolCallId" => "tool-1",
        "status" => "completed",
        "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => "ok"}}],
        "rawOutput" => "ok"
      }
    })
  end

  defp reply(id, result) do
    write(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp error(id, code, message) do
    write(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})
  end

  defp notify(method, params) do
    write(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  defp request_permission(id, session_id) do
    request(id, "session/request_permission", %{
      "sessionId" => session_id,
      "options" => [
        %{"kind" => "allow_always", "name" => "Allow All Edits", "optionId" => "proceed_always"},
        %{"kind" => "allow_once", "name" => "Allow", "optionId" => "proceed_once"},
        %{"kind" => "reject_once", "name" => "Reject", "optionId" => "cancel"}
      ],
      "toolCall" => %{
        "toolCallId" => "write-file-1",
        "title" => "Writing to DESIGN_B.md",
        "kind" => "edit",
        "status" => "pending",
        "locations" => [%{"path" => "DESIGN_B.md"}],
        "rawInput" => %{"path" => "DESIGN_B.md"}
      }
    })
  end

  defp request(id, method, params) do
    write(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
  end

  defp read_response(id) do
    case IO.read(:stdio, :line) do
      line when is_binary(line) ->
        {:ok, Jason.decode!(String.trim(line))}

      other ->
        {:error, {id, other}}
    end
  end

  defp write(message) do
    IO.write(Jason.encode!(message))
    IO.write("\n")
  end
end

Tractor.FakeACPAgent.run()
