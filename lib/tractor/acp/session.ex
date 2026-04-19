defmodule Tractor.ACP.Session do
  @moduledoc """
  Blocking ACP session backed by a single provider process.
  """

  use GenServer

  @behaviour Tractor.AgentClient

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
            buffer: []

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
  @spec prompt(pid(), String.t(), timeout()) :: {:ok, String.t()} | {:error, reason()}
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

    with {:ok, {executable, args, env}} <- command(agent_module, opts),
         {:ok, port} <- open_port(executable, args, env) do
      state = %__MODULE__{
        agent_module: agent_module,
        opts: opts,
        port: port,
        os_pid: os_pid(port)
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
    case Jason.decode(line) do
      {:ok, message} ->
        {:noreply, handle_message(message, state)}

      {:error, reason} ->
        {:noreply, fail_prompt(state, {:invalid_json, reason})}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, :normal, fail_prompt(state, {:port_exit, status})}
  end

  def handle_info({:prompt_timeout, timeout_ref}, %{prompt_timeout_ref: timeout_ref} = state) do
    {:noreply, fail_prompt(state, :timeout)}
  end

  def handle_info({:prompt_timeout, _timeout_ref}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
    Process.sleep(200)
    terminate_os_process(state.os_pid)
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

  defp open_port(executable, args, env) do
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

  defp port_env(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
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
    |> Map.put(:buffer, [])
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

    case {state.status, update["type"], get_in(update, ["content", "text"])} do
      {:prompting, "agent_message_chunk", text} when is_binary(text) ->
        %{state | buffer: [text | state.buffer]}

      _other ->
        state
    end
  end

  defp handle_message(_message, state), do: state

  defp maybe_send_queued_prompt(%{queued_prompt: nil} = state), do: state

  defp maybe_send_queued_prompt(%{queued_prompt: {from, text, timeout}} = state) do
    state
    |> Map.put(:queued_prompt, nil)
    |> send_prompt(from, text, timeout)
  end

  defp finish_prompt(state, result) do
    stop_reason = result["stopReason"] || result["stop_reason"]

    case stop_reason do
      reason when reason in ["end_turn", "done"] ->
        reply_prompt(state, {:ok, state.buffer |> Enum.reverse() |> Enum.join()})

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
        buffer: []
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

  defp terminate_os_process(nil), do: :ok

  defp terminate_os_process(pid) do
    if os_process_alive?(pid) do
      System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    _error -> :ok
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
