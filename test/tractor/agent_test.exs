defmodule Tractor.AgentTest do
  use ExUnit.Case, async: false

  setup do
    env_vars = [
      "TRACTOR_ACP_GEMINI_COMMAND",
      "TRACTOR_ACP_GEMINI_ARGS",
      "TRACTOR_ACP_GEMINI_ENV_JSON",
      "TRACTOR_ACP_CLAUDE_COMMAND",
      "TRACTOR_ACP_CLAUDE_ARGS",
      "TRACTOR_ACP_CLAUDE_ENV_JSON",
      "TRACTOR_ACP_CODEX_COMMAND",
      "TRACTOR_ACP_CODEX_ARGS",
      "TRACTOR_ACP_CODEX_ENV_JSON"
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

  test "provider adapters expose default ACP commands" do
    assert Tractor.Agent.Gemini.command([]) == {"gemini", ["--acp"], []}
    assert Tractor.Agent.Claude.command([]) == {"npx", ["acp-claude-code"], []}
    assert Tractor.Agent.Codex.command([]) == {"codex-acp", [], []}
  end

  test "provider adapters honor command, args, and env JSON overrides" do
    System.put_env("TRACTOR_ACP_GEMINI_COMMAND", "gemini-dev")
    System.put_env("TRACTOR_ACP_GEMINI_ARGS", ~s(["--experimental-acp"]))
    System.put_env("TRACTOR_ACP_GEMINI_ENV_JSON", ~s({"TOKEN":"secret","MODE":"test"}))

    assert Tractor.Agent.Gemini.command([]) ==
             {"gemini-dev", ["--experimental-acp"], [{"MODE", "test"}, {"TOKEN", "secret"}]}
  end
end
