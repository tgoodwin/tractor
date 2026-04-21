defmodule Tractor.HandlerJudgeTest do
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

  test "stub judge always rejects or accepts at probability bounds" do
    reject = %Node{
      id: "judge",
      type: "judge",
      attrs: %{"judge_mode" => "stub", "reject_probability" => "1.0"}
    }

    accept = %Node{
      id: "judge",
      type: "judge",
      attrs: %{"judge_mode" => "stub", "reject_probability" => "0.0"}
    }

    assert {:ok, _response, %{preferred_label: "reject", verdict: :reject}} =
             Handler.Judge.run(reject, %{"__run_id__" => "r", "__iteration__" => 1}, "/tmp/run")

    assert {:ok, _response, %{preferred_label: "accept", verdict: :accept}} =
             Handler.Judge.run(accept, %{"__run_id__" => "r", "__iteration__" => 1}, "/tmp/run")
  end

  test "stub judge verdicts are deterministic by run node and iteration" do
    node = %Node{
      id: "judge",
      type: "judge",
      attrs: %{"judge_mode" => "stub", "reject_probability" => "0.5"}
    }

    first =
      for iteration <- 1..6 do
        {:ok, _response, updates} =
          Handler.Judge.run(
            node,
            %{"__run_id__" => "fixed", "__iteration__" => iteration},
            "/tmp/run"
          )

        updates.preferred_label
      end

    second =
      for iteration <- 1..6 do
        {:ok, _response, updates} =
          Handler.Judge.run(
            node,
            %{"__run_id__" => "fixed", "__iteration__" => iteration},
            "/tmp/run"
          )

        updates.preferred_label
      end

    assert first == second
  end

  test "llm judge parses fenced JSON verdicts" do
    node = %Node{id: "judge", type: "judge", llm_provider: "codex", prompt: "Judge this"}

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "Judge this", 300_000 ->
      {:ok, "```json\n{\"verdict\":\"accept\",\"critique\":\"ship it\"}\n```"}
    end)

    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:ok, _response, updates} =
             Handler.Judge.run(node, %{"__run_id__" => "r", "__iteration__" => 1}, "/tmp/run")

    assert updates.preferred_label == "accept"
    assert updates.critique == "ship it"
  end

  test "llm judge fails malformed verdicts clearly" do
    node = %Node{id: "judge", type: "judge", llm_provider: "codex", prompt: "Judge this"}

    expect(Tractor.AgentClientMock, :start_session, fn Tractor.Agent.Codex, _opts ->
      {:ok, self()}
    end)

    expect(Tractor.AgentClientMock, :prompt, fn _pid, "Judge this", 300_000 ->
      {:ok, "{\"verdict\":\"maybe\",\"critique\":\"unclear\"}"}
    end)

    expect(Tractor.AgentClientMock, :stop, fn _pid -> :ok end)

    assert {:error, :judge_parse_error} =
             Handler.Judge.run(node, %{"__run_id__" => "r", "__iteration__" => 1}, "/tmp/run")
  end

  test "stub judge at reject_probability=0.5 converges within expected bounds over 1000 runs" do
    node = %Node{
      id: "judge",
      type: "judge",
      attrs: %{"judge_mode" => "stub", "reject_probability" => "0.5"}
    }

    rejects =
      for i <- 1..1000, reduce: 0 do
        acc ->
          {:ok, _response, updates} =
            Handler.Judge.run(
              node,
              %{"__run_id__" => "stat-#{i}", "__iteration__" => 1},
              "/tmp/run"
            )

          if updates.preferred_label == "reject", do: acc + 1, else: acc
      end

    assert rejects in 430..570,
           "expected ~500 rejects at p=0.5 across 1000 runs, got #{rejects}"
  end

  test "stub judge replays identical verdict sequence on resume (pure-function seed)" do
    node = %Node{
      id: "judge",
      type: "judge",
      attrs: %{"judge_mode" => "stub", "reject_probability" => "0.5"}
    }

    seed_inputs = for iteration <- 1..6, do: {"resumed-run", "judge", iteration}

    pre_crash =
      for {run_id, _nid, iteration} <- seed_inputs do
        {:ok, _response, updates} =
          Handler.Judge.run(
            node,
            %{"__run_id__" => run_id, "__iteration__" => iteration},
            "/tmp/run"
          )

        updates.preferred_label
      end

    # Simulate resume: fresh process state, same {run_id, node_id, iteration} triple
    # must yield the same verdict sequence — verifies determinism is pure, not process-local.
    :rand.seed(:exsplus, {1, 2, 3})

    post_resume =
      for {run_id, _nid, iteration} <- seed_inputs do
        {:ok, _response, updates} =
          Handler.Judge.run(
            node,
            %{"__run_id__" => run_id, "__iteration__" => iteration},
            "/tmp/run"
          )

        updates.preferred_label
      end

    assert pre_crash == post_resume
  end
end
