defmodule TractorWeb.ToolCallFormatter do
  @moduledoc """
  Human-readable labels for ACP tool calls.
  """

  alias TractorWeb.Format

  @spec format(map()) :: {String.t(), String.t()}
  def format(%{"kind" => kind, "title" => title})
      when is_binary(title) and byte_size(title) < 80 do
    {tag_for(kind), title}
  end

  def format(%{"kind" => "read", "rawInput" => %{"path" => path}}) when is_binary(path) do
    {"[READ]", Path.basename(path)}
  end

  def format(%{"kind" => "edit", "rawInput" => %{"path" => path, "edits" => edits}})
      when is_binary(path) and is_list(edits) do
    {"[EDIT]", "#{Path.basename(path)} (#{length(edits)} changes)"}
  end

  def format(%{"kind" => "write", "rawInput" => %{"path" => path, "content" => content}})
      when is_binary(path) and is_binary(content) do
    {"[WRITE]", "#{Path.basename(path)} (#{Format.humanize_bytes(byte_size(content))})"}
  end

  def format(%{"kind" => kind, "rawInput" => %{"command" => command}})
      when kind in ["bash", "execute", "shell"] and is_binary(command) do
    {"[BASH]", Format.truncate(command, 60)}
  end

  def format(%{"kind" => kind, "rawInput" => %{"pattern" => pattern, "path" => path}})
      when kind in ["grep", "search"] and is_binary(pattern) and is_binary(path) do
    {"[GREP]", ~s("#{pattern}" in #{path})}
  end

  def format(%{"kind" => "glob", "rawInput" => %{"pattern" => pattern}})
      when is_binary(pattern) do
    {"[GLOB]", pattern}
  end

  def format(%{"kind" => "fetch", "rawInput" => %{"url" => url}}) when is_binary(url) do
    {"[FETCH]", URI.parse(url).host || url}
  end

  def format(%{"kind" => kind, "title" => title, "toolCallId" => id}) do
    {"[TOOL]", "#{kind}: #{title || id}"}
  end

  def format(%{"toolCallId" => id}) when is_binary(id), do: {"[TOOL]", id}
  def format(_tool_call), do: {"[TOOL]", "unknown"}

  defp tag_for(kind) do
    case kind do
      "read" -> "[READ]"
      "edit" -> "[EDIT]"
      "write" -> "[WRITE]"
      kind when kind in ["bash", "execute", "shell"] -> "[BASH]"
      kind when kind in ["grep", "search"] -> "[GREP]"
      "glob" -> "[GLOB]"
      "fetch" -> "[FETCH]"
      _other -> "[TOOL]"
    end
  end
end
