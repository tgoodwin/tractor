defmodule TractorWeb.RunLive.ToolCallView do
  @moduledoc """
  Renders a tool_call timeline entry's body as readable HTML instead of raw JSON.

  The body shape (built by `Timeline`) is `%{"call" => call_data, "updates" => [...]}`.
  We dispatch on `call_data["kind"]` to pick a kind-specific input view, then append
  any output text accumulated from `tool_call_update` events.
  """

  alias TractorWeb.Format

  @output_byte_limit 4_000

  @spec render(map()) :: {:safe, iodata()}
  def render(%{} = body) do
    call = Map.get(body, "call") || %{}
    updates = Map.get(body, "updates") || []
    output = collect_output(updates)
    status = current_status(call, updates)

    iodata =
      [
        ~s(<div class="tool-call">),
        meta(call, status),
        inputs(call),
        if(output == "", do: [], else: output_block(output)),
        ~s(</div>)
      ]

    {:safe, iodata}
  end

  defp meta(call, status) do
    [
      ~s(<div class="tool-call-meta">),
      kind_chip(call),
      status_chip(status),
      ~s(</div>)
    ]
  end

  defp kind_chip(%{"kind" => kind}) when is_binary(kind) and kind != "" do
    ~s(<span class="tool-call-chip tool-call-kind">) <> escape(kind) <> ~s(</span>)
  end

  defp kind_chip(_), do: []

  defp status_chip(nil), do: []

  defp status_chip(status) when is_binary(status) and status != "" do
    ~s(<span class="tool-call-chip tool-call-status tool-call-status-) <>
      escape(status) <> ~s(">) <> escape(status) <> ~s(</span>)
  end

  defp status_chip(_), do: []

  # ---- Per-kind input views ----

  defp inputs(%{"kind" => kind} = call) when kind in ["bash", "execute", "shell"] do
    case bash_command(call) do
      "" -> []
      cmd -> bash_block(cmd)
    end
  end

  defp inputs(%{"kind" => "read"} = call) do
    paths = file_paths(call)
    if paths == [], do: [], else: path_list(paths)
  end

  defp inputs(%{"kind" => kind} = call) when kind in ["search", "grep"] do
    pattern = get_in(call, ["rawInput", "pattern"])
    path = get_in(call, ["rawInput", "path"])
    locations = file_paths(call)

    [
      if(is_binary(pattern) and pattern != "", do: kv_row("pattern", pattern), else: []),
      if(is_binary(path) and path != "", do: kv_row("in", path), else: []),
      if(locations != [], do: path_list(locations), else: [])
    ]
  end

  defp inputs(%{"kind" => "glob"} = call) do
    case get_in(call, ["rawInput", "pattern"]) do
      pattern when is_binary(pattern) and pattern != "" -> kv_row("pattern", pattern)
      _ -> []
    end
  end

  defp inputs(%{"kind" => "fetch"} = call) do
    case get_in(call, ["rawInput", "url"]) do
      url when is_binary(url) and url != "" -> kv_row("url", url)
      _ -> []
    end
  end

  defp inputs(%{"kind" => "edit"} = call) do
    path = get_in(call, ["rawInput", "path"])
    edits = get_in(call, ["rawInput", "edits"]) || []
    locations = file_paths(call)

    [
      if(is_binary(path) and path != "", do: kv_row("file", path), else: []),
      if(path == nil and locations != [], do: path_list(locations), else: []),
      if(is_list(edits) and edits != [], do: edits_block(edits), else: [])
    ]
  end

  defp inputs(%{"kind" => "write"} = call) do
    path = get_in(call, ["rawInput", "path"])
    content = get_in(call, ["rawInput", "content"])

    [
      if(is_binary(path) and path != "", do: kv_row("file", path), else: []),
      if(is_binary(content),
        do: kv_row("size", Format.humanize_bytes(byte_size(content))),
        else: []
      )
    ]
  end

  defp inputs(call) do
    # Unknown / generic tool: show locations if present, else fall back to a
    # compact JSON view so the row is never empty.
    case file_paths(call) do
      [] -> raw_json_block(Map.get(call, "rawInput") || %{})
      paths -> path_list(paths)
    end
  end

  # ---- Helpers ----

  defp bash_command(call) do
    case get_in(call, ["rawInput", "command_string"]) do
      cmd when is_binary(cmd) and cmd != "" ->
        cmd

      _ ->
        case get_in(call, ["rawInput", "command"]) do
          cmd when is_binary(cmd) -> cmd
          [_ | _] = parts -> command_to_string(parts)
          _ -> ""
        end
    end
  end

  defp command_to_string(parts) when is_list(parts) do
    parts
    |> Enum.map_join(" ", fn
      part when is_binary(part) -> shell_quote_if_needed(part)
      part -> inspect(part)
    end)
  end

  # Quote a command argument iff it contains a character that's meaningful to
  # the shell. Otherwise leave alone — keeps simple commands legible.
  defp shell_quote_if_needed(arg) do
    if Regex.match?(~r/[\s"'`$\\!*?\[\]<>|&;()]/, arg) do
      ~s('#{String.replace(arg, "'", "'\\''")}')
    else
      arg
    end
  end

  defp file_paths(call) do
    locations = Map.get(call, "locations") || []

    locations
    |> Enum.flat_map(fn
      %{"path" => path} when is_binary(path) -> [path]
      _ -> []
    end)
  end

  defp bash_block(cmd) do
    [
      ~s(<pre class="tool-call-bash"><span class="tool-call-bash-prompt">$</span> ),
      escape(cmd),
      ~s(</pre>)
    ]
  end

  defp path_list(paths) do
    [
      ~s(<ul class="tool-call-paths">),
      Enum.map(paths, fn path ->
        [~s(<li class="mono">), escape(path), ~s(</li>)]
      end),
      ~s(</ul>)
    ]
  end

  defp kv_row(label, value) do
    [
      ~s(<div class="tool-call-kv"><span class="tool-call-kv-key">),
      escape(label),
      ~s(</span><span class="tool-call-kv-value mono">),
      escape(value),
      ~s(</span></div>)
    ]
  end

  defp edits_block(edits) do
    [
      ~s(<div class="tool-call-edits">),
      Enum.with_index(edits, 1)
      |> Enum.map(fn {edit, idx} -> edit_block(edit, idx) end),
      ~s(</div>)
    ]
  end

  defp edit_block(edit, idx) do
    old = Map.get(edit, "oldText") || Map.get(edit, "old_string") || ""
    new = Map.get(edit, "newText") || Map.get(edit, "new_string") || ""

    [
      ~s(<div class="tool-call-edit">),
      ~s(<span class="tool-call-edit-label">edit #{idx}</span>),
      ~s(<pre class="tool-call-diff">),
      diff_lines(old, "-"),
      diff_lines(new, "+"),
      ~s(</pre>),
      ~s(</div>)
    ]
  end

  defp diff_lines(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      sign_class = if(prefix == "+", do: "diff-add", else: "diff-del")
      [~s(<span class="#{sign_class}">#{prefix} ), escape(line), ~s(</span>\n)]
    end)
  end

  defp output_block(text) do
    {trimmed, omitted} = truncate_output(text)

    [
      ~s(<div class="tool-call-output">),
      ~s(<span class="tool-call-output-label">↪ output</span>),
      ~s(<pre class="tool-call-output-body">),
      escape(trimmed),
      if(omitted > 0, do: "\n[truncated #{omitted} bytes]", else: ""),
      ~s(</pre>),
      ~s(</div>)
    ]
  end

  defp truncate_output(text) when is_binary(text) do
    if byte_size(text) <= @output_byte_limit do
      {text, 0}
    else
      {Format.truncate(text, @output_byte_limit), byte_size(text) - @output_byte_limit}
    end
  end

  defp raw_json_block(value) do
    [
      ~s(<pre class="tractor-raw-json">),
      value |> Jason.encode!(pretty: true) |> escape(),
      ~s(</pre>)
    ]
  end

  defp collect_output(updates) do
    updates
    |> Enum.flat_map(&extract_update_text/1)
    |> Enum.join("")
  end

  defp extract_update_text(%{} = update) do
    raw =
      case Map.get(update, "rawOutput") do
        text when is_binary(text) and text != "" -> [text]
        _ -> []
      end

    raw ++ extract_text_blocks(update)
  end

  defp extract_update_text(_), do: []

  defp extract_text_blocks(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"content" => %{"text" => text}} when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
  end

  defp extract_text_blocks(_), do: []

  defp current_status(call, updates) do
    case Enum.reverse(updates) do
      [%{"status" => status} | _] when is_binary(status) and status != "" -> status
      _ -> Map.get(call, "status")
    end
  end

  defp escape(value) when is_binary(value) do
    value
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp escape(value), do: value |> to_string() |> escape()
end
