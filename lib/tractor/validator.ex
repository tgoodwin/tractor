defmodule Tractor.Validator do
  @moduledoc """
  Strict sprint-one validation for normalized Tractor pipelines.
  """

  alias Decimal, as: D
  alias Tractor.{Condition, Diagnostic, DotParser, Duration, Edge, Node, Pipeline}

  @supported_providers ~w(claude codex gemini)

  @unsupported_handlers ~w(stack.manager_loop)

  @unsupported_edge_attrs ~w(fidelity thread_id loop_restart)
  @unsupported_graph_attrs ~w(model_stylesheet default-fidelity default_fidelity)
  @unsupported_attr_aliases ~w(max_retries default_max_retries status_agent_prompt)

  @spec validate_path(Path.t()) ::
          {:ok, Pipeline.t(), [Diagnostic.t()]} | {:error, [Diagnostic.t()]}
  def validate_path(path) do
    case DotParser.parse_file(path) do
      {:ok, %Pipeline{} = pipeline} -> {:ok, pipeline, diagnostics(pipeline)}
      {:error, diagnostics} when is_list(diagnostics) -> {:error, sort_diagnostics(diagnostics)}
    end
  end

  @spec diagnostics(Pipeline.t()) :: [Diagnostic.t()]
  def diagnostics(%Pipeline{} = pipeline) do
    []
    |> add_graph_shape_diagnostics(pipeline)
    |> add_cardinality_diagnostics(pipeline)
    |> add_endpoint_diagnostics(pipeline)
    |> add_connectivity_diagnostics(pipeline)
    |> add_cycle_diagnostics(pipeline)
    |> add_node_diagnostics(pipeline)
    |> add_budget_diagnostics(pipeline)
    |> add_status_agent_diagnostics(pipeline)
    |> add_parallel_diagnostics(pipeline)
    |> add_condition_diagnostics(pipeline)
    |> add_judge_diagnostics(pipeline)
    |> add_condition_coverage_diagnostics(pipeline)
    |> add_attr_diagnostics(pipeline)
    |> add_retry_diagnostics(pipeline)
    |> add_semantic_warning_diagnostics(pipeline)
    |> add_principle_warning_diagnostics(pipeline)
    |> add_retry_warning_diagnostics(pipeline)
    |> add_goal_gate_warning_diagnostics(pipeline)
    |> add_allow_partial_warning_diagnostics(pipeline)
    |> add_wait_human_warning_diagnostics(pipeline)
    |> add_implicit_iteration_cap_diagnostics(pipeline)
    |> Enum.reverse()
    |> sort_diagnostics()
  end

  @spec validate(Pipeline.t()) :: :ok | {:error, [Diagnostic.t()]}
  def validate(%Pipeline{} = pipeline) do
    diagnostics =
      pipeline
      |> diagnostics()
      |> Enum.filter(&(&1.severity == :error))

    case diagnostics do
      [] -> :ok
      diagnostics -> {:error, diagnostics}
    end
  end

  @spec warnings(Pipeline.t()) :: [Diagnostic.t()]
  def warnings(%Pipeline{} = pipeline) do
    pipeline
    |> diagnostics()
    |> Enum.filter(&(&1.severity == :warning))
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
      |> add_scc_cycle_diagnostics(nodes, edges, graph)
      |> maybe_add(
        not exit_reachable?(graph, nodes),
        :unreachable_exit,
        "exit node is not reachable from start"
      )
    after
      :digraph.delete(graph)
    end
  end

  defp add_scc_cycle_diagnostics(diagnostics, nodes, edges, graph) do
    graph
    |> :digraph_utils.strong_components()
    |> Enum.reduce(diagnostics, fn component, diagnostics ->
      component = Enum.map(component, &to_string/1)
      component_edges = edges_in_component(edges, component)

      cond do
        trivial_acyclic_component?(component, component_edges) ->
          diagnostics

        cycle_crosses_parallel?(nodes, component) ->
          diagnostic(
            diagnostics,
            :cycle_crosses_parallel,
            "cycle crosses parallel or parallel.fan_in boundary"
          )

        unconditional_cycle?(component, component_edges) ->
          diagnostic(
            diagnostics,
            :unconditional_cycle,
            "cycle contains an unconditional subcycle"
          )

        nested_cycle?(component, component_edges) ->
          diagnostic(diagnostics, :nested_cycles, "nested cycles are not supported")

        true ->
          diagnostics
      end
    end)
  end

  defp trivial_acyclic_component?([node_id], edges) do
    not Enum.any?(edges, &(&1.from == node_id and &1.to == node_id))
  end

  defp trivial_acyclic_component?(_component, _edges), do: false

  defp edges_in_component(edges, component) do
    ids = MapSet.new(component)
    Enum.filter(edges, &(MapSet.member?(ids, &1.from) and MapSet.member?(ids, &1.to)))
  end

  defp cycle_crosses_parallel?(nodes, component) do
    Enum.any?(component, fn node_id ->
      get_in(nodes, [node_id, Access.key(:type)]) in ["parallel", "parallel.fan_in"]
    end)
  end

  defp unconditional_cycle?(component, edges) do
    component
    |> cycle_graph(Enum.reject(edges, &conditional_edge?/1))
    |> cyclic_graph?()
  end

  defp nested_cycle?(component, edges) do
    conditional_edges = Enum.filter(edges, &conditional_edge?/1)
    component_size = length(component)

    Enum.any?(conditional_edges, fn removed_edge ->
      graph = cycle_graph(component, edges -- [removed_edge])

      try do
        graph
        |> :digraph_utils.strong_components()
        |> Enum.any?(fn subcomponent ->
          size = length(subcomponent)
          size > 1 and size < component_size
        end)
      after
        :digraph.delete(graph)
      end
    end)
  end

  defp cyclic_graph?(graph) do
    not :digraph_utils.is_acyclic(graph)
  after
    :digraph.delete(graph)
  end

  defp cycle_graph(component, edges) do
    graph = :digraph.new()
    Enum.each(component, &:digraph.add_vertex(graph, &1))
    Enum.each(edges, &:digraph.add_edge(graph, &1.from, &1.to))
    graph
  end

  defp conditional_edge?(%Edge{condition: condition}) when is_binary(condition),
    do: String.trim(condition) != ""

  defp conditional_edge?(%Edge{attrs: attrs}) do
    case Map.get(attrs, "condition") do
      condition when is_binary(condition) -> String.trim(condition) != ""
      _other -> false
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

  defp add_node_diagnostics(diagnostics, %Pipeline{nodes: nodes} = pipeline) do
    Enum.reduce(nodes, diagnostics, fn {_node_id, node}, diagnostics ->
      diagnostics
      |> add_handler_diagnostic(node)
      |> validate_handler_attrs(node, pipeline)
      |> add_provider_diagnostic(node)
      |> validate_max_iterations(node)
      |> validate_timeout(node)
      |> validate_goal_gate(node)
      |> validate_allow_partial(node)
    end)
  end

  defp add_handler_diagnostic(diagnostics, %Node{id: node_id, type: type})
       when type in @unsupported_handlers do
    diagnostic(diagnostics, :unsupported_handler, "unsupported handler type #{type}",
      node_id: node_id
    )
  end

  defp add_handler_diagnostic(diagnostics, _node), do: diagnostics

  defp validate_handler_attrs(diagnostics, %Node{type: "tool"} = node, _pipeline) do
    diagnostics
    |> validate_tool_command(node)
    |> validate_tool_env(node)
    |> validate_max_output_bytes(node)
  end

  defp validate_handler_attrs(diagnostics, %Node{type: "wait.human"} = node, pipeline) do
    validate_wait_human_attrs(diagnostics, node, pipeline)
  end

  defp validate_handler_attrs(diagnostics, %Node{type: "conditional"} = node, _pipeline) do
    validate_conditional_attrs(diagnostics, node)
  end

  defp validate_handler_attrs(diagnostics, _node, _pipeline), do: diagnostics

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

  defp validate_max_iterations(diagnostics, %Node{id: node_id} = node) do
    maybe_add(
      diagnostics,
      Node.max_iterations(node) < 1 or Node.max_iterations(node) > 100 or
        invalid_integer_attr?(node, "max_iterations"),
      :invalid_max_iterations,
      "max_iterations must be an integer between 1 and 100",
      node_id: node_id
    )
  end

  defp validate_timeout(diagnostics, %Node{id: node_id, attrs: attrs, timeout: timeout}) do
    explicit? = Map.has_key?(attrs, "timeout")

    maybe_add(
      diagnostics,
      explicit? and
        (is_nil(timeout) or timeout < 1_000 or timeout > 3_600_000),
      :invalid_timeout,
      "timeout must be a duration between 1s and 1h",
      node_id: node_id
    )
  end

  defp validate_goal_gate(diagnostics, %Node{id: node_id, attrs: attrs}) do
    maybe_add(
      diagnostics,
      Map.has_key?(attrs, "goal_gate") and attrs["goal_gate"] not in ~w(true false),
      :invalid_goal_gate,
      "goal_gate must be true or false",
      node_id: node_id
    )
  end

  defp validate_allow_partial(diagnostics, %Node{id: node_id, attrs: attrs}) do
    maybe_add(
      diagnostics,
      Map.has_key?(attrs, "allow_partial") and attrs["allow_partial"] not in ~w(true false),
      :invalid_allow_partial,
      "allow_partial must be true or false",
      node_id: node_id
    )
  end

  defp validate_tool_command(diagnostics, %Node{id: node_id, attrs: attrs}) do
    command = Map.get(attrs, "command")

    invalid? =
      is_nil(command) or
        not is_list(command) or
        command == [] or
        not Enum.all?(command, &is_binary/1)

    maybe_add(
      diagnostics,
      invalid?,
      :invalid_tool_command,
      "tool command must be a non-empty string array",
      node_id: node_id
    )
  end

  defp validate_tool_env(diagnostics, %Node{id: node_id, attrs: attrs}) do
    env = Map.get(attrs, "env")

    invalid? =
      not is_nil(env) and
        (not is_map(env) or
           not Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end))

    maybe_add(
      diagnostics,
      invalid?,
      :invalid_tool_env,
      "tool env must be a string-keyed, string-valued map",
      node_id: node_id
    )
  end

  defp validate_max_output_bytes(diagnostics, %Node{id: node_id, attrs: attrs}) do
    invalid? =
      case Map.fetch(attrs, "max_output_bytes") do
        {:ok, value} ->
          case parse_integer(value) do
            {:ok, integer} -> integer < 1 or integer > 100_000_000
            :error -> true
          end

        :error ->
          false
      end

    maybe_add(
      diagnostics,
      invalid?,
      :invalid_max_output_bytes,
      "max_output_bytes must be an integer between 1 and 100000000",
      node_id: node_id
    )
  end

  defp validate_wait_human_attrs(diagnostics, %Node{id: node_id} = node, %Pipeline{} = pipeline) do
    outgoing = Enum.filter(pipeline.edges, &(&1.from == node_id))
    wait_timeout = Node.wait_timeout_ms(node)
    default_edge = Node.default_edge(node)
    outgoing_labels = Node.outgoing_labels(node, pipeline)

    diagnostics
    |> maybe_add(
      outgoing == [],
      :wait_human_without_outgoing,
      "wait.human node must have at least one outgoing edge",
      node_id: node_id
    )
    |> maybe_add(
      Map.has_key?(node.attrs, "wait_timeout") and is_nil(wait_timeout),
      :invalid_wait_timeout,
      "wait_timeout must parse as a valid duration",
      node_id: node_id
    )
    |> maybe_add(
      Map.has_key?(node.attrs, "wait_timeout") and is_nil(default_edge),
      :wait_without_default,
      "wait.human nodes with wait_timeout must set default_edge",
      node_id: node_id
    )
    |> maybe_add(
      not is_nil(default_edge) and default_edge not in outgoing_labels,
      :invalid_default_edge,
      "default_edge must match an outgoing edge label",
      node_id: node_id
    )
  end

  defp validate_conditional_attrs(diagnostics, _node), do: diagnostics

  defp add_parallel_diagnostics(diagnostics, %Pipeline{nodes: nodes} = pipeline) do
    parallel_ids = node_ids_by_type(nodes, "parallel")
    fan_in_ids = MapSet.new(node_ids_by_type(nodes, "parallel.fan_in"))

    {diagnostics, fan_in_matches} =
      Enum.reduce(parallel_ids, {diagnostics, %{}}, fn parallel_id, {diagnostics, matches} ->
        node = Map.fetch!(nodes, parallel_id)

        diagnostics =
          diagnostics
          |> validate_join_policy(node)
          |> validate_max_parallel(node)

        case discover_parallel_block(pipeline, parallel_id) do
          {:ok, fan_in_id, branch_ids} ->
            diagnostics =
              validate_single_node_branches(diagnostics, pipeline, branch_ids, fan_in_id)

            {diagnostics, Map.update(matches, fan_in_id, [parallel_id], &[parallel_id | &1])}

          {:error, code} ->
            {diagnostic(diagnostics, code, parallel_message(code), node_id: parallel_id), matches}
        end
      end)

    Enum.reduce(fan_in_ids, diagnostics, fn fan_in_id, diagnostics ->
      case Map.get(fan_in_matches, fan_in_id, []) do
        [_parallel_id] ->
          diagnostics

        [] ->
          diagnostic(
            diagnostics,
            :fan_in_without_parallel,
            "parallel.fan_in has no matching upstream parallel",
            node_id: fan_in_id
          )

        _many ->
          diagnostic(
            diagnostics,
            :multiple_upstream_parallel,
            "parallel.fan_in has multiple upstream parallel nodes",
            node_id: fan_in_id
          )
      end
    end)
  end

  defp validate_join_policy(diagnostics, %Node{id: node_id} = node) do
    # credo:disable-for-next-line Credo.Check.Design.TagTODO
    # TODO(sprint-3): join_policy=first_success
    maybe_add(
      diagnostics,
      Node.join_policy(node) != "wait_all",
      :unsupported_join_policy,
      "unsupported join_policy #{Node.join_policy(node)}",
      node_id: node_id
    )
  end

  defp validate_max_parallel(diagnostics, %Node{id: node_id} = node) do
    max_parallel = Node.max_parallel(node)

    maybe_add(
      diagnostics,
      max_parallel <= 0 or max_parallel > 16 or invalid_integer_attr?(node, "max_parallel"),
      :invalid_max_parallel,
      "max_parallel must be an integer between 1 and 16",
      node_id: node_id
    )
  end

  defp invalid_integer_attr?(%Node{attrs: attrs}, attr) do
    case Map.fetch(attrs, attr) do
      {:ok, value} -> match?(:error, parse_integer(value))
      :error -> false
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> :error
    end
  end

  defp discover_parallel_block(%Pipeline{nodes: nodes, edges: edges}, parallel_id) do
    branch_ids = outgoing_to_existing(edges, nodes, parallel_id)

    common_fan_ins =
      branch_ids
      |> Enum.map(&reachable_fan_ins(nodes, edges, &1))
      |> intersect_all()

    case common_fan_ins do
      [] -> {:error, :no_common_fan_in}
      [fan_in_id] -> {:ok, fan_in_id, branch_ids}
      _many -> {:error, :multiple_common_fan_ins}
    end
  end

  defp validate_single_node_branches(diagnostics, %Pipeline{edges: edges}, branch_ids, fan_in_id) do
    Enum.reduce(branch_ids, diagnostics, fn branch_id, diagnostics ->
      outgoing = Enum.filter(edges, &(&1.from == branch_id))

      # credo:disable-for-next-line Credo.Check.Design.TagTODO
      # TODO(sprint-3): sub-DAG branches
      maybe_add(
        diagnostics,
        Enum.map(outgoing, & &1.to) != [fan_in_id],
        :nested_branches_unsupported,
        "parallel branches must be exactly one node in sprint 2",
        node_id: branch_id
      )
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

  defp parallel_message(:no_common_fan_in), do: "parallel node has no common downstream fan-in"

  defp parallel_message(:multiple_common_fan_ins),
    do: "parallel node has multiple common downstream fan-ins"

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

    diagnostics =
      Enum.reduce(@unsupported_attr_aliases, diagnostics, fn attr, diagnostics ->
        add_attr_alias_diagnostic(diagnostics, graph_attrs, attr)
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

  defp add_attr_alias_diagnostic(diagnostics, graph_attrs, "max_retries") do
    maybe_add(
      diagnostics,
      Map.has_key?(graph_attrs, "max_retries"),
      :deprecated_attr,
      "max_retries is deprecated; use retries",
      severity: :warning,
      fix: "Rename max_retries to retries."
    )
  end

  defp add_attr_alias_diagnostic(diagnostics, graph_attrs, "default_max_retries") do
    maybe_add(
      diagnostics,
      Map.has_key?(graph_attrs, "default_max_retries"),
      :deprecated_attr,
      "default_max_retries is deprecated; use retries",
      severity: :warning,
      fix: "Rename default_max_retries to retries."
    )
  end

  defp add_attr_alias_diagnostic(diagnostics, graph_attrs, attr) do
    maybe_add(
      diagnostics,
      Map.has_key?(graph_attrs, attr),
      :unsupported_attr,
      "unsupported attribute #{attr}"
    )
  end

  defp add_retry_diagnostics(
         diagnostics,
         %Pipeline{graph_attrs: graph_attrs, nodes: nodes} = pipeline
       ) do
    diagnostics = validate_retry_attrs(diagnostics, graph_attrs, [])

    Enum.reduce(nodes, diagnostics, fn {_node_id, %Node{id: node_id, attrs: attrs} = node},
                                       diagnostics ->
      validate_retry_attrs(diagnostics, attrs, node_id: node_id)
      |> validate_retry_targets(node, attrs, node_id, nodes, pipeline)
    end)
  end

  defp validate_retry_attrs(diagnostics, attrs, opts) do
    diagnostics
    |> validate_retry_integer(attrs, "retries", 0, 10, opts)
    |> validate_retry_integer(attrs, "retry_base_ms", 1, 60_000, opts)
    |> validate_retry_integer(attrs, "retry_cap_ms", 1, 300_000, opts)
    |> validate_retry_backoff(attrs, opts)
    |> validate_retry_jitter(attrs, opts)
  end

  defp validate_retry_integer(diagnostics, attrs, attr, min, max, opts) do
    valid? =
      case Map.fetch(attrs, attr) do
        {:ok, value} ->
          case parse_integer(value) do
            {:ok, integer} -> integer >= min and integer <= max
            :error -> false
          end

        :error ->
          true
      end

    maybe_add(
      diagnostics,
      not valid?,
      :invalid_retry_config,
      "#{attr} must be an integer between #{min} and #{max}",
      opts
    )
  end

  defp validate_retry_backoff(diagnostics, attrs, opts) do
    maybe_add(
      diagnostics,
      Map.has_key?(attrs, "retry_backoff") and
        attrs["retry_backoff"] not in ~w(exp linear constant),
      :invalid_retry_config,
      "retry_backoff must be exp, linear, or constant",
      opts
    )
  end

  defp validate_retry_jitter(diagnostics, attrs, opts) do
    maybe_add(
      diagnostics,
      Map.has_key?(attrs, "retry_jitter") and attrs["retry_jitter"] not in ~w(true false),
      :invalid_retry_config,
      "retry_jitter must be true or false",
      opts
    )
  end

  defp add_budget_diagnostics(diagnostics, %Pipeline{graph_attrs: attrs}) do
    diagnostics
    |> validate_total_iterations_budget(attrs)
    |> validate_wall_clock_budget(attrs)
    |> validate_total_cost_budget(attrs)
  end

  defp validate_total_iterations_budget(diagnostics, attrs) do
    valid? =
      case Map.fetch(attrs, "max_total_iterations") do
        {:ok, value} ->
          case parse_integer(value) do
            {:ok, integer} -> integer >= 1 and integer <= 1_000
            :error -> false
          end

        :error ->
          true
      end

    maybe_add(
      diagnostics,
      not valid?,
      :invalid_budget,
      "max_total_iterations must be an integer between 1 and 1000"
    )
  end

  defp validate_wall_clock_budget(diagnostics, attrs) do
    valid? =
      case Map.fetch(attrs, "max_wall_clock") do
        {:ok, value} ->
          case Duration.parse(value) do
            {:ok, ms} -> ms >= 1_000 and ms <= 86_400_000
            {:error, :invalid_duration} -> false
          end

        :error ->
          true
      end

    maybe_add(
      diagnostics,
      not valid?,
      :invalid_budget,
      "max_wall_clock must be a duration between 1s and 24h"
    )
  end

  defp validate_total_cost_budget(diagnostics, attrs) do
    valid? =
      case Map.fetch(attrs, "max_total_cost_usd") do
        {:ok, value} ->
          case D.parse(value) do
            {decimal, ""} ->
              D.compare(decimal, D.new("0.0001")) in [:gt, :eq] and
                D.compare(decimal, D.new("1000.0")) in [:lt, :eq]

            :error ->
              false
          end

        :error ->
          true
      end

    maybe_add(
      diagnostics,
      not valid?,
      :invalid_budget,
      "max_total_cost_usd must be a decimal between 0.0001 and 1000.0"
    )
  end

  defp add_status_agent_diagnostics(diagnostics, %Pipeline{graph_attrs: attrs}) do
    maybe_add(
      diagnostics,
      Map.has_key?(attrs, "status_agent") and
        attrs["status_agent"] not in ~w(claude codex gemini off),
      :invalid_status_agent,
      "status_agent must be claude, codex, gemini, or off"
    )
  end

  defp add_condition_diagnostics(diagnostics, %Pipeline{edges: edges}) do
    Enum.reduce(edges, diagnostics, fn %Edge{from: from, to: to} = edge, diagnostics ->
      condition = edge.condition || edge.attrs["condition"]

      maybe_add(
        diagnostics,
        conditional_edge?(edge) and invalid_condition?(condition),
        :invalid_condition,
        "invalid edge condition",
        edge: {from, to}
      )
    end)
  end

  defp add_judge_diagnostics(diagnostics, %Pipeline{nodes: nodes, edges: edges}) do
    Enum.reduce(nodes, diagnostics, fn
      {node_id, %Node{type: "judge"}}, diagnostics ->
        conditions =
          edges
          |> Enum.filter(&(&1.from == node_id))
          |> Enum.map(&normalized_condition/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.sort()

        expected_conditions =
          if Node.allow_partial?(nodes[node_id]) do
            ["accept", "partial_success", "reject"]
          else
            ["accept", "reject"]
          end

        maybe_add(
          diagnostics,
          conditions != expected_conditions,
          :judge_edge_cardinality,
          judge_edge_cardinality_message(Node.allow_partial?(nodes[node_id])),
          node_id: node_id
        )

      _other, diagnostics ->
        diagnostics
    end)
  end

  defp add_condition_coverage_diagnostics(diagnostics, %Pipeline{nodes: nodes, edges: edges}) do
    edges
    |> Enum.group_by(& &1.from)
    |> Enum.reduce(diagnostics, fn {node_id, outgoing}, diagnostics ->
      node = nodes[node_id]

      cond do
        is_nil(node) or node.type in ["judge", "conditional"] ->
          diagnostics

        length(outgoing) < 2 or not Enum.any?(outgoing, &conditional_edge?/1) ->
          diagnostics

        complete_condition_coverage?(outgoing) ->
          diagnostics

        true ->
          diagnostic(
            diagnostics,
            :incomplete_condition_coverage,
            "conditional outgoing edges must cover accept/reject or accept with a fall-through",
            node_id: node_id
          )
      end
    end)
  end

  defp complete_condition_coverage?(edges) do
    conditions =
      edges
      |> Enum.map(&normalized_condition/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    unconditional? = Enum.any?(edges, &(not conditional_edge?(&1)))

    MapSet.equal?(conditions, MapSet.new(["accept", "reject"])) or unconditional?
  end

  defp normalized_condition(edge) do
    (edge.condition || edge.attrs["condition"] || "")
    |> String.trim()
    |> String.downcase()
  end

  defp judge_edge_cardinality_message(true) do
    "judge node with allow_partial=true must have exactly accept, partial_success, and reject conditional outgoing edges"
  end

  defp judge_edge_cardinality_message(false) do
    "judge node must have exactly accept and reject conditional outgoing edges"
  end

  defp add_retry_warning_diagnostics(diagnostics, %Pipeline{} = pipeline) do
    reachable = reachable_from_start(pipeline)

    Enum.reduce(pipeline.nodes, diagnostics, fn {_node_id, %Node{id: node_id} = node},
                                                diagnostics ->
      Enum.reduce(
        [Node.retry_target(node), Node.fallback_retry_target(node)],
        diagnostics,
        fn
          nil, diagnostics ->
            diagnostics

          target_id, diagnostics ->
            maybe_add(
              diagnostics,
              not MapSet.member?(reachable, target_id),
              :unreachable_retry_target,
              "retry target is not reachable from start",
              node_id: node_id,
              severity: :warning
            )
        end
      )
    end)
  end

  defp add_goal_gate_warning_diagnostics(diagnostics, %Pipeline{nodes: nodes} = pipeline) do
    gate_ids =
      nodes
      |> Enum.filter(fn {_node_id, node} -> Node.goal_gate?(node) end)
      |> Enum.map(&elem(&1, 0))

    maybe_add(
      diagnostics,
      gate_ids != [] and gate_bypass?(pipeline, gate_ids),
      :goal_gate_bypass,
      "a start-to-exit path exists that bypasses all goal_gate nodes",
      severity: :warning
    )
  end

  defp add_allow_partial_warning_diagnostics(diagnostics, %Pipeline{nodes: nodes, edges: edges}) do
    Enum.reduce(nodes, diagnostics, fn
      {_node_id, %Node{id: node_id} = node}, diagnostics ->
        maybe_add(
          diagnostics,
          Node.allow_partial?(node) and not judge_upstream?(node_id, nodes, edges),
          :allow_partial_without_judge,
          "allow_partial=true has no incoming edge from a judge node",
          node_id: node_id,
          severity: :warning
        )

      _other, diagnostics ->
        diagnostics
    end)
  end

  defp add_wait_human_warning_diagnostics(diagnostics, %Pipeline{nodes: nodes}) do
    Enum.reduce(nodes, diagnostics, fn
      {_node_id, %Node{id: node_id, type: "wait.human"} = node}, diagnostics ->
        maybe_add(
          diagnostics,
          not Map.has_key?(node.attrs, "wait_timeout"),
          :wait_human_no_timeout,
          "wait.human node has no wait_timeout and may wait indefinitely",
          node_id: node_id,
          severity: :warning
        )

      _other, diagnostics ->
        diagnostics
    end)
  end

  defp add_implicit_iteration_cap_diagnostics(diagnostics, %Pipeline{nodes: nodes, edges: edges}) do
    back_edges = conditional_back_edges(nodes, edges)

    Enum.reduce(back_edges, diagnostics, fn %Edge{to: node_id}, diagnostics ->
      node = nodes[node_id]

      maybe_add(
        diagnostics,
        node && not Map.has_key?(node.attrs, "max_iterations"),
        :implicit_iteration_cap,
        "node targeted by a conditional back-edge uses default max_iterations=3",
        node_id: node_id,
        severity: :warning
      )
    end)
  end

  defp add_semantic_warning_diagnostics(diagnostics, %Pipeline{} = pipeline) do
    diagnostics
    |> add_node_semantic_warning_diagnostics(pipeline)
    |> add_two_way_edge_warning_diagnostics(pipeline)
  end

  defp add_node_semantic_warning_diagnostics(diagnostics, %Pipeline{nodes: nodes} = pipeline) do
    Enum.reduce(nodes, diagnostics, fn {_node_id, %Node{id: node_id} = node}, diagnostics ->
      implied_type = Node.implied_type_from_shape(node.attrs["shape"])
      effective_retries = effective_retries(node, pipeline.graph_attrs)

      diagnostics
      |> maybe_add(
        Map.has_key?(node.attrs, "type") and is_binary(implied_type) and node.type != implied_type,
        :type_shape_mismatch,
        "node '#{node_id}' has type='#{node.type}' but shape '#{node.attrs["shape"]}' implies type '#{implied_type}' - these disagree",
        node_id: node_id,
        severity: :warning,
        fix: "Make type and shape agree, or remove the explicit type."
      )
      |> maybe_add(
        Map.has_key?(node.attrs, "command") and not tool?(node),
        :tool_command_on_non_tool,
        "node '#{node_id}' has command but resolved type is '#{node.type}', not 'tool'",
        node_id: node_id,
        severity: :warning,
        fix: "Move command to a tool node, or remove the command attribute."
      )
      |> maybe_add(
        tool?(node) and Map.has_key?(node.attrs, "prompt"),
        :prompt_on_tool_node,
        "node '#{node_id}' is a tool node but has a prompt - tool nodes use command, not prompt",
        node_id: node_id,
        severity: :warning,
        fix: "Remove prompt from the tool node, or change the node type to codergen or judge."
      )
      |> maybe_add(
        Node.goal_gate?(node) and not agent_capable?(node),
        :goal_gate_on_non_agent,
        "node '#{node_id}' has goal_gate=true but resolved type is '#{node.type}', not an agent-capable node",
        node_id: node_id,
        severity: :warning,
        fix: "Use goal_gate only on codergen or judge nodes, or remove goal_gate."
      )
      |> maybe_add(
        llm_attrs_present?(node) and not agent_capable?(node),
        :agent_on_non_agent,
        "node '#{node_id}' has llm_provider or llm_model but resolved type is '#{node.type}' - LLM attrs are ignored on this node type",
        node_id: node_id,
        severity: :warning,
        fix: "Move llm_provider/llm_model to a codergen or judge node, or remove them."
      )
      |> maybe_add(
        Map.has_key?(node.attrs, "timeout") and instant_only?(node),
        :timeout_on_instant_node,
        "node '#{node_id}' has timeout but resolved type is '#{node.type}' - #{node.type} nodes execute instantly",
        node_id: node_id,
        severity: :warning,
        fix: "Remove timeout from instant-routing nodes."
      )
      |> maybe_add(
        Node.allow_partial?(node) and effective_retries == 0,
        :allow_partial_without_retries,
        "node '#{node_id}' has allow_partial=true but effective retries is 0 - allow_partial has no effect without retries",
        node_id: node_id,
        severity: :warning,
        fix: "Set retries above 0, or remove allow_partial."
      )
    end)
  end

  defp add_two_way_edge_warning_diagnostics(diagnostics, %Pipeline{edges: edges}) do
    edges
    |> Enum.map(fn %Edge{from: from, to: to} -> Enum.sort([from, to]) end)
    |> Enum.frequencies()
    |> Enum.reduce(diagnostics, fn
      {[from, to], count}, diagnostics when count > 1 ->
        diagnostic(
          diagnostics,
          :two_way_edge,
          "nodes '#{from}' and '#{to}' have edges in both directions",
          edge: {from, to},
          severity: :warning,
          fix: "Two-way edges are a potential malformed loop; a node should not validate its own work."
        )

      _other, diagnostics ->
        diagnostics
    end)
  end

  defp add_principle_warning_diagnostics(diagnostics, %Pipeline{nodes: nodes}) do
    Enum.reduce(nodes, diagnostics, fn
      {_node_id, %Node{id: node_id} = node}, diagnostics ->
        diagnostics
        |> maybe_add(
          wait_human?(node),
          :human_gate_warning,
          "node '#{node_id}' is a human gate - pipelines should run autonomously",
          node_id: node_id,
          severity: :warning,
          fix: "Human gates should only be used for debugging during pipeline development; replace with an agent node for production use."
        )
        |> maybe_add(
          tool?(node),
          :tool_node_warning,
          "node '#{node_id}' is a tool node running a shell command directly",
          node_id: node_id,
          severity: :warning,
          fix: "Prefer an agent node; agents run commands and can diagnose and fix errors."
        )

      _other, diagnostics ->
        diagnostics
    end)
  end

  defp conditional_back_edges(nodes, edges) do
    graph = :digraph.new()

    try do
      Enum.each(Map.keys(nodes), &:digraph.add_vertex(graph, &1))
      Enum.each(edges, &:digraph.add_edge(graph, &1.from, &1.to))

      components =
        graph
        |> :digraph_utils.strong_components()
        |> Enum.filter(&(length(&1) > 1))
        |> Enum.map(&MapSet.new/1)

      Enum.filter(edges, fn edge ->
        conditional_edge?(edge) and
          Enum.any?(components, &(MapSet.member?(&1, edge.from) and MapSet.member?(&1, edge.to)))
      end)
    after
      :digraph.delete(graph)
    end
  end

  defp count_type(nodes, type), do: nodes |> node_ids_by_type(type) |> length()

  defp node_ids_by_type(nodes, type) do
    for {node_id, %Node{type: ^type}} <- nodes, do: node_id
  end

  defp validate_retry_targets(diagnostics, node, attrs, node_id, nodes, pipeline) do
    declaring_scope = parallel_scope(node_id, pipeline)

    diagnostics
    |> maybe_add(
      declaring_scope != nil and
        (Map.has_key?(attrs, "retry_target") or Map.has_key?(attrs, "fallback_retry_target")),
      :invalid_retry_target,
      "retry_target and fallback_retry_target are not supported on nodes inside parallel blocks",
      node_id: node_id
    )
    |> validate_retry_target_attr(
      node,
      node_id,
      nodes,
      "retry_target",
      Node.retry_target(node),
      pipeline
    )
    |> validate_retry_target_attr(
      node,
      node_id,
      nodes,
      "fallback_retry_target",
      Node.fallback_retry_target(node),
      pipeline
    )
    |> maybe_add(
      Map.has_key?(attrs, "fallback_retry_target") and
        Node.fallback_retry_target(node) == Node.retry_target(node) and
        not is_nil(Node.retry_target(node)),
      :invalid_retry_target,
      "fallback_retry_target must differ from retry_target",
      node_id: node_id
    )
  end

  defp validate_retry_target_attr(diagnostics, _node, _node_id, _nodes, _attr, nil, _pipeline),
    do: diagnostics

  defp validate_retry_target_attr(
         diagnostics,
         _node,
         node_id,
         nodes,
         attr,
         target_id,
         pipeline
       ) do
    target = Map.get(nodes, target_id)
    target_scope = parallel_scope(target_id, pipeline)

    diagnostics
    |> maybe_add(
      is_nil(target),
      :retry_target_exists,
      "node '#{node_id}' has #{attr} '#{target_id}' which does not exist",
      node_id: node_id,
      severity: :warning,
      fix: "Point #{attr} at an existing non-terminal node."
    )
    |> maybe_add(
      not is_nil(target) and
        (target_id in ["start", "exit"] or
           target_id == node_id or
           not is_nil(target_scope) or
           target.type in ["start", "exit"]),
      :invalid_retry_target,
      "retry targets must reference a non-terminal node outside parallel blocks",
      node_id: node_id
    )
  end

  defp invalid_condition?(condition) do
    case Condition.parse(condition) do
      {:ok, ast} -> invalid_numeric_condition?(ast)
      {:error, :invalid_condition} -> true
    end
  end

  defp invalid_numeric_condition?(nil), do: false

  defp invalid_numeric_condition?({:or, left, right}),
    do: invalid_numeric_condition?(left) or invalid_numeric_condition?(right)

  defp invalid_numeric_condition?({:and, left, right}),
    do: invalid_numeric_condition?(left) or invalid_numeric_condition?(right)

  defp invalid_numeric_condition?({:not, expr}), do: invalid_numeric_condition?(expr)

  defp invalid_numeric_condition?({:cmp, op, key, _literal}) when op in [:lt, :lte, :gt, :gte] do
    not String.starts_with?(key, "context.")
  end

  defp invalid_numeric_condition?(_ast), do: false

  defp reachable_from_start(%Pipeline{nodes: nodes, edges: edges}) do
    case node_ids_by_type(nodes, "start") do
      [start_id] -> bfs([start_id], edges, MapSet.new())
      _other -> MapSet.new()
    end
  end

  defp bfs([], _edges, seen), do: seen

  defp bfs([node_id | rest], edges, seen) do
    if MapSet.member?(seen, node_id) do
      bfs(rest, edges, seen)
    else
      next =
        edges
        |> Enum.filter(&(&1.from == node_id))
        |> Enum.map(& &1.to)

      bfs(rest ++ next, edges, MapSet.put(seen, node_id))
    end
  end

  defp gate_bypass?(%Pipeline{nodes: nodes, edges: edges}, gate_ids) do
    gate_set = MapSet.new(gate_ids)

    with [start_id] <- node_ids_by_type(nodes, "start"),
         [exit_id] <- node_ids_by_type(nodes, "exit") do
      filtered_edges =
        Enum.reject(edges, fn edge ->
          MapSet.member?(gate_set, edge.from) or MapSet.member?(gate_set, edge.to)
        end)

      MapSet.member?(bfs([start_id], filtered_edges, MapSet.new()), exit_id)
    else
      _other -> false
    end
  end

  defp judge_upstream?(node_id, nodes, edges) do
    Enum.any?(edges, fn edge ->
      edge.to == node_id and get_in(nodes, [edge.from, Access.key(:type)]) == "judge"
    end)
  end

  defp effective_retries(node, graph_attrs) do
    retry_config = Node.retry_config(node, graph_attrs)
    Map.get(retry_config, :retries) || Map.get(retry_config, "retries") || 0
  end

  defp llm_attrs_present?(%Node{llm_provider: llm_provider, llm_model: llm_model}) do
    is_binary(llm_provider) or is_binary(llm_model)
  end

  # Moab's "agent" warnings map to tractor node types that can invoke an LLM handler.
  # parallel.fan_in is excluded because whether it invokes an LLM depends on runtime config,
  # which is not statically knowable from the lowered pipeline alone.
  defp agent_capable?(%Node{type: type}), do: type in ["codergen", "judge"]

  defp instant_only?(%Node{type: type}), do: type in ["start", "exit", "conditional", "parallel"]

  defp tool?(%Node{type: "tool"}), do: true
  defp tool?(%Node{}), do: false

  defp wait_human?(%Node{type: "wait.human"}), do: true
  defp wait_human?(%Node{}), do: false

  defp parallel_scope(node_id, %Pipeline{parallel_blocks: parallel_blocks})
       when parallel_blocks != %{} do
    Enum.find_value(parallel_blocks, fn {parallel_id, block} ->
      if node_id in block.branches or node_id == block.fan_in_id, do: parallel_id
    end)
  end

  defp parallel_scope(_node_id, _pipeline), do: nil

  defp maybe_add(diagnostics, condition, code, message, opts \\ [])
  defp maybe_add(diagnostics, false, _code, _message, _opts), do: diagnostics

  defp maybe_add(diagnostics, true, code, message, opts),
    do: diagnostic(diagnostics, code, message, opts)

  defp diagnostic(diagnostics, code, message), do: diagnostic(diagnostics, code, message, [])

  defp diagnostic(diagnostics, code, message, opts) do
    [
      %Diagnostic{
        code: code,
        message: message,
        node_id: Keyword.get(opts, :node_id),
        edge: Keyword.get(opts, :edge),
        fix: Keyword.get(opts, :fix),
        severity: Keyword.get(opts, :severity, :error)
      }
      | diagnostics
    ]
  end

  defp sort_diagnostics(diagnostics) do
    Enum.sort_by(diagnostics, fn diagnostic ->
      {severity_rank(diagnostic.severity), diagnostic.code,
       diagnostic.node_id || edge_from(diagnostic.edge),
       diagnostic.node_id || edge_to(diagnostic.edge)}
    end)
  end

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1

  defp edge_from({from, _to}), do: from
  defp edge_from(nil), do: nil

  defp edge_to({_from, to}), do: to
  defp edge_to(nil), do: nil
end
