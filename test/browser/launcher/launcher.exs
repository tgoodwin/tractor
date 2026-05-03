#!/usr/bin/env elixir

defmodule TestLauncher.Log do
  def append(path, message) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "[#{timestamp}] #{message}\n", [:append])
  end
end

defmodule TestLauncher.Job do
  @capture_lock {__MODULE__, :capture}

  def run_sync(request) do
    args = fetch_args(request)
    env = fetch_env(request)
    cwd = fetch_cwd(request)

    {result, captured_stdout, captured_stderr} =
      :global.trans(@capture_lock, fn ->
        {:ok, stdout_io} = StringIO.open("")
        {:ok, stderr_io} = StringIO.open("")
        original_group_leader = Process.group_leader()
        original_stderr = Process.whereis(:standard_error)

        try do
          Process.group_leader(self(), stdout_io)
          true = Process.unregister(:standard_error)
          true = Process.register(stderr_io, :standard_error)

          result =
            with_env_and_cwd(env, cwd, fn ->
              case Tractor.CLI.run(args) do
                {code, stdout, stderr} ->
                  {:ok, %{code: code, stdout: stdout, stderr: stderr}}

                {:serve, _fun} ->
                  {:error, "sync reap received async serve job"}
              end
            end)

          {_, stdout} = StringIO.contents(stdout_io)
          {_, stderr} = StringIO.contents(stderr_io)
          {result, stdout, stderr}
        after
          Process.group_leader(self(), original_group_leader)

          if Process.whereis(:standard_error) == stderr_io do
            true = Process.unregister(:standard_error)
          end

          true = Process.register(original_stderr, :standard_error)
          Process.exit(stdout_io, :normal)
          Process.exit(stderr_io, :normal)
        end
      end)

    case result do
      {:ok, %{code: code, stdout: stdout, stderr: stderr}} ->
        %{
          "ok" => true,
          "code" => code,
          "stdout" => safe_text(captured_stdout <> stdout),
          "stderr" => safe_text(captured_stderr <> stderr)
        }

      {:error, reason} ->
        %{
          "ok" => false,
          "code" => 20,
          "error" => reason,
          "stdout" => safe_text(captured_stdout),
          "stderr" => safe_text(captured_stderr)
        }
    end
  rescue
    error ->
      stacktrace = __STACKTRACE__

      %{
        "ok" => false,
        "code" => 20,
        "error" => Exception.message(error),
        "stdout" => "",
        "stderr" => safe_text(Exception.format(:error, error, stacktrace))
      }
  end

  def run_async(token, request, log_path, server_pid) do
    args = fetch_args(request)
    cwd = fetch_cwd(request)
    env = fetch_env(request) |> Enum.to_list()
    executable = Path.expand("bin/tractor", cwd)

    # `Tractor.CLI.run/1` is non-halting for sync reaps, but `--serve` returns
    # `{:serve, fun}` and that closure eventually exits the emulator via
    # `Tractor.CLI.main/1`'s finish path. Keep async jobs on the same argv
    # contract by delegating to `bin/tractor` as the closest non-halting wrapper.

    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "")

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 4096},
        {:args, args},
        {:cd, cwd},
        {:env,
         Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    state = %{
      token: token,
      port: port,
      os_pid: os_pid,
      log_path: log_path,
      run_id: nil,
      output: []
    }

    loop_async(state, server_pid)
  end

  defp loop_async(state, server_pid) do
    receive do
      {port, {:data, data}} when port == state.port ->
        chunk = normalize_chunk(data)
        File.write!(state.log_path, chunk, [:append])
        output = [chunk | state.output]
        run_id = state.run_id || extract_run_id(chunk)

        if run_id && is_nil(state.run_id) do
          send(server_pid, {:job_started, state.token, run_id, state.log_path})
        end

        loop_async(%{state | output: output, run_id: run_id}, server_pid)

      {port, {:exit_status, status}} when port == state.port ->
        combined = state.output |> Enum.reverse() |> IO.iodata_to_binary()

        send(
          server_pid,
          {:job_finished, state.token, state.run_id, status, combined, state.log_path}
        )

        :ok

      :kill ->
        terminate_os_pid(state.os_pid)
        loop_async(state, server_pid)
    end
  end

  def terminate_os_pid(os_pid) when is_integer(os_pid) and os_pid > 0 do
    os_pid = Integer.to_string(os_pid)
    System.cmd("kill", ["-TERM", os_pid], stderr_to_stdout: true)
    Process.sleep(200)
    System.cmd("kill", ["-KILL", os_pid], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  def terminate_os_pid(_other), do: :ok

  def safe_text(binary) when is_binary(binary) do
    String.replace_invalid(binary, "\uFFFD")
  end

  defp fetch_args(%{"args" => args}) when is_list(args) do
    Enum.map(args, fn
      value when is_binary(value) -> value
      value -> to_string(value)
    end)
  end

  defp fetch_args(_request), do: raise(ArgumentError, "request args must be a list")

  defp fetch_env(%{"env" => env}) when is_map(env) do
    Map.new(env, fn
      {key, value} when is_binary(key) and is_binary(value) -> {key, value}
      {key, value} -> {to_string(key), to_string(value)}
    end)
  end

  defp fetch_env(_request), do: %{}

  defp fetch_cwd(%{"cwd" => cwd}) when is_binary(cwd), do: cwd
  defp fetch_cwd(_request), do: File.cwd!()

  defp with_env_and_cwd(env, cwd, fun) do
    previous = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

    try do
      File.cd!(cwd, fun)
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp normalize_chunk({:eol, data}), do: data <> "\n"
  defp normalize_chunk({:noeol, data}), do: data
  defp normalize_chunk(data) when is_binary(data), do: data

  defp extract_run_id(chunk) do
    case Regex.run(~r/run: ([A-Za-z0-9_-]+)/, chunk) do
      [_, run_id] -> run_id
      _other -> nil
    end
  end
end

defmodule TestLauncher.Server do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def request(payload, timeout \\ :infinity) do
    request(__MODULE__, payload, timeout)
  end

  def request(server, payload, timeout) do
    GenServer.call(server, {:request, payload}, timeout)
  end

  def last_activity_ms(server \\ __MODULE__) do
    GenServer.call(server, :last_activity_ms)
  end

  def handle_connection(server, socket) do
    response =
      with {:ok, line} <- :gen_tcp.recv(socket, 0),
           {:ok, payload} <- Jason.decode(String.trim(line)),
           reply <- request(server, payload, :infinity) do
        reply
      else
        {:error, reason} ->
          %{"ok" => false, "code" => 64, "error" => inspect(reason)}
      end

    :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
    :gen_tcp.close(socket)
  rescue
    error ->
      :gen_tcp.send(
        socket,
        Jason.encode!(%{"ok" => false, "code" => 64, "error" => Exception.message(error)}) <> "\n"
      )

      :gen_tcp.close(socket)
  end

  @impl true
  def init(opts) do
    socket_path = Keyword.fetch!(opts, :socket_path)
    log_path = Keyword.fetch!(opts, :log_path)
    File.mkdir_p!(Path.dirname(socket_path))
    File.rm(socket_path)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :line,
        packet_size: 65_536,
        active: false,
        ifaddr: {:local, String.to_charlist(socket_path)}
      ])

    {:ok, task_supervisor} = Task.Supervisor.start_link()

    server_pid = self()

    acceptor =
      spawn_link(fn ->
        accept_loop(listen_socket, task_supervisor, server_pid)
      end)

    state = %{
      listen_socket: listen_socket,
      acceptor: acceptor,
      socket_path: socket_path,
      log_path: log_path,
      task_supervisor: task_supervisor,
      next_token: 1,
      jobs: %{},
      stop_all: nil,
      shutdown: nil,
      last_activity_ms: System.monotonic_time(:millisecond),
      lock_path: Keyword.get(opts, :lock_path)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:last_activity_ms, _from, state) do
    {:reply, state.last_activity_ms, state}
  end

  def handle_call({:request, %{"op" => "reap"} = request}, _from, state) do
    state = mark_activity(state)

    reply =
      request
      |> TestLauncher.Job.run_sync()
      |> log_failures(state.log_path)

    {:reply, reply, state}
  end

  def handle_call({:request, %{"op" => "reap_serve"} = request}, from, state) do
    state = mark_activity(state)
    token = "job-#{state.next_token}"
    log_path = Path.join(Path.dirname(state.log_path), "#{token}.log")
    server_pid = self()

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        TestLauncher.Job.run_async(token, request, log_path, server_pid)
      end)

    jobs =
      Map.put(state.jobs, token, %{
        token: token,
        task_pid: task.pid,
        ref: task.ref,
        waiters: [],
        start_from: from,
        result: nil,
        run_id: nil,
        log_path: log_path,
        state: :starting
      })

    {:noreply, %{state | jobs: jobs, next_token: state.next_token + 1}}
  end

  def handle_call({:request, %{"op" => "wait", "token" => token}}, from, state) do
    state = mark_activity(state)

    case Map.fetch(state.jobs, token) do
      {:ok, %{result: result} = job} when not is_nil(result) ->
        jobs = Map.put(state.jobs, token, %{job | waiters: []})
        {:reply, result, %{state | jobs: jobs}}

      {:ok, job} ->
        jobs = Map.put(state.jobs, token, %{job | waiters: [from | job.waiters]})
        {:noreply, %{state | jobs: jobs}}

      :error ->
        {:reply, %{"ok" => false, "code" => 64, "error" => "unknown token: #{token}"}, state}
    end
  end

  def handle_call({:request, %{"op" => "kill", "token" => token}}, _from, state) do
    state = mark_activity(state)

    case Map.fetch(state.jobs, token) do
      {:ok, %{task_pid: task_pid}} ->
        send(task_pid, :kill)
        {:reply, %{"ok" => true, "token" => token, "killed" => true}, state}

      :error ->
        {:reply, %{"ok" => false, "code" => 64, "error" => "unknown token: #{token}"}, state}
    end
  end

  def handle_call({:request, %{"op" => "stop_all"}}, from, state) do
    state = mark_activity(state)

    running =
      state.jobs
      |> Enum.filter(fn {_token, job} -> job.state in [:starting, :running] end)
      |> Enum.map(fn {token, job} ->
        send(job.task_pid, :kill)
        token
      end)

    if running == [] do
      {:reply, %{"ok" => true, "count" => 0}, state}
    else
      {:noreply,
       %{state | stop_all: %{from: from, tokens: MapSet.new(running), count: length(running)}}}
    end
  end

  def handle_call({:request, %{"op" => "status"}}, _from, state) do
    state = mark_activity(state)

    active_jobs =
      state.jobs
      |> Enum.filter(fn {_token, job} -> job.state in [:starting, :running] end)
      |> Enum.map(fn {token, job} ->
        %{"token" => token, "run_id" => job.run_id, "log_path" => job.log_path}
      end)

    {:reply,
     %{
       "ok" => true,
       "count" => length(active_jobs),
       "active_jobs" => active_jobs,
       "os_pid" => System.pid()
     }, state}
  end

  def handle_call({:request, %{"op" => "shutdown"}}, from, state) do
    state = mark_activity(state)

    running =
      state.jobs
      |> Enum.filter(fn {_token, job} -> job.state in [:starting, :running] end)
      |> Enum.map(fn {token, job} ->
        send(job.task_pid, :kill)
        token
      end)

    state = %{
      state
      | shutdown: %{from: from, tokens: MapSet.new(running), count: length(running)}
    }

    if running == [] do
      {:reply, %{"ok" => true, "count" => 0}, state, {:continue, :halt}}
    else
      {:noreply, state}
    end
  end

  def handle_call({:request, %{"op" => op}}, _from, state) do
    state = mark_activity(state)
    {:reply, %{"ok" => false, "code" => 64, "error" => "unknown op: #{op}"}, state}
  end

  def handle_info({:job_started, token, run_id, log_path}, state) do
    state = mark_activity(state)

    case Map.fetch(state.jobs, token) do
      {:ok, job} ->
        if job.start_from do
          GenServer.reply(
            job.start_from,
            %{"ok" => true, "token" => token, "run_id" => run_id, "log_path" => log_path}
          )
        end

        jobs =
          Map.put(state.jobs, token, %{job | start_from: nil, run_id: run_id, state: :running})

        {:noreply, %{state | jobs: jobs}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:job_finished, token, run_id, status, output, log_path}, state) do
    state = mark_activity(state)

    result = %{
      "ok" => status == 0,
      "code" => status,
      "stdout" => "",
      "stderr" => TestLauncher.Job.safe_text(output),
      "run_id" => run_id,
      "log_path" => log_path
    }

    state =
      case Map.fetch(state.jobs, token) do
        {:ok, job} ->
          if job.start_from do
            GenServer.reply(
              job.start_from,
              %{
                "ok" => false,
                "code" => status,
                "error" => "serve job exited before returning a run id",
                "stderr" => TestLauncher.Job.safe_text(output)
              }
            )
          end

          Enum.each(job.waiters, &GenServer.reply(&1, result))

          jobs =
            Map.put(state.jobs, token, %{
              job
              | start_from: nil,
                waiters: [],
                result: result,
                state: :done,
                run_id: run_id
            })

          %{state | jobs: jobs}

        :error ->
          state
      end

    {:noreply, finish_pending(state)}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    case Enum.find(state.jobs, fn {_token, job} -> job.ref == ref end) do
      {token, job} ->
        Process.demonitor(ref, [:flush])
        jobs = Map.put(state.jobs, token, %{job | ref: nil})
        {:noreply, %{state | jobs: jobs}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.jobs, fn {_token, job} -> job.ref == ref end) do
      {_token, %{result: result}} when not is_nil(result) ->
        {:noreply, state}

      {token, job} ->
        {:noreply, mark_job_crashed(state, token, job, reason)}

      nil ->
        {:noreply, state}
    end
  end

  defp mark_job_crashed(state, token, job, reason) do
    reply = %{"ok" => false, "code" => 20, "error" => "job crashed: #{inspect(reason)}"}

    if job.start_from, do: GenServer.reply(job.start_from, reply)
    Enum.each(job.waiters, &GenServer.reply(&1, reply))

    jobs =
      Map.put(state.jobs, token, %{
        job
        | start_from: nil,
          waiters: [],
          result: reply,
          state: :done
      })

    finish_pending(%{state | jobs: jobs})
  end

  @impl true
  def handle_continue(:halt, state) do
    cleanup_socket(state)
    System.halt(0)
  end

  defp finish_pending(state) do
    state
    |> maybe_finish_stop_all()
    |> maybe_finish_shutdown()
  end

  defp maybe_finish_stop_all(%{stop_all: nil} = state), do: state

  defp maybe_finish_stop_all(state) do
    remaining =
      state.stop_all.tokens
      |> Enum.filter(fn token ->
        case Map.get(state.jobs, token) do
          nil -> false
          job -> job.state in [:starting, :running]
        end
      end)
      |> MapSet.new()

    if MapSet.size(remaining) == 0 do
      GenServer.reply(state.stop_all.from, %{"ok" => true, "count" => state.stop_all.count})
      %{state | stop_all: nil}
    else
      %{state | stop_all: %{state.stop_all | tokens: remaining}}
    end
  end

  defp maybe_finish_shutdown(%{shutdown: nil} = state), do: state

  defp maybe_finish_shutdown(state) do
    remaining =
      state.shutdown.tokens
      |> Enum.filter(fn token ->
        case Map.get(state.jobs, token) do
          nil -> false
          job -> job.state in [:starting, :running]
        end
      end)
      |> MapSet.new()

    if MapSet.size(remaining) == 0 do
      GenServer.reply(state.shutdown.from, %{"ok" => true, "count" => state.shutdown.count})
      send(self(), :halt_launcher)
      %{state | shutdown: nil}
    else
      %{state | shutdown: %{state.shutdown | tokens: remaining}}
    end
  end

  def handle_info(:halt_launcher, state) do
    {:noreply, state, {:continue, :halt}}
  end

  def handle_info({:accept_error, reason}, state) do
    TestLauncher.Log.append(state.log_path, "accept error: #{inspect(reason)}")
    {:stop, reason, state}
  end

  defp accept_loop(listen_socket, task_supervisor, server_pid) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        {:ok, pid} =
          Task.Supervisor.start_child(task_supervisor, fn ->
            receive do
              {:handle_socket, accepted_socket} -> handle_connection(server_pid, accepted_socket)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, {:handle_socket, socket})
        accept_loop(listen_socket, task_supervisor, server_pid)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(server_pid, {:accept_error, reason})
    end
  end

  defp cleanup_socket(state) do
    :gen_tcp.close(state.listen_socket)
    File.rm(state.socket_path)
    release_lock(state.lock_path)
  end

  defp mark_activity(state) do
    %{state | last_activity_ms: System.monotonic_time(:millisecond)}
  end

  defp release_lock(nil), do: :ok

  defp release_lock(lock_path) do
    File.rm(lock_path)
    :ok
  end

  defp log_failures(%{"ok" => false, "error" => error} = reply, log_path) do
    TestLauncher.Log.append(log_path, "job failure: #{error}")
    reply
  end

  defp log_failures(reply, _log_path), do: reply
end

defmodule TestLauncher.ParentWatchdog do
  use GenServer

  @tick_ms 2_000
  @inactivity_ms 5 * 60 * 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      parent_pid: parent_pid(),
      log_path: Keyword.fetch!(opts, :log_path),
      server: Keyword.get(opts, :server, TestLauncher.Server)
    }

    {:ok, schedule_tick(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    cond do
      not os_pid_alive?(state.parent_pid) ->
        halt(state, "parent pid #{state.parent_pid} is no longer alive")

      inactive?(state) ->
        halt(state, "launcher inactive for #{@inactivity_ms}ms")

      true ->
        {:noreply, schedule_tick(state)}
    end
  end

  defp parent_pid do
    case System.get_env("TRACTOR_BROWSER_LAUNCHER_PARENT_PID") do
      nil -> :os.getppid() |> to_string()
      "" -> :os.getppid() |> to_string()
      pid -> pid
    end
  end

  defp os_pid_alive?(pid) do
    {_output, status} = System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true)
    status == 0
  rescue
    _error -> false
  end

  defp inactive?(state) do
    now_ms = System.monotonic_time(:millisecond)
    last_activity_ms = TestLauncher.Server.last_activity_ms(state.server)
    now_ms - last_activity_ms >= @inactivity_ms
  rescue
    _error -> false
  end

  defp halt(state, message) do
    TestLauncher.Log.append(state.log_path, "watchdog halt: #{message}")
    System.halt(0)
  end

  defp schedule_tick(state) do
    Process.send_after(self(), :tick, @tick_ms)
    state
  end
end

defmodule TestLauncher.CLI do
  def main(_argv) do
    log_dir = System.get_env("TRACTOR_BROWSER_LOG_DIR") || Path.expand("test/browser/logs")

    socket_path =
      System.get_env("TRACTOR_BROWSER_LAUNCHER_SOCK") || Path.join(log_dir, "launcher.sock")

    log_path = Path.join(log_dir, "launcher.log")
    lock_path = Path.join(log_dir, "launcher.lock")

    File.mkdir_p!(log_dir)
    claim_lock!(lock_path)
    System.at_exit(fn _status -> release_lock(lock_path) end)
    start_apps()

    {:ok, _pid} =
      TestLauncher.Server.start_link(
        socket_path: socket_path,
        log_path: log_path,
        lock_path: lock_path
      )

    {:ok, _pid} = TestLauncher.ParentWatchdog.start_link(log_path: log_path)
    TestLauncher.Log.append(log_path, "launcher ready on #{socket_path}")
    watch_stdin()
    Process.sleep(:infinity)
  end

  defp start_apps do
    Enum.each([:jason, :file_system, :tractor], fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _apps} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> raise "failed to start #{app}: #{inspect(reason)}"
      end
    end)
  end

  defp watch_stdin do
    if System.get_env("TRACTOR_BROWSER_LAUNCHER_DISABLE_STDIN_WATCH") == "1" do
      :ok
    else
      spawn_link(&watch_stdin_loop/0)
    end
  end

  defp watch_stdin_loop do
    case IO.binread(:stdio, :eof) do
      :eof -> TestLauncher.Server.request(%{"op" => "shutdown"}, 5_000)
      _other -> :ok
    end
  end

  defp claim_lock!(lock_path) do
    case File.read(lock_path) do
      {:ok, raw} ->
        pid = String.trim(raw)

        if os_pid_alive?(pid) do
          IO.puts(:stderr, "launcher already running with pid #{pid}; lockfile: #{lock_path}")
          System.halt(1)
        end

      {:error, :enoent} ->
        :ok

      {:error, _reason} ->
        :ok
    end

    File.write!(lock_path, System.pid() <> "\n")
  end

  defp release_lock(lock_path) do
    case File.read(lock_path) do
      {:ok, raw} ->
        if String.trim(raw) == System.pid() do
          File.rm(lock_path)
        end

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  defp os_pid_alive?(pid) do
    {_output, status} = System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true)
    status == 0
  rescue
    _error -> false
  end
end

TestLauncher.CLI.main(System.argv())
