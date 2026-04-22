defmodule Tractor.WaitHumanRunTest do
  use ExUnit.Case, async: false

  alias Tractor.{Checkpoint, DotParser, Edge, Node, Pipeline, ResumeBoot, Run, RunBus, Validator}

  @tag :tmp_dir
  test "wait.human suspends, rejects stale labels, and resumes through the normal success path",
       %{
         tmp_dir: tmp_dir
       } do
    run_id = "wait-human-operator"
    RunBus.subscribe(run_id)

    assert {:ok, ^run_id} = Run.start(wait_pipeline(), runs_dir: tmp_dir, run_id: run_id)
    assert_receive {:run_event, "gate", %{"kind" => "wait_human_pending", "data" => data}}, 1_000
    assert data["outgoing_labels"] == ["approve", "reject"]

    waiting = wait_for_waiting(run_id, "gate")
    assert waiting.wait_prompt == "Approve ?"

    assert {:error, {:invalid_wait_label, ["approve", "reject"]}} =
             Run.submit_wait_choice(run_id, "gate", "bogus")

    assert :ok = Run.submit_wait_choice(run_id, "gate", "approve")

    assert_receive {:run_event, "gate", %{"kind" => "wait_human_resolved", "data" => resolved}},
                   1_000

    assert resolved["label"] == "approve"
    assert resolved["source"] == "operator"

    assert {:error, :wait_not_pending} =
             Run.submit_wait_choice(run_id, "gate", "approve")

    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["approved"]["stdout"] == "approved"
    assert result.context["gate"]["resolved_label"] == "approve"
    assert result.context["gate"]["resolution_source"] == "operator"

    wait_artifact =
      tmp_dir
      |> Path.join(run_id)
      |> Path.join("gate/attempt-1/wait.json")
      |> File.read!()
      |> Jason.decode!()

    assert wait_artifact["outgoing_labels"] == ["approve", "reject"]
  end

  @tag :tmp_dir
  test "operator resolution rehydrates a pending wait from checkpoint when runner state is stale",
       %{tmp_dir: tmp_dir} do
    run_id = "wait-human-rehydrate"

    assert {:ok, ^run_id} = Run.start(wait_pipeline(), runs_dir: tmp_dir, run_id: run_id)

    waiting = wait_for_waiting(run_id, "gate")

    if is_reference(waiting.timeout_ref) do
      Process.cancel_timer(waiting.timeout_ref)
    end

    pid = runner_pid(run_id)

    :sys.replace_state(pid, fn state ->
      %{state | waiting: %{}, wait_timers: %{}}
    end)

    assert :ok = Run.submit_wait_choice(run_id, "gate", "approve")

    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["approved"]["stdout"] == "approved"
    assert result.context["gate"]["resolved_label"] == "approve"
    assert result.context["gate"]["resolution_source"] == "operator"
  end

  @tag :tmp_dir
  test "wait.human timeout resolves via default_edge", %{tmp_dir: tmp_dir} do
    run_id = "wait-human-timeout"
    RunBus.subscribe(run_id)

    pipeline =
      wait_pipeline(
        wait_attrs: %{"wait_timeout" => "10ms", "default_edge" => "approve"},
        run_id: run_id
      )

    assert {:ok, ^run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: run_id)
    assert_receive {:run_event, "gate", %{"kind" => "wait_human_pending"}}, 1_000

    assert_receive {:run_event, "gate", %{"kind" => "wait_human_resolved", "data" => resolved}},
                   1_000

    assert resolved["label"] == "approve"
    assert resolved["source"] == "timeout"

    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["approved"]["stdout"] == "approved"
    assert result.context["gate"]["resolution_source"] == "timeout"
  end

  @tag :tmp_dir
  test "resume rehydrates a pending wait and operator resolution completes the run", %{
    tmp_dir: tmp_dir
  } do
    run_id = "wait-human-resume"
    RunBus.subscribe(run_id)

    dot_path = write_wait_resume_dot(tmp_dir, run_id)
    assert {:ok, pipeline} = DotParser.parse_file(dot_path)
    assert :ok = Validator.validate(pipeline)

    assert {:ok, ^run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: run_id)
    assert_receive {:run_event, "gate", %{"kind" => "wait_human_pending"}}, 1_000

    pid = runner_pid(run_id)
    waiting = wait_for_waiting(run_id, "gate")
    assert waiting.attempt == 1
    waiting_since = waiting.waiting_since

    :ok = GenServer.stop(pid, :shutdown, 1_000)
    wait_for_runner_exit(run_id)

    assert {:ok, ^run_id} = Run.resume(Path.join(tmp_dir, run_id))
    assert_receive {:run_event, "gate", %{"kind" => "wait_human_pending"}}, 1_000

    resumed_waiting = wait_for_waiting(run_id, "gate")
    assert resumed_waiting.attempt == 1
    assert DateTime.compare(resumed_waiting.waiting_since, waiting_since) == :eq

    assert :ok = Run.submit_wait_choice(run_id, "gate", "reject")
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["rejected"]["stdout"] == "rejected"
  end

  @tag :tmp_dir
  test "resume boot respawns a pending wait from a running checkpoint", %{tmp_dir: tmp_dir} do
    run_id = "wait-human-resume-boot"

    dot_path = write_wait_resume_dot(tmp_dir, run_id)
    assert {:ok, pipeline} = DotParser.parse_file(dot_path)
    assert :ok = Validator.validate(pipeline)

    assert {:ok, ^run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: run_id)
    assert wait_for_waiting(run_id, "gate").attempt == 1

    pid = runner_pid(run_id)
    :ok = GenServer.stop(pid, :shutdown, 1_000)
    wait_for_runner_exit(run_id)

    assert ResumeBoot.resume_inflight_runs(tmp_dir) == 1
    assert wait_for_waiting(run_id, "gate").attempt == 1

    assert :ok = Run.submit_wait_choice(run_id, "gate", "approve")
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["approved"]["stdout"] == "approved"
  end

  @tag :tmp_dir
  test "stale wait timeout messages are ignored after operator resolution", %{tmp_dir: tmp_dir} do
    run_id = "wait-human-stale-timeout"

    pipeline =
      wait_pipeline(
        wait_attrs: %{"wait_timeout" => "5s", "default_edge" => "approve"},
        run_id: run_id
      )

    assert {:ok, ^run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: run_id)
    waiting = wait_for_waiting(run_id, "gate")
    pid = runner_pid(run_id)

    assert :ok = Run.submit_wait_choice(run_id, "gate", "reject")
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["rejected"]["stdout"] == "rejected"

    send(pid, {:wait_human_timeout, "gate", waiting.attempt})
    Process.sleep(50)

    resolved_events =
      tmp_dir
      |> Path.join(run_id)
      |> Path.join("gate/events.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["kind"] == "wait_human_resolved"))

    assert length(resolved_events) == 1
    assert hd(resolved_events)["data"]["source"] == "operator"
  end

  @tag :tmp_dir
  test "resume fires an already elapsed wait timeout immediately", %{tmp_dir: tmp_dir} do
    run_id = "wait-human-expired-resume"
    dot_path = write_wait_pipeline_dot(tmp_dir, run_id)

    assert {:ok, pipeline} = DotParser.parse_file(dot_path)
    assert :ok = Validator.validate(pipeline)

    run_dir = Path.join(tmp_dir, run_id)
    File.mkdir_p!(run_dir)

    started_at =
      DateTime.utc_now()
      |> DateTime.add(-5, :second)
      |> DateTime.to_iso8601()

    File.write!(
      Path.join(run_dir, "manifest.json"),
      Jason.encode!(%{
        "run_id" => run_id,
        "pipeline_path" => dot_path,
        "started_at" => started_at,
        "status" => "running",
        "provider_commands" => []
      })
    )

    Checkpoint.save(%{
      pipeline: pipeline,
      store: %{run_id: run_id, run_dir: run_dir},
      agenda: :queue.new(),
      completed: MapSet.new(["start"]),
      iterations: %{"start" => 1, "gate" => 1},
      context: %{"start" => "", "iterations" => %{"start" => []}},
      waiting: %{
        "gate" => %{
          node_id: "gate",
          waiting_since: DateTime.utc_now() |> DateTime.add(-5, :second),
          wait_prompt: "Approve ?",
          outgoing_labels: ["approve", "reject"],
          wait_timeout_ms: 10,
          default_edge: "approve",
          attempt: 1,
          branch_id: nil,
          parallel_id: nil,
          iteration: 1,
          declaring_node_id: "gate",
          origin_node_id: "gate",
          recovery_tier: :primary,
          routed_from: nil,
          max_iterations: 3,
          started_at: started_at
        }
      },
      provider_commands: [],
      started_at_wall_iso: started_at
    })

    assert {:ok, ^run_id} = Run.resume(run_dir)
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["approved"]["stdout"] == "approved"
    assert result.context["gate"]["resolution_source"] == "timeout"
  end

  @tag :tmp_dir
  test "wait.human inside a parallel branch blocks fan-in until resolution", %{tmp_dir: tmp_dir} do
    run_id = "wait-human-parallel"
    RunBus.subscribe(run_id)

    pipeline = parse_parallel_wait!(tmp_dir)

    assert {:ok, ^run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: run_id)
    assert_receive {:run_event, "gate", %{"kind" => "wait_human_pending"}}, 1_000

    waiting = wait_for_waiting(run_id, "gate")
    assert waiting.branch_id == "audit:gate"
    assert waiting.parallel_id == "audit"

    refute node_event?(tmp_dir, run_id, "join", "parallel_completed")
    refute node_event?(tmp_dir, run_id, "exit", "node_succeeded")

    assert :ok = Run.submit_wait_choice(run_id, "gate", "continue")
    assert {:ok, result} = Run.await(run_id, 2_000)
    assert result.context["audit"] == "success"

    assert Enum.any?(result.context["parallel.results.audit"], fn branch ->
             branch["entry_node_id"] == "quick" and branch["outcome"]["stdout"] == "quick"
           end)

    assert node_event?(tmp_dir, run_id, "join", "node_succeeded")
    assert node_event?(tmp_dir, run_id, "exit", "node_succeeded")
  end

  @tag :tmp_dir
  test "looped tool iterations persist timing metadata for cumulative graph badges", %{
    tmp_dir: tmp_dir
  } do
    run_id = "wait-human-loop-badges"
    RunBus.subscribe(run_id)

    assert {:ok, ^run_id} =
             Run.start(loop_badge_pipeline(run_id), runs_dir: tmp_dir, run_id: run_id)

    assert_receive {:run_event, "review", %{"kind" => "wait_human_pending"}}, 1_000

    assert :ok = Run.submit_wait_choice(run_id, "review", "revise")
    assert_receive {:run_event, "review", %{"kind" => "wait_human_pending"}}, 1_000

    run_dir = Path.join(tmp_dir, run_id)

    first_iteration =
      run_dir
      |> Path.join("draft/iterations/1/status.json")
      |> File.read!()
      |> Jason.decode!()

    second_iteration =
      run_dir
      |> Path.join("draft/iterations/2/status.json")
      |> File.read!()
      |> Jason.decode!()

    assert is_binary(first_iteration["started_at"])
    assert is_binary(first_iteration["finished_at"])
    assert is_binary(second_iteration["started_at"])
    assert is_binary(second_iteration["finished_at"])
    assert :ok = Run.submit_wait_choice(run_id, "review", "approve")
    assert {:ok, _result} = Run.await(run_id, 2_000)
  end

  defp wait_pipeline(opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "wait-human")
    wait_attrs = Keyword.get(opts, :wait_attrs, %{})

    %Pipeline{
      path: "#{run_id}.dot",
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{
              id: "gate",
              type: "wait.human",
              attrs:
                Map.merge(
                  %{"wait_prompt" => "Approve {{start}}?"},
                  wait_attrs
                )
            },
            %Node{
              id: "approved",
              type: "tool",
              attrs: %{"command" => ["sh", "-c", "printf approved"]}
            },
            %Node{
              id: "rejected",
              type: "tool",
              attrs: %{"command" => ["sh", "-c", "printf rejected"]}
            },
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [
        %Edge{from: "start", to: "gate"},
        %Edge{from: "gate", to: "approved", label: "approve"},
        %Edge{from: "gate", to: "rejected", label: "reject"},
        %Edge{from: "approved", to: "exit"},
        %Edge{from: "rejected", to: "exit"}
      ]
    }
  end

  defp write_wait_pipeline_dot(tmp_dir, run_id) do
    path = Path.join(tmp_dir, "#{run_id}.dot")

    File.write!(path, """
    digraph {
      start [shape=Mdiamond]
      gate [shape=hexagon, wait_prompt="Approve {{start}}?", wait_timeout="10ms", default_edge="approve"]
      approved [shape=parallelogram, command=["sh","-c","printf approved"]]
      rejected [shape=parallelogram, command=["sh","-c","printf rejected"]]
      exit [shape=Msquare]

      start -> gate
      gate -> approved [label="approve"]
      gate -> rejected [label="reject"]
      approved -> exit
      rejected -> exit
    }
    """)

    path
  end

  defp write_wait_resume_dot(tmp_dir, run_id) do
    path = Path.join(tmp_dir, "#{run_id}.dot")

    File.write!(path, """
    digraph {
      start [shape=Mdiamond]
      gate [shape=hexagon, wait_prompt="Approve {{start}}?"]
      approved [shape=parallelogram, command=["sh","-c","printf approved"]]
      rejected [shape=parallelogram, command=["sh","-c","printf rejected"]]
      exit [shape=Msquare]

      start -> gate
      gate -> approved [label="approve"]
      gate -> rejected [label="reject"]
      approved -> exit
      rejected -> exit
    }
    """)

    path
  end

  defp parse_parallel_wait!(tmp_dir) do
    path = Path.join(tmp_dir, "parallel_wait.dot")

    File.write!(path, """
    digraph {
      start [shape=Mdiamond]
      audit [shape=component, max_parallel=2]
      gate [shape=hexagon, wait_prompt="Decide"]
      quick [shape=parallelogram, command=["sh","-c","printf quick"]]
      join [shape=tripleoctagon]
      exit [shape=Msquare]

      start -> audit
      audit -> gate
      audit -> quick
      gate -> join [label="continue"]
      quick -> join
      join -> exit
    }
    """)

    assert {:ok, pipeline} = DotParser.parse_file(path)
    assert :ok = Validator.validate(pipeline)
    pipeline
  end

  defp loop_badge_pipeline(run_id) do
    %Pipeline{
      path: "#{run_id}.dot",
      nodes:
        Map.new(
          [
            %Node{id: "start", type: "start"},
            %Node{
              id: "draft",
              type: "tool",
              attrs: %{"command" => ["sh", "-c", "sleep 0.01; printf draft"]}
            },
            %Node{
              id: "review",
              type: "wait.human",
              attrs: %{"wait_prompt" => "Review the draft. Pick approve, revise, or reject."}
            },
            %Node{id: "exit", type: "exit"}
          ],
          &{&1.id, &1}
        ),
      edges: [
        %Edge{from: "start", to: "draft"},
        %Edge{from: "draft", to: "review"},
        %Edge{from: "review", to: "exit", label: "approve"},
        %Edge{
          from: "review",
          to: "draft",
          label: "revise",
          attrs: %{"condition" => "preferred_label=revise", "label" => "revise"}
        },
        %Edge{from: "review", to: "exit", label: "reject"}
      ]
    }
  end

  defp runner_pid(run_id) do
    [{pid, _value}] = Registry.lookup(Tractor.RunRegistry, run_id)
    pid
  end

  defp wait_for_runner_exit(run_id, attempts \\ 50)

  defp wait_for_runner_exit(_run_id, 0), do: :ok

  defp wait_for_runner_exit(run_id, attempts) do
    case Registry.lookup(Tractor.RunRegistry, run_id) do
      [] ->
        :ok

      _ ->
        Process.sleep(20)
        wait_for_runner_exit(run_id, attempts - 1)
    end
  end

  defp wait_for_waiting(run_id, node_id, attempts \\ 50)

  defp wait_for_waiting(run_id, node_id, 0) do
    flunk("expected #{node_id} to be waiting in run #{run_id}")
  end

  defp wait_for_waiting(run_id, node_id, attempts) do
    waiting =
      run_id
      |> runner_pid()
      |> :sys.get_state()
      |> Map.fetch!(:waiting)
      |> Map.get(node_id)

    if waiting do
      waiting
    else
      Process.sleep(20)
      wait_for_waiting(run_id, node_id, attempts - 1)
    end
  end

  defp node_event?(tmp_dir, run_id, node_id, kind) do
    path = Path.join([tmp_dir, run_id, node_id, "events.jsonl"])

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.any?(&(&1["kind"] == kind))
    else
      false
    end
  end
end
