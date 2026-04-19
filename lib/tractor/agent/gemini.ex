defmodule Tractor.Agent.Gemini do
  @moduledoc """
  Gemini ACP bridge adapter.
  """

  @behaviour Tractor.Agent

  @impl Tractor.Agent
  def command(_opts) do
    Tractor.Agent.Config.command("gemini", "gemini", ["--acp"])
  end
end
