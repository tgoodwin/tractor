defmodule Tractor.Agent.Claude do
  @moduledoc """
  Claude ACP bridge adapter.
  """

  @behaviour Tractor.Agent

  @impl Tractor.Agent
  def command(_opts) do
    Tractor.Agent.Config.command("claude", "npx", ["acp-claude-code"])
  end
end
