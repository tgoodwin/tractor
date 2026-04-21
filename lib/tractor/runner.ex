defmodule Tractor.Runner do
  @moduledoc """
  GenServer that executes a normalized pipeline.
  """

  use GenServer

  alias Tractor.{Checkpoint, Context, Duration, EdgeSelector, Node, Pipeline, RunEvents, RunStore}
  alias Tractor.Runner.{Adjudication, Budget, Failure, Routing}

  defstruct pipeline: nil,
            store: nil,
            frontier: %{},
            retry_timers: %{},
            waiting: %{},
            wait_timers: %{},
            retries: %{},
            agenda: :queue.new(),
            context: %{},
            iterations: %{},
            total_iterations_started: 0,
            branch_contexts: %{},
            parallel_state: %{},
            goal_gates_satisfied: MapSet.new(),
            total_cost_usd: Decimal.new("0"),
            node_costs_usd: %{},
            last_seen_usage: %{},
            warned_unknown_pricing: MapSet.new(),
            late_token_usage_warned?: false,
            completed: MapSet.new(),
            waiters: [],
            result: nil,
            provider_commands: [],
            started_at_ms: nil,
            started_at_wall_iso: nil,
            budget_exhausted?: false

  @spec child_spec({Pipeline.t(), keyword(), RunStore.t()}) :: Supervisor.child_spec()
  def child_spec({pipeline, opts, store}) do
    %{
      id: {__MODULE__, store.run_id},
      start: {__MODULE__, :start_link, [{pipeline, opts, store}]},
      restart: :transient
    }
  end

  @spec start_link({Pipeline.t(), keyword(), RunStore.t()}) :: GenServer.on_start()
  def start_link({pipeline, opts, store}) do
    GenServer.start_link(__MODULE__, {pipeline, opts, store}, name: via(store.run_id))
  end

  @spec await(String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def await(run_id, timeout) do
    case Registry.lookup(Tractor.RunRegistry, run_id) do
      [{pid, _value}] -> GenServer.call(pid, :await, timeout)
      [] -> {:error, :run_not_found}
    end
  end

  @spec info(String.t()) :: {:ok, map()} | {:error, term()}
  def info(run_id) do
    case Registry.lookup(Tractor.RunRegistry, run_id) do
      [{pid, _value}] -> GenServer.call(pid, :info)
      [] -> {:error, :run_not_found}
    end
  end

  @spec submit_wait_choice(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def submit_wait_choice(run_id, node_id, label) do
    case Registry.lookup(Tractor.RunRegistry, run_id) do
      [{pid, _value}] -> GenServer.call(pid, {:submit_wait_choice, node_id, label})
      [] -> {:error, :run_not_found}
    end
  end

  @impl true
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def init({%Pipeline{} = pipeline, opts, %RunStore{} = store}) do
    # Trap EXIT so a stray linked-process crash (e.g. an ACP session cleanup
    # racing handler completion) can't kill the runner GenServer and trigger a
    # supervisor restart loop. We handle the EXIT messages explicitly below.
    Process.flag(:trap_exit, true)

    state =
      case Keyword.get(opts, :resume_state) do
        nil ->
          Enum.each(Map.keys(pipeline.nodes), &RunStore.mark_node_pending(store, &1))
          RunEvents.emit(store.run_id, "_run", :run_started, %{"run_id" => store.run_id})
          started_at_wall_iso = DateTime.utc_now() |> DateTime.to_iso8601()

          %__MODULE__{
            pipeline: pipeline,
            store: store,
            agenda: :queue.in(start_node_id(pipeline), :queue.new()),
            total_iterations_started: 0,
            goal_gates_satisfied: MapSet.new(),
            total_cost_usd: Decimal.new("0"),
            started_at_ms: System.monotonic_time(:millisecond),
            started_at_wall_iso: started_at_wall_iso
          }

        checkpoint ->
          RunEvents.emit(store.run_id, "_run", :run_resumed, %{"run_id" => store.run_id})

          started_at_wall_iso =
            checkpoint["started_at_wall_iso"] || DateTime.to_iso8601(DateTime.utc_now())

          %__MODULE__{
            pipeline: pipeline,
            store: store,
            agenda: queue_from_list(checkpoint["agenda"] || []),
            context: checkpoint["context"] || %{},
            iterations: atomize_count_map(checkpoint["iteration_counts"] || %{}),
            total_iterations_started: checkpoint_total_iterations_started(checkpoint),
            goal_gates_satisfied: MapSet.new(checkpoint["goal_gates_satisfied"] || []),
            total_cost_usd: checkpoint_total_cost_usd(checkpoint),
            completed: MapSet.new(checkpoint["completed"] || []),
            branch_contexts: checkpoint["branch_contexts"] || %{},
            parallel_state:
              checkpoint_parallel_state(pipeline, checkpoint["parallel_state"] || %{}),
            provider_commands: checkpoint["provider_commands"] || [],
            started_at_ms: resumed_started_at_ms(started_at_wall_iso),
            started_at_wall_iso: started_at_wall_iso
          }
      end

    state =
      case Keyword.get(opts, :resume_state) do
        nil -> state
        checkpoint -> restore_waiting_state(state, checkpoint["waiting"] || %{})
      end

    maybe_start_status_agent(state)
    {:ok, state, {:continue, :advance}}
  end

  @impl true
  def handle_call(:await, from, %{result: nil} = state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:await, _from, %{result: result} = state) do
    {:reply, result, state}
  end

  def handle_call(:info, _from, state) do
    {:reply,
     {:ok, %{pipeline: state.pipeline, run_dir: state.store.run_dir, run_id: state.store.run_id}},
     state}
  end

  def handle_call({:submit_wait_choice, node_id, label}, _from, state) do
    case resolve_waiting_node(state, node_id, label, :operator) do
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:ok, next_state} -> {:reply, :ok, next_state}
    end
  end

  @impl true
  def handle_continue(:advance, state) do
    {:noreply, advance(state)}
  end

  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.frontier, ref) do
    Process.demonitor(ref, [:flush])
    {entry, frontier} = Map.pop(state.frontier, ref)
    cancel_timeout(entry)
    state = %{state | frontier: frontier}

    try do
      {:noreply, handle_handler_result(result, entry, state)}
    rescue
      e ->
        require Logger

        Logger.error(
          "Runner crash in handle_handler_result for node #{inspect(entry.node_id)}: " <>
            "#{Exception.format(:error, e, __STACKTRACE__)}"
        )

        reraise e, __STACKTRACE__
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if Map.has_key?(state.frontier, ref) do
      {entry, frontier} = Map.pop(state.frontier, ref)
      cancel_timeout(entry)

      {:noreply,
       handle_node_failure(%{state | frontier: frontier}, entry, {:handler_crash, reason})}
    else
      {:noreply, state}
    end
  end

  def handle_info({:node_timeout, timer_ref}, state) do
    case pop_frontier_by_timeout_ref(state.frontier, timer_ref) do
      {nil, _frontier} ->
        {:noreply, state}

      {{task_ref, entry}, frontier} ->
        Process.demonitor(task_ref, [:flush])
        Task.shutdown(entry.task, :brutal_kill)

        RunEvents.emit(state.store.run_id, entry.node_id, :node_timeout, %{
          "node_id" => entry.node_id,
          "iteration" => entry.iteration,
          "timeout_ms" => entry.timeout_ms,
          "attempt" => entry.attempt
        })

        {:noreply, handle_node_failure(%{state | frontier: frontier}, entry, :node_timeout)}
    end
  end

  def handle_info({:retry_node, node_id, retry_ref}, state) do
    case Map.pop(state.retry_timers, retry_ref) do
      {nil, _retry_timers} ->
        {:noreply, state}

      {entry, retry_timers} when entry.node_id == node_id ->
        {:noreply, start_retry_attempt(%{state | retry_timers: retry_timers}, entry)}
    end
  end

  def handle_info({:wait_human_timeout, node_id, attempt}, state) do
    waiting_entry = Map.get(state.waiting, node_id)

    cond do
      is_nil(waiting_entry) ->
        {:noreply, state}

      waiting_entry.attempt != attempt ->
        {:noreply, state}

      true ->
        case resolve_waiting_node(state, node_id, waiting_entry.default_edge, :timeout) do
          {:error, _reason} -> {:noreply, state}
          {:ok, next_state} -> {:noreply, next_state}
        end
    end
  end

  def handle_info({:token_usage_snapshot, snapshot}, %{result: nil} = state) do
    {:noreply, apply_token_usage_snapshot(state, snapshot)}
  end

  def handle_info({:token_usage_snapshot, _snapshot}, state) do
    {:noreply, warn_late_token_usage(state)}
  end

  def handle_info(:shutdown_after_completion, state) do
    {:stop, :normal, state}
  end

  # Swallow EXIT signals from linked processes (ACP session cleanup, port
  # owners, etc.) so they can't take down the runner. The Task.Supervisor uses
  # async_nolink so handler crashes arrive as {:DOWN, ...} which we handle
  # above; any EXIT that reaches us is a linking quirk we can safely ignore.
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %{result: nil} = state) do
    if interrupted_shutdown?(reason) do
      finalize_interrupted(state)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp via(run_id), do: {:via, Registry, {Tractor.RunRegistry, run_id}}

  # credo:disable-for-next-line Credo.Check.Design.TagTODO
  # TODO(sprint-3): checkpoint
  defp advance(%{result: result} = state) when not is_nil(result), do: state

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp advance(
         %{
           frontier: frontier,
           retry_timers: retry_timers,
           waiting: waiting,
           agenda: agenda
         } = state
       ) do
    cond do
      map_size(frontier) > 0 ->
        state

      map_size(retry_timers) > 0 ->
        state

      map_size(waiting) > 0 and :queue.is_empty(agenda) ->
        state

      map_size(waiting) > 0 and exit_queued?(state.pipeline, agenda) ->
        state

      :queue.is_empty(agenda) ->
        complete_success(state)

      wall_clock_budget_exhausted?(state) ->
        fail_budget(state, "max_wall_clock")

      cost_budget_exhausted?(state) ->
        fail_budget(state, "max_total_cost_usd")

      true ->
        dequeue_and_start(state)
    end
  end

  defp dequeue_and_start(%{agenda: agenda} = state) do
    {{:value, item}, agenda} = :queue.out(agenda)
    start_node(%{state | agenda: agenda}, normalize_agenda_item(item))
  end

  defp start_node(state, %{node_id: node_id, context: context, entry_attrs: entry_attrs}) do
    start_node_with_context(state, node_id, context, entry_attrs)
  end

  defp start_node(%{context: context} = state, node_id) when is_binary(node_id) do
    start_node_with_context(state, node_id, context, %{branch_id: nil, parallel_id: nil})
  end

  defp start_node_with_context(%{pipeline: pipeline} = state, node_id, context, entry_attrs) do
    node = Map.fetch!(pipeline.nodes, node_id)
    state = %{state | context: context}
    gate_id = unsatisfied_goal_gate(state)

    cond do
      node.type == "exit" and not is_nil(gate_id) ->
        fail_goal_gate(state, gate_id, :unsatisfied_before_exit)

      node.type == "parallel" ->
        enter_parallel(state, node)

      true ->
        start_task(state, node, context, entry_attrs)
    end
  end

  defp start_task(state, node, context, entry_attrs) do
    current_iteration = Map.get(state.iterations, node.id, 0)
    max_iterations = Node.max_iterations(node)

    cond do
      total_iteration_budget_exhausted?(state) ->
        fail_budget(state, "max_total_iterations", node.id)

      current_iteration >= max_iterations ->
        fail_iteration_cap(state, node, current_iteration + 1, max_iterations)

      true ->
        do_start_task(state, node, context, entry_attrs, current_iteration + 1, max_iterations)
    end
  end

  defp do_start_task(state, node, context, entry_attrs, iteration, max_iterations) do
    handler = handler_for(node)
    started_at = DateTime.utc_now()

    state = %{
      state
      | iterations: Map.put(state.iterations, node.id, iteration),
        total_iterations_started: state.total_iterations_started + 1,
        retries: Map.put(state.retries, node.id, 0)
    }

    context =
      context
      |> maybe_seed_routed_from(entry_attrs)
      |> prepare_handler_context(state.pipeline, state.store.run_id, node.id, iteration, 1)

    retry_config = Node.retry_config(node, state.pipeline.graph_attrs)

    log_starting(node)

    RunStore.mark_node_running(state.store, node.id, started_at, %{
      "iteration" => iteration,
      "max_iterations" => max_iterations,
      "attempt" => 1,
      "max_attempts" => retry_config.retries + 1
    })

    RunEvents.emit(state.store.run_id, node.id, :iteration_started, %{
      "node_id" => node.id,
      "iteration" => iteration,
      "max_iterations" => max_iterations
    })

    RunEvents.emit(state.store.run_id, node.id, :node_started, %{
      "started_at" => DateTime.to_iso8601(started_at),
      "iteration" => iteration
    })

    launch_attempt(state, node, context, handler, %{
      node_id: node.id,
      branch_id: entry_attrs.branch_id,
      parallel_id: entry_attrs.parallel_id,
      iteration: iteration,
      max_iterations: max_iterations,
      started_at: DateTime.to_iso8601(started_at),
      started_at_ms: System.monotonic_time(:millisecond),
      attempt: 1,
      retry_config: retry_config,
      semantic_started?: true,
      declaring_node_id: Map.get(entry_attrs, :declaring_node_id, node.id),
      origin_node_id: Map.get(entry_attrs, :origin_node_id, node.id),
      recovery_tier: Map.get(entry_attrs, :recovery_tier, :primary),
      routed_from: Map.get(entry_attrs, :routed_from)
    })
  end

  defp fail_iteration_cap(state, node, attempted_iteration, max_iterations) do
    RunEvents.emit(state.store.run_id, node.id, :iteration_cap_reached, %{
      "node_id" => node.id,
      "attempted_iteration" => attempted_iteration,
      "max_iterations" => max_iterations
    })

    fail_node(
      state,
      %{node_id: node.id, started_at_ms: System.monotonic_time(:millisecond)},
      {:max_iterations_exceeded, node.id, max_iterations, attempted_iteration}
    )
  end

  defp start_retry_attempt(state, entry) do
    node = Map.fetch!(state.pipeline.nodes, entry.node_id)
    handler = handler_for(node)

    context =
      prepare_handler_context(
        entry.context,
        state.pipeline,
        state.store.run_id,
        node.id,
        entry.iteration,
        entry.attempt
      )

    RunStore.mark_node_running(state.store, node.id, DateTime.utc_now(), %{
      "iteration" => entry.iteration,
      "max_iterations" => entry.max_iterations,
      "attempt" => entry.attempt,
      "max_attempts" => entry.retry_config.retries + 1,
      "retry_attempts" => entry.attempt - 1
    })

    launch_attempt(state, node, context, handler, entry)
  end

  defp launch_attempt(state, node, context, handler, entry) do
    task =
      Task.Supervisor.async_nolink(Tractor.HandlerTasks, fn ->
        handler.run(node, context, state.store.run_dir)
      end)

    timeout_ms = timeout_for(node, handler)
    timeout_ref = if timeout_ms, do: make_ref()

    timer_ref =
      if timeout_ms, do: Process.send_after(self(), {:node_timeout, timeout_ref}, timeout_ms)

    entry =
      entry
      |> Map.put(:task, task)
      |> Map.put(:context, context)
      |> Map.put(:timeout_ms, timeout_ms)
      |> Map.put(:timeout_ref, timeout_ref)
      |> Map.put(:timer_ref, timer_ref)

    put_in(state.frontier[task.ref], entry)
  end

  defp timeout_for(%Node{timeout: timeout}, _handler) when is_integer(timeout), do: timeout

  defp timeout_for(%Node{type: type}, _handler) when type in ["start", "exit"], do: nil

  defp timeout_for(_node, handler) do
    if function_exported?(handler, :default_timeout_ms, 0), do: handler.default_timeout_ms()
  end

  defp prepare_handler_context(context, pipeline, run_id, node_id, iteration, attempt) do
    context
    |> Map.put("__run_id__", run_id)
    |> Map.put("__node_id__", node_id)
    |> Map.put("__iteration__", iteration)
    |> Map.put("__attempt__", attempt)
    |> Map.put("__runner_pid__", self())
    |> Map.put("__pipeline__", pipeline)
    |> Map.put("#{node_id}.iteration", iteration)
  end

  defp handle_handler_result({:ok, outcome, updates}, entry, state) do
    if entry.branch_id do
      handle_branch_result({:ok, outcome, updates}, entry, state)
    else
      handle_node_success(outcome, updates, entry, state)
    end
  end

  defp handle_handler_result({:error, reason}, %{branch_id: branch_id} = entry, state)
       when not is_nil(branch_id) do
    handle_node_failure(state, entry, reason)
  end

  defp handle_handler_result({:error, reason}, entry, state) do
    handle_node_failure(state, entry, reason)
  end

  defp handle_handler_result({:wait, %{kind: :wait_human, payload: payload}}, entry, state) do
    node = Map.fetch!(state.pipeline.nodes, entry.node_id)

    if node.type == "wait.human" do
      suspend_wait_human(state, entry, payload)
    else
      raise ArgumentError,
            "handler #{inspect(node.type)} returned {:wait, _}; only wait.human may suspend"
    end
  end

  defp handle_handler_result({:wait, payload}, entry, state) do
    node = Map.fetch!(state.pipeline.nodes, entry.node_id)

    raise ArgumentError,
          "invalid wait return from #{inspect(node.type)}: #{inspect(payload)}"
  end

  defp handle_node_failure(state, entry, reason) do
    case Failure.classify(reason) do
      :transient -> maybe_retry_node(state, entry, reason)
      :permanent -> fail_permanent_node(state, entry, reason)
    end
  end

  defp suspend_wait_human(state, entry, payload) do
    waiting_since = DateTime.utc_now()

    timeout_ref =
      maybe_schedule_wait_timeout(payload["wait_timeout_ms"] || payload[:wait_timeout_ms], entry)

    wait_prompt = payload["wait_prompt"] || payload[:wait_prompt]
    outgoing_labels = payload["outgoing_labels"] || payload[:outgoing_labels] || []
    wait_timeout_ms = payload["wait_timeout_ms"] || payload[:wait_timeout_ms]
    default_edge = payload["default_edge"] || payload[:default_edge]

    waiting_entry = %{
      node_id: entry.node_id,
      waiting_since: waiting_since,
      timeout_ref: timeout_ref,
      wait_prompt: wait_prompt,
      outgoing_labels: outgoing_labels,
      wait_timeout_ms: wait_timeout_ms,
      default_edge: default_edge,
      attempt: entry.attempt,
      branch_id: entry.branch_id,
      parallel_id: entry.parallel_id,
      iteration: entry.iteration,
      declaring_node_id: entry.declaring_node_id,
      origin_node_id: entry.origin_node_id,
      recovery_tier: entry.recovery_tier,
      routed_from: entry.routed_from,
      max_iterations: entry.max_iterations,
      started_at: entry.started_at,
      started_at_ms: entry.started_at_ms
    }

    RunStore.mark_node_waiting(state.store, entry.node_id, %{
      "iteration" => entry.iteration,
      "max_iterations" => entry.max_iterations,
      "attempt" => entry.attempt,
      "wait_prompt" => wait_prompt,
      "outgoing_labels" => outgoing_labels,
      "wait_timeout_ms" => wait_timeout_ms,
      "default_edge" => default_edge
    })

    RunEvents.emit(state.store.run_id, entry.node_id, :wait_human_pending, %{
      "wait_prompt" => wait_prompt,
      "outgoing_labels" => outgoing_labels,
      "wait_timeout_ms" => wait_timeout_ms,
      "default_edge" => default_edge
    })

    state =
      state
      |> put_in([Access.key(:waiting), entry.node_id], waiting_entry)
      |> maybe_put_wait_timer(timeout_ref, entry.node_id, entry.attempt)

    Checkpoint.save(state)
    advance(state)
  end

  defp fail_permanent_node(state, %{branch_id: branch_id} = entry, reason)
       when not is_nil(branch_id) do
    handle_branch_result({:error, reason}, entry, state)
  end

  defp fail_permanent_node(state, %{node_id: node_id} = entry, reason) do
    node = Map.fetch!(state.pipeline.nodes, node_id)

    if Node.goal_gate?(node) do
      fail_goal_gate(state, node_id, reason)
    else
      fail_node(state, entry, reason)
    end
  end

  defp maybe_retry_node(state, entry, reason) do
    retries_used = Map.get(state.retries, entry.node_id, entry.attempt - 1)
    max_retries = entry.retry_config.retries

    if retries_used < max_retries do
      next_attempt = entry.attempt + 1
      retry_ref = make_ref()

      backoff_ms =
        backoff_ms(
          state.store.run_id,
          entry.node_id,
          entry.iteration,
          retries_used + 1,
          entry.retry_config
        )

      RunEvents.emit(state.store.run_id, entry.node_id, :retry_attempted, %{
        "node_id" => entry.node_id,
        "iteration" => entry.iteration,
        "attempt" => retries_used + 1,
        "max_attempts" => max_retries + 1,
        "backoff_ms" => backoff_ms,
        "reason" => inspect(reason)
      })

      RunStore.write_node(state.store, entry.node_id, %{
        status:
          iteration_status(
            %{
              "status" => "retrying",
              "reason" => inspect(reason),
              "attempt" => entry.attempt,
              "retry_attempts" => retries_used + 1,
              "max_attempts" => max_retries + 1,
              "backoff_ms" => backoff_ms
            },
            entry
          ),
        iteration: entry.iteration
      })

      Process.send_after(self(), {:retry_node, entry.node_id, retry_ref}, backoff_ms)

      entry =
        entry
        |> Map.drop([:task, :timeout_ref, :timer_ref])
        |> Map.put(:attempt, next_attempt)
        |> Map.put(:original_reason, Map.get(entry, :original_reason, reason))

      %{
        state
        | retries: Map.put(state.retries, entry.node_id, retries_used + 1),
          retry_timers: Map.put(state.retry_timers, retry_ref, entry)
      }
    else
      original_reason = Map.get(entry, :original_reason, reason)
      route_or_fail_exhausted_retry(state, entry, original_reason)
    end
  end

  defp handle_node_success(outcome, updates, entry, state) do
    node_id = entry.node_id
    node = Map.fetch!(state.pipeline.nodes, node_id)
    raw_outcome = normalize_outcome(outcome, updates)
    {decision, routing_outcome, _metadata} = Adjudication.classify(node, raw_outcome, updates)

    if decision == :fail do
      handle_node_failure(state, entry, {:partial_success_not_allowed, node_id})
    else
      log_done(node_id, :ok, entry.started_at_ms)
      write_success(state, node_id, updates, entry)

      RunStore.mark_node_succeeded(
        state.store,
        node_id,
        iteration_status(Map.get(updates, :status, %{}), entry)
        |> put_cost_status(state, node_id)
      )

      RunEvents.emit(state.store.run_id, node_id, :iteration_completed, %{
        "node_id" => node_id,
        "iteration" => entry.iteration,
        "status" => "ok"
      })

      RunEvents.emit(state.store.run_id, node_id, :node_succeeded, %{
        "status" => "ok",
        "iteration" => entry.iteration
      })

      state = %{
        state
        | context:
            state.context
            |> Context.apply_updates(Map.get(updates, :context, %{}))
            |> Context.add_iteration(node_id, iteration_entry(entry, routing_outcome)),
          provider_commands: collect_provider_command(state.provider_commands, updates),
          goal_gates_satisfied:
            maybe_mark_goal_gate_satisfied(state.goal_gates_satisfied, node, routing_outcome),
          completed: MapSet.put(state.completed, node_id)
      }

      maybe_observe_status(state, node, routing_outcome, entry)

      if node.type == "exit" do
        Checkpoint.save(state)
        complete_success(state)
      else
        state = enqueue_next(state, node_id, routing_outcome)
        Checkpoint.save(state)
        advance(state)
      end
    end
  end

  defp fail_node(state, entry, reason) do
    node_id = entry.node_id
    log_done(node_id, {:error, reason}, entry.started_at_ms)
    RunStore.mark_node_failed(state.store, node_id, reason)

    RunEvents.emit(state.store.run_id, node_id, :node_failed, %{
      "reason" => inspect(reason),
      "iteration" => entry[:iteration]
    })

    RunStore.write_node(state.store, node_id, %{
      status:
        iteration_status(%{"status" => "error", "reason" => inspect(reason)}, entry)
        |> put_cost_status(state, node_id)
    })

    RunStore.finalize(state.store, %{
      status: "error",
      provider_commands: state.provider_commands,
      total_cost_usd: Decimal.to_string(state.total_cost_usd)
    })

    RunEvents.emit(state.store.run_id, "_run", :run_failed, %{"reason" => inspect(reason)})
    RunEvents.emit(state.store.run_id, "_run", :run_finalized, %{"status" => "error"})
    Tractor.StatusAgent.stop_run(state.store.run_id)
    complete(state, {:error, reason})
  end

  defp complete_success(%{result: nil} = state) do
    RunStore.finalize(state.store, %{
      status: "ok",
      provider_commands: state.provider_commands,
      total_cost_usd: Decimal.to_string(state.total_cost_usd)
    })

    RunEvents.emit(state.store.run_id, "_run", :run_completed, %{"status" => "ok"})
    RunEvents.emit(state.store.run_id, "_run", :run_finalized, %{"status" => "ok"})
    Tractor.StatusAgent.stop_run(state.store.run_id)

    complete(
      state,
      {:ok, %{run_id: state.store.run_id, run_dir: state.store.run_dir, context: state.context}}
    )
  end

  defp complete_success(state), do: state

  defp fail_goal_gate(state, node_id, reason) do
    RunStore.finalize(state.store, %{
      status: "goal_gate_failed",
      provider_commands: state.provider_commands,
      total_cost_usd: Decimal.to_string(state.total_cost_usd)
    })

    RunEvents.emit(state.store.run_id, "_run", :goal_gate_failed, %{
      "node_id" => node_id,
      "reason" => inspect(reason)
    })

    RunEvents.emit(state.store.run_id, "_run", :run_finalized, %{"status" => "goal_gate_failed"})

    Tractor.StatusAgent.stop_run(state.store.run_id)
    complete(state, {:error, {:goal_gate_failed, node_id}})
  end

  defp finalize_interrupted(state) do
    RunStore.finalize(state.store, %{
      status: "interrupted",
      provider_commands: state.provider_commands,
      total_cost_usd: Decimal.to_string(state.total_cost_usd)
    })

    RunEvents.emit(state.store.run_id, "_run", :run_interrupted, %{"status" => "interrupted"})
    RunEvents.emit(state.store.run_id, "_run", :run_finalized, %{"status" => "interrupted"})
    Tractor.StatusAgent.stop_run(state.store.run_id)
  end

  defp complete(state, result) do
    Enum.each(state.waiters, &GenServer.reply(&1, result))
    Process.send_after(self(), :shutdown_after_completion, 5_000)
    %{state | result: result, waiters: []}
  end

  defp interrupted_shutdown?(:shutdown), do: true
  defp interrupted_shutdown?({:shutdown, _reason}), do: true
  defp interrupted_shutdown?(_reason), do: false

  defp enqueue_next(state, node_id, routing_outcome) do
    case next_edge(state.pipeline, node_id, routing_outcome, state.context) do
      nil ->
        state

      edge ->
        RunEvents.emit(state.store.run_id, node_id, :edge_taken, %{
          "from" => edge.from,
          "to" => edge.to,
          "condition" => edge.condition,
          "iteration" => Map.get(state.iterations, node_id)
        })

        %{state | agenda: :queue.in(edge.to, state.agenda)}
    end
  end

  defp route_or_fail_exhausted_retry(state, %{branch_id: branch_id} = entry, original_reason)
       when not is_nil(branch_id) do
    fail_permanent_node(
      state,
      entry,
      {:retries_exhausted, retry_exhausted_reason(original_reason)}
    )
  end

  defp route_or_fail_exhausted_retry(state, entry, original_reason) do
    declaring_node_id = Map.get(entry, :declaring_node_id, entry.node_id)
    origin_node_id = Map.get(entry, :origin_node_id, declaring_node_id)
    recovery_tier = Map.get(entry, :recovery_tier, :primary)
    declaring_node = Map.fetch!(state.pipeline.nodes, declaring_node_id)

    case Routing.next_target(declaring_node, recovery_tier) do
      {:route, target_id, next_tier} ->
        exhausted_reason = retry_exhausted_reason(original_reason)

        log_done(
          entry.node_id,
          {:error, {:retries_exhausted, exhausted_reason}},
          entry.started_at_ms
        )

        RunStore.mark_node_failed(
          state.store,
          entry.node_id,
          {:retries_exhausted, exhausted_reason}
        )

        RunStore.write_node(state.store, entry.node_id, %{
          status:
            iteration_status(
              %{"status" => "error", "reason" => inspect({:retries_exhausted, exhausted_reason})},
              entry
            )
            |> put_cost_status(state, entry.node_id)
        })

        RunEvents.emit(state.store.run_id, entry.node_id, :node_failed, %{
          "reason" => inspect({:retries_exhausted, exhausted_reason}),
          "iteration" => entry[:iteration]
        })

        RunEvents.emit(state.store.run_id, entry.node_id, :retry_routed, %{
          "from_node" => entry.node_id,
          "to_node" => target_id,
          "reason" => inspect(original_reason),
          "tier" => tier_name(recovery_tier)
        })

        routed_context = Map.put(state.context, "__routed_from__", origin_node_id)

        state = %{
          state
          | context: routed_context,
            iterations: Map.put(state.iterations, target_id, 0),
            agenda:
              :queue.in(
                %{
                  "node_id" => target_id,
                  "context" => routed_context,
                  "entry_attrs" => %{
                    "branch_id" => nil,
                    "parallel_id" => nil,
                    "declaring_node_id" => declaring_node_id,
                    "origin_node_id" => origin_node_id,
                    "recovery_tier" => Atom.to_string(next_tier),
                    "routed_from" => origin_node_id
                  }
                },
                state.agenda
              )
        }

        Checkpoint.save(state)
        advance(state)

      :terminate ->
        if Node.goal_gate?(declaring_node) do
          fail_goal_gate(
            state,
            declaring_node_id,
            {:retries_exhausted, retry_exhausted_reason(original_reason)}
          )
        else
          fail_permanent_node(
            state,
            entry,
            {:retries_exhausted, retry_exhausted_reason(original_reason)}
          )
        end
    end
  end

  defp retry_exhausted_reason({:tool_failed, %{exit_status: exit_status}}),
    do: {:tool_failed, exit_status}

  defp retry_exhausted_reason(reason), do: reason

  defp enter_parallel(state, %Node{id: parallel_id} = node) do
    block = Map.fetch!(state.pipeline.parallel_blocks, parallel_id)
    started_at = DateTime.utc_now()

    log_starting(node)
    RunStore.mark_node_running(state.store, parallel_id, started_at)

    RunEvents.emit(state.store.run_id, parallel_id, :parallel_started, %{
      "branches" => block.branches,
      "fan_in_id" => block.fan_in_id
    })

    case Context.snapshot(state.context) do
      {:ok, parent_context} ->
        parallel_state = %{
          block: block,
          pending: block.branches,
          running: MapSet.new(),
          settled: [],
          parent_context: parent_context,
          started_at_ms: System.monotonic_time(:millisecond)
        }

        state
        |> put_in([Access.key(:parallel_state), parallel_id], parallel_state)
        |> release_parallel_branches(parallel_id)

      {:error, reason} ->
        fail_node(
          state,
          %{node_id: parallel_id, started_at_ms: System.monotonic_time(:millisecond)},
          reason
        )
    end
  end

  defp release_parallel_branches(state, parallel_id) do
    parallel = Map.fetch!(state.parallel_state, parallel_id)
    capacity = parallel.block.max_parallel - MapSet.size(parallel.running)
    {to_start, pending} = Enum.split(parallel.pending, max(capacity, 0))

    parallel = %{parallel | pending: pending}
    state = put_in(state.parallel_state[parallel_id], parallel)

    Enum.reduce(to_start, state, fn node_id, state ->
      start_branch(state, parallel_id, node_id)
    end)
  end

  defp start_branch(state, parallel_id, node_id) do
    parallel = Map.fetch!(state.parallel_state, parallel_id)
    branch_id = "#{parallel_id}:#{node_id}"
    node = Map.fetch!(state.pipeline.nodes, node_id)

    case Context.clone_for_branch(parallel.parent_context, branch_id) do
      {:ok, branch_context} ->
        RunEvents.emit(state.store.run_id, node_id, :branch_started, %{
          "branch_id" => branch_id,
          "parallel_node_id" => parallel_id
        })

        state
        |> put_in([Access.key(:branch_contexts), branch_id], branch_context)
        |> update_in(
          [Access.key(:parallel_state), parallel_id, :running],
          &MapSet.put(&1, branch_id)
        )
        |> start_task(node, branch_context, %{branch_id: branch_id, parallel_id: parallel_id})

      {:error, reason} ->
        settle_branch(state, parallel_id, %{
          "branch_id" => branch_id,
          "entry_node_id" => node_id,
          "status" => "failed",
          "outcome" => inspect(reason),
          "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })
    end
  end

  defp handle_branch_result({:ok, outcome, updates}, entry, state) do
    log_done(entry.node_id, :ok, entry.started_at_ms)
    write_success(state, entry.node_id, updates, entry)

    RunStore.mark_node_succeeded(
      state.store,
      entry.node_id,
      iteration_status(Map.get(updates, :status, %{}), entry)
      |> put_cost_status(state, entry.node_id)
    )

    RunEvents.emit(state.store.run_id, entry.node_id, :node_succeeded, %{
      "status" => "ok",
      "iteration" => entry.iteration
    })

    state =
      update_in(state.branch_contexts[entry.branch_id], fn context ->
        context
        |> Context.apply_updates(Map.get(updates, :context, %{}))
        |> Map.put(entry.node_id, outcome)
      end)

    settle_branch(state, entry.parallel_id, %{
      "branch_id" => entry.branch_id,
      "entry_node_id" => entry.node_id,
      "status" => "success",
      "outcome" => outcome,
      "started_at" => entry.started_at,
      "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp handle_branch_result({:error, reason}, entry, state) do
    # credo:disable-for-next-line Credo.Check.Design.TagTODO
    # TODO(sprint-3): cancel in-flight branches on sibling failure
    log_done(entry.node_id, {:error, reason}, entry.started_at_ms)
    RunStore.mark_node_failed(state.store, entry.node_id, reason)

    RunEvents.emit(state.store.run_id, entry.node_id, :node_failed, %{"reason" => inspect(reason)})

    settle_branch(state, entry.parallel_id, %{
      "branch_id" => entry.branch_id,
      "entry_node_id" => entry.node_id,
      "status" => "failed",
      "outcome" => inspect(reason),
      "started_at" => entry.started_at,
      "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp settle_branch(state, parallel_id, result) do
    RunEvents.emit(state.store.run_id, result["entry_node_id"], :branch_settled, result)

    state =
      state
      |> update_in(
        [Access.key(:parallel_state), parallel_id, :running],
        &MapSet.delete(&1, result["branch_id"])
      )
      |> update_in([Access.key(:parallel_state), parallel_id, :settled], &(&1 ++ [result]))

    parallel = Map.fetch!(state.parallel_state, parallel_id)

    cond do
      parallel.pending != [] ->
        release_parallel_branches(state, parallel_id)

      MapSet.size(parallel.running) == 0 ->
        complete_parallel(state, parallel_id)

      true ->
        state
    end
  end

  defp complete_parallel(state, parallel_id) do
    parallel = Map.fetch!(state.parallel_state, parallel_id)
    results = Enum.sort_by(parallel.settled, & &1["branch_id"])
    status = parallel_status(results)
    finished_at = DateTime.utc_now() |> DateTime.to_iso8601()

    RunStore.mark_node_succeeded(state.store, parallel_id, %{
      "status" => status,
      "finished_at" => finished_at
    })

    RunEvents.emit(state.store.run_id, parallel_id, :parallel_completed, %{
      "status" => status,
      "results" => results
    })

    state = %{
      state
      | context:
          state.context
          |> Map.put("parallel.results.#{parallel_id}", results)
          |> Map.put(parallel_id, status),
        completed: MapSet.put(state.completed, parallel_id),
        agenda: :queue.in(parallel.block.fan_in_id, state.agenda)
    }

    Checkpoint.save(state)
    advance(state)
  end

  defp parallel_status(results) do
    successes = Enum.count(results, &(&1["status"] == "success"))

    cond do
      successes == length(results) -> "success"
      successes > 0 -> "partial_success"
      true -> "failed"
    end
  end

  defp write_success(state, node_id, updates, entry) do
    RunStore.write_node(state.store, node_id, %{
      prompt: Map.get(updates, :prompt),
      response: Map.get(updates, :response),
      status:
        iteration_status(Map.get(updates, :status, %{"status" => "ok"}), entry)
        |> put_cost_status(state, node_id),
      iteration: entry[:iteration],
      max_iterations: entry[:max_iterations]
    })
  end

  defp iteration_status(status, entry) when is_map(status) do
    status
    |> maybe_put_status_meta("iteration", entry[:iteration])
    |> maybe_put_status_meta("max_iterations", entry[:max_iterations])
    |> maybe_put_status_meta("started_at", entry[:started_at])
    |> maybe_put_finished_at()
  end

  defp maybe_put_status_meta(status, _key, nil), do: status
  defp maybe_put_status_meta(status, key, _value) when is_map_key(status, key), do: status
  defp maybe_put_status_meta(status, key, value), do: Map.put(status, key, value)

  defp maybe_put_finished_at(status) do
    case Map.get(status, "status") do
      value when value in ["running", "retrying", "waiting", "pending"] ->
        status

      _other ->
        maybe_put_status_meta(status, "finished_at", DateTime.utc_now() |> DateTime.to_iso8601())
    end
  end

  defp put_cost_status(status, state, node_id) do
    status
    |> Map.put(
      "total_cost_usd",
      state.node_costs_usd |> Map.get(node_id, Decimal.new("0")) |> Decimal.to_string()
    )
    |> Map.put("run_total_cost_usd", Decimal.to_string(state.total_cost_usd))
  end

  defp iteration_entry(entry, routing_outcome) do
    %{
      seq: entry[:iteration],
      output: routing_outcome.output,
      status: routing_outcome.status,
      verdict: routing_outcome.verdict,
      critique: routing_outcome.critique,
      routed_from: entry[:routed_from],
      started_at: entry[:started_at],
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp collect_provider_command(commands, %{provider_command: provider_command}) do
    [provider_command | commands]
  end

  defp collect_provider_command(commands, _updates), do: commands

  defp maybe_start_status_agent(state) do
    case Map.get(state.pipeline.graph_attrs, "status_agent", "off") do
      "off" -> :ok
      provider -> Tractor.StatusAgent.start_run(state.store.run_id, state.store.run_dir, provider)
    end
  end

  defp maybe_observe_status(_state, %Node{type: type}, _routing_outcome, _entry)
       when type in ["start", "exit"] do
    :ok
  end

  defp maybe_observe_status(_state, _node, _routing_outcome, %{branch_id: branch_id})
       when not is_nil(branch_id) do
    :ok
  end

  defp maybe_observe_status(state, _node, routing_outcome, entry) do
    Tractor.StatusAgent.observe(state.store.run_id, %{
      node_id: entry.node_id,
      iteration: entry.iteration,
      output_digest: output_digest(routing_outcome.output),
      verdict: routing_outcome.verdict,
      critique: routing_outcome.critique,
      per_node_iteration_counts: state.iterations,
      total_iterations: state.total_iterations_started,
      total_cost_usd: Decimal.to_string(state.total_cost_usd)
    })
  end

  defp apply_token_usage_snapshot(
         state,
         %{usage: usage, provider: provider, model: model} = snapshot
       ) do
    snapshot_key = {
      snapshot.node_id,
      snapshot.iteration,
      snapshot.attempt
    }

    last_seen = Map.get(state.last_seen_usage, snapshot_key)
    delta = usage_delta(last_seen, usage)

    state = %{state | last_seen_usage: Map.put(state.last_seen_usage, snapshot_key, usage)}

    case Tractor.Cost.estimate(provider, model, delta) do
      nil ->
        warn_unknown_pricing(state, provider, model)

      cost ->
        node_total =
          Decimal.add(Map.get(state.node_costs_usd, snapshot.node_id, Decimal.new("0")), cost)

        %{
          state
          | total_cost_usd: Decimal.add(state.total_cost_usd, cost),
            node_costs_usd: Map.put(state.node_costs_usd, snapshot.node_id, node_total)
        }
    end
  end

  defp warn_unknown_pricing(state, provider, model) do
    pair = {provider || "", model || ""}

    if MapSet.member?(state.warned_unknown_pricing, pair) do
      state
    else
      RunEvents.emit(state.store.run_id, "_run", :cost_unknown, %{
        "provider" => provider,
        "model" => model
      })

      %{state | warned_unknown_pricing: MapSet.put(state.warned_unknown_pricing, pair)}
    end
  end

  defp warn_late_token_usage(%{late_token_usage_warned?: true} = state), do: state

  defp warn_late_token_usage(state) do
    RunEvents.emit(state.store.run_id, "_run", :late_token_usage, %{})
    %{state | late_token_usage_warned?: true}
  end

  defp usage_delta(nil, usage), do: normalize_usage_counts(usage)

  defp usage_delta(previous, usage) do
    current = normalize_usage_counts(usage)
    prior = normalize_usage_counts(previous)

    %{
      input_tokens: max(current.input_tokens - prior.input_tokens, 0),
      output_tokens: max(current.output_tokens - prior.output_tokens, 0)
    }
  end

  defp normalize_usage_counts(usage) do
    %{
      input_tokens: usage_count(usage, :input_tokens),
      output_tokens: usage_count(usage, :output_tokens)
    }
  end

  defp usage_count(usage, key) do
    usage
    |> Map.get(key, Map.get(usage, to_string(key), 0))
    |> case do
      value when is_integer(value) -> value
      _other -> 0
    end
  end

  defp output_digest(output) when is_binary(output) and byte_size(output) > 2_048 do
    binary_part(output, 0, 2_048) <> "\n[truncated]"
  end

  defp output_digest(output) when is_binary(output), do: output
  defp output_digest(output), do: inspect(output)

  defp cancel_timeout(%{timer_ref: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_timeout(_entry), do: :ok

  defp maybe_schedule_wait_timeout(nil, _entry), do: nil

  defp maybe_schedule_wait_timeout(wait_timeout_ms, entry) when is_integer(wait_timeout_ms) do
    Process.send_after(
      self(),
      {:wait_human_timeout, entry.node_id, entry.attempt},
      wait_timeout_ms
    )
  end

  defp maybe_put_wait_timer(state, nil, _node_id, _attempt), do: state

  defp maybe_put_wait_timer(state, timeout_ref, node_id, attempt) do
    put_in(state.wait_timers[timeout_ref], %{node_id: node_id, attempt: attempt})
  end

  defp resolve_waiting_node(state, node_id, label, source) do
    case waiting_entry(state, node_id) do
      nil ->
        {:error, :wait_not_pending}

      %{default_edge: nil} when source == :timeout ->
        {:error, :missing_default_edge}

      %{outgoing_labels: labels} = entry ->
        if source == :operator and label not in labels do
          {:error, {:invalid_wait_label, labels}}
        else
          state = cancel_wait_timeout(state, entry.timeout_ref)

          RunEvents.emit(state.store.run_id, node_id, :wait_human_resolved, %{
            "label" => label,
            "source" => Atom.to_string(source)
          })

          state =
            update_in(state.waiting, &Map.delete(&1, node_id))

          handler_result = synthesized_wait_resolution(label, source)

          {:ok, handle_handler_result(handler_result, entry, state)}
        end
    end
  end

  defp waiting_entry(state, node_id) do
    case Map.get(state.waiting, node_id) do
      nil -> waiting_entry_from_checkpoint(state, node_id)
      entry -> entry
    end
  end

  defp waiting_entry_from_checkpoint(state, node_id) do
    with {:ok, checkpoint} <- Checkpoint.read(state.store.run_dir),
         entry when is_map(entry) <- get_in(checkpoint, ["waiting", node_id]) do
      entry
      |> normalize_waiting_entry()
      |> Map.put(:started_at_ms, resumed_started_at_ms(entry["started_at"]))
    else
      _other -> nil
    end
  end

  defp cancel_wait_timeout(state, nil), do: state

  defp cancel_wait_timeout(state, timeout_ref) do
    Process.cancel_timer(timeout_ref)
    %{state | wait_timers: Map.delete(state.wait_timers, timeout_ref)}
  end

  defp synthesized_wait_resolution(label, source) do
    source_value = Atom.to_string(source)

    {:ok,
     %{
       "resolved_label" => label,
       "resolution_source" => source_value
     },
     %{
       status: %{
         "status" => "ok",
         "resolved_label" => label,
         "resolution_source" => source_value
       },
       preferred_label: label,
       context: %{
         "resolved_label" => label,
         "resolution_source" => source_value
       }
     }}
  end

  defp pop_frontier_by_timeout_ref(frontier, timeout_ref) do
    case Enum.find(frontier, fn {_task_ref, entry} -> entry[:timeout_ref] == timeout_ref end) do
      nil -> {nil, frontier}
      {task_ref, entry} -> {{task_ref, entry}, Map.delete(frontier, task_ref)}
    end
  end

  defp backoff_ms(run_id, node_id, iteration, attempt, retry_config) do
    delay =
      case retry_config.retry_backoff do
        "linear" -> retry_config.retry_base_ms * attempt
        "constant" -> retry_config.retry_base_ms
        _exp -> retry_config.retry_base_ms * Integer.pow(2, attempt - 1)
      end
      |> min(retry_config.retry_cap_ms)

    if retry_config.retry_jitter do
      seeded_uniform(run_id, node_id, iteration, attempt, delay)
    else
      delay
    end
  end

  defp seeded_uniform(_run_id, _node_id, _iteration, _attempt, delay) when delay <= 1, do: delay

  defp seeded_uniform(run_id, node_id, iteration, attempt, delay) do
    <<a::32, b::32, c::32>> =
      :crypto.hash(:sha256, "#{run_id}:#{node_id}:#{iteration}:#{attempt}")
      |> binary_part(0, 12)

    seed_state = :rand.seed_s(:exsplus, {a, b, c})
    {value, _seed_state} = :rand.uniform_s(delay, seed_state)
    value
  end

  defp total_iteration_budget_exhausted?(state) do
    case max_total_iterations(state.pipeline) do
      nil -> false
      limit -> state.total_iterations_started >= limit
    end
  end

  defp wall_clock_budget_exhausted?(state) do
    case max_wall_clock_ms(state.pipeline) do
      nil -> false
      limit -> System.monotonic_time(:millisecond) - state.started_at_ms >= limit
    end
  end

  defp cost_budget_exhausted?(state) do
    match?({:budget_exhausted, _, _}, Budget.check_cost(state.pipeline, state.total_cost_usd))
  end

  defp fail_budget(state, budget, node_id \\ nil)

  defp fail_budget(state, "max_total_iterations", node_id) do
    limit = max_total_iterations(state.pipeline)
    observed = state.total_iterations_started

    RunEvents.emit(state.store.run_id, "_run", :budget_exhausted, %{
      "budget" => "max_total_iterations",
      "limit" => limit,
      "observed" => observed,
      "node_id" => node_id
    })

    fail_node(
      %{state | budget_exhausted?: true},
      %{node_id: node_id || "_run", started_at_ms: System.monotonic_time(:millisecond)},
      {:budget_exhausted, :max_total_iterations, observed, limit}
    )
  end

  defp fail_budget(state, "max_wall_clock", node_id) do
    limit = max_wall_clock_ms(state.pipeline)
    observed = System.monotonic_time(:millisecond) - state.started_at_ms

    RunEvents.emit(state.store.run_id, "_run", :budget_exhausted, %{
      "budget" => "max_wall_clock",
      "limit" => limit,
      "observed" => observed,
      "node_id" => node_id
    })

    fail_node(
      %{state | budget_exhausted?: true},
      %{node_id: node_id || "_run", started_at_ms: System.monotonic_time(:millisecond)},
      {:budget_exhausted, :max_wall_clock, observed, limit}
    )
  end

  defp fail_budget(state, "max_total_cost_usd", node_id) do
    {:budget_exhausted, observed, limit} = Budget.check_cost(state.pipeline, state.total_cost_usd)
    observed_text = Decimal.to_string(observed)
    limit_text = Decimal.to_string(limit)

    RunEvents.emit(state.store.run_id, "_run", :budget_exhausted, %{
      "budget" => "max_total_cost_usd",
      "limit" => limit_text,
      "observed" => observed_text,
      "node_id" => node_id
    })

    fail_node(
      %{state | budget_exhausted?: true},
      %{node_id: node_id || "_run", started_at_ms: System.monotonic_time(:millisecond)},
      {:budget_exhausted, :max_total_cost_usd, observed_text, limit_text}
    )
  end

  defp max_total_iterations(%Pipeline{graph_attrs: attrs}) do
    case Integer.parse(Map.get(attrs, "max_total_iterations", "")) do
      {value, ""} -> value
      _other -> nil
    end
  end

  defp max_wall_clock_ms(%Pipeline{graph_attrs: attrs}) do
    with value when is_binary(value) <- attrs["max_wall_clock"],
         {:ok, ms} <- Duration.parse(value) do
      ms
    else
      _other -> nil
    end
  end

  defp checkpoint_total_iterations_started(checkpoint) do
    cond do
      is_integer(get_in(checkpoint, ["budgets", "total_iterations_started"])) ->
        checkpoint["budgets"]["total_iterations_started"]

      is_integer(get_in(checkpoint, ["budgets", "total_iterations"])) ->
        checkpoint["budgets"]["total_iterations"]

      true ->
        checkpoint["iteration_counts"]
        |> atomize_count_map()
        |> Map.values()
        |> Enum.sum()
    end
  end

  defp checkpoint_total_cost_usd(checkpoint) do
    case get_in(checkpoint, ["budgets", "total_cost_usd"]) do
      value when is_binary(value) ->
        case Decimal.parse(value) do
          {decimal, ""} -> decimal
          _other -> Decimal.new("0")
        end

      _other ->
        Decimal.new("0")
    end
  end

  defp resumed_started_at_ms(started_at_wall_iso) do
    elapsed =
      case DateTime.from_iso8601(started_at_wall_iso) do
        {:ok, started_at_wall, _offset} ->
          DateTime.diff(DateTime.utc_now(), started_at_wall, :millisecond) |> max(0)

        _other ->
          0
      end

    System.monotonic_time(:millisecond) - elapsed
  end

  defp restore_waiting_state(state, serialized_waiting) do
    Enum.reduce(serialized_waiting, state, fn {node_id, entry}, state ->
      waiting_entry =
        entry
        |> normalize_waiting_entry()
        |> Map.put(:attempt, entry["attempt"] + 1)
        |> Map.put(:started_at_ms, resumed_started_at_ms(entry["started_at"]))

      timeout_ref =
        schedule_restored_wait_timeout(waiting_entry.wait_timeout_ms, waiting_entry)

      waiting_entry = Map.put(waiting_entry, :timeout_ref, timeout_ref)

      RunEvents.emit(state.store.run_id, node_id, :wait_human_pending, %{
        "wait_prompt" => waiting_entry.wait_prompt,
        "outgoing_labels" => waiting_entry.outgoing_labels,
        "wait_timeout_ms" => waiting_entry.wait_timeout_ms,
        "default_edge" => waiting_entry.default_edge
      })

      state
      |> put_in([Access.key(:waiting), node_id], waiting_entry)
      |> maybe_put_wait_timer(timeout_ref, node_id, waiting_entry.attempt)
    end)
  end

  defp schedule_restored_wait_timeout(nil, _entry), do: nil

  defp schedule_restored_wait_timeout(wait_timeout_ms, entry) do
    remaining =
      wait_timeout_ms -
        max(DateTime.diff(DateTime.utc_now(), entry.waiting_since, :millisecond), 0)

    Process.send_after(
      self(),
      {:wait_human_timeout, entry.node_id, entry.attempt},
      max(remaining, 0)
    )
  end

  defp normalize_waiting_entry(entry) do
    %{
      node_id: entry["node_id"],
      waiting_since: parse_iso_datetime!(entry["waiting_since"]),
      timeout_ref: nil,
      wait_prompt: entry["wait_prompt"],
      outgoing_labels: entry["outgoing_labels"] || [],
      wait_timeout_ms: entry["wait_timeout_ms"],
      default_edge: entry["default_edge"],
      attempt: entry["attempt"],
      branch_id: entry["branch_id"],
      parallel_id: entry["parallel_id"],
      iteration: entry["iteration"],
      declaring_node_id: entry["declaring_node_id"],
      origin_node_id: entry["origin_node_id"],
      recovery_tier: normalize_recovery_tier(entry["recovery_tier"]),
      routed_from: entry["routed_from"],
      max_iterations: entry["max_iterations"],
      started_at: entry["started_at"],
      started_at_ms: 0
    }
  end

  defp checkpoint_parallel_state(pipeline, serialized_parallel_state) do
    Map.new(serialized_parallel_state, fn {parallel_id, entry} ->
      block = Map.fetch!(pipeline.parallel_blocks, parallel_id)

      {parallel_id,
       %{
         block: block,
         pending: entry["pending"] || [],
         running: MapSet.new(entry["running"] || []),
         settled: entry["settled"] || [],
         parent_context: entry["parent_context"] || %{},
         started_at_ms: entry["started_at_ms"] || System.monotonic_time(:millisecond)
       }}
    end)
  end

  defp parse_iso_datetime!(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  defp log_starting(%Node{id: id, type: type, llm_provider: provider}) do
    suffix = if provider, do: "/#{provider}", else: ""
    IO.puts(:stderr, "#{id} [#{type}#{suffix}]: starting")
  end

  defp log_done(node_id, :ok, start_ms) do
    elapsed = System.monotonic_time(:millisecond) - start_ms
    IO.puts(:stderr, "#{node_id}: ok (#{format_ms(elapsed)})")
  end

  defp log_done(node_id, {:error, reason}, start_ms) do
    elapsed = System.monotonic_time(:millisecond) - start_ms
    IO.puts(:stderr, "#{node_id}: error (#{format_ms(elapsed)}): #{inspect(reason)}")
  end

  defp format_ms(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_ms(ms), do: :io_lib.format("~.1fs", [ms / 1_000]) |> IO.iodata_to_binary()

  defp handler_for(%Node{type: "start"}), do: Tractor.Handler.Start
  defp handler_for(%Node{type: "exit"}), do: Tractor.Handler.Exit
  defp handler_for(%Node{type: "codergen"}), do: Tractor.Handler.Codergen
  defp handler_for(%Node{type: "judge"}), do: Tractor.Handler.Judge
  defp handler_for(%Node{type: "conditional"}), do: Tractor.Handler.Conditional
  defp handler_for(%Node{type: "tool"}), do: Tractor.Handler.Tool
  defp handler_for(%Node{type: "wait.human"}), do: Tractor.Handler.WaitHuman
  defp handler_for(%Node{type: "parallel.fan_in"}), do: Tractor.Handler.FanIn

  defp next_edge(%Pipeline{edges: edges}, node_id, routing_outcome, context) do
    edges
    |> Enum.filter(&(&1.from == node_id))
    |> EdgeSelector.choose(routing_outcome, context)
  end

  defp normalize_outcome(output, updates) do
    status = updates |> Map.get(:status, %{}) |> Map.get("status", "ok") |> normalize_status()

    verdict = Map.get(updates, :verdict)
    preferred_label = Map.get(updates, :preferred_label) || verdict_label(verdict)

    %{
      output: output || "",
      status: status,
      preferred_label: preferred_label,
      suggested_next_ids: Map.get(updates, :suggested_next_ids, []),
      verdict: verdict,
      critique: Map.get(updates, :critique),
      context_updates: Map.get(updates, :context, %{}),
      metadata: Map.get(updates, :metadata, %{})
    }
  end

  defp normalize_status(status) when status in ["ok", :ok, "success", :success], do: :success
  defp normalize_status(status) when status in ["error", :error, "failed", :failed], do: :fail

  defp normalize_status(status) when status in ["partial_success", :partial_success],
    do: :partial_success

  defp normalize_status(status) when status in ["retry", :retry], do: :retry
  defp normalize_status(_status), do: :success

  defp verdict_label(nil), do: nil
  defp verdict_label(verdict) when is_atom(verdict), do: Atom.to_string(verdict)
  defp verdict_label(verdict), do: to_string(verdict)

  defp start_node_id(%Pipeline{nodes: nodes}) do
    nodes
    |> Enum.find(fn {_id, %Node{type: type}} -> type == "start" end)
    |> elem(0)
  end

  defp queue_from_list(list) when is_list(list) do
    Enum.reduce(list, :queue.new(), &:queue.in/2)
  end

  defp exit_queued?(pipeline, agenda) do
    case :queue.peek(agenda) do
      {:value, item} ->
        node_id =
          case normalize_agenda_item(item) do
            %{node_id: queued_node_id} -> queued_node_id
            queued_node_id -> queued_node_id
          end

        match?(%Node{type: "exit"}, Map.get(pipeline.nodes, node_id))

      :empty ->
        false
    end
  end

  defp atomize_count_map(map) do
    Map.new(map, fn {key, value} -> {key, value} end)
  end

  defp normalize_agenda_item(%{"node_id" => node_id} = item) do
    %{
      node_id: node_id,
      context: Map.get(item, "context", %{}),
      entry_attrs: normalize_entry_attrs(Map.get(item, "entry_attrs", %{}))
    }
  end

  defp normalize_agenda_item(%{node_id: _node_id} = item) do
    %{item | entry_attrs: normalize_entry_attrs(Map.get(item, :entry_attrs, %{}))}
  end

  defp normalize_agenda_item(node_id), do: node_id

  defp normalize_entry_attrs(attrs) do
    Enum.into(attrs, %{}, fn
      {"recovery_tier", value} -> {:recovery_tier, normalize_recovery_tier(value)}
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      pair -> pair
    end)
  end

  defp normalize_recovery_tier(value) when value in [:primary, :fallback, :exhausted], do: value
  defp normalize_recovery_tier("primary"), do: :primary
  defp normalize_recovery_tier("fallback"), do: :fallback
  defp normalize_recovery_tier("exhausted"), do: :exhausted
  defp normalize_recovery_tier(_value), do: :primary

  defp maybe_seed_routed_from(context, %{routed_from: routed_from}) when is_binary(routed_from) do
    Map.put(context, "__routed_from__", routed_from)
  end

  defp maybe_seed_routed_from(context, _entry_attrs), do: context

  defp tier_name(:primary), do: :primary
  defp tier_name(:fallback), do: :fallback

  defp maybe_mark_goal_gate_satisfied(goal_gates_satisfied, node, routing_outcome) do
    if Node.goal_gate?(node) and routing_outcome.status in [:success, :partial_success] do
      MapSet.put(goal_gates_satisfied, node.id)
    else
      goal_gates_satisfied
    end
  end

  defp unsatisfied_goal_gate(%{pipeline: %Pipeline{nodes: nodes}, goal_gates_satisfied: satisfied}) do
    nodes
    |> Enum.filter(fn {_node_id, node} -> Node.goal_gate?(node) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.find(&(not MapSet.member?(satisfied, &1)))
  end
end
