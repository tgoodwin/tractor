defmodule TestLauncherLockfileTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "second launcher cannot start while the first owns the lockfile", %{tmp_dir: _tmp_dir} do
    root = Path.expand("../../..", __DIR__)
    log_dir = Path.join(System.tmp_dir!(), "tractor-lockfile-#{unique_id()}")
    socket_path = Path.join(log_dir, "launcher.sock")
    lock_path = Path.join(log_dir, "launcher.lock")
    File.mkdir_p!(log_dir)

    first = start_launcher!(root, log_dir, socket_path)

    try do
      assert File.exists?(lock_path)
      second = start_launcher_port(root, log_dir, socket_path)
      {second_status, second_output} = wait_for_port_exit(second, 5_000)

      assert second_status != 0
      assert second_output =~ "launcher already running"

      status = request!(socket_path, %{"op" => "status"})
      assert status["ok"] == true

      shutdown = request!(socket_path, %{"op" => "shutdown"})
      assert shutdown == %{"ok" => true, "count" => 0}
      assert wait_for_port_exit(first.port, 5_000) |> elem(0) == 0
      refute wait_for_file(lock_path, 1_000)
    after
      if Port.info(first.port), do: Port.close(first.port)
      File.rm_rf(log_dir)
      File.rm(lock_path)
    end
  end

  defp start_launcher!(root, log_dir, socket_path) do
    port = start_launcher_port(root, log_dir, socket_path)
    wait_for_launcher!(socket_path, port)
    %{port: port}
  end

  defp start_launcher_port(root, log_dir, socket_path) do
    elixir = System.find_executable("elixir") || raise "elixir executable not found"

    Port.open({:spawn_executable, elixir}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:cd, root},
      {:env, launcher_env(root, log_dir, socket_path)},
      {:args, launcher_args(root)},
      {:line, 4096}
    ])
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
      {~c"TRACTOR_BROWSER_LAUNCHER_PARENT_PID", String.to_charlist(System.pid())},
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

  defp wait_for_launcher!(socket_path, port, attempts \\ 100, output \\ [])

  defp wait_for_launcher!(_socket_path, _port, 0, output) do
    flunk(
      "launcher socket did not appear\n#{output |> Enum.reverse() |> Enum.map_join(&normalize_port_line/1)}"
    )
  end

  defp wait_for_launcher!(socket_path, port, attempts, output) do
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
          {^port, {:data, line}} ->
            wait_for_launcher!(socket_path, port, attempts - 1, [line | output])

          {^port, {:exit_status, status}} ->
            flunk(
              "launcher exited before socket appeared (status #{status})\n" <>
                (output |> Enum.reverse() |> Enum.map_join(&normalize_port_line/1))
            )
        after
          100 ->
            wait_for_launcher!(socket_path, port, attempts - 1, output)
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

  defp wait_for_port_exit(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_port_exit(port, deadline, [])
  end

  defp do_wait_for_port_exit(port, deadline, output) do
    receive do
      {^port, {:exit_status, status}} ->
        {status, output |> Enum.reverse() |> Enum.map_join(&normalize_port_line/1)}

      {^port, {:data, line}} ->
        do_wait_for_port_exit(port, deadline, [line | output])
    after
      100 ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("launcher port did not exit")
        else
          do_wait_for_port_exit(port, deadline, output)
        end
    end
  end

  defp wait_for_file(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_file(path, deadline)
  end

  defp do_wait_for_file(path, deadline) do
    cond do
      not File.exists?(path) ->
        false

      System.monotonic_time(:millisecond) >= deadline ->
        true

      true ->
        Process.sleep(50)
        do_wait_for_file(path, deadline)
    end
  end

  defp normalize_port_line({:eol, line}), do: line <> "\n"
  defp normalize_port_line({:noeol, line}), do: line
  defp normalize_port_line(line) when is_binary(line), do: line
  defp unique_id, do: System.unique_integer([:positive]) |> Integer.to_string()
end
