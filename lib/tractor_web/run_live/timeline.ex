defmodule TractorWeb.RunLive.Timeline do
  @moduledoc """
  Builds and updates the observer sidebar timeline.
  """

  alias TractorWeb.{Format, ToolCallFormatter}

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

  @spec from_disk(Path.t(), String.t(), keyword()) :: [entry()]
  def from_disk(run_dir, node_id, opts \\ []) do
    node_dir = Path.join(run_dir, node_id)
    events = read_events(node_dir)
    static_prompt = Keyword.get(opts, :static_prompt)

    []
    |> maybe_add_prompt(node_dir, events, static_prompt)
    |> add_event_entries(events)
    |> maybe_add_response(node_dir, events)
    |> maybe_add_stderr(node_dir)
    |> maybe_add_terminal_status(node_dir, events)
    |> sort_entries()
  end

  @spec insert([entry()], map()) :: {non_neg_integer(), entry()} | nil
  def insert(entries, event) do
    case merge_event_entry(entries, event) do
      nil ->
        nil

      entry ->
        entries = upsert_entry(entries, entry)
        {position(entries, entry.id), entry}
    end
  end

  defp maybe_add_prompt(entries, node_dir, events, static_prompt) do
    # Prefer the on-disk prompt (post-interpolation) once the node has run;
    # fall back to the static template from the DOT source so pending nodes
    # still surface their prompt to the sidebar.
    case {read_text(node_dir, "prompt.md"), static_prompt} do
      {"", nil} ->
        entries

      {"", ""} ->
        entries

      {prompt, _static} when prompt != "" ->
        [prompt_entry(prompt, node_started_ts(events) || first_event_ts(events)) | entries]

      {"", static} when is_binary(static) ->
        [prompt_entry(static, nil) | entries]
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

  defp add_event_entries(entries, events) do
    events
    |> Enum.reduce(entries, fn event, entries ->
      case event_entry(event) do
        nil -> entries
        entry -> upsert_entry(entries, merge_with_existing(entry, entries, event))
      end
    end)
  end

  defp maybe_add_response(entries, node_dir, events) do
    response = read_text(node_dir, "response.md")
    chunks = response_chunks(events)

    cond do
      response != "" ->
        upsert_entry(entries, response_entry(response, response_ts(events), response_seq(events)))

      chunks != "" ->
        upsert_entry(entries, response_entry(chunks, response_ts(events), response_seq(events)))

      true ->
        entries
    end
  end

  defp maybe_add_stderr(entries, node_dir) do
    case read_text(node_dir, "stderr.log") do
      "" ->
        entries

      stderr ->
        [
          %{
            id: "stderr",
            ts: nil,
            seq: 1_000_000,
            type: :stderr,
            title: "stderr",
            summary: one_line(stderr),
            body: tail(stderr),
            collapsed_by_default?: true,
            tone: :accent
          }
          | entries
        ]
    end
  end

  defp maybe_add_terminal_status(entries, node_dir, events) do
    # If the event stream already has a node_succeeded / node_failed entry,
    # trust that and skip the synthesized status.json fallback — otherwise
    # the sidebar renders two "node succeeded" rows.
    if has_terminal_event?(events) do
      entries
    else
      status = read_json(node_dir, "status.json")

      case normalize_terminal_status(status["status"]) do
        nil ->
          entries

        {state, tone} ->
          [
            %{
              id: "lifecycle-status",
              ts: parse_ts(status["finished_at"]) || last_event_ts(events),
              seq: 1_000_001,
              type: :lifecycle,
              title: "Lifecycle",
              summary: "node #{state}",
              body: status,
              collapsed_by_default?: true,
              tone: tone
            }
            | entries
          ]
      end
    end
  end

  defp has_terminal_event?(events) do
    Enum.any?(events, fn event ->
      event["kind"] in ["node_succeeded", "node_failed", "parallel_completed"]
    end)
  end

  defp merge_event_entry(entries, event) do
    event
    |> event_entry()
    |> merge_with_existing(entries, event)
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
      body: %{"call" => nil, "updates" => [data]},
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
      summary: "Iteration #{iteration}",
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
      body: data,
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
      body: data,
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
      body: data,
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
      body: data,
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
      body: event["data"] || %{},
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
      body: %{"call" => data, "updates" => []},
      collapsed_by_default?: true,
      tone: :neutral
    }
  end

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

  defp merge_with_existing(nil, _entries, _event), do: nil

  defp merge_with_existing(%{id: "response"} = entry, entries, _event) do
    case Enum.find(entries, &(&1.id == "response")) do
      nil ->
        entry

      existing ->
        body = existing.body <> entry.body
        %{existing | body: body, summary: one_line(body)}
    end
  end

  defp merge_with_existing(%{type: :tool_call_update, id: id} = entry, entries, _event) do
    case Enum.find(entries, &(&1.id == id)) do
      nil ->
        entry

      existing ->
        updates = get_in(existing, [:body, "updates"]) || []
        update = entry.body["updates"] |> List.first()
        body = Map.put(existing.body, "updates", updates ++ [update])
        %{existing | body: body}
    end
  end

  defp merge_with_existing(entry, _entries, _event), do: entry

  defp sort_entries(entries) do
    Enum.sort_by(entries, &sort_key/1)
  end

  defp upsert_entry(entries, nil), do: entries

  defp upsert_entry(entries, %{id: id} = entry) do
    entries
    |> Enum.reject(&(&1.id == id))
    |> Kernel.++([entry])
    |> sort_entries()
  end

  defp position(entries, id) do
    Enum.find_index(entries, &(&1.id == id)) || length(entries)
  end

  defp sort_key(entry) do
    ts =
      case entry.ts do
        %DateTime{} = datetime -> DateTime.to_unix(datetime, :microsecond)
        nil -> 9_999_999_999_999_999
      end

    {ts, entry.seq || 0, entry.id}
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
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> Format.truncate(100)
  end

  defp tail(text) do
    text
    |> String.split("\n")
    |> Enum.take(-80)
    |> Enum.join("\n")
  end
end
