defmodule Tractor.Agent.Claude do
  @moduledoc """
  Claude ACP bridge adapter.

  By default, Tractor sessions opt out of the operator's globally-configured
  Claude MCP servers (Figma, Gmail, anki-mcp, etc.) so pipeline runs aren't
  paying their cold-start cost or risking a wedged MCP server killing init.
  Override by setting `mcp = true` under `[agents.claude]` in
  `.tractor/config.toml`, or via `TRACTOR_ACP_CLAUDE_MCP=true`.
  """

  @behaviour Tractor.Agent
  alias Tractor.Agent.Config

  @impl Tractor.Agent
  def command(_opts) do
    {exe, args, env} = Config.command("claude", "npx", ["acp-claude-code"])
    # Claude CLI refuses to launch when CLAUDECODE is set (nested-session check).
    # Unset it for this subprocess regardless of parent env.
    {exe, args, [{"CLAUDECODE", false} | env]}
  end

  @impl Tractor.Agent
  def session_params(_opts) do
    if mcp_enabled?() do
      %{}
    else
      # `claude-code-acp` hardcodes settingSources: ["user", "project", "local"]
      # in the Claude Code SDK options it builds, but spreads the user-provided
      # _meta.claudeCode.options afterward. Setting it to [] here suppresses
      # all on-disk MCP / hooks / agents / plugins config for this session.
      %{
        "_meta" => %{
          "claudeCode" => %{
            "options" => %{
              "settingSources" => []
            }
          }
        }
      }
    end
  end

  defp mcp_enabled? do
    case System.get_env("TRACTOR_ACP_CLAUDE_MCP") do
      nil -> Tractor.Config.get([:agents, :claude, :mcp], false) == true
      "true" -> true
      _ -> false
    end
  end
end
