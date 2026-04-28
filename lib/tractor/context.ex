defmodule Tractor.Context do
  @moduledoc """
  JSON-safe run context helpers.
  """

  @reserved_keys ~w(goal run_dir)

  @doc """
  Reserved well-known context keys that the runner injects at run start.
  Node IDs colliding with these keys would shadow the well-known values and
  break template rendering — the validator rejects such pipelines.
  """
  @spec reserved_keys() :: [String.t()]
  def reserved_keys, do: @reserved_keys

  @spec initial(map() | keyword()) :: map()
  def initial(seed \\ %{}) do
    Map.new(seed)
  end

  @doc """
  Inject the well-known run-metadata keys (`goal`, `run_dir`) into a context map.

  - `goal` is set when `attrs.goal` is a non-empty string; otherwise the key is
    left unset so unresolved `{{goal}}` placeholders surface in rendered prompts.
  - `run_dir` is always set when `attrs.run_dir` is a non-empty string.

  Idempotent — safe to call on resumed contexts that may already have the keys.
  """
  @spec with_run_metadata(map(), %{
          optional(:goal) => String.t() | nil,
          optional(:run_dir) => String.t() | nil
        }) :: map()
  def with_run_metadata(context, attrs) when is_map(context) and is_map(attrs) do
    context
    |> maybe_put_string("goal", Map.get(attrs, :goal))
    |> maybe_put_string("run_dir", Map.get(attrs, :run_dir))
  end

  defp maybe_put_string(context, _key, nil), do: context
  defp maybe_put_string(context, _key, ""), do: context
  defp maybe_put_string(context, key, value) when is_binary(value),
    do: Map.put(context, key, value)

  defp maybe_put_string(context, _key, _value), do: context

  @spec snapshot(map()) :: {:ok, map()} | {:error, term()}
  def snapshot(context) when is_map(context) do
    if json_safe?(context) do
      {:ok, Jason.decode!(Jason.encode!(context))}
    else
      {:error, :non_json_safe_context}
    end
  end

  @spec clone_for_branch(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def clone_for_branch(context, branch_id) do
    with {:ok, snapshot} <- snapshot(context) do
      {:ok, Map.put(snapshot, "parallel.branch_id", branch_id)}
    end
  end

  @spec apply_updates(map(), map()) :: map()
  def apply_updates(context, updates) when is_map(updates) do
    Map.merge(context, updates)
  end

  @spec add_iteration(map(), String.t(), map()) :: map()
  def add_iteration(context, node_id, entry) when is_map(context) and is_binary(node_id) do
    entry = json_safe_entry(entry)
    iterations = Map.get(context, "iterations", %{})
    node_iterations = Map.get(iterations, node_id, [])
    iterations = Map.put(iterations, node_id, node_iterations ++ [entry])
    output = entry["output"] || ""

    context
    |> Map.put("iterations", iterations)
    |> Map.put("__iterations__", iterations)
    |> Map.put(node_id, output)
    |> Map.put("#{node_id}.iteration", entry["seq"])
    |> Map.put("#{node_id}.last_output", output)
    |> Map.put("#{node_id}.last_status", entry["status"])
    |> Map.put("#{node_id}.last_verdict", entry["verdict"])
    |> Map.put("#{node_id}.last_critique", entry["critique"])
    |> maybe_put("#{node_id}.last_routed_from", entry["routed_from"])
  end

  defp json_safe_entry(entry) do
    entry
    |> stringify_keys()
    |> Map.new(fn {key, value} -> {key, json_safe_value(value)} end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp json_safe_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_safe_value(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe_value(value) when is_list(value) do
    Enum.map(value, &json_safe_value/1)
  end

  defp json_safe_value(value) when is_map(value) do
    value
    |> stringify_keys()
    |> Map.new(fn {key, value} -> {key, json_safe_value(value)} end)
  end

  defp json_safe_value(value), do: inspect(value)

  defp json_safe?(value) when is_pid(value) or is_reference(value) or is_function(value),
    do: false

  defp json_safe?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_safe?(value) when is_list(value) do
    Enum.all?(value, &json_safe?/1)
  end

  defp json_safe?(value) when is_map(value) do
    Enum.all?(value, fn {key, value} -> json_safe_key?(key) and json_safe?(value) end)
  end

  defp json_safe?(_value), do: false

  defp json_safe_key?(key) when is_binary(key), do: true
  defp json_safe_key?(key) when is_atom(key), do: true
  defp json_safe_key?(key) when is_number(key), do: true
  defp json_safe_key?(_key), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
