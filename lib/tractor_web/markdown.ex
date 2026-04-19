defmodule TractorWeb.Markdown do
  @moduledoc """
  Renders prompt/response text as markdown. Safe-mode only; no raw HTML.
  """

  @doc """
  Render a binary as safe HTML. Returns {:safe, iodata} for direct use in HEEx.
  Non-binaries are passed through `Jason` and wrapped in a <pre> so they still render.
  """
  @spec to_html(binary() | term()) :: {:safe, iodata()}
  def to_html(body) when is_binary(body) do
    html =
      case Earmark.as_html(body, earmark_opts()) do
        {:ok, html, _warnings} -> html
        {:error, html, _warnings} -> html
      end

    {:safe, html}
  end

  def to_html(body) do
    {:safe,
     [
       "<pre class=\"tractor-raw-json\">",
       Phoenix.HTML.html_escape(Jason.encode!(body, pretty: true)) |> elem(1),
       "</pre>"
     ]}
  end

  defp earmark_opts do
    %Earmark.Options{
      breaks: true,
      code_class_prefix: "language-",
      escape: true,
      smartypants: false,
      compact_output: true
    }
  end
end
