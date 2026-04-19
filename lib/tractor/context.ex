defmodule Tractor.Context do
  @moduledoc """
  JSON-safe run context helpers.
  """

  @spec initial(map() | keyword()) :: map()
  def initial(seed \\ %{}) do
    Map.new(seed)
  end

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
end
