defmodule Tractor.Runner do
  @moduledoc """
  GenServer that executes a normalized pipeline.
  """

  use GenServer

  alias Tractor.{Edge, Node, Pipeline, RunStore}

  defstruct pipeline: nil,
            store: nil,
            current_node_id: nil,
            context: %{},
            waiters: [],
            result: nil,
            task_ref: nil,
            task_node_id: nil,
            task_started_at_ms: nil,
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
    state = %__MODULE__{
      pipeline: pipeline,
      store: store,
      current_node_id: start_node_id(pipeline)
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
  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_handler_result(result, %{state | task_ref: nil})}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{task_ref: ref, task_node_id: node_id} = state
      ) do
    {:noreply, fail_node(%{state | task_ref: nil}, node_id, {:handler_crash, reason})}
  end

  def handle_info(:shutdown_after_completion, state) do
    {:stop, :normal, state}
  end

  defp via(run_id), do: {:via, Registry, {Tractor.RunRegistry, run_id}}

  # credo:disable-for-next-line Credo.Check.Design.TagTODO
  # TODO(sprint-2): checkpoint
  defp advance(%{current_node_id: node_id, pipeline: pipeline} = state) do
    node = Map.fetch!(pipeline.nodes, node_id)
    handler = handler_for(node)
    log_starting(node)

    task =
      Task.Supervisor.async_nolink(Tractor.HandlerTasks, fn ->
        handler.run(node, state.context, state.store.run_dir)
      end)

    %{
      state
      | task_ref: task.ref,
        task_node_id: node_id,
        task_started_at_ms: System.monotonic_time(:millisecond)
    }
  end

  defp handle_handler_result({:ok, outcome, updates}, %{task_node_id: node_id} = state) do
    node = Map.fetch!(state.pipeline.nodes, node_id)
    log_done(node_id, :ok, state.task_started_at_ms)
    write_success(state.store, node_id, updates)

    state = %{
      state
      | context: Map.put(state.context, node_id, outcome),
        provider_commands: collect_provider_command(state.provider_commands, updates),
        task_started_at_ms: nil
    }

    if node.type == "exit" do
      complete_success(state)
    else
      %{state | current_node_id: next_node_id(state.pipeline, node_id), task_node_id: nil}
      |> advance()
    end
  end

  defp handle_handler_result({:error, reason}, %{task_node_id: node_id} = state) do
    fail_node(state, node_id, reason)
  end

  defp fail_node(state, node_id, reason) do
    log_done(node_id, {:error, reason}, state.task_started_at_ms)

    RunStore.write_node(state.store, node_id, %{
      status: %{"status" => "error", "reason" => inspect(reason)}
    })

    RunStore.finalize(state.store, %{
      status: "error",
      provider_commands: state.provider_commands
    })

    complete(state, {:error, reason})
  end

  defp complete_success(state) do
    RunStore.finalize(state.store, %{
      status: "ok",
      provider_commands: state.provider_commands
    })

    complete(
      state,
      {:ok, %{run_id: state.store.run_id, run_dir: state.store.run_dir, context: state.context}}
    )
  end

  defp complete(state, result) do
    Enum.each(state.waiters, &GenServer.reply(&1, result))
    Process.send_after(self(), :shutdown_after_completion, 5_000)
    %{state | result: result, waiters: []}
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

  defp log_done(node_id, outcome, nil),
    do: log_done(node_id, outcome, System.monotonic_time(:millisecond))

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
