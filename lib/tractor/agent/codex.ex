defmodule Tractor.Agent.Codex do
  @moduledoc """
  Codex ACP bridge adapter.

  Tractor starts Codex in non-interactive workspace-write mode by default so
  pipeline runs do not stall on provider permission prompts. Override by
  setting `args` under `[agents.codex]` in `.tractor/config.toml` or via
  `TRACTOR_ACP_CODEX_ARGS`.

  Codex sandboxes file access to the session cwd. To widen that allowlist
  (for example, so a node can edit a sibling Git worktree and its metadata),
  set `include_dirs = ["/abs/path", ...]` under `[agents.codex]` in
  `.tractor/config.toml`, or pass `TRACTOR_CODEX_INCLUDE_DIRS=/abs/path1,/abs/path2`.
  """

  @behaviour Tractor.Agent
  alias Tractor.Agent.Config

  @impl Tractor.Agent
  def command(_opts) do
    {exe, args, env} = Config.command("codex", "npx", ["@zed-industries/codex-acp"])
    args = args |> append_autonomy_args() |> append_include_dirs()
    {exe, args, env}
  end

  defp append_autonomy_args(args) do
    args
    |> append_approval_args()
    |> append_sandbox_args()
  end

  defp append_approval_args(args) do
    if has_any_arg?(args, ["-a", "--ask-for-approval", "--full-auto"]) or
         has_arg_prefix?(args, "--ask-for-approval=") or
         bypasses_approvals?(args) do
      args
    else
      args ++ ["-a", "never"]
    end
  end

  defp append_sandbox_args(args) do
    if has_any_arg?(args, ["-s", "--sandbox", "--full-auto"]) or
         has_arg_prefix?(args, "--sandbox=") or
         bypasses_approvals?(args) do
      args
    else
      args ++ ["--sandbox", "workspace-write"]
    end
  end

  defp append_include_dirs(args) do
    case include_dirs() do
      [] ->
        args

      dirs ->
        if has_any_arg?(args, ["--add-dir"]) or has_arg_prefix?(args, "--add-dir=") do
          args
        else
          args ++ Enum.flat_map(dirs, &["--add-dir", &1])
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

  defp has_any_arg?(args, flags), do: Enum.any?(args, &(&1 in flags))
  defp has_arg_prefix?(args, prefix), do: Enum.any?(args, &String.starts_with?(&1, prefix))

  defp bypasses_approvals?(args) do
    "--dangerously-bypass-approvals-and-sandbox" in args
  end
end
