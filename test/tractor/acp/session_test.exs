defmodule Tractor.ACP.SessionTest do
  use ExUnit.Case, async: false

  alias Tractor.ACP.{Session, Turn}

  defmodule FakeAgent do
    def command(opts) do
      {
        System.fetch_env!("TRACTOR_TEST_ELIXIR"),
        ["--erl", "-kernel logger_level emergency", "-pa", jason_ebin_path(), fake_agent_path()],
        Keyword.get(opts, :env, [])
      }
    end

    defp fake_agent_path do
      Path.expand("../../support/fake_acp_agent.exs", __DIR__)
    end

    defp jason_ebin_path do
      Path.expand("../../../_build/test/lib/jason/ebin", __DIR__)
    end
  end

  setup do
    System.put_env("TRACTOR_TEST_ELIXIR", System.find_executable("elixir"))
    ports_before = length(:erlang.ports())

    on_exit(fn ->
      assert eventually_port_count(ports_before)
    end)

    :ok
  end

  test "prompts a fake ACP agent and accumulates streaming deltas" do
    {:ok, pid} = Session.start_link(FakeAgent, cwd: File.cwd!())

    assert {:ok, %Turn{response_text: "fake response: hello"} = turn} =
             Session.prompt(pid, "hello", 1_000)

    assert length(turn.agent_message_chunks) == 3
    assert :ok = Session.stop(pid)
  end

  test "maps max_turn_requests stop reason" do
    {:ok, pid} =
      Session.start_link(FakeAgent,
        cwd: File.cwd!(),
        env: [{"TRACTOR_FAKE_ACP_MODE", "max_turn_requests"}]
      )

    assert {:error, :max_turn_requests} = Session.prompt(pid, "hello", 1_000)
    assert :ok = Session.stop(pid)
  end

  test "maps JSON-RPC prompt errors" do
    {:ok, pid} =
      Session.start_link(FakeAgent,
        cwd: File.cwd!(),
        env: [{"TRACTOR_FAKE_ACP_MODE", "jsonrpc_error"}]
      )

    assert {:error, {:jsonrpc_error, %{"code" => -32_000, "message" => "scripted jsonrpc error"}}} =
             Session.prompt(pid, "hello", 1_000)

    assert :ok = Session.stop(pid)
  end

  test "ignores non-JSON provider stdout lines" do
    {:ok, pid} =
      Session.start_link(FakeAgent,
        cwd: File.cwd!(),
        env: [{"TRACTOR_FAKE_ACP_MODE", "noisy_stdout"}]
      )

    assert {:ok, %Turn{response_text: "fake response: hello"}} =
             Session.prompt(pid, "hello", 1_000)

    assert :ok = Session.stop(pid)
  end

  test "captures non-agent-message session updates without changing response text" do
    {:ok, pid} =
      Session.start_link(FakeAgent,
        cwd: File.cwd!(),
        env: [{"TRACTOR_FAKE_ACP_MODE", "tool_update"}]
      )

    assert {:ok, %Turn{response_text: "fake response: hello"} = turn} =
             Session.prompt(pid, "hello", 1_000)

    assert length(turn.tool_call_updates) == 1
    assert :ok = Session.stop(pid)
  end

  test "maps prompt timeout" do
    {:ok, pid} =
      Session.start_link(FakeAgent,
        cwd: File.cwd!(),
        env: [{"TRACTOR_FAKE_ACP_MODE", "timeout"}]
      )

    assert {:error, :timeout} = Session.prompt(pid, "hello", 50)
    assert :ok = Session.stop(pid)
  end

  test "maps agent crash" do
    {:ok, pid} =
      Session.start_link(FakeAgent,
        cwd: File.cwd!(),
        env: [{"TRACTOR_FAKE_ACP_MODE", "crash"}]
      )

    assert {:error, {:port_exit, 42}} = Session.prompt(pid, "hello", 1_000)
  end

  test "50 concurrent echo sessions resolve without leaking ports" do
    ports_before = length(:erlang.ports())

    results =
      1..50
      |> Task.async_stream(
        fn index ->
          {:ok, pid} = Session.start_link(FakeAgent, cwd: File.cwd!())
          result = Session.prompt(pid, "hello #{index}", 15_000)
          :ok = Session.stop(pid)
          result
        end,
        max_concurrency: 50,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    responses =
      Enum.map(results, fn {:ok, %Turn{response_text: response}} -> response end)

    expected = Enum.map(1..50, fn index -> "fake response: hello #{index}" end)

    assert Enum.sort(responses) == Enum.sort(expected)

    assert eventually_port_count(ports_before)
  end

  @tag :tmp_dir
  test "stops provider child processes", %{tmp_dir: tmp_dir} do
    child_pid_file = Path.join(tmp_dir, "child.pid")

    on_exit(fn ->
      if File.exists?(child_pid_file) do
        child_pid_file
        |> File.read!()
        |> String.to_integer()
        |> kill_os_process()
      end
    end)

    {:ok, pid} =
      Session.start_link(FakeAgent,
        cwd: File.cwd!(),
        env: [
          {"TRACTOR_FAKE_ACP_MODE", "spawn_child"},
          {"TRACTOR_FAKE_ACP_CHILD_PID_FILE", child_pid_file}
        ]
      )

    assert {:ok, %Turn{response_text: "fake response: hello"}} =
             Session.prompt(pid, "hello", 1_000)

    child_pid = child_pid_file |> File.read!() |> String.to_integer()

    assert os_process_alive?(child_pid)

    assert :ok = Session.stop(pid)
    assert eventually_os_process_gone?(child_pid)
  end

  @tag :integration
  test "real gemini ACP round trip" do
    if System.get_env("TRACTOR_REAL_GEMINI") == "1" do
      {:ok, pid} = Session.start_link(Tractor.Agent.Gemini, cwd: File.cwd!())

      assert {:ok, %Turn{response_text: response}} =
               Session.prompt(pid, "Reply with the single word tractor.", 120_000)

      assert is_binary(response)
      assert :ok = Session.stop(pid)
    end
  end

  test "captures thought chunks, tool calls, updates, and sink order" do
    test_pid = self()

    sink = fn event ->
      send(test_pid, {:sink, event.kind})
      :ok
    end

    {:ok, pid} =
      Session.start_link(FakeAgent,
        cwd: File.cwd!(),
        event_sink: sink,
        env: [{"FAKE_ACP_EVENTS", "full"}]
      )

    assert {:ok, %Turn{} = turn} = Session.prompt(pid, "hello", 1_000)
    assert turn.response_text == "fake response: hello"
    assert [%{"text" => "thinking "}] = turn.agent_thought_chunks
    assert [%{"toolCallId" => "tool-1"}] = turn.tool_calls
    assert [%{"toolCallId" => "tool-1", "status" => "completed"}] = turn.tool_call_updates

    assert_receive {:sink, :agent_thought_chunk}
    assert_receive {:sink, :tool_call}
    assert_receive {:sink, :tool_call_update}
    assert_receive {:sink, :agent_message_chunk}

    assert :ok = Session.stop(pid)
  end

  test "unknown discriminator is preserved for audit and otherwise ignored" do
    {:ok, pid} =
      Session.start_link(FakeAgent,
        cwd: File.cwd!(),
        env: [{"TRACTOR_FAKE_ACP_MODE", "unknown_update"}]
      )

    assert {:ok, %Turn{response_text: "fake response: hello", events: events}} =
             Session.prompt(pid, "hello", 1_000)

    assert Enum.any?(events, &(&1["type"] == "unknown_shape"))
    assert :ok = Session.stop(pid)
  end

  defp eventually_port_count(expected) do
    Enum.any?(1..100, fn _attempt ->
      if length(:erlang.ports()) == expected do
        true
      else
        Process.sleep(50)
        false
      end
    end)
  end

  defp eventually_os_process_gone?(pid) do
    Enum.any?(1..20, fn _attempt ->
      if os_process_alive?(pid) do
        Process.sleep(25)
        false
      else
        true
      end
    end)
  end

  defp os_process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _other -> false
    end
  rescue
    _error -> false
  end

  defp kill_os_process(pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end
end
