defmodule Tractor.DotParser do
  @moduledoc """
  Parses Graphviz DOT into Tractor-owned pipeline structs.
  """

  alias Tractor.{Diagnostic, Duration, Edge, Node, Pipeline}
  alias Tractor.Pipeline.ParallelBlock

  @doc """
  Parses a DOT file into a normalized Tractor pipeline.
  """
  @spec parse_file(Path.t()) :: {:ok, Pipeline.t()} | {:error, [Diagnostic.t()]}
  def parse_file(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, graph} <- Dotx.decode(preprocess_structured_literals(contents)),
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
    type = Map.get(attrs, "type") || Node.implied_type_from_shape(attrs["shape"])

    with {:ok, timeout} <- parse_timeout(attrs["timeout"], node_id) do
      {:ok,
       %Node{
         id: node_id,
         type: type,
         label: attrs["label"],
         prompt: unescape_prompt(attrs["prompt"]),
         llm_provider: attrs["llm_provider"],
         llm_model: attrs["llm_model"],
         timeout: timeout,
         retries: parse_integer_attr(attrs["retries"]),
         retry_backoff: attrs["retry_backoff"],
         retry_base_ms: parse_integer_attr(attrs["retry_base_ms"]),
         retry_cap_ms: parse_integer_attr(attrs["retry_cap_ms"]),
         retry_jitter: parse_boolean_attr(attrs["retry_jitter"]),
         retry_target: attrs["retry_target"],
         fallback_retry_target: attrs["fallback_retry_target"],
         goal_gate: parse_boolean_attr(attrs["goal_gate"]),
         allow_partial: parse_boolean_attr(attrs["allow_partial"]),
         attrs: attrs
       }}
    end
  end

  defp parse_integer_attr(nil), do: nil

  defp parse_integer_attr(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp parse_boolean_attr("true"), do: true
  defp parse_boolean_attr("false"), do: false
  defp parse_boolean_attr(_value), do: nil

  # DOT attribute values are literal; authors write `\n` expecting a newline.
  # Translate common escapes so prompts can be multi-line without DOT gymnastics.
  defp unescape_prompt(nil), do: nil

  defp unescape_prompt(prompt) when is_binary(prompt) do
    prompt
    |> String.replace("\\n", "\n")
    |> String.replace("\\r", "\r")
    |> String.replace("\\t", "\t")
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
         condition: attrs["condition"],
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
    Map.new(attrs, fn {key, value} ->
      key = normalize_value(key)
      {key, normalize_attr_value(key, value)}
    end)
  end

  defp normalize_node_id([id]), do: normalize_value(id)
  defp normalize_node_id([id | _ports]), do: normalize_value(id)

  defp normalize_value(%Dotx.HTML{html: html}), do: html
  defp normalize_value(value) when is_binary(value), do: value
  defp normalize_value(value), do: to_string(value)

  defp normalize_attr_value(key, value) when key in ["command", "env"] do
    value
    |> normalize_value()
    |> decode_structured_attr()
  end

  defp normalize_attr_value(_key, value), do: normalize_value(value)

  defp decode_structured_attr(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

  defp decode_structured_attr(value), do: normalize_value(value)

  defp parse_timeout(nil, _node_id), do: {:ok, nil}

  defp parse_timeout(value, node_id) do
    case Duration.parse(value) do
      {:ok, timeout} ->
        {:ok, timeout}

      {:error, :invalid_duration} ->
        {:error,
         diagnostic(:invalid_timeout, "invalid timeout #{inspect(value)}", node_id: node_id)}
    end
  end

  defp parse_weight(nil, _from, _to), do: {:ok, 0.0}

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

  defp preprocess_structured_literals(contents) do
    do_preprocess_structured_literals(contents, [], :normal, false)
    |> IO.iodata_to_binary()
  end

  defp do_preprocess_structured_literals(<<>>, acc, _mode, _prev_word?), do: Enum.reverse(acc)

  defp do_preprocess_structured_literals(<<"\"", rest::binary>>, acc, :normal, _prev_word?) do
    do_preprocess_structured_literals(rest, ["\"" | acc], :string, false)
  end

  defp do_preprocess_structured_literals(binary, acc, :string, _prev_word?) do
    <<char::utf8, rest::binary>> = binary
    next_mode = if char == ?", do: :normal, else: :string
    do_preprocess_structured_literals(rest, [<<char::utf8>> | acc], next_mode, false)
  end

  defp do_preprocess_structured_literals(binary, acc, :normal, false) do
    case take_structured_attr(binary) do
      {:ok, rewritten, rest} ->
        do_preprocess_structured_literals(rest, [rewritten | acc], :normal, false)

      :error ->
        <<char::utf8, rest::binary>> = binary

        do_preprocess_structured_literals(
          rest,
          [<<char::utf8>> | acc],
          :normal,
          word_char?(char)
        )
    end
  end

  defp do_preprocess_structured_literals(<<char::utf8, rest::binary>>, acc, :normal, _prev_word?) do
    do_preprocess_structured_literals(rest, [<<char::utf8>> | acc], :normal, word_char?(char))
  end

  defp take_structured_attr(binary) do
    with {attr, rest} <- attr_name(binary),
         {whitespace_before_equals, <<"=", rest::binary>>} <- take_leading_whitespace(rest),
         {whitespace_after_equals, rest} <- take_leading_whitespace(rest),
         <<open::utf8, _::binary>> = literal <- rest,
         true <- open in [?[, ?{],
         {:ok, structured_literal, remaining} <- take_balanced_literal(literal) do
      escaped_literal = escape_dot_string(structured_literal)

      {:ok,
       [
         attr,
         whitespace_before_equals,
         "=",
         whitespace_after_equals,
         "\"",
         escaped_literal,
         "\""
       ], remaining}
    else
      _other -> :error
    end
  end

  defp attr_name(<<"command", rest::binary>>) do
    if attr_terminator?(rest), do: {"command", rest}, else: nil
  end

  defp attr_name(<<"env", rest::binary>>) do
    if attr_terminator?(rest), do: {"env", rest}, else: nil
  end

  defp attr_name(_binary), do: nil

  defp attr_terminator?(<<char::utf8, _::binary>>) do
    String.trim(<<char::utf8>>) == "" or char == ?=
  end

  defp attr_terminator?(<<>>), do: true

  defp take_leading_whitespace(binary), do: take_leading_whitespace(binary, "")

  defp take_leading_whitespace(<<char::utf8, rest::binary>>, acc)
       when char in [?\s, ?\t, ?\n, ?\r] do
    take_leading_whitespace(rest, acc <> <<char::utf8>>)
  end

  defp take_leading_whitespace(binary, acc), do: {acc, binary}

  defp take_balanced_literal(<<open::utf8, rest::binary>>) when open in [?[, ?{] do
    closing = if open == ?[, do: ?], else: ?}
    do_take_balanced_literal(rest, [<<open::utf8>>], [closing], false, false)
  end

  defp do_take_balanced_literal(<<>>, _acc, _stack, _in_string?, _escaped?), do: :error

  defp do_take_balanced_literal(<<char::utf8, rest::binary>>, acc, stack, true, true) do
    do_take_balanced_literal(rest, [<<char::utf8>> | acc], stack, true, false)
  end

  defp do_take_balanced_literal(<<"\\", rest::binary>>, acc, stack, true, false) do
    do_take_balanced_literal(rest, ["\\" | acc], stack, true, true)
  end

  defp do_take_balanced_literal(<<"\"", rest::binary>>, acc, stack, in_string?, false) do
    do_take_balanced_literal(rest, ["\"" | acc], stack, not in_string?, false)
  end

  defp do_take_balanced_literal(<<"[", rest::binary>>, acc, stack, false, false) do
    do_take_balanced_literal(rest, ["[" | acc], [?] | stack], false, false)
  end

  defp do_take_balanced_literal(<<"{", rest::binary>>, acc, stack, false, false) do
    do_take_balanced_literal(rest, ["{" | acc], [?} | stack], false, false)
  end

  defp do_take_balanced_literal(<<char::utf8, rest::binary>>, acc, [char], false, false) do
    {:ok, acc |> Enum.reverse([<<char::utf8>>]) |> IO.iodata_to_binary(), rest}
  end

  defp do_take_balanced_literal(<<char::utf8, rest::binary>>, acc, [char | stack], false, false) do
    do_take_balanced_literal(rest, [<<char::utf8>> | acc], stack, false, false)
  end

  defp do_take_balanced_literal(<<char::utf8, rest::binary>>, acc, stack, in_string?, escaped?) do
    do_take_balanced_literal(rest, [<<char::utf8>> | acc], stack, in_string?, escaped?)
  end

  defp escape_dot_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
  end

  defp word_char?(char) when char in ?a..?z, do: true
  defp word_char?(char) when char in ?A..?Z, do: true
  defp word_char?(char) when char in ?0..?9, do: true
  defp word_char?(?_), do: true
  defp word_char?(_char), do: false

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
