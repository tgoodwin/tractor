defmodule Tractor.ConfigTest do
  use ExUnit.Case, async: false

  alias Tractor.Agent.Claude
  alias Tractor.Config

  setup do
    original_path = Application.get_env(:tractor, :config_path)
    original_env = System.get_env("TRACTOR_ACP_CLAUDE_COMMAND")
    Config.reset()

    on_exit(fn ->
      if original_path do
        Application.put_env(:tractor, :config_path, original_path)
      else
        Application.delete_env(:tractor, :config_path)
      end

      if original_env do
        System.put_env("TRACTOR_ACP_CLAUDE_COMMAND", original_env)
      else
        System.delete_env("TRACTOR_ACP_CLAUDE_COMMAND")
      end

      Config.reset()
    end)

    :ok
  end

  @tag :tmp_dir
  test "config.toml overrides adapter default for command + args + env", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "config.toml")

    File.write!(path, """
    [agents.claude]
    command = "claude-code-acp"
    args = ["--extra"]

    [agents.claude.env]
    CUSTOM = "value"
    """)

    Application.put_env(:tractor, :config_path, path)
    Config.reset()
    System.delete_env("TRACTOR_ACP_CLAUDE_COMMAND")
    System.delete_env("TRACTOR_ACP_CLAUDE_ARGS")
    System.delete_env("TRACTOR_ACP_CLAUDE_ENV_JSON")

    {exe, args, env} = Claude.command([])

    assert exe == "claude-code-acp"
    assert args == ["--extra"]
    assert {"CUSTOM", "value"} in env
    # Claude adapter always unsets CLAUDECODE regardless of config.
    assert {"CLAUDECODE", false} in env
  end

  @tag :tmp_dir
  test "env var beats config.toml", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "config.toml")

    File.write!(path, """
    [agents.claude]
    command = "from-config"
    """)

    Application.put_env(:tractor, :config_path, path)
    Config.reset()
    System.put_env("TRACTOR_ACP_CLAUDE_COMMAND", "from-env")

    {exe, _args, _env} = Claude.command([])
    assert exe == "from-env"
  end

  test "missing config file is silently empty" do
    Application.put_env(:tractor, :config_path, "/tmp/does-not-exist-#{System.unique_integer()}")
    Config.reset()
    System.delete_env("TRACTOR_ACP_CLAUDE_COMMAND")

    {exe, args, _env} = Claude.command([])
    assert exe == "npx"
    assert args == ["acp-claude-code"]
  end
end
