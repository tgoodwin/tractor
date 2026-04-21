defmodule Tractor.StatusAgent do
  @moduledoc """
  Per-run async observer that summarizes completed node outputs.
  """

  use GenServer

  alias Tractor.RunEvents

  @providers %{
    "claude" => Tractor.Agent.Claude,
    "codex" => Tractor.Agent.Codex,
    "gemini" => Tractor.Agent.Gemini
  }

  @max_queue 20
  @observation_timeout 30_000
  @stop_grace 5_000

  defstruct run_id: nil,
            run_dir: nil,
            provider: nil,
            queue: :queue.new(),
            queue_size: 0,
            current: nil,
            seq: 0

  @spec start_run(String.t(), Path.t(), String.t()) :: :ok | {:error, term()}
  def start_run(_run_id, _run_dir, "off"), do: :ok

  def start_run(run_id, run_dir, provider) when provider in ~w(claude codex gemini) do
    case DynamicSupervisor.start_child(
           Tractor.StatusAgentSup,
           {__MODULE__, {run_id, run_dir, provider}}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec observe(String.t(), map()) :: :ok
  def observe(run_id, payload) do
    case Registry.lookup(Tractor.StatusAgentRegistry, run_id) do
      [{pid, _value}] -> GenServer.cast(pid, {:observe, payload})
      [] -> :ok
    end
  end

  @spec stop_run(String.t()) :: :ok
  def stop_run(run_id) do
    case Registry.lookup(Tractor.StatusAgentRegistry, run_id) do
      [{pid, _value}] -> GenServer.cast(pid, :stop_run)
      [] -> :ok
    end
  end

  @spec prompt_template() :: String.t()
  def prompt_template do
    """
    Summarize the latest Tractor pipeline observation for an operator.

    Node: {{node_id}}
    Iteration: {{iteration}}
    Verdict: {{verdict}}
    Critique: {{critique}}
    Per-node iterations: {{per_node_iteration_counts}}
    Total iterations: {{total_iterations}}

    Output digest:
    {{output_digest}}

    Write one concise status update.
    """
    |> String.trim()
  end

  def child_spec({run_id, run_dir, provider}) do
    %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [{run_id, run_dir, provider}]},
      restart: :temporary
    }
  end

  @spec start_link({String.t(), Path.t(), String.t()}) :: GenServer.on_start()
  def start_link({run_id, run_dir, provider}) do
    GenServer.start_link(__MODULE__, {run_id, run_dir, provider},
      name: {:via, Registry, {Tractor.StatusAgentRegistry, run_id}}
    )
  end

  @impl true
  def init({run_id, run_dir, provider}) do
    {:ok, %__MODULE__{run_id: run_id, run_dir: run_dir, provider: provider}}
  end

  @impl true
  def handle_cast({:observe, payload}, state) do
    state
    |> enqueue(payload)
    |> process_next()
    |> then(&{:noreply, &1})
  end

  def handle_cast(:stop_run, state) do
    if state.current do
      Task.shutdown(state.current.task, @stop_grace)
    end

    RunEvents.emit(state.run_id, "_run", :status_agent_stopped, %{})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({ref, _result}, %{current: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    cancel_observation_timer(state.current)
    {:noreply, %{state | current: nil} |> process_next()}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{current: %{ref: ref}} = state) do
    cancel_observation_timer(state.current)
    {:noreply, %{state | current: nil} |> process_next()}
  end

  def handle_info(
        {:observation_timeout, timeout_ref},
        %{current: %{timeout_ref: timeout_ref}} = state
      ) do
    Task.shutdown(state.current.task, :brutal_kill)

    RunEvents.emit(state.run_id, "_run", :status_update_failed, %{
      "node_id" => state.current.payload.node_id,
      "iteration" => state.current.payload.iteration,
      "reason" => "timeout"
    })

    {:noreply, %{state | current: nil} |> process_next()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp enqueue(%{queue_size: size} = state, payload) when size >= @max_queue do
    {{:value, dropped}, queue} = :queue.out(state.queue)

    RunEvents.emit(state.run_id, "_run", :status_agent_dropped, %{
      "node_id" => dropped.node_id,
      "iteration" => dropped.iteration
    })

    %{state | queue: :queue.in(payload, queue)}
  end

  defp enqueue(state, payload) do
    %{state | queue: :queue.in(payload, state.queue), queue_size: state.queue_size + 1}
  end

  defp process_next(%{current: current} = state) when not is_nil(current), do: state

  defp process_next(%{queue_size: 0} = state), do: state

  defp process_next(state) do
    {{:value, payload}, queue} = :queue.out(state.queue)
    seq = state.seq + 1
    status_update_id = "status-#{seq}"

    task =
      Task.Supervisor.async_nolink(Tractor.StatusAgentTasks, fn ->
        run_observation(
          state.run_id,
          state.run_dir,
          state.provider,
          seq,
          status_update_id,
          payload
        )
      end)

    timeout_ref = make_ref()

    timer_ref =
      Process.send_after(self(), {:observation_timeout, timeout_ref}, @observation_timeout)

    %{
      state
      | queue: queue,
        queue_size: state.queue_size - 1,
        seq: seq,
        current: %{
          ref: task.ref,
          task: task,
          timer_ref: timer_ref,
          timeout_ref: timeout_ref,
          payload: payload
        }
    }
  end

  defp run_observation(run_id, run_dir, provider, seq, status_update_id, payload) do
    agent_client = Application.get_env(:tractor, :agent_client, Tractor.ACP.Session)
    adapter = Map.fetch!(@providers, provider)
    artifact_dir = Path.join([run_dir, "_status_agent", Integer.to_string(seq)])
    File.mkdir_p!(artifact_dir)

    prompt = render_prompt(payload)
    Tractor.Paths.atomic_write!(Path.join(artifact_dir, "prompt.md"), prompt)

    event_sink = fn
      %{kind: :agent_message_chunk, data: %{"text" => text}} ->
        emit_status_update(run_id, status_update_id, payload, text)

      _event ->
        :ok
    end

    result =
      with {:ok, session} <-
             agent_client.start_session(adapter,
               cwd: run_dir,
               stderr_log: Path.join(artifact_dir, "stderr.log"),
               event_sink: event_sink
             ) do
        reply = agent_client.prompt(session, prompt, @observation_timeout)
        :ok = agent_client.stop(session)
        reply
      end

    case result do
      {:ok, turn} ->
        summary = response_text(turn)
        Tractor.Paths.atomic_write!(Path.join(artifact_dir, "response.md"), summary)

        Tractor.Paths.atomic_write!(
          Path.join(artifact_dir, "status.json"),
          Jason.encode!(%{"status" => "ok"})
        )

        emit_status_update(run_id, status_update_id, payload, summary)

      {:error, :timeout} ->
        Tractor.Paths.atomic_write!(
          Path.join(artifact_dir, "status.json"),
          Jason.encode!(%{"status" => "error", "reason" => "timeout"})
        )

        RunEvents.emit(run_id, "_run", :status_update_failed, %{
          "node_id" => payload.node_id,
          "iteration" => payload.iteration,
          "reason" => "timeout"
        })

      {:error, reason} ->
        Tractor.Paths.atomic_write!(
          Path.join(artifact_dir, "status.json"),
          Jason.encode!(%{"status" => "error", "reason" => inspect(reason)})
        )

        RunEvents.emit(run_id, "_run", :status_update_failed, %{
          "node_id" => payload.node_id,
          "iteration" => payload.iteration,
          "reason" => inspect(reason)
        })
    end
  end

  defp render_prompt(payload) do
    prompt_template()
    |> String.replace("{{node_id}}", to_string(payload.node_id))
    |> String.replace("{{iteration}}", to_string(payload.iteration))
    |> String.replace("{{verdict}}", to_string(payload.verdict || ""))
    |> String.replace("{{critique}}", to_string(payload.critique || ""))
    |> String.replace("{{per_node_iteration_counts}}", inspect(payload.per_node_iteration_counts))
    |> String.replace("{{total_iterations}}", to_string(payload.total_iterations))
    |> String.replace("{{output_digest}}", payload.output_digest || "")
  end

  defp emit_status_update(run_id, status_update_id, payload, summary) do
    RunEvents.emit(run_id, "_run", :status_update, %{
      "status_update_id" => status_update_id,
      "node_id" => payload.node_id,
      "iteration" => payload.iteration,
      "summary" => summary || "",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp response_text(%Tractor.ACP.Turn{response_text: response}), do: response
  defp response_text(response) when is_binary(response), do: response

  defp cancel_observation_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_observation_timer(_current), do: :ok
end
