defmodule Tractor.ParallelRunTest do
  use ExUnit.Case, async: false

  import Mox

  alias Tractor.{DotParser, Run, Validator}
  alias Tractor.Handler.FanIn

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    original = Application.get_env(:tractor, :agent_client)
    Application.put_env(:tractor, :agent_client, Tractor.AgentClientMock)

    stub(Tractor.AgentClientMock, :start_session, fn adapter, _opts -> {:ok, adapter} end)
    stub(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    on_exit(fn ->
      if original do
        Application.put_env(:tractor, :agent_client, original)
      else
        Application.delete_env(:tractor, :agent_client)
      end
    end)
  end

  @tag :tmp_dir
  test "three branches run concurrently", %{tmp_dir: tmp_dir} do
    test_pid = self()

    stub(Tractor.AgentClientMock, :prompt, fn _pid, prompt, _timeout ->
      send(test_pid, {:started, prompt, System.monotonic_time(:millisecond)})
      Process.sleep(100)
      send(test_pid, {:finished, prompt, System.monotonic_time(:millisecond)})
      {:ok, %Tractor.ACP.Turn{response_text: "out #{prompt}"}}
    end)

    pipeline = parse!(tmp_dir, parallel_dot(max_parallel: 3))

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "parallel-concurrent")
    assert {:ok, _result} = Run.await(run_id, 2_000)

    starts = receive_messages(:started, 3)
    finishes = receive_messages(:finished, 3)

    latest_start = starts |> Enum.map(fn {_prompt, ts} -> ts end) |> Enum.max()
    earliest_finish = finishes |> Enum.map(fn {_prompt, ts} -> ts end) |> Enum.min()

    assert latest_start < earliest_finish
  end

  @tag :tmp_dir
  test "max_parallel bounds branch concurrency", %{tmp_dir: tmp_dir} do
    test_pid = self()

    stub(Tractor.AgentClientMock, :prompt, fn _pid, prompt, _timeout ->
      send(test_pid, {:started, prompt, System.monotonic_time(:millisecond)})
      Process.sleep(100)
      send(test_pid, {:finished, prompt, System.monotonic_time(:millisecond)})
      {:ok, %Tractor.ACP.Turn{response_text: "out #{prompt}"}}
    end)

    pipeline = parse!(tmp_dir, parallel_dot(max_parallel: 2))

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "parallel-bounded")
    assert_receive {:started, _prompt_a, _ts_a}, 1_000
    assert_receive {:started, _prompt_b, _ts_b}, 1_000
    refute_receive {:started, _prompt_c, _ts_c}, 40
    assert {:ok, _result} = Run.await(run_id, 2_000)
  end

  @tag :tmp_dir
  test "branch context is isolated and does not leak to parent", %{tmp_dir: tmp_dir} do
    stub(Tractor.AgentClientMock, :prompt, fn _pid, prompt, _timeout ->
      {:ok, %Tractor.ACP.Turn{response_text: prompt}}
    end)

    pipeline = parse!(tmp_dir, parallel_dot(prompt: "{{parallel.branch_id}}"))

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "parallel-isolated")
    assert {:ok, result} = Run.await(run_id, 2_000)

    results = result.context["parallel.results.audit"]
    assert Enum.map(results, & &1["outcome"]) == ["audit:a", "audit:b", "audit:c"]
    refute Map.has_key?(result.context, "parallel.branch_id")
    refute Map.has_key?(result.context, "a")
    refute Map.has_key?(result.context, "b")
    refute Map.has_key?(result.context, "c")
  end

  @tag :tmp_dir
  test "one branch can fail and fan-in still consolidates successful branches", %{
    tmp_dir: tmp_dir
  } do
    stub(Tractor.AgentClientMock, :prompt, fn
      _pid, "b", _timeout -> {:error, :boom}
      _pid, prompt, _timeout -> {:ok, %Tractor.ACP.Turn{response_text: "ok #{prompt}"}}
    end)

    pipeline = parse!(tmp_dir, parallel_dot())

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "parallel-partial")
    assert {:ok, result} = Run.await(run_id, 2_000)

    assert result.context["audit"] == "partial_success"
    assert result.context["parallel.fan_in.best_id"] in ["audit:a", "audit:c"]
    assert Enum.count(result.context["parallel.results.audit"], &(&1["status"] == "failed")) == 1
  end

  @tag :tmp_dir
  test "all branch failures fail at fan-in", %{tmp_dir: tmp_dir} do
    stub(Tractor.AgentClientMock, :prompt, fn _pid, _prompt, _timeout -> {:error, :boom} end)

    pipeline = parse!(tmp_dir, parallel_dot())

    assert {:ok, run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: "parallel-all-fail")
    assert {:error, :all_branches_failed} = Run.await(run_id, 2_000)
  end

  test "fan-in selection is deterministic" do
    results = [
      %{"branch_id" => "p:c", "status" => "success", "outcome" => %{"score" => 2}},
      %{"branch_id" => "p:a", "status" => "success", "outcome" => %{"score" => 5}},
      %{"branch_id" => "p:b", "status" => "partial_success", "outcome" => %{"score" => 10}}
    ]

    assert {:ok, %{"branch_id" => "p:a"}} = FanIn.select_best(results)
  end

  defp parse!(tmp_dir, contents) when is_binary(contents) do
    path = Path.join(tmp_dir, "parallel.dot")
    File.write!(path, contents)
    assert {:ok, pipeline} = DotParser.parse_file(path)
    assert :ok = Validator.validate(pipeline)
    pipeline
  end

  defp parallel_dot(opts \\ []) do
    max_parallel = Keyword.get(opts, :max_parallel, 3)
    prompt = Keyword.get(opts, :prompt, nil)
    prompt_a = prompt || "a"
    prompt_b = prompt || "b"
    prompt_c = prompt || "c"

    """
    digraph {
      start [shape=Mdiamond]
      audit [shape=component, max_parallel=#{max_parallel}]
      a [shape=box, llm_provider=codex, prompt="#{prompt_a}"]
      b [shape=box, llm_provider=codex, prompt="#{prompt_b}"]
      c [shape=box, llm_provider=codex, prompt="#{prompt_c}"]
      consolidate [shape=tripleoctagon]
      exit [shape=Msquare]

      start -> audit
      audit -> a
      audit -> b
      audit -> c
      a -> consolidate
      b -> consolidate
      c -> consolidate
      consolidate -> exit
    }
    """
  end

  defp receive_messages(kind, count) do
    Enum.map(1..count, fn _index ->
      assert_receive {^kind, prompt, ts}, 1_000
      {prompt, ts}
    end)
  end
end
