defmodule TractorWeb.RunLive.Show do
  @moduledoc false

  use Phoenix.LiveView

  alias Tractor.{Run, RunBus}
  alias TractorWeb.GraphRenderer
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

  defp entry_body(body) when is_binary(body), do: body
  defp entry_body(body), do: Jason.encode!(body, pretty: true)
end
