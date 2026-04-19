defmodule Tractor.Agent.Codex do
  @moduledoc """
  Codex ACP bridge adapter.
  """

  @behaviour Tractor.Agent
  alias Tractor.Agent.Config

  @impl Tractor.Agent
  def command(_opts) do
    Config.command("codex", "codex-acp", [])
  end
end
