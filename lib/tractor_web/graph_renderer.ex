defmodule TractorWeb.GraphRenderer do
  @moduledoc """
  Renders pipeline DOT to clickable SVG through Graphviz.
  """

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
      nil -> {:error, "Graphviz dot not found; install graphviz (brew install graphviz / apt install graphviz) or run without --serve"}
      _path -> :ok
    end
  end

  defp dot_to_svg(path) do
    case System.cmd("dot", ["-Tsvg", path], stderr_to_stdout: true) do
      {svg, 0} -> {:ok, svg}
      {error, _code} -> {:error, {:dot_failed, error}}
    end
  rescue
    _error -> {:error, "Graphviz dot not found; install graphviz (brew install graphviz / apt install graphviz) or run without --serve"}
  end

  defp inject_node_attrs(svg) do
    Regex.replace(~r/<g([^>]*class="node"[^>]*)>\s*<title>([^<]+)<\/title>/, svg, fn _all, attrs, node_id ->
      escaped = Plug.HTML.html_escape(node_id) |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
      attrs = String.replace(attrs, ~s(class="node"), ~s(class="node tractor-node"))
      ~s(<g#{attrs} data-node-id="#{escaped}" phx-click="select_node" phx-value-node-id="#{escaped}"><title>#{escaped}</title>)
    end)
  end

  defp ensure_cache do
    case :ets.whereis(@cache) do
      :undefined -> :ets.new(@cache, [:named_table, :public, read_concurrency: true])
      _tid -> :ok
    end
  end
end
