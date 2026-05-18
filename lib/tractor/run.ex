defmodule Tractor.Run do
  @moduledoc """
  Public API for starting and awaiting Tractor runs.

  `finalize/2` is the only public path to terminal state — every site that
  needs to flip a run to `ok | error | interrupted | goal_gate_failed` must
  route through it. Direct calls to `RunStore.finalize/2` are not supported.
  """

  alias Tractor.{Checkpoint, DotParser, Pipeline, RunEvents, Runner, RunStore, Validator}
  alias Tractor.Runner.ControlFile

  @terminal_statuses ~w(ok error interrupted goal_gate_failed)

  @spec start(Pipeline.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start(%Pipeline{} = pipeline, opts \\ []) do
    with {:ok, store} <- RunStore.open(pipeline, opts),
         {:ok, _pid} <-
           DynamicSupervisor.start_child(Tractor.RunSup, {Runner, {pipeline, opts, store}}) do
      {:ok, store.run_id}
    end
  end

  @spec resume(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resume(run_dir, opts \\ []) do
    {force?, runner_opts} = Keyword.pop(opts, :force, false)

    with {:ok, store} <- RunStore.resume(run_dir),
         {:ok, checkpoint} <- Checkpoint.read(run_dir),
         pipeline_path when is_binary(pipeline_path) <- checkpoint["pipeline_path"],
         {:ok, pipeline} <- DotParser.parse_file(pipeline_path),
         :ok <- Validator.validate(pipeline),
         :ok <- maybe_verify(pipeline, checkpoint, force?),
         {:ok, _pid} <-
           DynamicSupervisor.start_child(
             Tractor.RunSup,
             {Runner, {pipeline, Keyword.put(runner_opts, :resume_state, checkpoint), store}}
           ) do
      {:ok, store.run_id}
    else
      nil -> {:error, :missing_pipeline_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_verify(_pipeline, _checkpoint, true), do: :ok
  defp maybe_verify(pipeline, checkpoint, false), do: Checkpoint.verify!(pipeline, checkpoint)

  @spec await(String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def await(run_id, timeout \\ 300_000) do
    Runner.await(run_id, timeout)
  end

  @spec info(String.t()) :: {:ok, map()} | {:error, term()}
  def info(run_id) do
    Runner.info(run_id)
  end

  @typedoc """
  Caller-supplied finalize attributes.

  - `:status` — terminal status; one of `"ok"`, `"error"`, `"interrupted"`,
    `"goal_gate_failed"`. Required.
  - `:reason` — opaque reason term; written to the manifest's `"reason"` key
    and the canonical `_run/run_finalized` event payload.
  - `:provider_commands`, `:total_cost_usd` — manifest fields supplied by the
    runner. Optional; the reconciler omits both.
  - `:source` — `:runner` (default) or `:reconciler`. When `:reconciler`,
    `finalize/2` also emits `_run/run_reconciled` before the canonical
    `_run/run_finalized` event.
  - `:terminal_event` — `{event_kind, payload}` override for the status-
    specific event. Falls back to a stock event keyed off `:status` when
    omitted. Use this to preserve runner-specific payloads (e.g. failure
    reason, failing node id).
  - `:owner_pid` — `:reconciler`-only; carried through to `_run/run_reconciled`.
  """
  @type finalize_attrs :: %{
          required(:status) => String.t(),
          optional(:reason) => term(),
          optional(:provider_commands) => list(),
          optional(:total_cost_usd) => String.t(),
          optional(:source) => :runner | :reconciler,
          optional(:terminal_event) => {atom(), map()},
          optional(:owner_pid) => integer() | nil
        }

  @doc """
  Single public entry for flipping a run to a terminal state.

  Idempotent: if the on-disk manifest already shows a terminal status,
  returns `:ok` without re-writing the manifest or re-emitting events. This
  protects the terminate/complete/reconcile race that can fire three sites
  for the same run within one tick.
  """
  @spec finalize(RunStore.t(), finalize_attrs()) :: :ok
  def finalize(%RunStore{} = store, attrs) do
    status = Map.fetch!(attrs, :status)
    source = Map.get(attrs, :source, :runner)
    reason = Map.get(attrs, :reason)

    if RunStore.read_status(store) in @terminal_statuses do
      :ok
    else
      :ok = RunStore.write_terminal_manifest(store, normalize_attrs(attrs, reason))

      {terminal_kind, terminal_data} = terminal_event(status, attrs)
      :ok = emit_with_register(store, "_run", terminal_kind, terminal_data)

      if source == :reconciler do
        :ok =
          emit_with_register(store, "_run", :run_reconciled, %{
            "reason" => reason_payload(reason),
            "owner_pid" => Map.get(attrs, :owner_pid)
          })
      end

      :ok =
        emit_with_register(store, "_run", :run_finalized, %{
          "status" => status,
          "reason" => reason_payload(reason),
          "source" => Atom.to_string(source)
        })

      Tractor.StatusAgent.stop_run(store.run_id)
      :ok = RunStore.delete_runner_pidfile(store)
      :ok
    end
  end

  defp terminal_event(status, attrs) do
    case Map.get(attrs, :terminal_event) do
      {kind, data} when is_atom(kind) and is_map(data) -> {kind, data}
      nil -> stock_terminal_event(status)
    end
  end

  defp stock_terminal_event("ok"), do: {:run_completed, %{"status" => "ok"}}
  defp stock_terminal_event("error"), do: {:run_failed, %{"status" => "error"}}
  defp stock_terminal_event("interrupted"), do: {:run_interrupted, %{"status" => "interrupted"}}

  defp stock_terminal_event("goal_gate_failed"),
    do: {:goal_gate_failed, %{"status" => "goal_gate_failed"}}

  defp emit_with_register(store, node_id, kind, data) do
    case RunEvents.emit(store.run_id, node_id, kind, data) do
      :ok ->
        :ok

      {:error, :run_not_registered} ->
        :ok = RunEvents.register_run(store.run_id, store.run_dir)
        :ok = RunEvents.emit(store.run_id, node_id, kind, data)
    end
  end

  defp reason_payload(nil), do: nil
  defp reason_payload(reason) when is_binary(reason), do: reason
  defp reason_payload(other), do: inspect(other)

  # The manifest is a JSON document on disk; non-binary reasons (atoms, tuples,
  # error terms) would crash Jason. Coerce here so RunStore.write_terminal_manifest
  # can stay a thin writer.
  defp normalize_attrs(attrs, reason) do
    case Map.fetch(attrs, :reason) do
      {:ok, _} -> Map.put(attrs, :reason, reason_payload(reason))
      :error -> attrs
    end
  end

  @spec submit_wait_choice(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def submit_wait_choice(run_id, node_id, label) do
    case Process.whereis(Tractor.RunRegistry) do
      nil ->
        run_dir = Path.join(Tractor.Paths.runs_dir(), run_id)
        :ok = ControlFile.write(run_dir, run_id, node_id, label)
        :ok

      _registry ->
        case Runner.submit_wait_choice(run_id, node_id, label) do
          {:error, :run_not_found} ->
            run_dir = Path.join(Tractor.Paths.runs_dir(), run_id)
            :ok = ControlFile.write(run_dir, run_id, node_id, label)
            :ok

          other ->
            other
        end
    end
  end
end
