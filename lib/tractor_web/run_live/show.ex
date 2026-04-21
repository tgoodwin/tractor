defmodule TractorWeb.RunLive.Show do
  @moduledoc false

  use Phoenix.LiveView

  alias Tractor.{Run, RunBus}
  alias TractorWeb.{Format, GraphRenderer, RunIndex}
  alias TractorWeb.RunLive.{StatusFeed, WaitForm}
  alias TractorWeb.RunLive.Timeline

  @runs_refresh_ms 5_000

  embed_templates("../templates/run_live/*")

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    socket =
      socket
      |> assign(
        run_id: run_id,
        graph_svg: "",
        node_states: %{},
        run_status: :unknown,
        run_total_cost_usd: "0",
        selected_node_id: nil,
        selected_node: nil,
        pending_waits: %{},
        show_help?: false,
        timeline_entries: [],
        latest_plans: %{},
        selected_plan: [],
        wait_form_error: nil,
        status_agent: "off",
        status_feed_empty?: true
      )
      |> stream(:timeline, [])
      |> stream(:status_updates, [])

    case resolve_run(run_id) do
      {:ok, %{pipeline: pipeline, run_dir: run_dir}} ->
        if connected?(socket) do
          RunBus.subscribe(run_id)
          :timer.send_interval(@runs_refresh_ms, :refresh_runs)
        end

        {:ok, svg} = GraphRenderer.render(pipeline)
        node_states = load_node_states(pipeline, run_dir)
        selected = first_node_id(pipeline)
        runs = list_runs(run_dir)
        status_agent = Map.get(pipeline.graph_attrs, "status_agent", "off")
        status_updates = load_status_updates(run_dir)
        latest_plans = load_latest_plans(pipeline, run_dir)
        run_meta = load_run_meta(run_dir)
        pending_waits = load_pending_waits(run_dir)

        {:ok,
         socket
         |> assign(
           pipeline: pipeline,
           run_dir: run_dir,
           graph_svg: svg,
           node_states: node_states,
           runs: runs,
           run_status: run_meta.status,
           run_total_cost_usd: run_meta.total_cost_usd,
           status_agent: status_agent,
           latest_plans: latest_plans,
           pending_waits: pending_waits,
           status_feed_empty?: status_updates == []
         )
         |> stream(:status_updates, status_updates, reset: true)
         |> push_graph_node_states(node_states)
         |> push_all_graph_badges(pipeline, run_dir, node_states)
         |> select_node(selected)}

      {:error, _reason} ->
        {:ok, assign(socket, missing?: true, runs: [])}
    end
  end

  defp list_runs(run_dir) do
    run_dir |> Path.dirname() |> RunIndex.list()
  end

  # Try the live registry first (a run that's still supervised by RunSup).
  # Fall back to reading the manifest + re-parsing the DOT for post-mortem
  # viewing of a run that finished (or crashed) before the page load.
  defp resolve_run(run_id) do
    case Run.info(run_id) do
      {:ok, info} ->
        {:ok, info}

      {:error, :run_not_found} ->
        load_from_disk(run_id)

      other ->
        other
    end
  end

  defp load_from_disk(run_id) do
    runs_dir = Path.join(Tractor.Paths.data_dir(), "runs")
    run_dir = Path.join(runs_dir, run_id)
    manifest_path = Path.join(run_dir, "manifest.json")

    with true <- File.dir?(run_dir),
         {:ok, raw} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(raw),
         pipeline_path when is_binary(pipeline_path) and pipeline_path != "" <-
           manifest["pipeline_path"],
         {:ok, pipeline} <- Tractor.DotParser.parse_file(pipeline_path) do
      {:ok, %{pipeline: pipeline, run_dir: run_dir}}
    else
      _ -> {:error, :run_not_found}
    end
  end

  @impl true
  def render(assigns), do: show(assigns)

  @impl true
  def handle_info(:refresh_runs, socket) do
    case socket.assigns[:run_dir] do
      nil ->
        {:noreply, socket}

      run_dir ->
        socket =
          socket
          |> assign(:runs, list_runs(run_dir))
          |> assign(:pending_waits, load_pending_waits(run_dir))
          |> maybe_refresh_selected_wait()

        {:noreply, socket}
    end
  end

  def handle_info({:run_event, node_id, event}, socket) do
    socket =
      if node_id == "_run" do
        refresh_run_meta(socket)
      else
        socket
      end

    node_states = update_node_state(socket.assigns.node_states, node_id, event)

    pending_waits =
      update_pending_waits(socket.assigns.pending_waits, socket.assigns.run_dir, node_id, event)

    socket =
      socket
      |> assign(:node_states, node_states)
      |> assign(:pending_waits, pending_waits)
      |> push_graph_node_state(node_id, Map.get(node_states, node_id))
      |> maybe_push_edge_taken(event)
      |> maybe_push_graph_badges(node_id, event["kind"])
      |> maybe_insert_status_update(node_id, event)
      |> maybe_update_plan(node_id, event)
      |> maybe_insert_selected_event(node_id, event)
      |> maybe_refresh_selected_node(node_id, event)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_node", %{"node-id" => node_id}, socket) do
    {:noreply, select_node(socket, node_id)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply,
     socket
     |> assign(
       selected_node_id: nil,
       selected_node: nil,
       timeline_entries: [],
       wait_form_error: nil
     )
     |> stream(:timeline, [], reset: true)
     |> push_event("graph:selected", %{node_id: nil})}
  end

  def handle_event("toggle_help", _params, socket) do
    {:noreply, update(socket, :show_help?, &(!&1))}
  end

  def handle_event("submit_wait_choice", %{"label" => label}, socket) do
    case socket.assigns.selected_node do
      %{id: node_id, type: "wait.human", state: "waiting"} ->
        case Run.submit_wait_choice(socket.assigns.run_id, node_id, label) do
          :ok ->
            {:noreply, assign(socket, :wait_form_error, nil)}

          {:error, {:invalid_wait_label, labels}} ->
            {:noreply,
             assign(
               socket,
               :wait_form_error,
               "Invalid choice. Expected one of: #{Enum.join(labels, ", ")}"
             )}

          {:error, :wait_not_pending} ->
            {:noreply, assign(socket, :wait_form_error, "Decision is no longer pending.")}

          {:error, reason} ->
            {:noreply,
             assign(socket, :wait_form_error, "Could not submit choice: #{inspect(reason)}")}
        end

      _other ->
        {:noreply, socket}
    end
  end

  defp select_node(socket, nil), do: socket

  defp select_node(%{assigns: assigns} = socket, node_id) do
    static_prompt =
      case assigns[:pipeline] do
        %Tractor.Pipeline{nodes: nodes} ->
          case Map.get(nodes, node_id) do
            %Tractor.Node{prompt: prompt} -> prompt
            _ -> nil
          end

        _ ->
          nil
      end

    entries = Timeline.from_disk(assigns.run_dir, node_id, static_prompt: static_prompt)

    socket
    |> assign(
      selected_node_id: node_id,
      selected_node: selected_node(assigns, node_id),
      timeline_entries: entries,
      selected_plan: Map.get(assigns.latest_plans, node_id, []),
      wait_form_error: nil
    )
    |> stream(:timeline, entries, reset: true)
    |> push_event("graph:selected", %{node_id: node_id})
  end

  defp maybe_insert_status_update(socket, "_run", %{"kind" => "status_update"} = event) do
    entry = status_update_entry(event)

    socket
    |> assign(:status_feed_empty?, false)
    |> stream_insert(:status_updates, entry, at: 0)
  end

  defp maybe_insert_status_update(socket, _node_id, _event), do: socket

  defp maybe_update_plan(socket, node_id, %{"kind" => "plan_update", "data" => data}) do
    entries = Map.get(data, "entries", [])
    latest_plans = Map.put(socket.assigns.latest_plans, node_id, entries)

    socket =
      assign(socket, :latest_plans, latest_plans)

    if socket.assigns.selected_node_id == node_id do
      assign(socket, :selected_plan, entries)
    else
      socket
    end
  end

  defp maybe_update_plan(socket, _node_id, _event), do: socket

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
    status = read_status_json(run_dir, node_id)

    case status["verdict"] do
      "reject" -> "rejected"
      "accept" -> "accepted"
      _ -> status |> Map.get("status", "pending") |> normalize_status()
    end
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

  defp update_node_state(states, node_id, %{"kind" => "node_started"}),
    do: Map.put(states, node_id, "running")

  defp update_node_state(states, node_id, %{"kind" => "wait_human_pending"}),
    do: Map.put(states, node_id, "waiting")

  defp update_node_state(states, node_id, %{"kind" => "wait_human_resolved"}),
    do: Map.put(states, node_id, "running")

  defp update_node_state(states, node_id, %{"kind" => "node_succeeded"}) do
    # Preserve a prior verdict-derived state (rejected/accepted) so a judge's
    # red/green state survives the node_succeeded that always follows.
    case Map.get(states, node_id) do
      "rejected" -> states
      "accepted" -> states
      _ -> Map.put(states, node_id, "succeeded")
    end
  end

  defp update_node_state(states, node_id, %{"kind" => "node_failed"}),
    do: Map.put(states, node_id, "failed")

  defp update_node_state(states, node_id, %{"kind" => "parallel_started"}),
    do: Map.put(states, node_id, "running")

  defp update_node_state(states, node_id, %{"kind" => "parallel_completed"}),
    do: Map.put(states, node_id, "succeeded")

  defp update_node_state(states, node_id, %{
         "kind" => "judge_verdict",
         "data" => %{"verdict" => "reject"}
       }),
       do: Map.put(states, node_id, "rejected")

  defp update_node_state(states, node_id, %{
         "kind" => "judge_verdict",
         "data" => %{"verdict" => "accept"}
       }),
       do: Map.put(states, node_id, "accepted")

  defp update_node_state(states, _node_id, _event), do: states

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
       when kind in ["node_succeeded", "node_failed", "parallel_completed", "wait_human_pending"] do
    state = Map.get(socket.assigns.node_states, node_id)
    push_graph_badges(socket, node_id, socket.assigns.run_dir, state)
  end

  defp maybe_push_graph_badges(socket, _node_id, _kind), do: socket

  defp maybe_push_edge_taken(socket, %{"kind" => "edge_taken", "data" => data}) do
    push_event(socket, "graph:edge_taken", data)
  end

  defp maybe_push_edge_taken(socket, _event), do: socket

  defp push_graph_badges(socket, node_id, run_dir, state) do
    push_event(socket, "graph:badges", badge_payload(run_dir, node_id, state))
  end

  defp badge_payload(run_dir, node_id, state) do
    status = read_status_json(run_dir, node_id)

    %{
      node_id: node_id,
      state: state || "pending",
      duration: duration_badge(run_dir, node_id, status),
      cumulative: cumulative_duration_badge(run_dir, node_id, status),
      tokens: token_badge(status),
      iterations: iteration_badge(status)
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

  defp iteration_badge(%{"iteration" => iteration}) when is_integer(iteration) and iteration >= 1,
    do: "×#{iteration}"

  defp iteration_badge(_status), do: nil

  # Sum all iterations/*/status.json durations so a looped node shows cumulative
  # time across every iteration. When only one iteration exists, we skip this
  # badge to avoid redundancy with the primary duration badge.
  defp cumulative_duration_badge(run_dir, node_id, status) do
    iteration = status["iteration"]

    if is_integer(iteration) and iteration > 1 do
      total =
        Path.join([run_dir, node_id, "iterations"])
        |> File.ls()
        |> case do
          {:ok, names} -> names
          _ -> []
        end
        |> Enum.map(&Path.join([run_dir, node_id, "iterations", &1, "status.json"]))
        |> Enum.map(&iteration_ms/1)
        |> Enum.sum()

      if total > 0, do: Format.duration_ms(total)
    end
  end

  defp iteration_ms(path) do
    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, status} <- Jason.decode(body),
         started when is_binary(started) <- status["started_at"],
         finished when is_binary(finished) <- status["finished_at"],
         {:ok, s, _} <- DateTime.from_iso8601(started),
         {:ok, f, _} <- DateTime.from_iso8601(finished) do
      DateTime.diff(f, s, :millisecond)
    else
      _ -> 0
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

  defp load_status_updates(run_dir) do
    run_dir
    |> read_node_events("_run")
    |> Enum.filter(&(&1["kind"] == "status_update"))
    |> Enum.reduce(%{}, fn event, acc ->
      entry = status_update_entry(event)
      Map.put(acc, entry.id, entry)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.sort_ts, {:desc, DateTime})
  end

  defp status_update_entry(%{"data" => data} = event) do
    timestamp = data["timestamp"] || event["ts"]
    id = data["status_update_id"] || "#{event["seq"]}"

    %{
      id: id,
      node_id: data["node_id"],
      iteration: data["iteration"],
      timestamp: timestamp,
      sort_ts: parse_time(timestamp) || DateTime.from_unix!(0),
      summary: data["summary"] || ""
    }
  end

  defp load_latest_plans(pipeline, run_dir) do
    Map.new(pipeline.nodes, fn {node_id, _node} ->
      plan =
        run_dir
        |> read_node_events(node_id)
        |> Enum.filter(&(&1["kind"] == "plan_update"))
        |> List.last()
        |> case do
          nil -> []
          event -> get_in(event, ["data", "entries"]) || []
        end

      {node_id, plan}
    end)
  end

  defp normalize_status("ok"), do: "succeeded"
  defp normalize_status("success"), do: "succeeded"
  defp normalize_status("partial_success"), do: "succeeded"
  defp normalize_status("error"), do: "failed"
  defp normalize_status("failed"), do: "failed"
  defp normalize_status("running"), do: "running"
  defp normalize_status("waiting"), do: "waiting"
  defp normalize_status(_status), do: "pending"

  defp load_pending_waits(run_dir) do
    checkpoint_path = Path.join(run_dir, "checkpoint.json")

    waiting =
      with true <- File.exists?(checkpoint_path),
           {:ok, raw} <- File.read(checkpoint_path),
           {:ok, checkpoint} <- Jason.decode(raw) do
        checkpoint["waiting"] || %{}
      else
        _other -> %{}
      end

    Map.reject(waiting, fn {node_id, _entry} ->
      wait_cleared?(read_node_events(run_dir, node_id))
    end)
  end

  defp wait_cleared?(events) do
    Enum.reduce(events, :unknown, fn event, state ->
      case event["kind"] do
        "wait_human_pending" -> :pending
        "wait_human_resolved" -> :cleared
        "node_succeeded" -> :cleared
        "node_failed" -> :cleared
        _other -> state
      end
    end) == :cleared
  end

  defp update_pending_waits(pending_waits, run_dir, node_id, %{"kind" => "wait_human_pending"}) do
    Map.put(pending_waits, node_id, read_status_json(run_dir, node_id))
  end

  defp update_pending_waits(pending_waits, _run_dir, node_id, %{"kind" => kind})
       when kind in ["wait_human_resolved", "node_succeeded", "node_failed"] do
    Map.delete(pending_waits, node_id)
  end

  defp update_pending_waits(pending_waits, _run_dir, _node_id, _event), do: pending_waits

  defp load_run_meta(run_dir) do
    status_path = Path.join(run_dir, "status.json")

    status =
      if File.exists?(status_path) do
        status_path
        |> File.read!()
        |> Jason.decode!()
      else
        %{}
      end

    %{
      status: run_status(status["status"]),
      total_cost_usd: status["total_cost_usd"] || "0"
    }
  end

  defp refresh_run_meta(%{assigns: %{run_dir: nil}} = socket), do: socket

  defp refresh_run_meta(%{assigns: %{run_dir: run_dir}} = socket) do
    meta = load_run_meta(run_dir)

    assign(socket,
      run_status: meta.status,
      run_total_cost_usd: meta.total_cost_usd
    )
  end

  defp run_status("ok"), do: :completed
  defp run_status("error"), do: :errored
  defp run_status("goal_gate_failed"), do: :goal_gate_failed
  defp run_status("running"), do: :running
  defp run_status("interrupted"), do: :interrupted
  defp run_status(_status), do: :unknown

  defp first_node_id(pipeline) do
    pipeline.nodes
    |> Map.keys()
    |> Enum.sort()
    |> List.first()
  end

  defp parse_time(nil), do: nil

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

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
        |> maybe_pill(model_display_name(node.llm_provider, node.llm_model))
        |> maybe_pill(node.attrs["reasoning_effort"])
        |> Enum.reverse()

      _other ->
        []
    end
  end

  defp maybe_pill(acc, nil), do: acc
  defp maybe_pill(acc, ""), do: acc
  defp maybe_pill(acc, value), do: [value | acc]

  # Shown on the selected node's heading. Prefers an explicit llm_model
  # from the DOT source; otherwise falls back to the provider name so we
  # don't claim a specific model version the pipeline didn't declare.
  defp model_display_name(_, model) when is_binary(model) and model != "", do: model
  defp model_display_name(provider, _) when is_binary(provider) and provider != "", do: provider
  defp model_display_name(_, _), do: nil

  defp run_started_at(%{started_at: nil}), do: "—"

  defp run_started_at(%{started_at: %DateTime{} = dt}) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end

  defp run_duration(entry), do: TractorWeb.RunIndex.duration_label(entry)
  defp run_status_label(%{status: status}), do: TractorWeb.RunIndex.status_label(status)
  defp run_status_label(status) when is_atom(status), do: TractorWeb.RunIndex.status_label(status)

  defp run_total_cost_label(total_cost_usd), do: Format.usd(total_cost_usd)

  defp tractor_version do
    case Application.spec(:tractor, :vsn) do
      nil -> ""
      vsn -> "v#{List.to_string(vsn)}"
    end
  end

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

  defp maybe_refresh_selected_wait(%{assigns: %{selected_node_id: nil}} = socket), do: socket

  defp maybe_refresh_selected_wait(%{assigns: %{selected_node_id: node_id}} = socket) do
    case socket.assigns.selected_node do
      %{state: "waiting"} ->
        assign(socket, :selected_node, selected_node(socket.assigns, node_id))

      _other ->
        socket
    end
  end

  defp maybe_refresh_selected_node(
         %{assigns: %{selected_node_id: node_id}} = socket,
         node_id,
         event
       ) do
    socket
    |> assign(:selected_node, selected_node(socket.assigns, node_id))
    |> maybe_clear_wait_error(event)
  end

  defp maybe_refresh_selected_node(socket, _node_id, _event), do: socket

  defp maybe_clear_wait_error(socket, %{"kind" => kind})
       when kind in ["wait_human_pending", "wait_human_resolved", "node_succeeded"] do
    assign(socket, :wait_form_error, nil)
  end

  defp maybe_clear_wait_error(socket, _event), do: socket

  defp selected_node(assigns, node_id) do
    case assigns.pipeline.nodes[node_id] do
      %Tractor.Node{} = node ->
        status =
          read_status_json(assigns.run_dir, node_id)
          |> merge_pending_wait(Map.get(assigns.pending_waits, node_id))

        %{
          id: node_id,
          type: node.type,
          state: Map.get(assigns.node_states, node_id, "pending"),
          status: status
        }

      _other ->
        nil
    end
  end

  defp merge_pending_wait(status, nil), do: status

  defp merge_pending_wait(status, pending_wait) do
    status
    |> Map.merge(pending_wait)
    |> Map.put("status", "waiting")
  end
end
