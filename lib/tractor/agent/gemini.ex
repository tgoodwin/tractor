defmodule Tractor.Agent.Gemini do
  @moduledoc """
  Gemini ACP bridge adapter.
  """

  @behaviour Tractor.Agent
  alias Tractor.Agent.Config

  @impl Tractor.Agent
  def command(_opts) do
    Config.command("gemini", "gemini", ["--acp"])
  end
end
