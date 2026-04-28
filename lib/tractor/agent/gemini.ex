defmodule Tractor.Agent.Gemini do
  @moduledoc """
  Gemini ACP bridge adapter.

  By default, Tractor sessions block the gemini-cli's globally-configured MCP
  servers via `--allowed-mcp-server-names=__tractor_no_mcp__`, which scopes
  the allowlist to a sentinel name no real server matches. Override by
  setting `mcp = true` under `[agents.gemini]` in `.tractor/config.toml` or
  via `TRACTOR_ACP_GEMINI_MCP=true`.
  """

  @behaviour Tractor.Agent
  alias Tractor.Agent.Config

  @mcp_block_sentinel "__tractor_no_mcp__"

  @impl Tractor.Agent
  def command(_opts) do
    {exe, args, env} = Config.command("gemini", "gemini", ["--acp"])
    args = if mcp_enabled?(), do: args, else: append_mcp_block(args)
    {exe, args, env}
  end

  defp append_mcp_block(args) do
    if Enum.any?(args, &String.starts_with?(&1, "--allowed-mcp-server-names")) do
      args
    else
      args ++ ["--allowed-mcp-server-names=" <> @mcp_block_sentinel]
    end
  end

  defp mcp_enabled? do
    case System.get_env("TRACTOR_ACP_GEMINI_MCP") do
      nil -> Tractor.Config.get([:agents, :gemini], %{}) |> Map.get("mcp", false) == true
      "true" -> true
      _ -> false
    end
  end
end
