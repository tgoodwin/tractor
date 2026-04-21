defmodule Tractor.HandlerTest do
  use ExUnit.Case, async: false

  import Mox

  alias Tractor.{Handler, Node}

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:tractor, :agent_client)
    Application.put_env(:tractor, :agent_client, Tractor.AgentClientMock)

    on_exit(fn ->
      if original do
        Application.put_env(:tractor, :agent_client, original)
      else
        Application.delete_env(:tractor, :agent_client)
      end
    end)
  end

  test "start and exit handlers no-op successfully" do
    assert {:ok, "", %{status: %{"status" => "ok"}}} =
             Handler.Start.run(%Node{id: "start", type: "start"}, %{}, "/tmp/run")

    assert {:ok, "", %{status: %{"status" => "ok"}}} =
             Handler.Exit.run(%Node{id: "exit", type: "exit"}, %{}, "/tmp/run")
  end

  test "conditional handler succeeds without side effects" do
    assert {:ok, %{}, %{status: %{"status" => "ok"}}} =
             Handler.Conditional.run(%Node{id: "route", type: "conditional"}, %{}, "/tmp/run")
  end

  test "codergen interpolates prior node output and prompts provider session" do
    node = %Node{
      id: "ask",
      type: "codergen",
      llm_provider: "codex",
      prompt: "Use {{start}}"
    }

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "Use ready", 600_000 -> {:ok, "done"} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, "done", updates} = Handler.Codergen.run(node, %{"start" => "ready"}, "/tmp/run")
    assert updates.prompt == "Use ready"
    assert updates.response == "done"
    assert updates.status["status"] == "ok"
    assert updates.provider_command.provider == "codex"
  end

  test "codergen preserves unresolved placeholders for artifact debugging" do
    node = %Node{
      id: "ask",
      type: "codergen",
      llm_provider: "codex",
      prompt: "Use {{missing}}"
    }

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "Use {{missing}}", 600_000 ->
      {:ok, "done"}
    end)

    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, "done", updates} = Handler.Codergen.run(node, %{}, "/tmp/run")
    assert updates.prompt == "Use {{missing}}"
  end

  test "codergen carries token usage into status metadata" do
    node = %Node{
      id: "ask",
      type: "codergen",
      llm_provider: "codex",
      prompt: "Go"
    }

    usage = %{input_tokens: 12, output_tokens: 8, total_tokens: 20, raw: %{"totalTokens" => 20}}

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "Go", 600_000 ->
      {:ok, %Tractor.ACP.Turn{response_text: "done", token_usage: usage}}
    end)

    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, "done", updates} = Handler.Codergen.run(node, %{}, "/tmp/run")
    assert updates.status["token_usage"] == usage
  end

  test "codergen returns agent errors" do
    node = %Node{id: "ask", type: "codergen", llm_provider: "gemini", prompt: "Go", timeout: 10}

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Gemini, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "Go", 10 -> {:error, :timeout} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:error, :timeout} = Handler.Codergen.run(node, %{}, "/tmp/run")
  end
end
