defmodule Tractor.RunTest do
  use ExUnit.Case, async: false

  import Mox

  alias Tractor.{Edge, Node, Pipeline, Run}

  setup :set_mox_global
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

  @tag :tmp_dir
  test "runs a minimal start to exit pipeline", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [node("start", "start"), node("exit", "exit")],
        edges: [edge("start", "exit")]
      )

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-minimal")
    assert run_id == "run-minimal"

    assert {:ok, result} = Run.await(run_id, 1_000)
    assert result.context == %{"start" => "", "exit" => ""}
    assert File.exists?(Path.join(result.run_dir, "manifest.json"))
    assert File.exists?(Path.join(result.run_dir, "start/status.json"))
    assert File.exists?(Path.join(result.run_dir, "exit/status.json"))
  end

  @tag :tmp_dir
  test "runs a four-node pipeline in order and carries context", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("one", "codergen", provider: "codex", prompt: "First"),
          node("two", "codergen", provider: "gemini", prompt: "Second {{one}}"),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "two"), edge("two", "exit")]
      )

    expect_session(Tractor.Agent.Codex, "First", "one out")
    expect_session(Tractor.Agent.Gemini, "Second one out", "two out")

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-context")
    assert {:ok, result} = Run.await(run_id, 1_000)

    assert result.context["one"] == "one out"
    assert result.context["two"] == "two out"
  end

  @tag :tmp_dir
  test "propagates handler errors", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("one", "codergen", provider: "codex", prompt: "First"),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 300_000 -> {:error, :timeout} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-error")
    assert {:error, :timeout} = Run.await(run_id, 1_000)

    status = read_json(Path.join(tmp_dir, "run-error/one/status.json"))
    assert status["status"] == "error"
    assert status["reason"] =~ ":timeout"
  end

  @tag :tmp_dir
  @tag :capture_log
  test "propagates handler crashes", %{tmp_dir: tmp_dir} do
    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("one", "codergen", provider: "codex", prompt: "First"),
          node("exit", "exit")
        ],
        edges: [edge("start", "one"), edge("one", "exit")]
      )

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "First", 300_000 -> raise "boom" end)

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-crash")

    assert {:error, {:handler_crash, {%RuntimeError{message: "boom"}, _stack}}} =
             Run.await(run_id, 1_000)
  end

  @tag :tmp_dir
  test "runs claude, codex, then gemini providers in graph order", %{tmp_dir: tmp_dir} do
    test_pid = self()

    pipeline =
      pipeline(
        nodes: [
          node("start", "start"),
          node("claude", "codergen", provider: "claude", prompt: "Claude"),
          node("codex", "codergen", provider: "codex", prompt: "Codex {{claude}}"),
          node("gemini", "codergen", provider: "gemini", prompt: "Gemini {{codex}}"),
          node("exit", "exit")
        ],
        edges: [
          edge("start", "claude"),
          edge("claude", "codex"),
          edge("codex", "gemini"),
          edge("gemini", "exit")
        ]
      )

    expect_ordered_session(test_pid, Tractor.Agent.Claude, :claude, "Claude", "c1")
    expect_ordered_session(test_pid, Tractor.Agent.Codex, :codex, "Codex c1", "c2")
    expect_ordered_session(test_pid, Tractor.Agent.Gemini, :gemini, "Gemini c2", "c3")

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "run-providers")
    assert {:ok, _result} = Run.await(run_id, 1_000)

    assert_receive {:provider, :claude}
    assert_receive {:provider, :codex}
    assert_receive {:provider, :gemini}
  end

  defp pipeline(opts) do
    nodes =
      opts
      |> Keyword.fetch!(:nodes)
      |> Map.new(&{&1.id, &1})

    %Pipeline{nodes: nodes, edges: Keyword.fetch!(opts, :edges)}
  end

  defp node(id, type, opts \\ []) do
    %Node{
      id: id,
      type: type,
      llm_provider: Keyword.get(opts, :provider),
      prompt: Keyword.get(opts, :prompt)
    }
  end

  defp edge(from, to), do: %Edge{from: from, to: to}

  defp expect_session(adapter, prompt, response) do
    expect(Tractor.AgentClientMock, :start_session, fn ^adapter, _opts -> {:ok, self()} end)
    expect(Tractor.AgentClientMock, :prompt, fn _pid, ^prompt, 300_000 -> {:ok, response} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)
  end

  defp expect_ordered_session(test_pid, adapter, provider, prompt, response) do
    expect(Tractor.AgentClientMock, :start_session, fn ^adapter, _opts ->
      send(test_pid, {:provider, provider})
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, ^prompt, 300_000 -> {:ok, response} end)
    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()
end
