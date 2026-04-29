defmodule Tractor.Agent.Gemini do
  @moduledoc """
  Gemini ACP bridge adapter.

  By default, Tractor sessions block the gemini-cli's globally-configured MCP
  servers via `--allowed-mcp-server-names=__tractor_no_mcp__`, which scopes
  the allowlist to a sentinel name no real server matches. Override by
  setting `mcp = true` under `[agents.gemini]` in `.tractor/config.toml` or
  via `TRACTOR_ACP_GEMINI_MCP=true`.

  Tractor switches Gemini ACP sessions to `yolo` mode by default so pipeline
  runs do not stall on provider permission prompts. Override with
  `TRACTOR_ACP_GEMINI_MODE` or `[agents.gemini].mode`.

  Gemini-cli sandboxes file access to the session cwd plus the project temp
  dir. To widen that allowlist (e.g. so a pipeline node can read a sibling
  worktree), set `include_dirs = ["/abs/path", ...]` under `[agents.gemini]`
  in `.tractor/config.toml`, or pass `TRACTOR_GEMINI_INCLUDE_DIRS=/abs/path1,/abs/path2`.
  """

  @behaviour Tractor.Agent
  alias Tractor.Agent.Config

  @mcp_block_sentinel "__tractor_no_mcp__"

  @impl Tractor.Agent
  def command(_opts) do
    {exe, args, env} = Config.command("gemini", "gemini", ["--acp"])
    args = if mcp_enabled?(), do: args, else: append_mcp_block(args)
    args = append_include_dirs(args)
    {exe, args, env}
  end

  @impl Tractor.Agent
  def session_mode(_opts), do: session_mode()

  defp append_mcp_block(args) do
    if Enum.any?(args, &String.starts_with?(&1, "--allowed-mcp-server-names")) do
      args
    else
      args ++ ["--allowed-mcp-server-names=" <> @mcp_block_sentinel]
    end
  end

  defp append_include_dirs(args) do
    case include_dirs() do
      [] ->
        args

      dirs ->
        if Enum.any?(args, &String.starts_with?(&1, "--include-directories")) do
          args
        else
          args ++ ["--include-directories=" <> Enum.join(dirs, ",")]
        end
    end
  end

  defp include_dirs do
    env_dirs = System.get_env("TRACTOR_GEMINI_INCLUDE_DIRS") |> parse_list()

    cfg_dirs =
      Tractor.Config.get([:agents, :gemini, :include_dirs], [])
      |> List.wrap()
      |> Enum.map(&to_string/1)

    (env_dirs ++ cfg_dirs)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_list(nil), do: []
  defp parse_list(s) when is_binary(s), do: String.split(s, ",", trim: true)

  defp mcp_enabled? do
    case System.get_env("TRACTOR_ACP_GEMINI_MCP") do
      nil -> Tractor.Config.get([:agents, :gemini], %{}) |> Map.get("mcp", false) == true
      "true" -> true
      _ -> false
    end
  end

  defp session_mode do
    System.get_env("TRACTOR_ACP_GEMINI_MODE") ||
      Tractor.Config.get([:agents, :gemini], %{}) |> Map.get("mode") ||
      "yolo"
  end
end
