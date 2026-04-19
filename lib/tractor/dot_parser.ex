defmodule Tractor.DotParser do
  @moduledoc """
  Parses Graphviz DOT into Tractor-owned pipeline structs.
  """

  alias Tractor.{Diagnostic, Edge, Node, Pipeline}

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
         edges: edges
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
end
