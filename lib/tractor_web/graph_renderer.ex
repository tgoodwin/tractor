defmodule TractorWeb.GraphRenderer do
  @moduledoc """
  Renders pipeline DOT to clickable SVG through Graphviz.
  """

  alias Phoenix.HTML.Safe

  @spec render(Tractor.Pipeline.t()) :: {:ok, String.t()} | {:error, term()}
  def render(%Tractor.Pipeline{} = pipeline) do
    with {:ok, svg} <- dot_to_svg(pipeline) do
      svg = inject_node_attrs(svg)
      svg = inject_edge_attrs(svg, pipeline)
      {:ok, svg}
    end
  end

  @spec probe_dot() :: :ok | {:error, String.t()}
  def probe_dot do
    case System.find_executable("dot") do
      nil ->
        {:error,
         "Graphviz dot not found; install graphviz (brew install graphviz / apt install graphviz) or run without --serve"}

      _path ->
        :ok
    end
  end

  defp dot_to_svg(pipeline) do
    # credo:disable-for-next-line Credo.Check.Design.TagTODO
    # TODO(sprint-3): pure-Elixir layered-DAG layout
    # Force monospace labels so node text reads as structured data, not prose.
    args = [
      "-Tsvg",
      "-Nfontname=Menlo",
      "-Efontname=Menlo",
      "-Gfontname=Menlo",
      dot_path(pipeline)
    ]

    case System.cmd("dot", args, stderr_to_stdout: true) do
      {svg, 0} -> {:ok, svg |> strip_svg_background() |> inject_grid_pattern()}
      {error, _code} -> {:error, {:dot_failed, error}}
    end
  rescue
    _error ->
      {:error,
       "Graphviz dot not found; install graphviz (brew install graphviz / apt install graphviz) or run without --serve"}
  end

  defp dot_path(pipeline) do
    path = Path.join(System.tmp_dir!(), "tractor-graph-#{System.unique_integer([:positive])}.dot")
    Tractor.Paths.atomic_write!(path, pipeline_dot(pipeline))
    path
  end

  defp pipeline_dot(pipeline) do
    back_edges = back_edge_set(pipeline)

    nodes =
      pipeline.nodes
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {id, node} ->
        attrs =
          node.attrs
          |> Map.put_new("label", node.label || id)
          |> dot_attrs()

        "  #{quote_id(id)} [#{attrs}]"
      end)

    edges =
      pipeline.edges
      |> Enum.map_join("\n", fn edge ->
        attrs =
          edge.attrs
          |> maybe_put("condition", edge.condition)
          |> maybe_put("label", edge.label)
          |> maybe_put("weight", edge.weight)
          |> maybe_put("constraint", MapSet.member?(back_edges, {edge.from, edge.to}) && "false")
          |> dot_attrs()

        "  #{quote_id(edge.from)} -> #{quote_id(edge.to)} [#{attrs}]"
      end)

    "digraph {\n#{nodes}\n#{edges}\n}\n"
  end

  defp dot_attrs(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == false end)
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{quote_attr(value)}" end)
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, _key, false), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp quote_id(id), do: quote_attr(id)

  defp quote_attr(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> then(&"\"#{&1}\"")
  end

  # Graphviz emits a white-filled polygon at the top of the main <g> as the
  # graph background. Drop it so the page's cutting-mat grid shows through.
  defp strip_svg_background(svg) do
    Regex.replace(
      ~r{<polygon fill="white"[^/]*?/>\s*}s,
      svg,
      "",
      global: false
    )
  end

  # Inject an Excalidraw-style grid pattern INSIDE the transformed <g> so the
  # grid pans and zooms with the graph content. Two layers: faint 8px, stronger
  # 40px section lines. Uses generous negative offsets so panning never reveals
  # an edge. Strokes carry CSS classes so light/dark theme can restyle them.
  defp inject_grid_pattern(svg) do
    defs = """
    <defs>
      <pattern id="tractor-grid-minor" x="0" y="0" width="8" height="8" patternUnits="userSpaceOnUse">
        <path class="tractor-grid-line tractor-grid-line-minor" d="M 8 0 L 0 0 0 8" fill="none" stroke-width="0.5"/>
      </pattern>
      <pattern id="tractor-grid-major" x="0" y="0" width="40" height="40" patternUnits="userSpaceOnUse">
        <path class="tractor-grid-line tractor-grid-line-major" d="M 40 0 L 0 0 0 40" fill="none" stroke-width="1"/>
      </pattern>
    </defs>
    <rect x="-10000" y="-10000" width="20000" height="20000" fill="url(#tractor-grid-minor)" pointer-events="none"/>
    <rect x="-10000" y="-10000" width="20000" height="20000" fill="url(#tractor-grid-major)" pointer-events="none"/>
    """

    # Insert after the opening <g ... class="graph" ...> so the grid is
    # INSIDE the transform group and pans/zooms with the graph.
    Regex.replace(
      ~r{(<g[^>]*class="graph"[^>]*>)(\s*<title>[^<]*</title>)?}s,
      svg,
      fn _full, g_open, title -> g_open <> (title || "") <> defs end,
      global: false
    )
  end

  defp inject_node_attrs(svg) do
    # Runtime graph state is hook-owned. Do not inject pending/running/succeeded/failed
    # classes here; LiveView must push graph:* events for GraphBoard to apply.
    Regex.replace(~r/<g([^>]*class="node"[^>]*)>\s*<title>([^<]+)<\/title>/, svg, fn _all,
                                                                                     attrs,
                                                                                     node_id ->
      escaped = Plug.HTML.html_escape(node_id) |> Safe.to_iodata() |> IO.iodata_to_binary()

      attrs = String.replace(attrs, ~s(class="node"), ~s(class="node tractor-node"))

      ~s(<g#{attrs} data-node-id="#{escaped}" data-testid="node-#{escaped}"><title>#{escaped}</title>)
    end)
  end

  defp inject_edge_attrs(svg, pipeline) do
    edge_meta =
      Map.new(pipeline.edges, fn edge ->
        title = "#{edge.from}->#{edge.to}"

        classes =
          ["tractor-edge"]
          |> maybe_class(condition?(edge), "tractor-edge-conditional")
          |> maybe_class(edge_condition(edge) == "accept", "tractor-edge-accept")
          |> maybe_class(edge_condition(edge) == "reject", "tractor-edge-reject")
          |> maybe_class(
            MapSet.member?(back_edge_set(pipeline), {edge.from, edge.to}),
            "tractor-edge-back"
          )
          |> Enum.join(" ")

        {title,
         %{condition: edge.condition || "", classes: classes, from: edge.from, to: edge.to}}
      end)

    Regex.replace(~r/<g([^>]*class="edge"[^>]*)>\s*<title>([^<]+)<\/title>/, svg, fn all,
                                                                                     attrs,
                                                                                     title ->
      case Map.fetch(edge_meta, decode_edge_title(title)) do
        {:ok, meta} ->
          attrs =
            attrs
            |> String.replace(~s(class="edge"), ~s(class="edge #{meta.classes}"))

          condition =
            Plug.HTML.html_escape(meta.condition) |> Safe.to_iodata() |> IO.iodata_to_binary()

          from = Plug.HTML.html_escape(meta.from) |> Safe.to_iodata() |> IO.iodata_to_binary()
          to = Plug.HTML.html_escape(meta.to) |> Safe.to_iodata() |> IO.iodata_to_binary()

          ~s(<g#{attrs} data-from="#{from}" data-to="#{to}" data-condition="#{condition}"><title>#{title}</title>)

        :error ->
          all
      end
    end)
  end

  defp maybe_class(classes, true, class), do: [class | classes]
  defp maybe_class(classes, _condition, _class), do: classes

  defp decode_edge_title(title) do
    title
    |> String.replace("&#45;", "-")
    |> String.replace("&gt;", ">")
    |> String.replace("&lt;", "<")
  end

  defp condition?(edge), do: edge_condition(edge) != ""

  defp edge_condition(edge) do
    (edge.condition || edge.attrs["condition"] || "") |> String.trim() |> String.downcase()
  end

  defp back_edge_set(pipeline) do
    graph = :digraph.new()

    try do
      Enum.each(Map.keys(pipeline.nodes), &:digraph.add_vertex(graph, &1))
      Enum.each(pipeline.edges, &:digraph.add_edge(graph, &1.from, &1.to))

      components =
        graph
        |> :digraph_utils.strong_components()
        |> Enum.filter(&(length(&1) > 1))
        |> Enum.map(&MapSet.new/1)

      pipeline.edges
      |> Enum.filter(fn edge ->
        condition?(edge) and
          Enum.any?(
            components,
            &(MapSet.member?(&1, edge.from) and MapSet.member?(&1, edge.to))
          )
      end)
      |> MapSet.new(&{&1.from, &1.to})
    after
      :digraph.delete(graph)
    end
  end
end
