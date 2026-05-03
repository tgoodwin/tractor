defmodule TractorWeb.RunLive.Timeline do
  @moduledoc """
  Builds and updates the observer sidebar timeline.
  """

  alias TractorWeb.{Format, ToolCallFormatter}

  @display_string_limit 4_000
  @display_map_limit 40
  @display_list_limit 40

  @type entry :: %{
          id: String.t(),
          ts: DateTime.t() | nil,
          seq: integer() | nil,
          type:
            :prompt
            | :thinking
            | :tool_call
            | :tool_call_update
            | :message
            | :response
            | :stderr
            | :acp
            | :lifecycle
            | :usage
            | :iteration_header
            | :verdict
            | :tool_runtime
            | :wait_runtime,
          title: String.t(),
          summary: String.t(),
          body: binary() | map(),
          collapsed_by_default?: boolean(),
          tone: :neutral | :accent | :success | :failure | :muted
        }

  # The timeline preserves the order in which entries first appear:
  # - Prompt sits at the front (synthesized before any event-derived rows).
  # - Event-derived rows follow events.jsonl's seq order, which is the order
  #   they were written by the runner.
  # - Synthetic "fallback" rows (response.md, terminal lifecycle, stderr.log)
  #   land at the tail when no event already covered them.
  # Because events on disk are already in chronological order, we never
  # re-sort. New live events arrive monotonically and append at the end.
  @spec from_disk(Path.t(), String.t(), keyword()) :: [entry()]
  def from_disk(run_dir, node_id, opts \\ []) do
    node_dir = Path.join(run_dir, node_id)
    events = read_events(node_dir)
    static_prompt = Keyword.get(opts, :static_prompt)

    new_acc()
    |> maybe_add_prompt(node_dir, events, static_prompt)
    |> add_event_entries(events)
    |> maybe_add_response(node_dir, events)
    |> maybe_add_terminal_status(node_dir, events)
    |> maybe_add_stderr(node_dir)
    |> finalize()
  end

  @spec insert([entry()], map()) :: {non_neg_integer(), entry()} | nil
  def insert(entries, event) do
    case event_entry(event) do
      nil ->
        nil

      new_entry ->
        case Enum.find_index(entries, &(&1.id == new_entry.id)) do
          nil ->
            {length(entries), new_entry}

          idx ->
            existing = Enum.at(entries, idx)
            {idx, merge_existing(existing, new_entry)}
        end
    end
  end

  defp new_acc, do: %{by_id: %{}, ids_rev: []}

  defp finalize(%{by_id: by_id, ids_rev: ids_rev}) do
    ids_rev
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(by_id, &1))
  end

  defp upsert(acc, nil), do: acc

  defp upsert(%{by_id: by_id, ids_rev: ids_rev} = acc, %{id: id} = entry) do
    case Map.get(by_id, id) do
      nil ->
        %{acc | by_id: Map.put(by_id, id, entry), ids_rev: [id | ids_rev]}

      existing ->
        %{acc | by_id: Map.put(by_id, id, merge_existing(existing, entry))}
    end
  end

  # Put without merging — used by file-based synthetic fallbacks (response.md,
  # stderr.log, terminal status.json) where the file content is authoritative
  # and should replace any chunk-derived entry under the same id.
  defp put(%{by_id: by_id, ids_rev: ids_rev} = acc, %{id: id} = entry) do
    if Map.has_key?(by_id, id) do
      %{acc | by_id: Map.put(by_id, id, entry)}
    else
      %{acc | by_id: Map.put(by_id, id, entry), ids_rev: [id | ids_rev]}
    end
  end

  defp maybe_add_prompt(acc, node_dir, events, static_prompt) do
    # Prefer the on-disk prompt (post-interpolation) once the node has run;
    # fall back to the static template from the DOT source so pending nodes
    # still surface their prompt to the sidebar.
    case {read_text(node_dir, "prompt.md"), static_prompt} do
      {"", nil} ->
        acc

      {"", ""} ->
        acc

      {prompt, _static} when prompt != "" ->
        upsert(acc, prompt_entry(prompt, node_started_ts(events) || first_event_ts(events)))

      {"", static} when is_binary(static) ->
        upsert(acc, prompt_entry(static, nil))
    end
  end

  defp prompt_entry(prompt, ts) do
    %{
      id: "prompt",
      ts: ts,
      seq: -2,
      type: :prompt,
      title: "Prompt",
      summary: one_line(prompt),
      body: prompt,
      collapsed_by_default?: true,
      tone: :neutral
    }
  end

  defp add_event_entries(acc, events) do
    Enum.reduce(events, acc, fn event, acc -> upsert(acc, event_entry(event)) end)
  end

  defp maybe_add_response(acc, node_dir, events) do
    response = read_text(node_dir, "response.md")
    chunks = response_chunks(events)

    cond do
      response != "" ->
        put(acc, response_entry(response, response_ts(events), response_seq(events)))

      chunks != "" and not Map.has_key?(acc.by_id, "response") ->
        put(acc, response_entry(chunks, response_ts(events), response_seq(events)))

      true ->
        acc
    end
  end

  defp maybe_add_stderr(%{by_id: by_id} = acc, node_dir) do
    if Map.has_key?(by_id, "stderr") do
      acc
    else
      case read_text(node_dir, "stderr.log") do
        "" ->
          acc

        stderr ->
          upsert(acc, %{
            id: "stderr",
            ts: nil,
            seq: 1_000_000,
            type: :stderr,
            title: "stderr",
            summary: one_line(stderr),
            body: tail(stderr),
            collapsed_by_default?: true,
            tone: :accent
          })
      end
    end
  end

  defp stderr_entry(event, text) do
    %{
      id: "stderr",
      ts: parse_ts(event["ts"]),
      seq: event["seq"],
      type: :stderr,
      title: "stderr",
      summary: one_line(text),
      body: text,
      collapsed_by_default?: true,
      tone: :accent
    }
  end

  defp stdout_entry(event, text) do
    %{
      id: "stdout-#{event["seq"]}",
      ts: parse_ts(event["ts"]),
      seq: event["seq"],
      type: :stdout,
      title: "stdout",
      summary: one_line(text),
      body: text,
      collapsed_by_default?: true,
      tone: :muted
    }
  end

  defp acp_entry(event, title, summary, data) do
    %{
      id: "acp-#{event["seq"]}",
      ts: parse_ts(event["ts"]),
      seq: event["seq"],
      type: :acp,
      title: title,
      summary: summary,
      body: display_data(data),
      collapsed_by_default?: true,
      tone: :accent
    }
  end

  defp maybe_add_terminal_status(acc, node_dir, events) do
    # If the event stream already has a node_succeeded / node_failed entry,
    # trust that and skip the synthesized status.json fallback — otherwise
    # the sidebar renders two "node succeeded" rows.
    if has_terminal_event?(events) do
      acc
    else
      status = read_json(node_dir, "status.json")

      case normalize_terminal_status(status["status"]) do
        nil ->
          acc

        {state, tone} ->
          upsert(acc, %{
            id: "lifecycle-status",
            ts: parse_ts(status["finished_at"]) || last_event_ts(events),
            seq: 1_000_001,
            type: :lifecycle,
            title: "Lifecycle",
            summary: "node #{state}",
            body: status,
            collapsed_by_default?: true,
            tone: tone
          })
      end
    end
  end

  defp has_terminal_event?(events) do
    Enum.any?(events, fn event ->
      event["kind"] in ["node_succeeded", "node_failed", "parallel_completed"]
    end)
  end

  defp event_entry(%{"kind" => "agent_message_chunk"} = event) do
    text = text_data(event)
    response_entry(text, parse_ts(event["ts"]), event["seq"])
  end

  defp event_entry(%{"kind" => "agent_thought_chunk"} = event) do
    text = text_data(event)

    %{
      id: "thinking-#{event["seq"]}",
      ts: parse_ts(event["ts"]),
      seq: event["seq"],
      type: :thinking,
      title: "Thinking",
      summary: one_line(text),
      body: text,
      collapsed_by_default?: true,
      tone: :muted
    }
  end

  defp event_entry(%{"kind" => "stderr_chunk", "data" => data} = event) do
    stderr_entry(event, data["text"] || "")
  end

  defp event_entry(%{"kind" => "acp_stdout_line", "data" => data} = event) do
    stdout_entry(event, data["text"] || "")
  end

  defp event_entry(%{"kind" => "acp_unknown_update", "data" => data} = event) do
    kind = data["updateKind"] || "unknown"
    acp_entry(event, "ACP", "unknown update #{kind}", data)
  end

  defp event_entry(%{"kind" => "acp_unknown_message", "data" => data} = event) do
    method = data["method"] || "message"
    acp_entry(event, "ACP", "unknown #{method}", data)
  end

  defp event_entry(%{"kind" => "tool_call", "data" => data} = event) do
    tool_call_entry(event, data)
  end

  defp event_entry(%{"kind" => "tool_call_update", "data" => data} = event) do
    id = tool_call_id(data) || event["seq"]

    %{
      id: "tool-#{id}",
      ts: parse_ts(event["ts"]),
      seq: event["seq"],
      type: :tool_call_update,
      title: "[TOOL] update",
      summary: "tool update #{id}",
      body: %{"call" => nil, "updates" => [display_data(data)]},
      collapsed_by_default?: true,
      tone: :neutral
    }
  end

  defp event_entry(%{"kind" => kind, "data" => data} = event)
       when kind in ["usage", "token_usage"] do
    total = data["total_tokens"] || data[:total_tokens]

    %{
      id: "usage-#{event["seq"]}",
      ts: parse_ts(event["ts"]),
      seq: event["seq"],
      type: :usage,
      title: "Usage",
      summary: usage_summary(total),
      body: data,
      collapsed_by_default?: true,
      tone: :muted
    }
  end

  defp event_entry(%{"kind" => "iteration_started", "data" => data} = event) do
    iteration = data["iteration"]

    %{
      id: "iteration-#{iteration}",
      ts: parse_ts(event["ts"]),
      seq: event["seq"],
      type: :iteration_header,
      title: "Iteration",
      summary: "Iteration #{iteration} started",
      body: data,
      collapsed_by_default?: true,
      tone: :muted
    }
  end

  defp event_entry(%{"kind" => "judge_verdict", "data" => data} = event) do
    verdict = data["verdict"] || "unknown"
    critique = data["critique"] || ""

    %{
      id: "verdict-#{event["seq"]}",
      ts: parse_ts(event["ts"]),
      seq: event["seq"],
      type: :verdict,
      title: "Verdict",
      summary: "#{verdict}: #{one_line(critique)}",
      body: critique,
      collapsed_by_default?: false,
      tone: verdict_tone(verdict)
    }
  end

  defp event_entry(%{"kind" => "tool_invoked", "data" => data} = event) do
    command = data["command"] || []
    exit_status = data["exit_status"]

    %{
      id: "tool-runtime-#{event["seq"]}",
      ts: parse_ts(event["ts"]),
      seq: event["seq"],
      type: :tool_runtime,
      title: "[TOOL] invoked",
      summary: "#{Enum.join(command, " ")} (exit #{exit_status})",
      body: display_data(data),
      collapsed_by_default?: true,
      tone: if(exit_status in [0, nil], do: :neutral, else: :accent)
    }
  end

  defp event_entry(%{"kind" => "tool_output_truncated", "data" => data} = event) do
    stream = data["stream"] || "stdout"
    limit = data["limit"] || "?"

    %{
      id: "tool-runtime-#{event["seq"]}",
      ts: parse_ts(event["ts"]),
      seq: event["seq"],
      type: :tool_runtime,
      title: "[TOOL] output truncated",
      summary: "#{stream} limited to #{limit} bytes",
      body: display_data(data),
      collapsed_by_default?: true,
      tone: :accent
    }
  end

  defp event_entry(%{"kind" => "wait_human_pending", "data" => data} = event) do
    labels = data["outgoing_labels"] || []
    prompt = data["wait_prompt"] || "human decision required"

    %{
      id: "wait-runtime-#{event["seq"]}",
      ts: parse_ts(event["ts"]),
      seq: event["seq"],
      type: :wait_runtime,
      title: "[WAIT] pending",
      summary: "#{prompt} (#{Enum.join(labels, ", ")})",
      body: display_data(data),
      collapsed_by_default?: false,
      tone: :accent
    }
  end

  defp event_entry(%{"kind" => "wait_human_resolved", "data" => data} = event) do
    label = data["label"] || "?"
    source = data["source"] || "operator"

    %{
      id: "wait-runtime-#{event["seq"]}",
      ts: parse_ts(event["ts"]),
      seq: event["seq"],
      type: :wait_runtime,
      title: "[WAIT] resolved",
      summary: "#{label} via #{source}",
      body: display_data(data),
      collapsed_by_default?: true,
      tone: :success
    }
  end

  defp event_entry(%{"kind" => kind} = event)
       when kind in [
              "node_started",
              "node_succeeded",
              "node_failed",
              "parallel_started",
              "parallel_completed",
              "branch_started",
              "branch_settled"
            ] do
    %{
      id: "lifecycle-#{kind}-#{event["seq"]}",
      ts: parse_ts(event["ts"]),
      seq: event["seq"],
      type: :lifecycle,
      title: "Lifecycle",
      summary: String.replace(kind, "_", " "),
      body: display_data(event["data"] || %{}),
      collapsed_by_default?: true,
      tone: lifecycle_tone(kind)
    }
  end

  defp event_entry(_event), do: nil

  defp tool_call_entry(event, data) do
    {tag, summary} = ToolCallFormatter.format(data)
    id = tool_call_id(data) || event["seq"]

    %{
      id: "tool-#{id}",
      ts: parse_ts(event["ts"]),
      seq: event["seq"],
      type: :tool_call,
      title: tag,
      summary: summary,
      body: %{"call" => display_data(data), "updates" => []},
      collapsed_by_default?: not exec_tool?(data),
      tone: :neutral
    }
  end

  # Bash/shell/execute tool calls are the most action-relevant for an observer
  # to scan at a glance, so they default to expanded. Read/edit/write/grep/etc.
  # stay collapsed.
  defp exec_tool?(%{"kind" => kind}) when kind in ["bash", "execute", "shell"], do: true
  defp exec_tool?(_data), do: false

  defp response_entry(text, ts, seq) do
    %{
      id: "response",
      ts: ts,
      seq: seq,
      type: :response,
      title: "Response",
      summary: one_line(text),
      body: text,
      collapsed_by_default?: false,
      tone: :neutral
    }
  end

  # Merge a freshly-built entry into the existing one for the same id. Keeps
  # the existing entry's identity (id/position) and folds in fields from the
  # new one — body deltas for streamed types, update lists for tool calls.
  defp merge_existing(%{type: :response} = existing, %{type: :response} = new) do
    body = existing.body <> new.body
    %{existing | body: body, summary: response_summary(new.summary, body)}
  end

  defp merge_existing(%{type: :stderr} = existing, %{type: :stderr} = new) do
    body = existing.body <> new.body
    %{existing | body: body, summary: one_line(body), ts: new.ts || existing.ts}
  end

  defp merge_existing(%{body: %{"updates" => updates}} = existing, %{
         type: :tool_call_update,
         body: %{"updates" => new_updates}
       }) do
    %{existing | body: Map.put(existing.body, "updates", updates ++ new_updates)}
  end

  defp merge_existing(_existing, new), do: new

  defp response_summary(summary, body) do
    case String.split(summary || "", ": ", parts: 2) do
      [source, _text] -> "#{source}: #{one_line(body)}"
      _other -> one_line(body)
    end
  end

  defp read_events(node_dir) do
    path = Path.join(node_dir, "events.jsonl")

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
    else
      []
    end
  end

  defp read_text(node_dir, name) do
    path = Path.join(node_dir, name)
    if File.exists?(path), do: File.read!(path), else: ""
  end

  defp read_json(node_dir, name) do
    path = Path.join(node_dir, name)

    if File.exists?(path) do
      path |> File.read!() |> Jason.decode!()
    else
      %{}
    end
  end

  defp response_chunks(events) do
    events
    |> Enum.filter(&(&1["kind"] == "agent_message_chunk"))
    |> Enum.map_join("", &text_data/1)
  end

  defp response_ts(events) do
    events
    |> Enum.find(&(&1["kind"] == "agent_message_chunk"))
    |> case do
      nil -> nil
      event -> parse_ts(event["ts"])
    end
  end

  defp response_seq(events) do
    events
    |> Enum.find(&(&1["kind"] == "agent_message_chunk"))
    |> case do
      nil -> nil
      event -> event["seq"]
    end
  end

  defp node_started_ts(events) do
    events
    |> Enum.find(&(&1["kind"] == "node_started"))
    |> case do
      nil -> nil
      event -> parse_ts(event["ts"])
    end
  end

  defp first_event_ts([]), do: nil
  defp first_event_ts(events), do: events |> List.first() |> Map.get("ts") |> parse_ts()

  defp last_event_ts([]), do: nil
  defp last_event_ts(events), do: events |> List.last() |> Map.get("ts") |> parse_ts()

  defp parse_ts(nil), do: nil

  defp parse_ts(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp text_data(event), do: get_in(event, ["data", "text"]) || ""
  defp tool_call_id(data), do: data["toolCallId"] || data["id"]

  defp normalize_terminal_status(status) when status in ["ok", "success", "partial_success"],
    do: {"succeeded", :success}

  defp normalize_terminal_status(status) when status in ["error", "failed"],
    do: {"failed", :failure}

  defp normalize_terminal_status(_status), do: nil

  defp lifecycle_tone("node_succeeded"), do: :success
  defp lifecycle_tone("parallel_completed"), do: :success
  defp lifecycle_tone("node_failed"), do: :failure
  defp lifecycle_tone(_kind), do: :muted

  defp verdict_tone("accept"), do: :success
  defp verdict_tone("reject"), do: :accent
  defp verdict_tone(_verdict), do: :muted

  defp usage_summary(nil), do: "usage updated"
  defp usage_summary(total), do: "#{Format.token_count(total)} tokens"

  defp one_line(text) do
    text
    |> Format.sanitize_text(printable_limit: @display_string_limit)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> Format.truncate(100)
  end

  defp tail(text) do
    text
    |> Format.sanitize_text(printable_limit: @display_string_limit)
    |> String.split("\n")
    |> Enum.take(-80)
    |> Enum.join("\n")
  end

  defp display_data(value) when is_binary(value), do: display_text(value)

  defp display_data(value) when is_map(value) do
    value
    |> Enum.take(@display_map_limit)
    |> Map.new(fn {key, child} -> {key, display_data(child)} end)
    |> maybe_put_omitted(map_size(value), @display_map_limit)
  end

  defp display_data(value) when is_list(value) do
    displayed = value |> Enum.take(@display_list_limit) |> Enum.map(&display_data/1)
    maybe_append_omitted(displayed, length(value), @display_list_limit)
  end

  defp display_data(value), do: value

  defp display_text(text) do
    text = Format.sanitize_text(text, printable_limit: @display_string_limit)

    if byte_size(text) <= @display_string_limit do
      text
    else
      truncate_display_text(text)
    end
  end

  defp truncate_display_text(text) do
    omitted = byte_size(text) - @display_string_limit

    Format.truncate(text, @display_string_limit) <>
      "\n\n[truncated #{omitted} bytes for browser display; full event is in events.jsonl]"
  end

  defp maybe_put_omitted(map, size, limit) when size > limit do
    Map.put(map, "__tractor_omitted__", "#{size - limit} map entries omitted for browser display")
  end

  defp maybe_put_omitted(map, _size, _limit), do: map

  defp maybe_append_omitted(list, size, limit) when size > limit do
    list ++ ["#{size - limit} list entries omitted for browser display"]
  end

  defp maybe_append_omitted(list, _size, _limit), do: list
end
