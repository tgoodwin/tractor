defmodule Tractor.Checkpoint do
  @moduledoc """
  JSON checkpoint persistence for resumable runs.
  """

  alias Tractor.{Paths, Pipeline}

  @schema_version 1

  @spec save(map()) :: :ok
  def save(%{pipeline: %Pipeline{} = pipeline, store: store} = state) do
    started_at_wall_iso =
      Map.get(state, :started_at_wall_iso) || DateTime.to_iso8601(DateTime.utc_now())

    total_iterations_started =
      Map.get(state, :total_iterations_started) ||
        state.iterations |> Map.values() |> Enum.sum()

    total_cost_usd = Map.get(state, :total_cost_usd) || Decimal.new(0)

    goal_gates_satisfied = Map.get(state, :goal_gates_satisfied) || MapSet.new()

    checkpoint = %{
      "schema_version" => @schema_version,
      "run_id" => store.run_id,
      "pipeline_path" => pipeline.path,
      "dot_semantic_hash" => semantic_hash(pipeline),
      "saved_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "agenda" => queue_to_list(state.agenda),
      "completed" => state.completed |> MapSet.to_list() |> Enum.sort(),
      "goal_gates_satisfied" => goal_gates_satisfied |> MapSet.to_list() |> Enum.sort(),
      "iteration_counts" => stringify_key_map(state.iterations),
      "started_at_wall_iso" => started_at_wall_iso,
      "budgets" => %{
        "total_iterations" => total_iterations_started,
        "total_iterations_started" => total_iterations_started,
        "total_cost_usd" => Decimal.to_string(total_cost_usd),
        "started_at_wall_iso" => started_at_wall_iso
      },
      "node_ids" => pipeline.nodes |> Map.keys() |> Enum.sort(),
      "context" => state.context,
      "waiting" => serialize_waiting(Map.get(state, :waiting, %{})),
      "branch_contexts" => json_safe_value(Map.get(state, :branch_contexts, %{})),
      "parallel_state" => serialize_parallel_state(Map.get(state, :parallel_state, %{})),
      "provider_commands" => json_safe_value(Enum.reverse(state.provider_commands || [])),
      "node_states" => %{}
    }

    Paths.atomic_write!(
      Paths.checkpoint_path(store.run_dir),
      Jason.encode_to_iodata!(checkpoint, pretty: true)
    )
  end

  @spec read(Path.t()) :: {:ok, map()} | {:error, atom()}
  def read(run_dir) do
    path = Paths.checkpoint_path(run_dir)

    with {:ok, raw} <- File.read(path),
         {:ok, checkpoint} <- Jason.decode(raw),
         :ok <- validate_schema(checkpoint) do
      {:ok, checkpoint}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_checkpoint}
      {:error, :enoent} -> {:error, :missing_checkpoint}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec verify!(Pipeline.t(), map()) :: :ok | {:error, term()}
  def verify!(%Pipeline{} = pipeline, checkpoint) do
    cond do
      checkpoint["dot_semantic_hash"] != semantic_hash(pipeline) ->
        {:error, :pipeline_changed}

      MapSet.new(Map.keys(pipeline.nodes)) != MapSet.new(checkpoint["node_ids"] || []) ->
        {:error, :node_ids_changed}

      true ->
        :ok
    end
  end

  @spec semantic_hash(Pipeline.t()) :: String.t()
  def semantic_hash(%Pipeline{} = pipeline) do
    graph = %{
      nodes:
        pipeline.nodes
        |> Enum.map(fn {id, node} ->
          %{
            id: id,
            type: node.type,
            label: node.label,
            prompt: node.prompt,
            llm_provider: node.llm_provider,
            llm_model: node.llm_model,
            timeout: node.timeout,
            attrs: sort_attrs(node.attrs)
          }
        end)
        |> Enum.sort_by(& &1.id),
      edges:
        pipeline.edges
        |> Enum.map(fn edge ->
          %{
            from: edge.from,
            to: edge.to,
            label: edge.label,
            condition: edge.condition,
            weight: edge.weight,
            attrs: sort_attrs(edge.attrs)
          }
        end)
        |> Enum.sort_by(&{&1.from, &1.to, &1.label || "", &1.condition || ""})
    }

    :crypto.hash(:sha256, Jason.encode!(graph))
    |> Base.encode16(case: :lower)
  end

  defp validate_schema(%{"schema_version" => @schema_version}), do: :ok
  defp validate_schema(%{"schema_version" => _other}), do: {:error, :unsupported_checkpoint}
  defp validate_schema(_checkpoint), do: {:error, :unsupported_checkpoint}

  defp queue_to_list(queue), do: :queue.to_list(queue)

  defp serialize_waiting(waiting) do
    Map.new(waiting, fn {node_id, entry} ->
      {node_id,
       %{
         "node_id" => entry.node_id,
         "waiting_since" => DateTime.to_iso8601(entry.waiting_since),
         "wait_prompt" => entry.wait_prompt,
         "outgoing_labels" => entry.outgoing_labels,
         "wait_timeout_ms" => entry.wait_timeout_ms,
         "default_edge" => entry.default_edge,
         "attempt" => entry.attempt,
         "branch_id" => entry.branch_id,
         "parallel_id" => entry.parallel_id,
         "iteration" => entry.iteration,
         "declaring_node_id" => entry.declaring_node_id,
         "origin_node_id" => entry.origin_node_id,
         "recovery_tier" => Atom.to_string(entry.recovery_tier || :primary),
         "routed_from" => entry.routed_from,
         "max_iterations" => entry.max_iterations,
         "started_at" => entry.started_at
       }}
    end)
  end

  defp serialize_parallel_state(parallel_state) do
    Map.new(parallel_state, fn {parallel_id, entry} ->
      {parallel_id,
       %{
         "pending" => entry.pending,
         "running" => entry.running |> MapSet.to_list() |> Enum.sort(),
         "settled" => json_safe_value(entry.settled),
         "parent_context" => json_safe_value(entry.parent_context),
         "started_at_ms" => entry.started_at_ms
       }}
    end)
  end

  defp stringify_key_map(map) do
    Map.new(map || %{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp sort_attrs(map) do
    map
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> %{"key" => key, "value" => value} end)
  end

  defp json_safe_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_safe_value(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> json_safe_value()
  end

  defp json_safe_value(value) when is_list(value), do: Enum.map(value, &json_safe_value/1)

  defp json_safe_value(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), json_safe_value(value)} end)
  end

  defp json_safe_value(value), do: inspect(value)
end
