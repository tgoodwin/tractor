defmodule Tractor.Runner do
  @moduledoc """
  GenServer that executes a normalized pipeline.
  """

  use GenServer

  alias Tractor.{Context, Edge, Node, Pipeline, RunEvents, RunStore}

  defstruct pipeline: nil,
            store: nil,
            frontier: %{},
            agenda: :queue.new(),
            context: %{},
            branch_contexts: %{},
            parallel_state: %{},
            completed: MapSet.new(),
            waiters: [],
            result: nil,
            provider_commands: []

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

  @impl true
  def init({%Pipeline{} = pipeline, _opts, %RunStore{} = store}) do
    Enum.each(Map.keys(pipeline.nodes), &RunStore.mark_node_pending(store, &1))
    RunEvents.emit(store.run_id, "_run", :run_started, %{"run_id" => store.run_id})

    state = %__MODULE__{
      pipeline: pipeline,
      store: store,
      agenda: :queue.in(start_node_id(pipeline), :queue.new())
    }

    {:ok, state, {:continue, :advance}}
  end

  @impl true
  def handle_call(:await, from, %{result: nil} = state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:await, _from, %{result: result} = state) do
    {:reply, result, state}
  end

  @impl true
  def handle_continue(:advance, state) do
    {:noreply, advance(state)}
  end

  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.frontier, ref) do
    Process.demonitor(ref, [:flush])
    {entry, frontier} = Map.pop(state.frontier, ref)
    {:noreply, handle_handler_result(result, entry, %{state | frontier: frontier})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if Map.has_key?(state.frontier, ref) do
      {entry, frontier} = Map.pop(state.frontier, ref)
      {:noreply, fail_node(%{state | frontier: frontier}, entry, {:handler_crash, reason})}
    else
      {:noreply, state}
    end
  end

  def handle_info(:shutdown_after_completion, state) do
    {:stop, :normal, state}
  end

  defp via(run_id), do: {:via, Registry, {Tractor.RunRegistry, run_id}}

  # credo:disable-for-next-line Credo.Check.Design.TagTODO
  # TODO(sprint-3): checkpoint
  defp advance(%{result: result} = state) when not is_nil(result), do: state

  defp advance(%{frontier: frontier, agenda: agenda} = state) do
    cond do
      map_size(frontier) > 0 ->
        state

      :queue.is_empty(agenda) ->
        complete_success(state)

      true ->
        dequeue_and_start(state)
    end
  end

  defp dequeue_and_start(%{agenda: agenda} = state) do
    {{:value, node_id}, agenda} = :queue.out(agenda)
    start_node(%{state | agenda: agenda}, node_id)
  end

  defp start_node(%{pipeline: pipeline} = state, node_id) do
    node = Map.fetch!(pipeline.nodes, node_id)

    if node.type == "parallel" do
      enter_parallel(state, node)
    else
      start_task(state, node, state.context, %{branch_id: nil, parallel_id: nil})
    end
  end

  defp start_task(state, node, context, entry_attrs) do
    handler = handler_for(node)
    started_at = DateTime.utc_now()

    log_starting(node)
    RunStore.mark_node_running(state.store, node.id, started_at)
    RunEvents.emit(state.store.run_id, node.id, :node_started, %{"started_at" => DateTime.to_iso8601(started_at)})

    task =
      Task.Supervisor.async_nolink(Tractor.HandlerTasks, fn ->
        handler.run(node, context, state.store.run_dir)
      end)

    put_in(state.frontier[task.ref], %{
      node_id: node.id,
      branch_id: entry_attrs.branch_id,
      parallel_id: entry_attrs.parallel_id,
      started_at: DateTime.to_iso8601(started_at),
      started_at_ms: System.monotonic_time(:millisecond)
    })
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
    handle_branch_result({:error, reason}, entry, state)
  end

  defp handle_handler_result({:error, reason}, entry, state) do
    fail_node(state, entry, reason)
  end

  defp handle_node_success(outcome, updates, entry, state) do
    node_id = entry.node_id
    node = Map.fetch!(state.pipeline.nodes, node_id)
    log_done(node_id, :ok, entry.started_at_ms)
    write_success(state.store, node_id, updates)
    RunStore.mark_node_succeeded(state.store, node_id, Map.get(updates, :status, %{}))
    RunEvents.emit(state.store.run_id, node_id, :node_succeeded, %{"status" => "ok"})

    state = %{
      state
      | context:
          state.context
          |> Context.apply_updates(Map.get(updates, :context, %{}))
          |> Map.put(node_id, outcome),
        provider_commands: collect_provider_command(state.provider_commands, updates),
        completed: MapSet.put(state.completed, node_id)
    }

    if node.type == "exit" do
      complete_success(state)
    else
      state
      |> enqueue_next(node_id)
      |> advance()
    end
  end

  defp fail_node(state, entry, reason) do
    node_id = entry.node_id
    log_done(node_id, {:error, reason}, entry.started_at_ms)
    RunStore.mark_node_failed(state.store, node_id, reason)
    RunEvents.emit(state.store.run_id, node_id, :node_failed, %{"reason" => inspect(reason)})

    RunStore.write_node(state.store, node_id, %{
      status: %{"status" => "error", "reason" => inspect(reason)}
    })

    RunStore.finalize(state.store, %{
      status: "error",
      provider_commands: state.provider_commands
    })

    RunEvents.emit(state.store.run_id, "_run", :run_failed, %{"reason" => inspect(reason)})
    complete(state, {:error, reason})
  end

  defp complete_success(%{result: nil} = state) do
    RunStore.finalize(state.store, %{
      status: "ok",
      provider_commands: state.provider_commands
    })

    RunEvents.emit(state.store.run_id, "_run", :run_completed, %{"status" => "ok"})

    complete(
      state,
      {:ok, %{run_id: state.store.run_id, run_dir: state.store.run_dir, context: state.context}}
    )
  end

  defp complete_success(state), do: state

  defp complete(state, result) do
    Enum.each(state.waiters, &GenServer.reply(&1, result))
    Process.send_after(self(), :shutdown_after_completion, 5_000)
    %{state | result: result, waiters: []}
  end

  defp enqueue_next(state, node_id) do
    %{state | agenda: :queue.in(next_node_id(state.pipeline, node_id), state.agenda)}
  end

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
        fail_node(state, %{node_id: parallel_id, started_at_ms: System.monotonic_time(:millisecond)}, reason)
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
        |> update_in([Access.key(:parallel_state), parallel_id, :running], &MapSet.put(&1, branch_id))
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
    write_success(state.store, entry.node_id, updates)
    RunStore.mark_node_succeeded(state.store, entry.node_id, Map.get(updates, :status, %{}))
    RunEvents.emit(state.store.run_id, entry.node_id, :node_succeeded, %{"status" => "ok"})

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
      |> update_in([Access.key(:parallel_state), parallel_id, :running], &MapSet.delete(&1, result["branch_id"]))
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

    RunStore.mark_node_succeeded(state.store, parallel_id, %{"status" => status, "finished_at" => finished_at})

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

  defp write_success(store, node_id, updates) do
    RunStore.write_node(store, node_id, %{
      prompt: Map.get(updates, :prompt),
      response: Map.get(updates, :response),
      status: Map.get(updates, :status, %{"status" => "ok"})
    })
  end

  defp collect_provider_command(commands, %{provider_command: provider_command}) do
    [provider_command | commands]
  end

  defp collect_provider_command(commands, _updates), do: commands

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
  defp handler_for(%Node{type: "parallel.fan_in"}), do: Tractor.Handler.FanIn

  defp next_node_id(%Pipeline{edges: edges}, node_id) do
    edges
    |> Enum.filter(&(&1.from == node_id))
    |> Enum.sort_by(fn %Edge{weight: weight, to: to} -> {-weight, to} end)
    |> List.first()
    |> Map.fetch!(:to)
  end

  defp start_node_id(%Pipeline{nodes: nodes}) do
    nodes
    |> Enum.find(fn {_id, %Node{type: type}} -> type == "start" end)
    |> elem(0)
  end
end
