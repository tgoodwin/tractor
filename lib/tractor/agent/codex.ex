defmodule Tractor.Agent.Codex do
  @moduledoc """
  Codex ACP bridge adapter.

  Tractor starts Codex in non-interactive workspace-write mode by default so
  pipeline runs do not stall on provider permission prompts. The ACP bridge
  accepts Codex settings via `-c key=value` config overrides rather than the
  interactive Codex CLI flags.

  Codex sandboxes file access to the session cwd. To widen that allowlist
  (for example, so a node can edit a sibling Git worktree and its metadata),
  set `include_dirs = ["/abs/path", ...]` under `[agents.codex]` in
  `.tractor/config.toml`, or pass `TRACTOR_CODEX_INCLUDE_DIRS=/abs/path1,/abs/path2`.
  """

  @behaviour Tractor.Agent
  alias Tractor.Agent.Config

  @approval_policy_config ~s(approval_policy="never")
  @sandbox_mode_config ~s(sandbox_mode="workspace-write")
  @writable_roots_key "sandbox_workspace_write.writable_roots"

  @impl Tractor.Agent
  def command(_opts) do
    {exe, args, env} = Config.command("codex", "npx", ["@zed-industries/codex-acp"])
    args = args |> append_autonomy_config() |> append_include_dirs()
    {exe, args, env}
  end

  defp append_autonomy_config(args) do
    args
    |> append_config_if_missing("approval_policy", @approval_policy_config)
    |> append_config_if_missing("sandbox_mode", @sandbox_mode_config)
  end

  defp append_config_if_missing(args, key, config_arg) do
    if has_config_key?(args, key) do
      args
    else
      args ++ ["-c", config_arg]
    end
  end

  defp append_include_dirs(args) do
    case include_dirs() do
      [] ->
        args

      dirs ->
        if has_config_key?(args, @writable_roots_key) do
          args
        else
          args ++ ["-c", "#{@writable_roots_key}=#{Jason.encode!(dirs)}"]
        end
    end
  end

  defp include_dirs do
    env_dirs = System.get_env("TRACTOR_CODEX_INCLUDE_DIRS") |> parse_list()

    cfg_dirs =
      Tractor.Config.get([:agents, :codex, :include_dirs], [])
      |> List.wrap()
      |> Enum.map(&to_string/1)

    (env_dirs ++ cfg_dirs)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_list(nil), do: []
  defp parse_list(s) when is_binary(s), do: String.split(s, ",", trim: true)

  defp has_config_key?(args, key) do
    args
    |> config_args()
    |> Enum.any?(&(config_key(&1) == key))
  end

  defp config_args(["-c", value | rest]), do: [value | config_args(rest)]
  defp config_args(["--config", value | rest]), do: [value | config_args(rest)]

  defp config_args([arg | rest]) do
    case String.split(arg, "=", parts: 2) do
      ["--config", value] -> [value | config_args(rest)]
      _ -> config_args(rest)
    end
  end

  defp config_args([]), do: []

  defp config_key(arg), do: arg |> String.split("=", parts: 2) |> hd() |> String.trim()
end
