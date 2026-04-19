defmodule Tractor.DotParser do
  @moduledoc """
  Parses Graphviz DOT into Tractor-owned pipeline structs.
  """

  alias Tractor.{Diagnostic, Edge, Node, Pipeline}
  alias Tractor.Pipeline.ParallelBlock

  @shape_types %{
    "Mdiamond" => "start",
    "Msquare" => "exit",
    "box" => "codergen",
    "component" => "parallel",
    "tripleoctagon" => "parallel.fan_in"
  }

  @doc """
  Parses a DOT file into a normalized Tractor pipeline.
  """
  @spec parse_file(Path.t()) :: {:ok, Pipeline.t()} | {:error, [Diagnostic.t()]}
  def parse_file(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, graph} <- Dotx.decode(contents),
         {:ok, pipeline} <- normalize_graph(graph, path) do
      {:ok, pipeline}
    else
      {:error, %Diagnostic{} = diagnostic} -> {:error, [diagnostic]}
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      {:error, reason} -> {:error, [diagnostic(:parse_error, to_string(reason), path: path)]}
    end
  end

  defp normalize_graph(%Dotx.Graph{} = graph, path) do
    graph = graph |> Dotx.flatten() |> Dotx.spread_attributes()
    graph_attrs = normalize_attrs(Map.merge(graph.graphs_attrs, graph.attrs))

    with {:ok, nodes} <- normalize_nodes(graph),
         {:ok, edges} <- normalize_edges(graph) do
      {:ok,
       %Pipeline{
         path: path,
         goal: graph_attrs["goal"],
         strict?: graph.strict,
         graph_type: graph.type,
         graph_attrs: graph_attrs,
         nodes: nodes,
         edges: edges,
         parallel_blocks: discover_parallel_blocks(nodes, edges)
       }}
    end
  end

  defp normalize_nodes(graph) do
    graph
    |> collect_nodes()
    |> Enum.reduce_while({:ok, %{}}, fn node, {:ok, nodes} ->
      case normalize_node(node) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(nodes, normalized.id, normalized)}}
        {:error, diagnostic} -> {:halt, {:error, diagnostic}}
      end
    end)
  end

  defp normalize_node(%Dotx.Node{id: id, attrs: attrs}) do
    attrs = normalize_attrs(attrs)
    node_id = normalize_node_id(id)
    type = Map.get(attrs, "type") || @shape_types[attrs["shape"]]

    with {:ok, timeout} <- parse_timeout(attrs["timeout"], node_id) do
      {:ok,
       %Node{
         id: node_id,
         type: type,
         label: attrs["label"],
         prompt: attrs["prompt"],
         llm_provider: attrs["llm_provider"],
         llm_model: attrs["llm_model"],
         timeout: timeout,
         attrs: attrs
       }}
    end
  end

  defp normalize_edges(graph) do
    graph
    |> collect_edges()
    |> Enum.reduce_while({:ok, []}, fn edge, {:ok, edges} ->
      case normalize_edge(edge) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | edges]}}
        {:error, diagnostic} -> {:halt, {:error, diagnostic}}
      end
    end)
    |> then(fn
      {:ok, edges} -> {:ok, Enum.reverse(edges)}
      error -> error
    end)
  end

  defp normalize_edge(%Dotx.Edge{from: from, to: to, attrs: attrs}) do
    attrs = normalize_attrs(attrs)

    with {:ok, weight} <-
           parse_weight(attrs["weight"], normalize_node_id(from.id), normalize_node_id(to.id)) do
      {:ok,
       %Edge{
         from: normalize_node_id(from.id),
         to: normalize_node_id(to.id),
         label: attrs["label"],
         weight: weight,
         attrs: attrs
       }}
    end
  end

  defp collect_nodes(%{children: children}) do
    Enum.flat_map(children, fn
      %Dotx.Node{} = node -> [node]
      %Dotx.SubGraph{} = subgraph -> collect_nodes(subgraph)
      _other -> []
    end)
  end

  defp collect_edges(%{children: children}) do
    Enum.flat_map(children, fn
      %Dotx.Edge{} = edge -> [edge]
      %Dotx.SubGraph{} = subgraph -> collect_edges(subgraph)
      _other -> []
    end)
  end

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_value(key), normalize_value(value)} end)
  end

  defp normalize_node_id([id]), do: normalize_value(id)
  defp normalize_node_id([id | _ports]), do: normalize_value(id)

  defp normalize_value(%Dotx.HTML{html: html}), do: html
  defp normalize_value(value) when is_binary(value), do: value
  defp normalize_value(value), do: to_string(value)

  defp parse_timeout(nil, _node_id), do: {:ok, nil}

  defp parse_timeout(value, node_id) do
    case parse_duration(value) do
      {:ok, timeout} ->
        {:ok, timeout}

      :error ->
        {:error,
         diagnostic(:invalid_timeout, "invalid timeout #{inspect(value)}", node_id: node_id)}
    end
  end

  defp parse_duration(value) do
    case Regex.run(~r/^(\d+)(ms|s|m|h)?$/, String.trim(value)) do
      [_, amount, nil] -> {:ok, String.to_integer(amount)}
      [_, amount, "ms"] -> {:ok, String.to_integer(amount)}
      [_, amount, "s"] -> {:ok, String.to_integer(amount) * 1_000}
      [_, amount, "m"] -> {:ok, String.to_integer(amount) * 60_000}
      [_, amount, "h"] -> {:ok, String.to_integer(amount) * 3_600_000}
      _other -> :error
    end
  end

  defp parse_weight(nil, _from, _to), do: {:ok, 1.0}

  defp parse_weight(value, from, to) do
    case Float.parse(value) do
      {weight, ""} ->
        {:ok, weight}

      _other ->
        {:error,
         diagnostic(:invalid_weight, "invalid edge weight #{inspect(value)}", edge: {from, to})}
    end
  end

  defp diagnostic(code, message, opts) do
    %Diagnostic{
      code: code,
      message: message,
      node_id: Keyword.get(opts, :node_id),
      edge: Keyword.get(opts, :edge),
      path: Keyword.get(opts, :path)
    }
  end

  defp discover_parallel_blocks(nodes, edges) do
    nodes
    |> Enum.filter(fn {_id, %Node{type: type}} -> type == "parallel" end)
    |> Enum.reduce(%{}, fn {parallel_id, node}, blocks ->
      branches = outgoing_to_existing(edges, nodes, parallel_id)

      fan_ins =
        branches
        |> Enum.map(&reachable_fan_ins(nodes, edges, &1))
        |> intersect_all()

      case fan_ins do
        [fan_in_id] ->
          Map.put(blocks, parallel_id, %ParallelBlock{
            parallel_node_id: parallel_id,
            branches: branches,
            fan_in_id: fan_in_id,
            max_parallel: Node.max_parallel(node),
            join_policy: Node.join_policy(node)
          })

        _other ->
          blocks
      end
    end)
  end

  defp outgoing_to_existing(edges, nodes, node_id) do
    edges
    |> Enum.filter(&(&1.from == node_id and Map.has_key?(nodes, &1.to)))
    |> Enum.map(& &1.to)
  end

  defp reachable_fan_ins(nodes, edges, start_id) do
    do_reachable_fan_ins(nodes, edges, [start_id], MapSet.new(), MapSet.new())
  end

  defp do_reachable_fan_ins(_nodes, _edges, [], _seen, acc), do: acc

  defp do_reachable_fan_ins(nodes, edges, [node_id | rest], seen, acc) do
    cond do
      MapSet.member?(seen, node_id) ->
        do_reachable_fan_ins(nodes, edges, rest, seen, acc)

      get_in(nodes, [node_id, Access.key(:type)]) == "parallel.fan_in" ->
        do_reachable_fan_ins(
          nodes,
          edges,
          rest,
          MapSet.put(seen, node_id),
          MapSet.put(acc, node_id)
        )

      true ->
        next = outgoing_to_existing(edges, nodes, node_id)
        do_reachable_fan_ins(nodes, edges, next ++ rest, MapSet.put(seen, node_id), acc)
    end
  end

  defp intersect_all([]), do: []

  defp intersect_all([first | rest]) do
    rest
    |> Enum.reduce(first, &MapSet.intersection/2)
    |> MapSet.to_list()
    |> Enum.sort()
  end
end
