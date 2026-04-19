defmodule TractorWeb.GraphRenderer do
  @moduledoc """
  Renders pipeline DOT to clickable SVG through Graphviz.
  """

  alias Phoenix.HTML.Safe

  @cache :tractor_graph_svg_cache

  @spec render(Tractor.Pipeline.t()) :: {:ok, String.t()} | {:error, term()}
  def render(%Tractor.Pipeline{} = pipeline) do
    ensure_cache()

    case :ets.lookup(@cache, pipeline.path) do
      [{_path, svg}] ->
        {:ok, svg}

      [] ->
        with {:ok, svg} <- dot_to_svg(pipeline.path) do
          svg = inject_node_attrs(svg)
          :ets.insert(@cache, {pipeline.path, svg})
          {:ok, svg}
        end
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

  defp dot_to_svg(path) do
    # credo:disable-for-next-line Credo.Check.Design.TagTODO
    # TODO(sprint-3): pure-Elixir layered-DAG layout
    # Force monospace labels so node text reads as structured data, not prose.
    args = [
      "-Tsvg",
      "-Nfontname=Menlo",
      "-Efontname=Menlo",
      "-Gfontname=Menlo",
      path
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
  # an edge.
  defp inject_grid_pattern(svg) do
    defs = """
    <defs>
      <pattern id="tractor-grid-minor" x="0" y="0" width="8" height="8" patternUnits="userSpaceOnUse">
        <path d="M 8 0 L 0 0 0 8" fill="none" stroke="rgba(63,99,61,0.10)" stroke-width="0.5"/>
      </pattern>
      <pattern id="tractor-grid-major" x="0" y="0" width="40" height="40" patternUnits="userSpaceOnUse">
        <path d="M 40 0 L 0 0 0 40" fill="none" stroke="rgba(63,99,61,0.22)" stroke-width="1"/>
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

      ~s(<g#{attrs} data-node-id="#{escaped}"><title>#{escaped}</title>)
    end)
  end

  defp ensure_cache do
    case :ets.whereis(@cache) do
      :undefined -> :ets.new(@cache, [:named_table, :public, read_concurrency: true])
      _tid -> :ok
    end
  end
end
