defmodule Tractor.ACP.Session do
  @moduledoc """
  Blocking ACP session backed by a single provider process.
  """

  use GenServer

  @behaviour Tractor.AgentClient

  alias Tractor.ACP.Turn

  @default_timeout 300_000
  @line_length 1024 * 1024

  defstruct agent_module: nil,
            opts: [],
            port: nil,
            os_pid: nil,
            next_id: 1,
            pending: %{},
            status: :starting,
            session_id: nil,
            queued_prompt: nil,
            prompt_from: nil,
            prompt_timer: nil,
            prompt_timeout_ref: nil,
            event_sink: nil,
            turn: %Turn{}

  @type reason ::
          :timeout
          | :max_tokens
          | :max_turn_requests
          | :refusal
          | :cancelled
          | {:jsonrpc_error, map()}
          | {:port_exit, non_neg_integer()}
          | {:stop_reason, String.t()}

  @impl Tractor.AgentClient
  def start_session(agent_module, opts) do
    start_link(agent_module, opts)
  end

  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(agent_module, opts) do
    GenServer.start_link(__MODULE__, {agent_module, opts})
  end

  @impl Tractor.AgentClient
  @spec prompt(pid(), String.t(), timeout()) :: {:ok, Turn.t()} | {:error, reason()}
  def prompt(pid, text, timeout \\ @default_timeout) do
    GenServer.call(pid, {:prompt, text, normalize_timeout(timeout)}, call_timeout(timeout))
  end

  @impl Tractor.AgentClient
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  @impl true
  def init({agent_module, opts}) do
    Process.flag(:trap_exit, true)

    stderr_log = Keyword.get(opts, :stderr_log)

    with {:ok, {executable, args, env}} <- command(agent_module, opts),
         {:ok, port} <- open_port(executable, args, env, stderr_log) do
      state = %__MODULE__{
        agent_module: agent_module,
        opts: opts,
        port: port,
        os_pid: os_pid(port),
        event_sink: Keyword.get(opts, :event_sink, fn _event -> :ok end)
      }

      {:ok, send_initialize(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:prompt, text, timeout}, from, %{status: :idle} = state) do
    {:noreply, send_prompt(state, from, text, timeout)}
  end

  def handle_call({:prompt, text, timeout}, from, %{status: :starting} = state) do
    {:noreply, %{state | queued_prompt: {from, text, timeout}}}
  end

  def handle_call({:prompt, _text, _timeout}, _from, %{status: :prompting} = state) do
    {:reply, {:error, :busy}, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    line = String.trim_leading(line)

    if String.starts_with?(line, "{") do
      handle_json_line(line, state)
    else
      {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, :normal, fail_prompt(state, {:port_exit, status})}
  end

  def handle_info({:prompt_timeout, timeout_ref}, %{prompt_timeout_ref: timeout_ref} = state) do
    {:noreply, fail_prompt(state, :timeout)}
  end

  def handle_info({:prompt_timeout, _timeout_ref}, state), do: {:noreply, state}

  defp handle_json_line(line, state) do
    case Jason.decode(line) do
      {:ok, message} ->
        {:noreply, handle_message(message, state)}

      {:error, reason} ->
        {:noreply, fail_prompt(state, {:invalid_json, reason})}
    end
  end

  @impl true
  def terminate(_reason, state) do
    pids = os_process_tree(state.os_pid)
    close_port(state.port)
    terminate_os_processes(pids)
    :ok
  end

  defp command(agent_module, opts) do
    case agent_module.command(opts) do
      {executable, args, env} ->
        with {:ok, executable} <- resolve_executable(executable) do
          {:ok, {executable, args, env}}
        end

      other ->
        {:error, {:invalid_agent_command, other}}
    end
  end

  defp resolve_executable(executable) do
    cond do
      Path.type(executable) == :absolute and File.exists?(executable) ->
        {:ok, executable}

      Path.type(executable) == :absolute ->
        {:error, {:missing_executable, executable}}

      resolved = System.find_executable(executable) ->
        {:ok, resolved}

      true ->
        {:error, {:missing_executable, executable}}
    end
  end

  defp open_port(executable, args, env, nil) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:line, @line_length},
        :use_stdio,
        :hide,
        {:args, args},
        {:env, port_env(env)}
      ])

    {:ok, port}
  rescue
    error -> {:error, {:port_open_failed, error}}
  end

  defp open_port(executable, args, env, stderr_log) when is_binary(stderr_log) do
    script = redirect_script(executable, args, stderr_log)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:line, @line_length},
        :use_stdio,
        :hide,
        {:args, ["-c", script]},
        {:env, port_env(env)}
      ])

    {:ok, port}
  rescue
    error -> {:error, {:port_open_failed, error}}
  end

  defp redirect_script(executable, args, stderr_log) do
    escaped = Enum.map_join([executable | args], " ", &shell_escape/1)
    "exec #{escaped} 2>>#{shell_escape(stderr_log)}"
  end

  defp shell_escape(s) when is_binary(s) do
    "'" <> String.replace(s, "'", ~S('\'')) <> "'"
  end

  defp port_env(env) do
    Enum.map(env, fn
      {key, false} -> {String.to_charlist(key), false}
      {key, value} -> {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp send_initialize(state) do
    send_request(state, :initialize, "initialize", %{
      "protocolVersion" => 1,
      "clientCapabilities" => %{}
    })
  end

  defp send_session_new(state) do
    send_request(state, :session_new, "session/new", %{
      "cwd" => Keyword.get(state.opts, :cwd, File.cwd!()),
      "mcpServers" => []
    })
  end

  defp send_prompt(state, from, text, timeout) do
    timeout_ref = make_ref()

    state
    |> Map.put(:prompt_from, from)
    |> Map.put(:prompt_timer, prompt_timer(timeout_ref, timeout))
    |> Map.put(:prompt_timeout_ref, timeout_ref)
    |> Map.put(:turn, %Turn{})
    |> Map.put(:status, :prompting)
    |> send_request(:prompt, "session/prompt", %{
      "sessionId" => state.session_id,
      "prompt" => [%{"type" => "text", "text" => text}]
    })
  end

  defp send_request(state, kind, method, params) do
    id = state.next_id

    send_message(state.port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })

    %{state | next_id: id + 1, pending: Map.put(state.pending, id, kind)}
  end

  defp send_message(port, message) do
    Port.command(port, Jason.encode!(message) <> "\n")
  end

  defp handle_message(%{"id" => id, "result" => result}, state) do
    case Map.pop(state.pending, id) do
      {:initialize, pending} ->
        %{state | pending: pending} |> send_session_new()

      {:session_new, pending} ->
        session_id = result["sessionId"] || result["session_id"]
        state = %{state | pending: pending, session_id: session_id, status: :idle}
        maybe_send_queued_prompt(state)

      {:prompt, pending} ->
        %{state | pending: pending} |> finish_prompt(result)

      {nil, _pending} ->
        state
    end
  end

  defp handle_message(%{"id" => id, "error" => error}, state) do
    case Map.pop(state.pending, id) do
      {:prompt, pending} -> %{state | pending: pending} |> fail_prompt({:jsonrpc_error, error})
      {nil, _pending} -> state
      {_kind, pending} -> %{state | pending: pending} |> fail_prompt({:jsonrpc_error, error})
    end
  end

  defp handle_message(%{"method" => "session/update", "params" => params}, state) do
    update = params["update"] || %{}

    if state.status == :prompting do
      capture_update(state, update)
    else
      state
    end
  end

  defp handle_message(_message, state), do: state

  defp capture_update(state, update) do
    kind = update["type"] || update["sessionUpdate"]
    turn = %{state.turn | events: state.turn.events ++ [update]}
    state = %{state | turn: turn} |> maybe_capture_usage(update)

    case kind do
      "agent_message_chunk" ->
        turn = state.turn
        chunk = %{"text" => chunk_text(update), "raw" => update}
        emit_event(state, :agent_message_chunk, chunk)

        %{
          state
          | turn: %{
              turn
              | response_text: turn.response_text <> (chunk["text"] || ""),
                agent_message_chunks: turn.agent_message_chunks ++ [chunk]
            }
        }

      "agent_thought_chunk" ->
        turn = state.turn
        chunk = %{"text" => chunk_text(update), "raw" => update}
        emit_event(state, :agent_thought_chunk, chunk)
        %{state | turn: %{turn | agent_thought_chunks: turn.agent_thought_chunks ++ [chunk]}}

      "tool_call" ->
        turn = state.turn
        tool_call = extract_tool_call(update)
        emit_event(state, :tool_call, tool_call)
        %{state | turn: %{turn | tool_calls: turn.tool_calls ++ [tool_call]}}

      "tool_call_update" ->
        turn = state.turn
        update_data = extract_tool_call_update(update)
        emit_event(state, :tool_call_update, update_data)
        %{state | turn: %{turn | tool_call_updates: turn.tool_call_updates ++ [update_data]}}

      _other ->
        state
    end
  end

  defp maybe_capture_usage(state, payload) do
    case normalize_usage(payload) do
      nil ->
        state

      usage ->
        merged = merge_usage(state.turn.token_usage, usage)

        if merged == state.turn.token_usage do
          state
        else
          emit_event(state, :usage, merged)
          %{state | turn: %{state.turn | token_usage: merged}}
        end
    end
  end

  defp emit_event(state, kind, data) do
    state.event_sink.(%{kind: kind, data: data})
    :ok
  end

  defp chunk_text(%{"content" => %{"text" => text}}) when is_binary(text), do: text

  defp chunk_text(%{"content" => %{"type" => "text", "text" => text}}) when is_binary(text),
    do: text

  defp chunk_text(%{"content" => text}) when is_binary(text), do: text
  defp chunk_text(%{"text" => text}) when is_binary(text), do: text
  defp chunk_text(_update), do: ""

  defp extract_tool_call(update) do
    content = content_map(update)

    %{
      "toolCallId" => first_present(update, content, ["toolCallId", "tool_call_id", "id"]),
      "title" => first_present(update, content, ["title", "name"]),
      "kind" => first_present(update, content, ["kind", "type"]),
      "status" => first_present(update, content, ["status"]),
      "content" => Map.get(content, "content", Map.get(update, "content")),
      "locations" => first_present(update, content, ["locations"]),
      "rawInput" => first_present(update, content, ["rawInput", "raw_input"]),
      "rawOutput" => first_present(update, content, ["rawOutput", "raw_output"]),
      "raw" => update
    }
  end

  defp extract_tool_call_update(update) do
    content = content_map(update)

    %{
      "toolCallId" => first_present(update, content, ["toolCallId", "tool_call_id", "id"]),
      "status" => first_present(update, content, ["status"]),
      "content" => Map.get(update, "content"),
      "rawInput" => first_present(update, content, ["rawInput", "raw_input"]),
      "rawOutput" => first_present(update, content, ["rawOutput", "raw_output"]),
      "raw" => update
    }
  end

  defp first_present(primary, secondary, keys) do
    Enum.find_value(keys, fn key -> Map.get(primary, key) || Map.get(secondary, key) end)
  end

  defp normalize_usage(payload) when is_map(payload) do
    payload
    |> usage_payload()
    |> normalize_usage_payload()
  end

  defp normalize_usage(_payload), do: nil

  defp usage_payload(payload) do
    content = content_map(payload)

    Enum.find_value(["usage", "tokenUsage", "token_usage", "modelUsage"], fn key ->
      Map.get(payload, key)
    end) || Map.get(content, "usage")
  end

  defp normalize_usage_payload(payload) when is_map(payload) do
    usage =
      %{
        input_tokens: usage_integer(payload, ["input_tokens", "inputTokens", "prompt_tokens"]),
        output_tokens: usage_integer(payload, ["output_tokens", "outputTokens", "completion_tokens"]),
        total_tokens: usage_integer(payload, ["total_tokens", "totalTokens"]),
        raw: payload
      }
      |> Enum.reject(fn {key, value} -> key != :raw and is_nil(value) end)
      |> Map.new()

    if map_size(Map.delete(usage, :raw)) == 0, do: nil, else: usage
  end

  defp normalize_usage_payload(_payload), do: nil

  defp usage_integer(payload, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(payload, key) do
        value when is_integer(value) and value >= 0 -> value
        value when is_binary(value) -> parse_usage_integer(value)
        _other -> nil
      end
    end)
  end

  defp parse_usage_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> nil
    end
  end

  defp merge_usage(nil, usage), do: usage

  defp merge_usage(current, usage) do
    Enum.reduce([:input_tokens, :output_tokens, :total_tokens, :raw], current, fn key, acc ->
      case Map.get(usage, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp content_map(%{"content" => content}) when is_map(content), do: content
  defp content_map(_update), do: %{}

  defp maybe_send_queued_prompt(%{queued_prompt: nil} = state), do: state

  defp maybe_send_queued_prompt(%{queued_prompt: {from, text, timeout}} = state) do
    state
    |> Map.put(:queued_prompt, nil)
    |> send_prompt(from, text, timeout)
  end

  defp finish_prompt(state, result) do
    stop_reason = result["stopReason"] || result["stop_reason"]
    state = maybe_capture_usage(state, result)

    case stop_reason do
      reason when reason in ["end_turn", "done"] ->
        reply_prompt(state, {:ok, state.turn})

      "max_tokens" ->
        fail_prompt(state, :max_tokens)

      "max_turn_requests" ->
        fail_prompt(state, :max_turn_requests)

      "refusal" ->
        fail_prompt(state, :refusal)

      "cancelled" ->
        fail_prompt(state, :cancelled)

      other when is_binary(other) ->
        fail_prompt(state, {:stop_reason, other})
    end
  end

  defp fail_prompt(%{prompt_from: nil} = state, _reason), do: state

  defp fail_prompt(state, reason) do
    reply_prompt(state, {:error, reason})
  end

  defp reply_prompt(state, reply) do
    if state.prompt_timer do
      Process.cancel_timer(state.prompt_timer)
    end

    GenServer.reply(state.prompt_from, reply)

    %{
      state
      | status: :idle,
        prompt_from: nil,
        prompt_timer: nil,
        prompt_timeout_ref: nil,
        turn: %Turn{}
    }
  end

  defp prompt_timer(_timeout_ref, :infinity), do: nil

  defp prompt_timer(timeout_ref, timeout) do
    Process.send_after(self(), {:prompt_timeout, timeout_ref}, timeout)
  end

  defp normalize_timeout(nil), do: @default_timeout
  defp normalize_timeout(:infinity), do: :infinity
  defp normalize_timeout(timeout), do: timeout

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(nil), do: @default_timeout + 1_000
  defp call_timeout(timeout), do: timeout + 1_000

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _other -> nil
    end
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    if Port.info(port) do
      Port.close(port)
    end
  rescue
    _error -> :ok
  end

  defp os_process_tree(nil), do: []

  defp os_process_tree(pid) do
    descendant_pids(pid) ++ [pid]
  rescue
    _error -> []
  end

  defp terminate_os_processes([]), do: :ok

  defp terminate_os_processes(pids) do
    signal_os_processes(pids, "-TERM")

    unless wait_for_os_processes_exit(pids) do
      signal_os_processes(pids, "-KILL")
      wait_for_os_processes_exit(pids)
    end

    :ok
  rescue
    _error -> :ok
  end

  defp descendant_pids(pid) do
    pid
    |> child_pids()
    |> Enum.flat_map(fn child_pid -> descendant_pids(child_pid) ++ [child_pid] end)
  end

  defp child_pids(pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split()
        |> Enum.map(&String.to_integer/1)

      _other ->
        []
    end
  rescue
    _error -> []
  end

  defp signal_os_processes(pids, signal) do
    Enum.each(pids, fn pid ->
      try do
        System.cmd("kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true)
      rescue
        _error -> :ok
      end
    end)
  end

  defp wait_for_os_processes_exit(pids) do
    Enum.any?(1..20, fn _attempt ->
      if Enum.any?(pids, &os_process_alive?/1) do
        Process.sleep(50)
        false
      else
        true
      end
    end)
  end

  defp os_process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _other -> false
    end
  rescue
    _error -> false
  end
end
