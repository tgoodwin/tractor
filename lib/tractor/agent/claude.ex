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
    env =
      env
      |> put_env("CLAUDECODE", false)
      |> put_env_default("ACP_PERMISSION_MODE", permission_mode())
      |> maybe_enable_simple_mode()

    {exe, args, env}
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

  @impl Tractor.Agent
  def session_mode(_opts), do: permission_mode()

  defp mcp_enabled? do
    case System.get_env("TRACTOR_ACP_CLAUDE_MCP") do
      nil -> Tractor.Config.get([:agents, :claude, :mcp], false) == true
      "true" -> true
      _ -> false
    end
  end

  defp permission_mode do
    System.get_env("TRACTOR_ACP_CLAUDE_PERMISSION_MODE") ||
      env_json_permission_mode() ||
      config_permission_mode() ||
      config_env_permission_mode() ||
      "bypassPermissions"
  end

  defp env_json_permission_mode do
    case System.get_env("TRACTOR_ACP_CLAUDE_ENV_JSON") do
      nil ->
        nil

      json ->
        case Jason.decode(json) do
          {:ok, %{} = env} -> env |> Map.get("ACP_PERMISSION_MODE") |> stringify_mode()
          _other -> nil
        end
    end
  end

  defp config_permission_mode do
    case Tractor.Config.get([:agents, :claude], %{}) do
      %{} = config -> Map.get(config, "permission_mode")
      _other -> nil
    end
    |> stringify_mode()
  end

  defp config_env_permission_mode do
    case Tractor.Config.get([:agents, :claude, :env], %{}) do
      %{} = env -> Map.get(env, "ACP_PERMISSION_MODE")
      _other -> nil
    end
    |> stringify_mode()
  end

  defp stringify_mode(nil), do: nil
  defp stringify_mode(mode), do: to_string(mode)

  defp maybe_enable_simple_mode(env) do
    if mcp_enabled?() do
      env
    else
      put_env_default(env, "CLAUDE_CODE_SIMPLE", "1")
    end
  end

  defp put_env(env, key, value) do
    [{key, value} | Enum.reject(env, fn {existing, _value} -> existing == key end)]
  end

  defp put_env_default(env, key, value) do
    if Enum.any?(env, fn {existing, _value} -> existing == key end) do
      env
    else
      [{key, value} | env]
    end
  end
end
