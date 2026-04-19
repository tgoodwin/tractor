defmodule TractorWeb.RunLive.Show do
  @moduledoc false

  use Phoenix.LiveView

  alias Tractor.{Run, RunBus}
  alias TractorWeb.GraphRenderer

  embed_templates("../templates/run_live/*")

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    socket =
      socket
      |> assign(run_id: run_id, graph_svg: "", node_states: %{}, selected_node_id: nil)
      |> assign(prompt: "", response: "", stderr: "", tool_groups: %{})
      |> stream(:message_chunks, [])
      |> stream(:thought_chunks, [])

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
      |> maybe_insert_selected_event(node_id, event)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_node", %{"node-id" => node_id}, socket) do
    {:noreply, select_node(socket, node_id)}
  end

  defp select_node(socket, nil), do: socket

  defp select_node(%{assigns: %{run_dir: run_dir}} = socket, node_id) do
    events = read_events(run_dir, node_id)

    socket
    |> assign(
      selected_node_id: node_id,
      prompt: read_file(run_dir, node_id, "prompt.md"),
      response: read_file(run_dir, node_id, "response.md"),
      stderr: read_file(run_dir, node_id, "stderr.log"),
      tool_groups: group_tools(events)
    )
    |> stream(:message_chunks, event_stream(events, "agent_message_chunk"), reset: true)
    |> stream(:thought_chunks, event_stream(events, "agent_thought_chunk"), reset: true)
    |> push_event("graph:selected", %{node_id: node_id})
  end

  defp maybe_insert_selected_event(
         %{assigns: %{selected_node_id: node_id}} = socket,
         node_id,
         event
       ) do
    case event["kind"] do
      "agent_message_chunk" ->
        stream_insert(socket, :message_chunks, stream_item(event))

      "agent_thought_chunk" ->
        stream_insert(socket, :thought_chunks, stream_item(event))

      "tool_call" ->
        update(socket, :tool_groups, &merge_tool_event(&1, event))

      "tool_call_update" ->
        update(socket, :tool_groups, &merge_tool_event(&1, event))

      _other ->
        socket
    end
  end

  defp maybe_insert_selected_event(socket, _node_id, _event), do: socket

  defp load_node_states(pipeline, run_dir) do
    Map.new(pipeline.nodes, fn {node_id, _node} ->
      {node_id, read_status(run_dir, node_id)}
    end)
  end

  defp read_status(run_dir, node_id) do
    path = Path.join([run_dir, node_id, "status.json"])

    if File.exists?(path) do
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.get("status", "pending")
      |> normalize_status()
    else
      "pending"
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

  defp push_graph_node_state(socket, node_id, nil), do: push_graph_node_state(socket, node_id, "pending")

  defp push_graph_node_state(socket, node_id, state) do
    push_event(socket, "graph:node_state", %{node_id: node_id, state: state})
  end

  defp normalize_status("ok"), do: "succeeded"
  defp normalize_status("success"), do: "succeeded"
  defp normalize_status("partial_success"), do: "succeeded"
  defp normalize_status("error"), do: "failed"
  defp normalize_status("failed"), do: "failed"
  defp normalize_status("running"), do: "running"
  defp normalize_status(_status), do: "pending"

  defp read_events(run_dir, node_id) do
    path = Path.join([run_dir, node_id, "events.jsonl"])

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
    else
      []
    end
  end

  defp event_stream(events, kind) do
    events
    |> Enum.filter(&(&1["kind"] == kind))
    |> Enum.map(&stream_item/1)
  end

  defp stream_item(event) do
    %{
      id: "#{event["kind"]}-#{event["seq"]}",
      text: get_in(event, ["data", "text"]) || inspect(event["data"])
    }
  end

  defp group_tools(events) do
    events
    |> Enum.filter(&(&1["kind"] in ["tool_call", "tool_call_update"]))
    |> Enum.reduce(%{}, &merge_tool_event(&2, &1))
  end

  defp merge_tool_event(groups, event) do
    id = get_in(event, ["data", "toolCallId"]) || "unknown"
    Map.update(groups, id, [event], &(&1 ++ [event]))
  end

  defp read_file(run_dir, node_id, name) do
    path = Path.join([run_dir, node_id, name])
    if File.exists?(path), do: File.read!(path), else: ""
  end

  defp first_node_id(pipeline) do
    pipeline.nodes
    |> Map.keys()
    |> Enum.sort()
    |> List.first()
  end

  defp apply_node_states(svg, node_states) do
    Enum.reduce(node_states, svg, fn {node_id, state}, svg ->
      Regex.replace(
        ~r/(<g[^>]*class="[^"]*)(?="[^>]*data-node-id="#{Regex.escape(node_id)}")/,
        svg,
        "\\1 #{state}"
      )
    end)
  end
end
