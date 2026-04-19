defmodule Tractor.Agent.Codex do
  @moduledoc """
  Codex ACP bridge adapter.
  """

  @behaviour Tractor.Agent

  @impl Tractor.Agent
  def command(_opts) do
    Tractor.Agent.Config.command("codex", "codex-acp", [])
  end
end
