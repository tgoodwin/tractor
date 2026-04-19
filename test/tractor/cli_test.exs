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
end
