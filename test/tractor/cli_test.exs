defmodule Tractor.CLITest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "run/1 returns usage and missing-file exit codes", %{tmp_dir: tmp_dir} do
    assert {2, "", usage} = Tractor.CLI.run([])
    assert usage =~ "Usage:"

    missing = Path.join(tmp_dir, "missing.dot")
    assert {3, "", message} = Tractor.CLI.run(["reap", missing])
    assert message =~ "DOT file not found"
  end

  @tag :tmp_dir
  test "escript exits 0 against fake ACP agent on PATH", %{tmp_dir: tmp_dir} do
    fake_bin = fake_agent_wrapper!(tmp_dir)

    dot = Path.join(tmp_dir, "three.dot")

    File.write!(dot, """
    digraph {
      start [shape=Mdiamond]
      one [shape=box, prompt="one", llm_provider=claude]
      two [shape=box, prompt="two {{one}}", llm_provider=codex]
      three [shape=box, prompt="three {{two}}", llm_provider=gemini]
      exit [shape=Msquare]
      start -> one -> two -> three -> exit
    }
    """)

    assert {_output, 0} = System.cmd("mix", ["escript.build"])

    env = [
      {"PATH", tmp_dir <> ":" <> System.get_env("PATH", "")},
      {"TRACTOR_ACP_CLAUDE_COMMAND", Path.basename(fake_bin)},
      {"TRACTOR_ACP_CODEX_COMMAND", Path.basename(fake_bin)},
      {"TRACTOR_ACP_GEMINI_COMMAND", Path.basename(fake_bin)}
    ]

    tractor = Path.expand("bin/tractor")

    {stdout, exit_code} =
      System.cmd(tractor, ["reap", dot, "--runs-dir", tmp_dir, "--timeout", "15s"],
        env: env,
        stderr_to_stdout: true
      )

    assert exit_code == 0
    run_dir = String.trim(stdout) |> String.split("\n") |> List.last()
    assert File.exists?(Path.join(run_dir, "manifest.json"))
    assert File.exists?(Path.join(run_dir, "one/response.md"))
    assert File.exists?(Path.join(run_dir, "two/response.md"))
    assert File.exists?(Path.join(run_dir, "three/response.md"))
  end

  @tag :tmp_dir
  test "escript exit-code matrix for validation and agent failure", %{tmp_dir: tmp_dir} do
    fake_bin = fake_agent_wrapper!(tmp_dir)
    assert {_output, 0} = System.cmd("mix", ["escript.build"])

    validation_dot = Path.expand("../fixtures/dot/missing_provider.dot", __DIR__)
    tractor = Path.expand("bin/tractor")

    {_stdout, validation_code} =
      System.cmd(tractor, ["reap", validation_dot], stderr_to_stdout: true)

    assert validation_code == 10

    failure_dot = Path.expand("../fixtures/dot/valid_linear.dot", __DIR__)

    env = [
      {"PATH", tmp_dir <> ":" <> System.get_env("PATH", "")},
      {"TRACTOR_ACP_CODEX_COMMAND", Path.basename(fake_bin)},
      {"TRACTOR_FAKE_ACP_MODE", "jsonrpc_error"}
    ]

    {_stdout, failure_code} =
      System.cmd(tractor, ["reap", failure_dot, "--runs-dir", tmp_dir],
        env: env,
        stderr_to_stdout: true
      )

    assert failure_code == 20
  end

  @tag :tmp_dir
  test "escript serve prints URL and serves LiveView shell", %{tmp_dir: tmp_dir} do
    assert {_output, 0} = System.cmd("mix", ["escript.build"])
    tractor = Path.expand("bin/tractor")
    dot = Path.expand("examples/wait_human_review.dot")

    port =
      Port.open({:spawn_executable, tractor}, [
        :binary,
        :exit_status,
        {:line, 4096},
        {:args, ["reap", "--serve", "--port", "0", "--no-open", "--runs-dir", tmp_dir, dot]},
        :stderr_to_stdout
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    url = wait_for_url(port)

    try do
      assert url =~ "/runs/"
      assert {html, 0} = System.cmd("curl", ["-fsS", url])
      assert html =~ "tractor-shell"
      asset_url = URI.merge(url, "/assets/app.css") |> URI.to_string()
      assert {css, 0} = System.cmd("curl", ["-fsS", asset_url])
      assert css =~ "tractor-shell"
    after
      System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end
  end

  @tag :tmp_dir
  test "adopted observer loss mid-run does not abort the CLI", %{tmp_dir: tmp_dir} do
    assert {_output, 0} = System.cmd("mix", ["escript.build"])

    data_dir = Path.join(tmp_dir, "data") |> Path.expand()
    runs_dir = Path.join(data_dir, "runs")
    dot = Path.join(tmp_dir, "slow.dot")
    port_number = 4012

    File.write!(dot, """
    digraph {
      start [shape=Mdiamond]
      tool [shape=parallelogram, command=["sh","-c","sleep 2; printf done"]]
      exit [shape=Msquare]
      start -> tool -> exit
    }
    """)

    observer =
      start_mix_observer!(port_number, data_dir, runs_dir)

    tractor = Path.expand("bin/tractor")

    cli =
      Port.open({:spawn_executable, tractor}, [
        :binary,
        :exit_status,
        {:line, 4096},
        {:args,
         [
           "reap",
           "--serve",
           "--port",
           Integer.to_string(port_number),
           "--no-open",
           "--runs-dir",
           runs_dir,
           dot
         ]},
        :stderr_to_stdout
      ])

    run_id = wait_for_run_id(cli)

    try do
      stop_listener!(port_number)
      assert wait_for_exit_status(cli, 10_000) == 0

      run_dir = Path.join(runs_dir, run_id)
      manifest = run_dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
      assert manifest["status"] == "ok"

      output = Path.join([run_dir, "tool", "response.md"]) |> File.read!()
      assert output == "done"
    after
      close_port(observer)
      close_port(cli)
    end
  end

  @tag :tmp_dir
  test "--serve without dot on PATH returns actionable exit 2", %{tmp_dir: tmp_dir} do
    dot = Path.join(tmp_dir, "serve.dot")

    File.write!(dot, """
    digraph {
      start [shape=Mdiamond]
      exit [shape=Msquare]
      start -> exit
    }
    """)

    original_path = System.get_env("PATH")
    System.put_env("PATH", tmp_dir)

    try do
      assert {2, "", message} = Tractor.CLI.run(["reap", "--serve", dot])
      assert message =~ "install graphviz"
    after
      if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
    end
  end

  defp fake_agent_wrapper!(tmp_dir) do
    path = Path.join(tmp_dir, "fake-acp-agent")
    elixir = System.find_executable("elixir")
    jason_ebin = Path.expand("../../_build/test/lib/jason/ebin", __DIR__)
    fake_agent = Path.expand("../support/fake_acp_agent.exs", __DIR__)

    File.write!(path, """
    #!/bin/sh
    exec #{elixir} --erl "-kernel logger_level emergency" -pa #{jason_ebin} #{fake_agent}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp wait_for_url(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Regex.run(~r{https?://127\.0\.0\.1:\d+/runs/\S+}, line) do
          [url] -> url
          _other -> wait_for_url(port)
        end

      {^port, {:exit_status, status}} ->
        flunk("serve process exited before URL with status #{status}")
    after
      5_000 -> flunk("serve process did not print URL")
    end
  end

  defp wait_for_run_id(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Regex.run(~r/run: ([A-Za-z0-9_-]+)/, line) do
          [_, run_id] -> run_id
          _other -> wait_for_run_id(port)
        end

      {^port, {:exit_status, status}} ->
        flunk("process exited before printing run id with status #{status}")
    after
      10_000 -> flunk("process did not print a run id")
    end
  end

  defp wait_for_exit_status(port, timeout) do
    receive do
      {^port, {:data, _line}} ->
        wait_for_exit_status(port, timeout)

      {^port, {:exit_status, status}} ->
        status
    after
      timeout -> flunk("process did not exit")
    end
  end

  defp start_mix_observer!(port_number, data_dir, runs_dir) do
    mix = System.find_executable("mix") || flunk("mix executable not found")

    port =
      Port.open({:spawn_executable, mix}, [
        :binary,
        :exit_status,
        {:line, 4096},
        {:args, ["phx.server"]},
        {:cd, File.cwd!()},
        {:env,
         [
           {~c"MIX_ENV", ~c"dev"},
           {~c"PORT", String.to_charlist(Integer.to_string(port_number))},
           {~c"TRACTOR_DATA_DIR", String.to_charlist(data_dir)}
         ]},
        :stderr_to_stdout
      ])

    wait_for_observer!(port, port_number, runs_dir, 200)
    port
  end

  defp wait_for_observer!(_observer, _port_number, _runs_dir, 0) do
    flunk("observer did not boot")
  end

  defp wait_for_observer!(observer, port_number, runs_dir, attempts) do
    case Tractor.CLI.probe_observer(port: port_number, runs_dir: runs_dir) do
      {:adopt, _observer} ->
        :ok

      _other ->
        assert_port_alive!(observer)
        Process.sleep(50)
        wait_for_observer!(observer, port_number, runs_dir, attempts - 1)
    end
  end

  defp stop_listener!(port_number) do
    {output, 0} =
      System.cmd("lsof", ["-tiTCP:#{port_number}", "-sTCP:LISTEN"], stderr_to_stdout: true)

    pid =
      output
      |> String.split("\n", trim: true)
      |> List.first()

    System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)
  end

  defp assert_port_alive!(port) do
    receive do
      {^port, {:data, _line}} ->
        :ok

      {^port, {:exit_status, status}} ->
        flunk("observer exited before becoming ready with status #{status}")
    after
      0 -> :ok
    end
  end

  defp close_port(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end
end
