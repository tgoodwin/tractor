defmodule Tractor.Context.Template do
  @moduledoc """
  Shared prompt interpolation for run context values.
  """

  @spec render(String.t(), map()) :: String.t()
  def render(template, context) when is_binary(template) and is_map(context) do
    Regex.replace(~r/\{\{\s*([^}]+?)\s*\}\}/, template, fn placeholder, key ->
      case resolve(String.trim(key), context) do
        nil -> placeholder
        value when is_binary(value) -> value
        value -> to_string(value)
      end
    end)
  end

  @spec resolve(String.t(), map()) :: term() | nil
  def resolve("branch:" <> branch_id, context) do
    context["branch:#{branch_id}"] || context[branch_id]
  end

  def resolve(key, context) do
    cond do
      Map.has_key?(context, key) ->
        Map.get(context, key)

      String.ends_with?(key, ".last") ->
        node_id = String.replace_suffix(key, ".last", "")
        Map.get(context, "#{node_id}.last_output") || Map.get(context, node_id)

      String.ends_with?(key, ".last_critique") ->
        node_id = String.replace_suffix(key, ".last_critique", "")
        Map.get(context, "#{node_id}.last_critique")

      match = Regex.run(~r/^(.+)\.iteration\((\d+)\)$/, key) ->
        [_, node_id, seq] = match
        iteration_output(context, node_id, String.to_integer(seq))

      String.ends_with?(key, ".iterations.length") ->
        node_id = String.replace_suffix(key, ".iterations.length", "")
        context |> iterations(node_id) |> length()

      true ->
        dotted(context, String.split(key, "."))
    end
  end

  defp iteration_output(context, node_id, seq) do
    context
    |> iterations(node_id)
    |> Enum.find(&(&1["seq"] == seq or &1[:seq] == seq))
    |> case do
      nil -> nil
      entry -> entry["output"] || entry[:output]
    end
  end

  defp iterations(context, node_id) do
    get_in(context, ["iterations", node_id]) ||
      get_in(context, ["__iterations__", node_id]) ||
      []
  end

  defp dotted(value, []), do: value

  defp dotted(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> dotted(value, rest)
      :error -> nil
    end
  end

  defp dotted(list, [key | rest]) when is_list(list) do
    case Integer.parse(key) do
      {index, ""} -> list |> Enum.at(index) |> dotted(rest)
      _other -> nil
    end
  end

  defp dotted(_value, _path), do: nil
end
