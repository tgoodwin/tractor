defmodule Tractor.AgentTest do
  use ExUnit.Case, async: false

  alias Tractor.Agent.{Claude, Codex, Gemini}

  setup do
    env_vars = [
      "TRACTOR_ACP_GEMINI_COMMAND",
      "TRACTOR_ACP_GEMINI_ARGS",
      "TRACTOR_ACP_GEMINI_ENV_JSON",
      "TRACTOR_ACP_GEMINI_MCP",
      "TRACTOR_ACP_GEMINI_MODE",
      "TRACTOR_GEMINI_INCLUDE_DIRS",
      "TRACTOR_ACP_CLAUDE_COMMAND",
      "TRACTOR_ACP_CLAUDE_ARGS",
      "TRACTOR_ACP_CLAUDE_ENV_JSON",
      "TRACTOR_ACP_CLAUDE_MCP",
      "TRACTOR_ACP_CLAUDE_PERMISSION_MODE",
      "TRACTOR_ACP_CODEX_COMMAND",
      "TRACTOR_ACP_CODEX_ARGS",
      "TRACTOR_ACP_CODEX_ENV_JSON",
      "TRACTOR_CODEX_INCLUDE_DIRS"
    ]

    originals = Map.new(env_vars, &{&1, System.get_env(&1)})
    Enum.each(env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(originals, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  @gemini_block "--allowed-mcp-server-names=__tractor_no_mcp__"

  test "provider adapters expose default ACP commands" do
    assert Gemini.command([]) == {"gemini", ["--acp", @gemini_block], []}

    assert Claude.command([]) ==
             {"npx", ["@zed-industries/claude-code-acp"],
              [
                {"CLAUDE_CODE_SIMPLE", "1"},
                {"ACP_PERMISSION_MODE", "bypassPermissions"},
                {"CLAUDECODE", false}
              ]}

    assert Codex.command([]) ==
             {"npx",
              [
                "@zed-industries/codex-acp",
                "-c",
                ~s(approval_policy="never"),
                "-c",
                ~s(sandbox_mode="workspace-write")
              ], []}
  end

  test "Claude sessions default to autonomous bypass mode" do
    assert Claude.session_mode([]) == "bypassPermissions"
  end

  test "Gemini sessions default to autonomous yolo mode" do
    assert Gemini.session_mode([]) == "yolo"
  end

  test "Gemini session mode can be overridden directly" do
    System.put_env("TRACTOR_ACP_GEMINI_MODE", "autoEdit")

    assert Gemini.session_mode([]) == "autoEdit"
  end

  test "Codex include dirs are passed as additional writable roots" do
    System.put_env("TRACTOR_CODEX_INCLUDE_DIRS", "/abs/one,/abs/two")

    assert Codex.command([]) ==
             {"npx",
              [
                "@zed-industries/codex-acp",
                "-c",
                ~s(approval_policy="never"),
                "-c",
                ~s(sandbox_mode="workspace-write"),
                "-c",
                ~s(sandbox_workspace_write.writable_roots=["/abs/one","/abs/two"])
              ], []}
  end

  test "Codex config overrides are not double-appended when explicitly configured" do
    System.put_env(
      "TRACTOR_ACP_CODEX_ARGS",
      ~s(["-c","approval_policy=\\"on-request\\"","--config=sandbox_mode=\\"read-only\\"","-c","sandbox_workspace_write.writable_roots=[\\"/already/there\\"]"])
    )

    System.put_env("TRACTOR_CODEX_INCLUDE_DIRS", "/abs/one")

    assert Codex.command([]) ==
             {"npx",
              [
                "-c",
                ~s(approval_policy="on-request"),
                ~s(--config=sandbox_mode="read-only"),
                "-c",
                ~s(sandbox_workspace_write.writable_roots=["/already/there"])
              ], []}
  end

  test "Claude session_params suppresses on-disk MCP / settings by default" do
    assert Claude.session_params([]) == %{
             "_meta" => %{
               "claudeCode" => %{
                 "options" => %{
                   "settingSources" => []
                 }
               }
             }
           }
  end

  test "TRACTOR_ACP_CLAUDE_MCP=true restores claude-code-acp's default settingSources" do
    System.put_env("TRACTOR_ACP_CLAUDE_MCP", "true")
    assert Claude.session_params([]) == %{}
    assert {_exe, _args, env} = Claude.command([])
    refute {"CLAUDE_CODE_SIMPLE", "1"} in env
    assert {"ACP_PERMISSION_MODE", "bypassPermissions"} in env
  end

  test "TRACTOR_ACP_GEMINI_MCP=true drops the gemini MCP allowlist sentinel" do
    System.put_env("TRACTOR_ACP_GEMINI_MCP", "true")
    assert Gemini.command([]) == {"gemini", ["--acp"], []}
  end

  test "Gemini args containing --allowed-mcp-server-names are not double-appended" do
    System.put_env("TRACTOR_ACP_GEMINI_ARGS", ~s(["--acp","--allowed-mcp-server-names=foo"]))
    assert Gemini.command([]) == {"gemini", ["--acp", "--allowed-mcp-server-names=foo"], []}
  end

  test "TRACTOR_GEMINI_INCLUDE_DIRS appends --include-directories" do
    System.put_env("TRACTOR_GEMINI_INCLUDE_DIRS", "/abs/one,/abs/two")

    assert Gemini.command([]) ==
             {"gemini", ["--acp", @gemini_block, "--include-directories=/abs/one,/abs/two"], []}
  end

  test "Gemini does not double-append --include-directories when already in args" do
    System.put_env("TRACTOR_GEMINI_INCLUDE_DIRS", "/abs/one")

    System.put_env(
      "TRACTOR_ACP_GEMINI_ARGS",
      ~s(["--acp","--include-directories=/already/there"])
    )

    assert Gemini.command([]) ==
             {"gemini", ["--acp", "--include-directories=/already/there", @gemini_block], []}
  end

  test "Claude adapter unsets CLAUDECODE even with env overrides" do
    System.put_env("TRACTOR_ACP_CLAUDE_ENV_JSON", ~s({"FOO":"bar"}))

    assert {_exe, _args, env} = Claude.command([])
    assert {"CLAUDECODE", false} in env
    assert {"CLAUDE_CODE_SIMPLE", "1"} in env
    assert {"ACP_PERMISSION_MODE", "bypassPermissions"} in env
    assert {"FOO", "bar"} in env
  end

  test "Claude permission mode can be overridden directly" do
    System.put_env("TRACTOR_ACP_CLAUDE_PERMISSION_MODE", "acceptEdits")

    assert Claude.session_mode([]) == "acceptEdits"
    assert {_exe, _args, env} = Claude.command([])
    assert {"ACP_PERMISSION_MODE", "acceptEdits"} in env
  end

  test "Claude env JSON ACP_PERMISSION_MODE also drives session mode" do
    System.put_env("TRACTOR_ACP_CLAUDE_ENV_JSON", ~s({"ACP_PERMISSION_MODE":"default"}))

    assert Claude.session_mode([]) == "default"
    assert {_exe, _args, env} = Claude.command([])
    assert {"ACP_PERMISSION_MODE", "default"} in env
  end

  test "provider adapters honor command, args, and env JSON overrides" do
    System.put_env("TRACTOR_ACP_GEMINI_COMMAND", "gemini-dev")
    System.put_env("TRACTOR_ACP_GEMINI_ARGS", ~s(["--experimental-acp"]))
    System.put_env("TRACTOR_ACP_GEMINI_ENV_JSON", ~s({"TOKEN":"secret","MODE":"test"}))

    assert Gemini.command([]) ==
             {"gemini-dev", ["--experimental-acp", @gemini_block],
              [{"MODE", "test"}, {"TOKEN", "secret"}]}
  end
end
