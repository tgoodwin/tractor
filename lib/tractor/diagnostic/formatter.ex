defmodule Tractor.Diagnostic.Formatter do
  @moduledoc """
  Shared rendering for parse and validation diagnostics.
  """

  alias Tractor.Diagnostic

  @spec format([Diagnostic.t()]) :: String.t()
  def format(diagnostics) do
    Enum.map_join(diagnostics, "", &format_diagnostic/1)
  end

  defp format_diagnostic(%Diagnostic{} = diagnostic) do
    [
      severity_label(diagnostic.severity),
      " [",
      to_string(diagnostic.code),
      "]",
      format_context(diagnostic),
      ": ",
      diagnostic.message,
      "\n",
      format_fix(diagnostic.fix)
    ]
    |> IO.iodata_to_binary()
  end

  defp severity_label(:error), do: "ERROR"
  defp severity_label(:warning), do: "WARNING"

  defp format_context(%Diagnostic{node_id: node_id}) when is_binary(node_id),
    do: " (node: #{node_id})"

  defp format_context(%Diagnostic{edge: {from, to}}),
    do: " (edge: #{from} -> #{to})"

  defp format_context(%Diagnostic{path: path}) when is_binary(path),
    do: " (path: #{path})"

  defp format_context(_diagnostic), do: ""

  defp format_fix(nil), do: ""
  defp format_fix(fix), do: "Fix: #{fix}\n"
end
