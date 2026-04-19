defmodule Tractor.Agent.Claude do
  @moduledoc """
  Claude ACP bridge adapter.
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
end
