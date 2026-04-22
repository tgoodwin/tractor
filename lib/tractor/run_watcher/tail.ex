defmodule Tractor.RunWatcher.Tail do
  @moduledoc false

  use GenServer

  require Logger

  @flush_ms 200
  @rescan_ms 1_000
  @terminal_kinds ~w(run_completed run_failed run_interrupted)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    run_dir = Keyword.fetch!(opts, :run_dir)

    state = %{
      run_id: run_id,
      run_dir: run_dir,
      notify: Keyword.fetch!(opts, :notify),
      watcher: start_fs_watcher(run_dir),
      nodes: %{},
      flush_ref: nil,
      terminal_sent?: false
    }

    {:ok, state |> discover_nodes() |> replay_nodes() |> schedule_rescan()}
  end

  @impl true
  def handle_info(:rescan, state) do
    state =
      state
      |> discover_nodes()
      |> replay_nodes()
      |> flush_offsets()
      |> schedule_rescan()

    {:noreply, state}
  end

  def handle_info(:flush_offsets, state) do
    {:noreply, %{flush_offsets(state) | flush_ref: nil}}
  end

  def handle_info({:file_event, watcher, _event}, %{watcher: watcher} = state) do
    {:noreply, state |> discover_nodes() |> replay_nodes()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    flush_offsets(%{state | flush_ref: nil})
    :ok
  end

  defp discover_nodes(state) do
    node_entries =
      case File.ls(state.run_dir) do
        {:ok, entries} -> entries
        _ -> []
      end

    Enum.reduce(node_entries, state, fn entry, state ->
      node_dir = Path.join(state.run_dir, entry)

      cond do
        not File.dir?(node_dir) ->
          state

        entry == "control" or String.starts_with?(entry, ".") ->
          state

        Map.has_key?(state.nodes, entry) ->
          state

        true ->
          put_in(state.nodes[entry], load_node_state(node_dir))
      end
    end)
  end

  defp replay_nodes(state) do
    Enum.reduce(state.nodes, state, fn {node_id, node_state}, state ->
      replay_node(state, node_id, node_state)
    end)
  end

  defp replay_node(state, node_id, node_state) do
    events_path = events_path(state.run_dir, node_id)

    case File.read(events_path) do
      {:ok, contents} ->
        contents = IO.iodata_to_binary(contents)
        size = byte_size(contents)
        offset = normalize_offset(node_state.offset, size)
        raw = binary_part(contents, offset, size - offset)
        chunk = merge_buffer(node_state.buffer, raw)
        {complete, remainder} = split_complete_lines(chunk)
        {last_seq, terminal_sent?} = emit_events(state, node_id, complete, node_state.last_seq)

        node_state = %{
          node_state
          | offset: offset + byte_size(complete),
            buffer: remainder,
            last_seq: last_seq,
            dirty?: node_state.dirty? or byte_size(complete) > 0
        }

        state =
          state
          |> put_in([Access.key(:nodes), node_id], node_state)
          |> maybe_schedule_flush(node_state.dirty?)

        if terminal_sent? and not state.terminal_sent? do
          send(state.notify, {:run_watcher_terminal, state.run_id})
          %{state | terminal_sent?: true}
        else
          state
        end

      {:error, :enoent} ->
        state

      {:error, reason} ->
        Logger.warning("RunWatcher tail read failed for #{events_path}: #{inspect(reason)}")
        state
    end
  end

  defp emit_events(state, node_id, complete, last_seq) do
    complete
    |> String.split("\n", trim: true)
    |> Enum.reduce({last_seq, false}, fn line, {last_seq, terminal_sent?} ->
      case Jason.decode(line) do
        {:ok, %{"seq" => seq} = event} when is_integer(seq) and seq > last_seq ->
          Tractor.RunBus.broadcast(state.run_id, node_id, event)

          {
            seq,
            terminal_sent? or terminal_event?(node_id, event)
          }

        {:ok, %{"seq" => seq} = event} when is_integer(seq) ->
          {
            max(last_seq || 0, seq),
            terminal_sent? or terminal_event?(node_id, event)
          }

        {:ok, event} ->
          Tractor.RunBus.broadcast(state.run_id, node_id, event)
          {last_seq, terminal_sent? or terminal_event?(node_id, event)}

        {:error, reason} ->
          Logger.warning(
            "RunWatcher skipped malformed event line for #{state.run_id}/#{node_id}: #{inspect(reason)}"
          )

          {last_seq, terminal_sent?}
      end
    end)
  end

  defp terminal_event?("_run", %{"kind" => kind}), do: kind in @terminal_kinds
  defp terminal_event?(_node_id, _event), do: false

  defp flush_offsets(state) do
    nodes =
      Map.new(state.nodes, fn {node_id, node_state} ->
        if node_state.dirty? do
          Tractor.Paths.atomic_write!(
            offset_path(state.run_dir, node_id),
            Integer.to_string(node_state.offset)
          )

          {node_id, %{node_state | dirty?: false}}
        else
          {node_id, node_state}
        end
      end)

    %{state | nodes: nodes}
  end

  defp maybe_schedule_flush(state, false), do: state

  defp maybe_schedule_flush(state, true) do
    if state.flush_ref do
      state
    else
      %{state | flush_ref: Process.send_after(self(), :flush_offsets, @flush_ms)}
    end
  end

  defp schedule_rescan(state) do
    Process.send_after(self(), :rescan, @rescan_ms)
    state
  end

  defp load_node_state(node_dir) do
    events_path = Path.join(node_dir, "events.jsonl")
    file_size = file_size(events_path)
    offset = offset_path(node_dir) |> read_offset() |> normalize_offset(file_size)

    %{
      offset: offset,
      buffer: "",
      last_seq: last_seq(node_dir),
      dirty?: false
    }
  end

  defp offset_path(run_dir, node_id), do: Path.join([run_dir, node_id, ".watcher-offset"])
  defp offset_path(node_dir), do: Path.join(node_dir, ".watcher-offset")
  defp events_path(run_dir, node_id), do: Path.join([run_dir, node_id, "events.jsonl"])

  defp read_offset(path) do
    with {:ok, raw} <- File.read(path),
         {value, _rest} <- Integer.parse(String.trim(raw)) do
      value
    else
      _other -> 0
    end
  end

  defp last_seq(node_dir) do
    events_path = Path.join(node_dir, "events.jsonl")

    with {:ok, contents} <- File.read(events_path),
         contents = IO.iodata_to_binary(contents),
         true <- contents != "" do
      contents
      |> String.split("\n", trim: true)
      |> List.last()
      |> case do
        nil -> 0
        line -> Jason.decode!(line)["seq"] || 0
      end
    else
      _other -> 0
    end
  rescue
    _error -> 0
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  defp normalize_offset(offset, size) when offset > size, do: 0
  defp normalize_offset(offset, _size) when offset < 0, do: 0
  defp normalize_offset(offset, _size), do: offset

  defp merge_buffer("", raw), do: raw
  defp merge_buffer(buffer, raw) when raw == "", do: buffer

  defp merge_buffer(buffer, raw) do
    if String.starts_with?(raw, buffer) do
      raw
    else
      buffer <> raw
    end
  end

  defp split_complete_lines(chunk) do
    case :binary.matches(chunk, "\n") do
      [] ->
        {"", chunk}

      matches ->
        {position, 1} = List.last(matches)
        split_at = position + 1

        {
          binary_part(chunk, 0, split_at),
          binary_part(chunk, split_at, byte_size(chunk) - split_at)
        }
    end
  end

  defp start_fs_watcher(run_dir) do
    case FileSystem.start_link(dirs: [run_dir]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        pid

      :ignore ->
        Logger.warning("RunWatcher tail file_system unavailable for #{run_dir}: :ignore")
        nil

      {:error, reason} ->
        Logger.warning(
          "RunWatcher tail file_system unavailable for #{run_dir}: #{inspect(reason)}"
        )

        nil
    end
  end
end
