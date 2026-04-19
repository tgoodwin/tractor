#!/usr/bin/env elixir

defmodule Tractor.FakeACPAgent do
  @moduledoc false

  def run do
    mode = System.get_env("TRACTOR_FAKE_ACP_MODE", "ok")
    loop(%{mode: mode, session_id: "fake-session"})
  end

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

  defp handle_prompt(message, state) do
    prompt_text =
      message
      |> get_in(["params", "prompt"])
      |> List.wrap()
      |> Enum.map_join("", &Map.get(&1, "text", ""))

    send_delta(state.session_id, "fake ")
    send_delta(state.session_id, "response: ")
    send_delta(state.session_id, prompt_text)
    reply(message["id"], %{"stopReason" => "end_turn"})

    state
  end

  defp send_delta(session_id, text) do
    notify("session/update", %{
      "sessionId" => session_id,
      "update" => %{
        "type" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
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

  defp write(message) do
    IO.write(Jason.encode!(message))
    IO.write("\n")
  end
end

Tractor.FakeACPAgent.run()
