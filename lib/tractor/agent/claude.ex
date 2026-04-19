defmodule Tractor.Agent.Claude do
  @moduledoc """
  Claude ACP bridge adapter.
  """

  @behaviour Tractor.Agent
  alias Tractor.Agent.Config

  @impl Tractor.Agent
  def command(_opts) do
    Config.command("claude", "npx", ["acp-claude-code"])
  end
end
