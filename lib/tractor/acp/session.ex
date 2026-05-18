defmodule Tractor.ACP.Session do
  @moduledoc """
  Blocking ACP session backed by a single provider process.
  """

  use GenServer

  @behaviour Tractor.AgentClient

  require Logger

  alias Tractor.ACP.Turn

  @default_timeout 300_000
  @default_init_timeout 30_000
  @line_length 1024 * 1024
  @stderr_poll_ms 250

  defstruct agent_module: nil,
            opts: [],
            owner_pid: nil,
            owner_monitor: nil,
            port: nil,
            os_pid: nil,
            janitor_port: nil,
            janitor_os_pid: nil,
            stderr_log: nil,
            stderr_offset: 0,
            stderr_poll_timer: nil,
            wire_log: nil,
            next_id: 1,
            pending: %{},
            status: :starting,
            session_id: nil,
            queued_prompt: nil,
            prompt_from: nil,
            prompt_timer: nil,
            prompt_timeout_ref: nil,
            init_timer: nil,
            init_timeout_ref: nil,
            event_sink: nil,
            turn: %Turn{},
            line_buffer: ""

  @type reason ::
          :timeout
          | :init_timeout
          | :max_tokens
          | :max_turn_requests
          | :refusal
          | :cancelled
          | {:jsonrpc_error, map()}
          | {:port_exit, non_neg_integer()}
          | {:stop_reason, String.t()}

  @impl Tractor.AgentClient
  def start_session(agent_module, opts) do
    case Process.whereis(Tractor.ACP.SessionSup) do
      nil ->
        start_link(agent_module, opts)

      _pid ->
        DynamicSupervisor.start_child(
          Tractor.ACP.SessionSup,
          {__MODULE__, {agent_module, opts, self()}}
        )
    end
  end

  @spec child_spec({module(), keyword(), pid()}) :: Supervisor.child_spec()
  def child_spec({agent_module, opts, owner_pid}) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [agent_module, opts, owner_pid]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(agent_module, opts) do
    start_link(agent_module, opts, self())
  end

  @spec start_link(module(), keyword(), pid()) :: GenServer.on_start()
  def start_link(agent_module, opts, owner_pid) when is_pid(owner_pid) do
    GenServer.start_link(__MODULE__, {agent_module, opts, owner_pid})
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
  catch
    :exit, :normal -> :ok
    :exit, {:normal, _stack} -> :ok
    :exit, {{:normal, _details}, _stack} -> :ok
    :exit, {:noproc, _stack} -> :ok
    :exit, {{:noproc, _details}, _stack} -> :ok
  end

  @impl true
  def init({agent_module, opts, owner_pid}) do
    Process.flag(:trap_exit, true)

    stderr_log = Keyword.get(opts, :stderr_log)
    wire_log = Keyword.get(opts, :wire_log) || default_wire_log(stderr_log)

    with {:ok, {executable, args, env}} <- command(agent_module, opts),
         {:ok, port} <- open_port(executable, args, env, stderr_log) do
      os_pid = os_pid(port)
      janitor_port = start_process_janitor(os_pid)

      state = %__MODULE__{
        agent_module: agent_module,
        opts: opts,
        owner_pid: owner_pid,
        owner_monitor: Process.monitor(owner_pid),
        port: port,
        os_pid: os_pid,
        janitor_port: janitor_port,
        janitor_os_pid: os_pid(janitor_port),
        stderr_log: stderr_log,
        stderr_offset: file_size(stderr_log),
        wire_log: wire_log,
        event_sink: Keyword.get(opts, :event_sink, fn _event -> :ok end)
      }

      prepare_debug_log(wire_log)

      {:ok, state |> arm_init_timer() |> arm_stderr_poll() |> send_initialize()}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp arm_init_timer(state) do
    timeout = Keyword.get(state.opts, :init_timeout, @default_init_timeout)

    case timeout do
      :infinity ->
        state

      ms when is_integer(ms) and ms > 0 ->
        ref = make_ref()
        timer = Process.send_after(self(), {:init_timeout, ref}, ms)
        %{state | init_timer: timer, init_timeout_ref: ref}

      _other ->
        state
    end
  end

  defp cancel_init_timer(%{init_timer: nil} = state), do: state

  defp cancel_init_timer(%{init_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | init_timer: nil, init_timeout_ref: nil}
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
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    # ACP messages occasionally exceed the @line_length buffer (e.g. a tool
    # result containing a large file dump). The port splits them into
    # successive :noeol chunks followed by an :eol terminator — accumulate
    # until we have a full line.
    {:noreply, %{state | line_buffer: state.line_buffer <> chunk}}
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    {full, state} = take_buffered_line(state, chunk)
    line = String.trim_leading(full)

    if String.starts_with?(line, "{") do
      handle_json_line(line, state)
    else
      state = record_stdout_line(state, line)
      {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, :normal, fail_any_pending(state, {:port_exit, status})}
  end

  def handle_info({:prompt_timeout, timeout_ref}, %{prompt_timeout_ref: timeout_ref} = state) do
    {:noreply, fail_prompt(state, :timeout)}
  end

  def handle_info({:prompt_timeout, _timeout_ref}, state), do: {:noreply, state}

  def handle_info({:init_timeout, ref}, %{init_timeout_ref: ref} = state) do
    {:stop, :normal, fail_any_pending(state, :init_timeout)}
  end

  def handle_info({:init_timeout, _ref}, state), do: {:noreply, state}

  def handle_info(:poll_stderr, state) do
    {:noreply, state |> drain_stderr() |> arm_stderr_poll()}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, owner_pid, reason},
        %{owner_monitor: monitor_ref, owner_pid: owner_pid} = state
      ) do
    {:stop, {:shutdown, {:owner_down, reason}}, fail_any_pending(state, :cancelled)}
  end

  def handle_info({:EXIT, owner_pid, reason}, %{owner_pid: owner_pid} = state) do
    {:stop, {:shutdown, {:owner_exit, reason}}, fail_any_pending(state, :cancelled)}
  end

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.warning(
      "ACP session received unexpected :EXIT pid=#{inspect(pid)} reason=#{inspect(reason)}"
    )

    {:noreply, state}
  end

  defp handle_json_line(line, state) do
    case Jason.decode(line) do
      {:ok, message} ->
        write_wire(state, "in", message)
        {:noreply, handle_message(message, state)}

      {:error, reason} ->
        write_wire(state, "in", %{"raw" => line, "decode_error" => Exception.message(reason)})
        {:noreply, fail_prompt(state, {:invalid_json, reason})}
    end
  end

  @impl true
  def terminate(_reason, state) do
    demonitor_owner(state)
    cancel_stderr_poll(state)
    state = drain_stderr(state)
    pids = os_process_tree(state.os_pid)
    close_port(state.port)
    terminate_os_processes(pids)
    close_port(state.janitor_port)
    :ok
  end

  defp demonitor_owner(%{owner_monitor: monitor_ref}) when is_reference(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  defp demonitor_owner(_state), do: :ok

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
    base = %{
      "cwd" => Keyword.get(state.opts, :cwd, File.cwd!()),
      "mcpServers" => []
    }

    extras = Tractor.Agent.session_params(state.agent_module, state.opts)
    send_request(state, :session_new, "session/new", deep_merge(base, extras))
  end

  # Deep merge two maps (right-biased). Used to fold adapter-provided extras
  # into session/new params without clobbering nested keys like `_meta`.
  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, l, r ->
      if is_map(l) and is_map(r), do: deep_merge(l, r), else: r
    end)
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

    message = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    write_wire(state, "out", message)
    send_message(state.port, message)

    %{state | next_id: id + 1, pending: Map.put(state.pending, id, kind)}
  end

  defp send_response(state, id, result) do
    message = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    write_wire(state, "out", message)
    send_message(state.port, message)
    state
  end

  defp send_error(state, id, code, message_text) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message_text}
    }

    write_wire(state, "out", message)
    send_message(state.port, message)
    state
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

        %{state | pending: pending, session_id: session_id}
        |> maybe_send_session_mode()

      {:session_set_mode, pending} ->
        %{state | pending: pending} |> complete_session_start()

      {:prompt, pending} ->
        %{state | pending: pending} |> finish_prompt(result)

      {nil, _pending} ->
        emit_unknown_message(state, %{"id" => id, "result" => result, "unmatched" => true})
    end
  end

  defp handle_message(%{"id" => id, "error" => error}, state) do
    case Map.pop(state.pending, id) do
      {:prompt, pending} ->
        %{state | pending: pending} |> fail_prompt({:jsonrpc_error, error})

      {:session_set_mode, pending} ->
        state = %{state | pending: pending}

        if method_not_found?(error) do
          emit_event(state, :acp_unknown_message, %{
            "method" => "session/set_mode",
            "error" => error,
            "ignored" => true
          })

          complete_session_start(state)
        else
          fail_any_pending(state, {:jsonrpc_error, error})
        end

      {nil, _pending} ->
        state

      # initialize / session_new failures: the session can't recover, so fail
      # the queued prompt too rather than letting the caller hang.
      {_kind, pending} ->
        %{state | pending: pending} |> fail_any_pending({:jsonrpc_error, error})
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

  defp handle_message(
         %{"id" => id, "method" => "session/request_permission", "params" => params} = message,
         state
       ) do
    {response, selected} = permission_response(params)

    emit_event(state, :acp_unknown_message, %{
      "method" => "session/request_permission",
      "id" => id,
      "autoApproved" => selected != nil,
      "selectedOption" => selected,
      "raw" => message
    })

    send_response(state, id, response)
  end

  defp handle_message(%{"id" => id, "method" => method} = message, state) do
    emit_event(state, :acp_unknown_message, %{
      "method" => method,
      "id" => id,
      "raw" => message,
      "replied" => "method_not_found"
    })

    send_error(state, id, -32_601, "method not found")
  end

  defp handle_message(%{"method" => method} = message, state) do
    emit_unknown_message(state, %{"method" => method, "raw" => message})
  end

  defp handle_message(message, state) do
    emit_unknown_message(state, %{"raw" => message})
  end

  defp maybe_send_session_mode(state) do
    case Tractor.Agent.session_mode(state.agent_module, state.opts) do
      mode when is_binary(mode) and mode != "" ->
        send_request(state, :session_set_mode, "session/set_mode", %{
          "sessionId" => state.session_id,
          "modeId" => mode
        })

      _other ->
        complete_session_start(state)
    end
  end

  defp complete_session_start(state) do
    state
    |> Map.put(:status, :idle)
    |> cancel_init_timer()
    |> maybe_send_queued_prompt()
  end

  defp method_not_found?(%{"code" => -32_601}), do: true

  defp method_not_found?(%{"message" => message}) when is_binary(message) do
    message |> String.downcase() |> String.contains?("method not found")
  end

  defp method_not_found?(_error), do: false

  defp permission_response(params) do
    options = List.wrap(params["options"])

    selected =
      Enum.find(options, &(Map.get(&1, "kind") == "allow_always")) ||
        Enum.find(options, &(Map.get(&1, "kind") == "allow_once")) ||
        Enum.find(options, &allowish_option?/1)

    case selected do
      %{"optionId" => option_id} ->
        {%{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}, selected}

      _other ->
        {%{"outcome" => %{"outcome" => "cancelled"}}, nil}
    end
  end

  defp allowish_option?(%{"optionId" => option_id}) when is_binary(option_id) do
    option_id
    |> String.downcase()
    |> then(&(String.contains?(&1, "allow") or String.contains?(&1, "proceed")))
  end

  defp allowish_option?(_option), do: false

  defp capture_update(state, update) do
    kind = update["type"] || update["sessionUpdate"]
    turn = %{state.turn | events: state.turn.events ++ [update]}
    state = %{state | turn: turn} |> maybe_capture_usage(update)
    dispatch_update(state, kind, update)
  end

  defp dispatch_update(state, "agent_message_chunk", update) do
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
  end

  defp dispatch_update(state, "agent_thought_chunk", update) do
    turn = state.turn
    chunk = %{"text" => chunk_text(update), "raw" => update}
    emit_event(state, :agent_thought_chunk, chunk)
    %{state | turn: %{turn | agent_thought_chunks: turn.agent_thought_chunks ++ [chunk]}}
  end

  defp dispatch_update(state, "tool_call", update) do
    turn = state.turn
    tool_call = extract_tool_call(update)
    emit_event(state, :tool_call, tool_call)
    %{state | turn: %{turn | tool_calls: turn.tool_calls ++ [tool_call]}}
  end

  defp dispatch_update(state, "tool_call_update", update) do
    turn = state.turn
    update_data = extract_tool_call_update(update)
    emit_event(state, :tool_call_update, update_data)
    %{state | turn: %{turn | tool_call_updates: turn.tool_call_updates ++ [update_data]}}
  end

  defp dispatch_update(state, "plan", update) do
    turn = state.turn
    plan = extract_plan(update)
    emit_event(state, :plan_update, plan)
    %{state | turn: %{turn | plan: plan["entries"]}}
  end

  # Codex emits a high-frequency context-window telemetry update: {size, used}.
  # Recognize it so it doesn't render as "unknown update usage_update" in the
  # timeline. Emit as a distinct kind; the timeline has no event_entry for it,
  # so it's silently dropped from the activity log but still preserved in
  # events.jsonl for downstream tooling.
  defp dispatch_update(state, "usage_update", update) do
    payload = %{
      "size" => update["size"],
      "used" => update["used"]
    }

    emit_event(state, :acp_context_window, payload)
    state
  end

  defp dispatch_update(state, kind, update) do
    emit_event(state, :acp_unknown_update, %{
      "updateKind" => kind || "unknown",
      "raw" => update
    })

    state
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

  defp emit_unknown_message(state, data) do
    emit_event(state, :acp_unknown_message, data)
    state
  end

  defp default_wire_log(nil), do: nil
  defp default_wire_log(stderr_log), do: Path.join(Path.dirname(stderr_log), "acp-wire.jsonl")

  defp prepare_debug_log(nil), do: :ok

  defp prepare_debug_log(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write(path, "", [:append])
    :ok
  rescue
    _error -> :ok
  end

  defp write_wire(%{wire_log: nil}, _direction, _payload), do: :ok

  defp write_wire(%{wire_log: path}, direction, payload) do
    entry = %{
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "direction" => direction,
      "payload" => payload
    }

    File.write(path, Jason.encode!(entry) <> "\n", [:append])
    :ok
  rescue
    _error -> :ok
  end

  defp take_buffered_line(%{line_buffer: ""} = state, chunk), do: {chunk, state}

  defp take_buffered_line(%{line_buffer: buf} = state, chunk),
    do: {buf <> chunk, %{state | line_buffer: ""}}

  defp record_stdout_line(state, ""), do: state

  defp record_stdout_line(state, line) do
    write_wire(state, "stdout", %{"text" => redact_stdout_line(line)})

    case visible_stdout_line(line) do
      :drop -> :ok
      text -> emit_event(state, :acp_stdout_line, %{"text" => text})
    end

    state
  end

  defp visible_stdout_line(line) do
    display_line = line |> strip_ansi_sequences() |> redact_stdout_line()
    classifier_line = stdout_classifier_line(display_line)

    if telemetry_stdout_line?(classifier_line) do
      :drop
    else
      display_line
    end
  end

  @telemetry_substrings [
    " codex_otel::otel_manager: ",
    " INFO feedback_tags: ",
    " codex_acp::",
    " codex_rmcp_client::",
    " codex_core::features:",
    " codex_core::config:",
    " codex_core::stream_events_utils:",
    " serve_inner:",
    " rmcp::service:",
    " Service initialized as client ",
    " MCP server stderr "
  ]

  defp telemetry_stdout_line?("[... telemetry preview truncated ...]"), do: true

  defp telemetry_stdout_line?(line) do
    Enum.any?(@telemetry_substrings, &String.contains?(line, &1))
  end

  defp stdout_classifier_line(line) do
    line
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\s+:\s+/, ": ")
    |> String.trim()
  end

  defp strip_ansi_sequences(line) do
    line
    |> then(&Regex.replace(~r/\x1B\[[0-?]*[ -\/]*[@-~]/, &1, ""))
    |> then(&Regex.replace(~r/\[(?:\d{1,3})(?:;\d{1,3})*m/, &1, ""))
  end

  defp redact_stdout_line(line) do
    line
    |> then(&Regex.replace(~r/user\.email="[^"]+"/, &1, ~s(user.email="[redacted]")))
    |> then(&Regex.replace(~r/user\.account_id="[^"]+"/, &1, ~s(user.account_id="[redacted]")))
    |> then(&Regex.replace(~r/conversation\.id=[^ ]+/, &1, "conversation.id=[redacted]"))
  end

  defp arm_stderr_poll(%{stderr_log: nil} = state), do: state

  defp arm_stderr_poll(state) do
    timer = Process.send_after(self(), :poll_stderr, @stderr_poll_ms)
    %{state | stderr_poll_timer: timer}
  end

  defp cancel_stderr_poll(%{stderr_poll_timer: timer}) when is_reference(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  defp cancel_stderr_poll(_state), do: :ok

  defp drain_stderr(%{stderr_log: nil} = state), do: state

  defp drain_stderr(%{stderr_log: path, stderr_offset: offset} = state) do
    case File.read(path) do
      {:ok, body} ->
        size = byte_size(body)

        cond do
          size > offset ->
            chunk = binary_part(body, offset, size - offset)
            write_wire(state, "stderr", %{"text" => chunk})
            emit_event(state, :stderr_chunk, %{"text" => chunk})
            %{state | stderr_offset: size}

          size < offset ->
            %{state | stderr_offset: size}

          true ->
            state
        end

      _other ->
        state
    end
  rescue
    _error -> state
  end

  defp file_size(nil), do: 0

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _other -> 0
    end
  rescue
    _error -> 0
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

  defp extract_plan(update) do
    entries =
      update
      |> Map.get("entries", [])
      |> Enum.map(&normalize_plan_entry/1)

    %{"entries" => entries, "raw" => update}
  end

  defp normalize_plan_entry(entry) when is_map(entry) do
    raw_status = Map.get(entry, "status", "pending")
    status = normalize_plan_status(raw_status)

    if status != raw_status do
      Logger.warning("unknown ACP plan status #{inspect(raw_status)}; rendering as pending")
    end

    %{
      "content" => to_string(Map.get(entry, "content", "")),
      "priority" => Map.get(entry, "priority"),
      "status" => status,
      "raw" => entry
    }
  end

  defp normalize_plan_entry(entry) do
    %{"content" => to_string(entry), "priority" => nil, "status" => "pending", "raw" => entry}
  end

  defp normalize_plan_status(status) when status in ["pending", "in_progress", "completed"],
    do: status

  defp normalize_plan_status(_status), do: "pending"

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
        output_tokens:
          usage_integer(payload, ["output_tokens", "outputTokens", "completion_tokens"]),
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

  # Fail every blocked caller on this session — both the in-flight prompt and
  # any queued one waiting for :starting → :idle. Used for terminal failures
  # (port_exit, init_timeout, init-stage JSON-RPC errors) where the session
  # can't recover, so we must reply rather than let GenServer.call hang.
  defp fail_any_pending(state, reason) do
    state
    |> fail_prompt(reason)
    |> fail_queued_prompt(reason)
  end

  defp fail_queued_prompt(%{queued_prompt: nil} = state, _reason), do: state

  defp fail_queued_prompt(%{queued_prompt: {from, _text, _timeout}} = state, reason) do
    GenServer.reply(from, {:error, reason})
    %{state | queued_prompt: nil}
  end

  defp reply_prompt(state, reply) do
    state = drain_stderr(state)

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

  defp os_pid(nil), do: nil

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

  defp start_process_janitor(nil), do: nil

  defp start_process_janitor(target_pid) do
    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      :hide,
      :nouse_stdio,
      {:args,
       ["-c", process_janitor_script(), "tractor-acp-janitor", System.pid(), "#{target_pid}"]}
    ])
  rescue
    _error -> nil
  end

  defp process_janitor_script do
    """
    parent_pid=$1
    target_pid=$2

    alive() {
      kill -0 "$1" 2>/dev/null
    }

    kill_tree() {
      tree_pid=$1
      signal=$2

      for child_pid in $(pgrep -P "$tree_pid" 2>/dev/null); do
        kill_tree "$child_pid" "$signal"
      done

      kill "$signal" "$tree_pid" 2>/dev/null || true
    }

    wait_for_exit() {
      waited=0

      while [ "$waited" -lt 20 ] && alive "$target_pid"; do
        sleep 0.1
        waited=$((waited + 1))
      done

      ! alive "$target_pid"
    }

    trap '' HUP

    while alive "$parent_pid" && alive "$target_pid"; do
      sleep 1
    done

    if ! alive "$parent_pid" && alive "$target_pid"; then
      kill_tree "$target_pid" -TERM

      if ! wait_for_exit; then
        kill_tree "$target_pid" -KILL
      fi
    fi
    """
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
