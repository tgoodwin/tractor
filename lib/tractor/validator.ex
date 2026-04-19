defmodule Tractor.Validator do
  @moduledoc """
  Strict sprint-one validation for normalized Tractor pipelines.
  """

  alias Tractor.{Diagnostic, Edge, Node, Pipeline}

  @supported_providers ~w(claude codex gemini)

  @unsupported_handlers ~w(
    wait.human
    conditional
    parallel
    parallel.fan_in
    tool
    stack.manager_loop
  )

  @unsupported_edge_attrs ~w(condition fidelity thread_id loop_restart)
  @unsupported_graph_attrs ~w(model_stylesheet retries default-fidelity default_fidelity)

  @spec validate(Pipeline.t()) :: :ok | {:error, [Diagnostic.t()]}
  def validate(%Pipeline{} = pipeline) do
    diagnostics =
      []
      |> add_graph_shape_diagnostics(pipeline)
      |> add_cardinality_diagnostics(pipeline)
      |> add_endpoint_diagnostics(pipeline)
      |> add_connectivity_diagnostics(pipeline)
      |> add_cycle_diagnostics(pipeline)
      |> add_node_diagnostics(pipeline)
      |> add_attr_diagnostics(pipeline)
      |> Enum.reverse()

    case diagnostics do
      [] -> :ok
      diagnostics -> {:error, diagnostics}
    end
  end

  defp add_graph_shape_diagnostics(diagnostics, %Pipeline{} = pipeline) do
    diagnostics
    |> maybe_add(
      pipeline.graph_type == :graph,
      :undirected_graph,
      "undirected graphs are not supported"
    )
    |> maybe_add(pipeline.strict?, :strict_graph, "strict graphs are not supported")
  end

  defp add_cardinality_diagnostics(diagnostics, %Pipeline{nodes: nodes}) do
    start_count = count_type(nodes, "start")
    exit_count = count_type(nodes, "exit")

    diagnostics
    |> maybe_add(
      start_count != 1,
      :start_cardinality,
      "pipeline must contain exactly one start node"
    )
    |> maybe_add(
      exit_count != 1,
      :exit_cardinality,
      "pipeline must contain exactly one exit node"
    )
  end

  defp add_endpoint_diagnostics(diagnostics, %Pipeline{nodes: nodes, edges: edges}) do
    node_ids = MapSet.new(Map.keys(nodes))

    Enum.reduce(edges, diagnostics, fn %Edge{from: from, to: to}, diagnostics ->
      missing? = not MapSet.member?(node_ids, from) or not MapSet.member?(node_ids, to)

      maybe_add(
        diagnostics,
        missing?,
        :unknown_edge_endpoint,
        "edge points to an undeclared node",
        edge: {from, to}
      )
    end)
  end

  defp add_connectivity_diagnostics(diagnostics, %Pipeline{nodes: nodes, edges: edges}) do
    node_ids = MapSet.new(Map.keys(nodes))

    incoming =
      edges
      |> Enum.filter(&MapSet.member?(node_ids, &1.to))
      |> Enum.group_by(& &1.to)

    outgoing =
      edges
      |> Enum.filter(&MapSet.member?(node_ids, &1.from))
      |> Enum.group_by(& &1.from)

    Enum.reduce(nodes, diagnostics, fn {node_id, %Node{type: type}}, diagnostics ->
      diagnostics
      |> maybe_add(
        type != "start" and not Map.has_key?(incoming, node_id),
        :missing_incoming,
        "non-start node has no incoming edge",
        node_id: node_id
      )
      |> maybe_add(
        type != "exit" and not Map.has_key?(outgoing, node_id),
        :missing_outgoing,
        "non-exit node has no outgoing edge",
        node_id: node_id
      )
    end)
  end

  defp add_cycle_diagnostics(diagnostics, %Pipeline{nodes: nodes, edges: edges}) do
    graph = :digraph.new()

    try do
      Enum.each(Map.keys(nodes), &:digraph.add_vertex(graph, &1))

      edges
      |> Enum.filter(&(Map.has_key?(nodes, &1.from) and Map.has_key?(nodes, &1.to)))
      |> Enum.each(&:digraph.add_edge(graph, &1.from, &1.to))

      diagnostics
      |> maybe_add(
        not :digraph_utils.is_acyclic(graph),
        :cycle,
        "pipeline graph contains a cycle"
      )
      |> maybe_add(
        not exit_reachable?(graph, nodes),
        :unreachable_exit,
        "exit node is not reachable from start"
      )
    after
      :digraph.delete(graph)
    end
  end

  defp exit_reachable?(graph, nodes) do
    with [start] <- node_ids_by_type(nodes, "start"),
         [exit] <- node_ids_by_type(nodes, "exit") do
      :digraph.get_path(graph, start, exit) != false
    else
      _other -> true
    end
  end

  defp add_node_diagnostics(diagnostics, %Pipeline{nodes: nodes}) do
    Enum.reduce(nodes, diagnostics, fn {_node_id, node}, diagnostics ->
      diagnostics
      |> add_handler_diagnostic(node)
      |> add_provider_diagnostic(node)
    end)
  end

  defp add_handler_diagnostic(diagnostics, %Node{id: node_id, type: type})
       when type in @unsupported_handlers do
    diagnostic(diagnostics, :unsupported_handler, "unsupported handler type #{type}",
      node_id: node_id
    )
  end

  defp add_handler_diagnostic(diagnostics, _node), do: diagnostics

  defp add_provider_diagnostic(diagnostics, %Node{
         id: node_id,
         type: "codergen",
         llm_provider: nil
       }) do
    diagnostic(diagnostics, :missing_provider, "codergen node is missing llm_provider",
      node_id: node_id
    )
  end

  defp add_provider_diagnostic(diagnostics, %Node{
         id: node_id,
         type: "codergen",
         llm_provider: provider
       })
       when provider not in @supported_providers do
    diagnostic(diagnostics, :unknown_provider, "unsupported llm_provider #{provider}",
      node_id: node_id
    )
  end

  defp add_provider_diagnostic(diagnostics, _node), do: diagnostics

  defp add_attr_diagnostics(diagnostics, %Pipeline{graph_attrs: graph_attrs, edges: edges}) do
    diagnostics =
      Enum.reduce(@unsupported_graph_attrs, diagnostics, fn attr, diagnostics ->
        maybe_add(
          diagnostics,
          Map.has_key?(graph_attrs, attr),
          :unsupported_graph_attr,
          "unsupported graph attribute #{attr}"
        )
      end)

    Enum.reduce(edges, diagnostics, fn %Edge{from: from, to: to, attrs: attrs}, diagnostics ->
      Enum.reduce(@unsupported_edge_attrs, diagnostics, fn attr, diagnostics ->
        maybe_add(
          diagnostics,
          Map.has_key?(attrs, attr),
          :unsupported_edge_attr,
          "unsupported edge attribute #{attr}",
          edge: {from, to}
        )
      end)
    end)
  end

  defp count_type(nodes, type), do: nodes |> node_ids_by_type(type) |> length()

  defp node_ids_by_type(nodes, type) do
    for {node_id, %Node{type: ^type}} <- nodes, do: node_id
  end

  defp maybe_add(diagnostics, condition, code, message, opts \\ [])
  defp maybe_add(diagnostics, false, _code, _message, _opts), do: diagnostics

  defp maybe_add(diagnostics, true, code, message, opts),
    do: diagnostic(diagnostics, code, message, opts)

  defp diagnostic(diagnostics, code, message, opts) do
    [
      %Diagnostic{
        code: code,
        message: message,
        node_id: Keyword.get(opts, :node_id),
        edge: Keyword.get(opts, :edge)
      }
      | diagnostics
    ]
  end
end
