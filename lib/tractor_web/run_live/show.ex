defmodule TractorWeb.RunLive.Show do
  @moduledoc false

  use Phoenix.LiveView

  alias Tractor.{Run, RunBus}
  alias TractorWeb.{Format, GraphRenderer}
  alias TractorWeb.RunLive.Timeline

  embed_templates("../templates/run_live/*")

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    socket =
      socket
      |> assign(
        run_id: run_id,
        graph_svg: "",
        node_states: %{},
        selected_node_id: nil,
        show_help?: false,
        timeline_entries: []
      )
      |> stream(:timeline, [])

    case Run.info(run_id) do
      {:ok, %{pipeline: pipeline, run_dir: run_dir}} ->
        if connected?(socket), do: RunBus.subscribe(run_id)

        {:ok, svg} = GraphRenderer.render(pipeline)
        node_states = load_node_states(pipeline, run_dir)
        selected = first_node_id(pipeline)

        {:ok,
         socket
         |> assign(pipeline: pipeline, run_dir: run_dir, graph_svg: svg, node_states: node_states)
         |> push_graph_node_states(node_states)
         |> push_all_graph_badges(pipeline, run_dir, node_states)
         |> select_node(selected)}

      {:error, _reason} ->
        {:ok, assign(socket, missing?: true)}
    end
  end

  @impl true
  def render(assigns), do: show(assigns)

  @impl true
  def handle_info({:run_event, node_id, event}, socket) do
    node_states = update_node_state(socket.assigns.node_states, node_id, event["kind"])

    socket =
      socket
      |> assign(:node_states, node_states)
      |> push_graph_node_state(node_id, Map.get(node_states, node_id))
      |> maybe_push_graph_badges(node_id, event["kind"])
      |> maybe_insert_selected_event(node_id, event)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_node", %{"node-id" => node_id}, socket) do
    {:noreply, select_node(socket, node_id)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply,
     socket
     |> assign(selected_node_id: nil, timeline_entries: [])
     |> stream(:timeline, [], reset: true)
     |> push_event("graph:selected", %{node_id: nil})}
  end

  def handle_event("toggle_help", _params, socket) do
    {:noreply, update(socket, :show_help?, &(!&1))}
  end

  defp select_node(socket, nil), do: socket

  defp select_node(%{assigns: %{run_dir: run_dir}} = socket, node_id) do
    entries = Timeline.from_disk(run_dir, node_id)

    socket
    |> assign(selected_node_id: node_id, timeline_entries: entries)
    |> stream(:timeline, entries, reset: true)
    |> push_event("graph:selected", %{node_id: node_id})
  end

  defp maybe_insert_selected_event(
         %{assigns: %{selected_node_id: node_id}} = socket,
         node_id,
         event
       ) do
    case Timeline.insert(socket.assigns.timeline_entries, event) do
      nil ->
        socket

      {position, entry} ->
        entries =
          socket.assigns.timeline_entries
          |> Enum.reject(&(&1.id == entry.id))
          |> List.insert_at(position, entry)

        socket
        |> assign(:timeline_entries, entries)
        |> stream_insert(:timeline, entry, at: position)
    end
  end

  defp maybe_insert_selected_event(socket, _node_id, _event), do: socket

  defp load_node_states(pipeline, run_dir) do
    Map.new(pipeline.nodes, fn {node_id, _node} ->
      {node_id, read_status(run_dir, node_id)}
    end)
  end

  defp read_status(run_dir, node_id) do
    run_dir
    |> read_status_json(node_id)
    |> Map.get("status", "pending")
    |> normalize_status()
  end

  defp read_status_json(run_dir, node_id) do
    path = Path.join([run_dir, node_id, "status.json"])

    if File.exists?(path) do
      path
      |> File.read!()
      |> Jason.decode!()
    else
      %{}
    end
  end

  defp update_node_state(states, node_id, "node_started"), do: Map.put(states, node_id, "running")

  defp update_node_state(states, node_id, "node_succeeded"),
    do: Map.put(states, node_id, "succeeded")

  defp update_node_state(states, node_id, "node_failed"), do: Map.put(states, node_id, "failed")

  defp update_node_state(states, node_id, "parallel_started"),
    do: Map.put(states, node_id, "running")

  defp update_node_state(states, node_id, "parallel_completed"),
    do: Map.put(states, node_id, "succeeded")

  defp update_node_state(states, _node_id, _kind), do: states

  defp push_graph_node_states(socket, node_states) do
    Enum.reduce(node_states, socket, fn {node_id, state}, socket ->
      push_graph_node_state(socket, node_id, state)
    end)
  end

  defp push_graph_node_state(socket, node_id, nil),
    do: push_graph_node_state(socket, node_id, "pending")

  defp push_graph_node_state(socket, node_id, state) do
    push_event(socket, "graph:node_state", %{node_id: node_id, state: state})
  end

  defp push_all_graph_badges(socket, pipeline, run_dir, node_states) do
    Enum.reduce(pipeline.nodes, socket, fn {node_id, _node}, socket ->
      push_graph_badges(socket, node_id, run_dir, Map.get(node_states, node_id))
    end)
  end

  defp maybe_push_graph_badges(socket, node_id, kind)
       when kind in ["node_succeeded", "node_failed", "parallel_completed"] do
    state = Map.get(socket.assigns.node_states, node_id)
    push_graph_badges(socket, node_id, socket.assigns.run_dir, state)
  end

  defp maybe_push_graph_badges(socket, _node_id, _kind), do: socket

  defp push_graph_badges(socket, node_id, run_dir, state) do
    push_event(socket, "graph:badges", badge_payload(run_dir, node_id, state))
  end

  defp badge_payload(run_dir, node_id, state) do
    status = read_status_json(run_dir, node_id)

    %{
      node_id: node_id,
      state: state || "pending",
      duration: duration_badge(run_dir, node_id, status),
      tokens: token_badge(status)
    }
  end

  defp duration_badge(run_dir, node_id, status) do
    started_at = parse_time(status["started_at"]) || node_started_at(run_dir, node_id)
    finished_at = parse_time(status["finished_at"])

    if started_at && finished_at do
      finished_at
      |> DateTime.diff(started_at, :millisecond)
      |> Format.duration_ms()
    end
  end

  defp token_badge(status) do
    case get_in(status, ["token_usage", "total_tokens"]) do
      nil -> nil
      tokens -> Format.token_count(tokens)
    end
  end

  defp node_started_at(run_dir, node_id) do
    run_dir
    |> read_node_events(node_id)
    |> Enum.find(&(&1["kind"] == "node_started"))
    |> case do
      nil -> nil
      event -> parse_time(get_in(event, ["data", "started_at"])) || parse_time(event["ts"])
    end
  end

  defp read_node_events(run_dir, node_id) do
    path = Path.join([run_dir, node_id, "events.jsonl"])

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
    else
      []
    end
  end

  defp normalize_status("ok"), do: "succeeded"
  defp normalize_status("success"), do: "succeeded"
  defp normalize_status("partial_success"), do: "succeeded"
  defp normalize_status("error"), do: "failed"
  defp normalize_status("failed"), do: "failed"
  defp normalize_status("running"), do: "running"
  defp normalize_status(_status), do: "pending"

  defp first_node_id(pipeline) do
    pipeline.nodes
    |> Map.keys()
    |> Enum.sort()
    |> List.first()
  end

  defp overall_status(node_states) do
    states = Map.values(node_states)

    cond do
      Enum.any?(states, &(&1 == "failed")) -> "failed"
      Enum.any?(states, &(&1 == "running")) -> "running"
      states != [] and Enum.all?(states, &(&1 == "succeeded")) -> "succeeded"
      true -> "pending"
    end
  end

  defp elapsed_label(nil), do: "elapsed n/a"

  defp elapsed_label(run_dir) do
    manifest_path = Path.join(run_dir, "manifest.json")

    with true <- File.exists?(manifest_path),
         {:ok, manifest} <- manifest_path |> File.read!() |> Jason.decode(),
         {:ok, started_at, _offset} <- DateTime.from_iso8601(manifest["started_at"]) do
      finished_at = parse_time(manifest["finished_at"]) || DateTime.utc_now()
      "elapsed " <> format_elapsed(DateTime.diff(finished_at, started_at, :millisecond))
    else
      _other -> "elapsed n/a"
    end
  end

  defp parse_time(nil), do: nil

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp format_elapsed(ms) when ms < 1_000, do: "#{max(ms, 0)}ms"
  defp format_elapsed(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"
  defp format_elapsed(ms), do: "#{div(ms, 60_000)}m#{rem(div(ms, 1_000), 60)}s"

  defp timeline_open?(entry), do: not entry.collapsed_by_default?

  defp timeline_aria_label(entry), do: "#{entry.title}: #{entry.summary}"

  defp timeline_time(%DateTime{} = datetime) do
    time = DateTime.to_time(datetime)
    {microsecond, _precision} = time.microsecond
    millisecond = div(microsecond, 1_000) |> Integer.to_string() |> String.pad_leading(3, "0")

    "#{Time.to_iso8601(%{time | microsecond: {0, 0}})}.#{millisecond}"
  end

  defp entry_body(body) when is_binary(body), do: body
  defp entry_body(body), do: Jason.encode!(body, pretty: true)

  defp node_pills(pipeline, node_id) do
    case pipeline.nodes[node_id] do
      %Tractor.Node{} = node ->
        []
        |> maybe_pill(node.llm_provider)
        |> maybe_pill(node.llm_model)
        |> maybe_pill(node.attrs["reasoning_effort"])
        |> Enum.reverse()

      _other ->
        []
    end
  end

  defp maybe_pill(acc, nil), do: acc
  defp maybe_pill(acc, ""), do: acc
  defp maybe_pill(acc, value), do: [value | acc]

  # Text-ish entry types render as markdown (preserves newlines, lists, code fences).
  # Structured types (tool calls, lifecycle, usage) keep the raw JSON presentation.
  defp render_entry_body(%{type: type, body: body})
       when type in [:prompt, :response, :thinking, :message, :stderr] and is_binary(body) do
    TractorWeb.Markdown.to_html(body)
  end

  defp render_entry_body(%{body: body}) do
    {:safe,
     [
       "<pre class=\"tractor-raw-json\">",
       body |> entry_body() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string(),
       "</pre>"
     ]}
  end
end
