defmodule TestLauncherParentWatchdogTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  @tag timeout: 10_000
  test "launcher halts when its parent wrapper dies", %{tmp_dir: _tmp_dir} do
    root = Path.expand("../../..", __DIR__)
    log_dir = Path.join(System.tmp_dir!(), "tractor-parent-watchdog-#{unique_id()}")
    socket_path = Path.join(log_dir, "launcher.sock")
    File.mkdir_p!(log_dir)

    wrapper = start_wrapper!(root, log_dir, socket_path)

    try do
      wait_for_launcher!(socket_path, wrapper)
      status = request!(socket_path, %{"op" => "status"})
      launcher_os_pid = status["os_pid"] || flunk("status did not include os_pid")
      Process.put(:launcher_os_pid, launcher_os_pid)
      assert os_pid_alive?(launcher_os_pid)

      terminate_os_pid(wrapper.os_pid, "-KILL")
      assert wait_for_pid_exit(launcher_os_pid, 5_000)
    after
      terminate_os_pid(wrapper.os_pid, "-KILL")
      terminate_os_pid(Process.get(:launcher_os_pid), "-KILL")
      File.rm_rf(log_dir)
    end
  end

  defp start_wrapper!(root, log_dir, socket_path) do
    bash = System.find_executable("bash") || raise "bash executable not found"
    launcher_cmd = launcher_command(root)

    script = """
    set -euo pipefail
    export TRACTOR_BROWSER_LAUNCHER_PARENT_PID=$$
    #{launcher_cmd} &
    echo "launcher_pid=$!"
    wait
    """

    port =
      Port.open({:spawn_executable, bash}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, root},
        {:env, launcher_env(root, log_dir, socket_path)},
        {:args, ["-c", script]},
        {:line, 4096}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    %{port: port, os_pid: os_pid}
  end

  defp launcher_command(root) do
    elixir = System.find_executable("elixir") || raise "elixir executable not found"

    [elixir | launcher_args(root)]
    |> Enum.map_join(" ", &sh_quote/1)
  end

  defp launcher_args(root) do
    code_paths =
      root
      |> Path.join("_build/test/lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(fn path -> ["-pa", path] end)

    ["--no-halt" | code_paths] ++ [Path.join(root, "test/browser/launcher/launcher.exs")]
  end

  defp launcher_env(root, log_dir, socket_path) do
    env = [
      {~c"MIX_ENV", ~c"test"},
      {~c"TRACTOR_BROWSER_LOG_DIR", String.to_charlist(log_dir)},
      {~c"TRACTOR_BROWSER_LAUNCHER_SOCK", String.to_charlist(socket_path)},
      {~c"TRACTOR_BROWSER_LAUNCHER_DISABLE_STDIN_WATCH", ~c"1"}
    ]

    case file_system_env(root) do
      nil -> env
      value -> [{~c"FILESYSTEM_FSMAC_EXECUTABLE_FILE", String.to_charlist(value)} | env]
    end
  end

  defp file_system_env(root) do
    path = Path.join(root, "deps/file_system/priv/mac_listener")
    if File.regular?(path), do: path
  end

  defp sh_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp wait_for_launcher!(socket_path, wrapper, attempts \\ 100, output \\ [])

  defp wait_for_launcher!(_socket_path, _wrapper, 0, output) do
    flunk(
      "launcher socket did not appear\n#{output |> Enum.reverse() |> Enum.map_join(&normalize_port_line/1)}"
    )
  end

  defp wait_for_launcher!(socket_path, wrapper, attempts, output) do
    case :gen_tcp.connect({:local, String.to_charlist(socket_path)}, 0, [
           :binary,
           packet: :raw,
           active: false
         ]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _reason} ->
        receive do
          {port, {:data, line}} when port == wrapper.port ->
            wait_for_launcher!(socket_path, wrapper, attempts - 1, [line | output])

          {port, {:exit_status, status}} when port == wrapper.port ->
            flunk(
              "launcher wrapper exited before socket appeared (status #{status})\n" <>
                (output |> Enum.reverse() |> Enum.map_join(&normalize_port_line/1))
            )
        after
          100 ->
            wait_for_launcher!(socket_path, wrapper, attempts - 1, output)
        end
    end
  end

  defp request!(socket_path, payload) do
    socket = connect_socket!(socket_path)

    :ok = :gen_tcp.send(socket, Jason.encode!(payload) <> "\n")
    line = recv_until_closed(socket, [])
    :gen_tcp.close(socket)
    Jason.decode!(String.trim(line))
  end

  defp connect_socket!(socket_path, attempts \\ 50)

  defp connect_socket!(_socket_path, 0), do: flunk("failed to connect to launcher socket")

  defp connect_socket!(socket_path, attempts) do
    case :gen_tcp.connect({:local, String.to_charlist(socket_path)}, 0, [
           :binary,
           packet: :raw,
           active: false
         ]) do
      {:ok, socket} ->
        socket

      {:error, _reason} ->
        Process.sleep(100)
        connect_socket!(socket_path, attempts - 1)
    end
  end

  defp recv_until_closed(socket, acc) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, chunk} -> recv_until_closed(socket, [acc, chunk])
      {:error, :closed} -> IO.iodata_to_binary(acc)
    end
  end

  defp wait_for_pid_exit(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_pid_exit(to_string(os_pid), deadline)
  end

  defp do_wait_for_pid_exit(os_pid, deadline) do
    cond do
      not os_pid_alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(100)
        do_wait_for_pid_exit(os_pid, deadline)
    end
  end

  defp os_pid_alive?(pid) do
    {_output, status} = System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true)
    status == 0
  rescue
    _error -> false
  end

  defp terminate_os_pid(nil, _signal), do: :ok

  defp terminate_os_pid(pid, signal) do
    System.cmd("kill", [signal, to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  defp normalize_port_line({:eol, line}), do: line <> "\n"
  defp normalize_port_line({:noeol, line}), do: line
  defp normalize_port_line(line) when is_binary(line), do: line
  defp unique_id, do: System.unique_integer([:positive]) |> Integer.to_string()
end
