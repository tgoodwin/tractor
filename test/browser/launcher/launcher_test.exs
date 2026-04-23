defmodule TestLauncherTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "launcher handles sync and async browser harness ops", %{tmp_dir: tmp_dir} do
    assert {_output, 0} = System.cmd("mix", ["escript.build"])

    launcher = start_launcher!(tmp_dir)

    try do
      sync_runs_dir = Path.join(tmp_dir, "sync-runs")

      sync =
        request!(launcher, %{
          "op" => "reap",
          "args" => ["reap", "examples/haiku_feedback.dot", "--runs-dir", sync_runs_dir],
          "env" => fake_acp_env(tmp_dir, launcher.root),
          "cwd" => launcher.root
        })

      assert sync["ok"] == true
      assert sync["code"] == 0
      assert sync["stderr"] =~ "run: "

      sync_run_dir = String.trim(sync["stdout"])
      assert File.exists?(Path.join(sync_run_dir, "_run/events.jsonl"))

      serve_runs_dir = Path.join(tmp_dir, "serve-runs")

      serve_one =
        request!(launcher, %{
          "op" => "reap_serve",
          "args" => [
            "reap",
            "examples/wait_human_review.dot",
            "--serve",
            "--no-open",
            "--port",
            "0",
            "--runs-dir",
            serve_runs_dir
          ],
          "env" => fake_acp_env(tmp_dir, launcher.root),
          "cwd" => launcher.root
        })

      assert serve_one["ok"] == true
      assert is_binary(serve_one["token"])
      assert is_binary(serve_one["run_id"])
      assert File.exists?(serve_one["log_path"])

      status = request!(launcher, %{"op" => "status"})
      assert status["ok"] == true
      assert status["count"] == 1

      killed = request!(launcher, %{"op" => "kill", "token" => serve_one["token"]})
      assert killed == %{"ok" => true, "killed" => true, "token" => serve_one["token"]}

      waited = request!(launcher, %{"op" => "wait", "token" => serve_one["token"]})
      assert is_integer(waited["code"])
      assert waited["run_id"] == serve_one["run_id"]
      assert File.exists?(waited["log_path"])

      serve_two =
        request!(launcher, %{
          "op" => "reap_serve",
          "args" => [
            "reap",
            "examples/wait_human_review.dot",
            "--serve",
            "--no-open",
            "--port",
            "0",
            "--runs-dir",
            serve_runs_dir
          ],
          "env" => fake_acp_env(tmp_dir, launcher.root),
          "cwd" => launcher.root
        })

      stopped = request!(launcher, %{"op" => "stop_all"})
      assert stopped == %{"ok" => true, "count" => 1}

      waited_after_stop = request!(launcher, %{"op" => "wait", "token" => serve_two["token"]})
      assert is_integer(waited_after_stop["code"])
      assert waited_after_stop["run_id"] == serve_two["run_id"]

      final_status = request!(launcher, %{"op" => "status"})
      assert final_status["count"] == 0

      shutdown = request!(launcher, %{"op" => "shutdown"})
      assert shutdown == %{"ok" => true, "count" => 0}
      assert wait_for_port_exit(launcher.port) == 0
    after
      if Port.info(launcher.port), do: Port.close(launcher.port)
    end
  end

  defp start_launcher!(_tmp_dir) do
    root = Path.expand("../../..", __DIR__)

    log_dir =
      Path.join(System.tmp_dir!(), "tractor-launcher-#{System.unique_integer([:positive])}")

    socket_path = Path.join(log_dir, "launcher.sock")
    elixir = System.find_executable("elixir") || raise "elixir executable not found"

    port =
      Port.open({:spawn_executable, elixir}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, root},
        {:env, launcher_env(log_dir, socket_path)},
        {:args, launcher_args(root)},
        {:line, 4096}
      ])

    wait_for_launcher!(socket_path, port)
    %{port: port, root: root, socket_path: socket_path}
  end

  defp launcher_env(log_dir, socket_path) do
    env = [
      {~c"MIX_ENV", ~c"test"},
      {~c"TRACTOR_BROWSER_LOG_DIR", String.to_charlist(log_dir)},
      {~c"TRACTOR_BROWSER_LAUNCHER_SOCK", String.to_charlist(socket_path)},
      {~c"TRACTOR_BROWSER_LAUNCHER_DISABLE_STDIN_WATCH", ~c"1"}
    ]

    case file_system_env(root_dir()) do
      nil -> env
      value -> [{~c"FILESYSTEM_FSMAC_EXECUTABLE_FILE", String.to_charlist(value)} | env]
    end
  end

  defp launcher_args(root) do
    code_paths =
      root
      |> Path.join("_build/test/lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(fn path -> ["-pa", path] end)

    ["--no-halt" | code_paths] ++ [Path.join(root, "test/browser/launcher/launcher.exs")]
  end

  defp fake_acp_env(tmp_dir, root) do
    elixir = System.find_executable("elixir") || raise "elixir executable not found"
    jason_ebin = Path.join(root, "_build/test/lib/jason/ebin")
    fake_agent = Path.join(root, "test/support/fake_acp_agent.exs")

    %{
      "TRACTOR_DATA_DIR" => Path.join(tmp_dir, "data"),
      "FAKE_ACP_EVENTS" => "full",
      "TRACTOR_ACP_CLAUDE_COMMAND" => elixir,
      "TRACTOR_ACP_CLAUDE_ARGS" =>
        Jason.encode!(["--erl", "-kernel logger_level emergency", "-pa", jason_ebin, fake_agent]),
      "TRACTOR_ACP_CODEX_COMMAND" => elixir,
      "TRACTOR_ACP_CODEX_ARGS" =>
        Jason.encode!(["--erl", "-kernel logger_level emergency", "-pa", jason_ebin, fake_agent]),
      "TRACTOR_ACP_GEMINI_COMMAND" => elixir,
      "TRACTOR_ACP_GEMINI_ARGS" =>
        Jason.encode!(["--erl", "-kernel logger_level emergency", "-pa", jason_ebin, fake_agent])
    }
    |> maybe_put_file_system_env(root)
  end

  defp maybe_put_file_system_env(env, root) do
    case file_system_env(root) do
      nil -> env
      value -> Map.put(env, "FILESYSTEM_FSMAC_EXECUTABLE_FILE", value)
    end
  end

  defp file_system_env(root) do
    path = Path.join(root, "deps/file_system/priv/mac_listener")
    if File.regular?(path), do: path
  end

  defp root_dir, do: Path.expand("../../..", __DIR__)

  defp request!(launcher, payload) do
    socket = connect_socket!(launcher.socket_path)

    :ok = :gen_tcp.send(socket, Jason.encode!(payload) <> "\n")
    line = recv_until_closed(socket, [])
    :gen_tcp.close(socket)
    Jason.decode!(String.trim(line))
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

  defp normalize_port_line({:eol, line}), do: line <> "\n"
  defp normalize_port_line({:noeol, line}), do: line
  defp normalize_port_line(line) when is_binary(line), do: line

  defp recv_until_closed(socket, acc) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, chunk} -> recv_until_closed(socket, [acc, chunk])
      {:error, :closed} -> IO.iodata_to_binary(acc)
    end
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

  defp wait_for_port_exit(port, attempts \\ 100)

  defp wait_for_port_exit(_port, 0), do: flunk("launcher port did not exit")

  defp wait_for_port_exit(port, attempts) do
    receive do
      {^port, {:exit_status, status}} -> status
      {^port, {:data, _line}} -> wait_for_port_exit(port, attempts)
    after
      100 -> wait_for_port_exit(port, attempts - 1)
    end
  end
end
