defmodule Tractor.AgentClient do
  @moduledoc """
  Behaviour for blocking prompt sessions used by Tractor handlers.
  """

  @callback start_session(agent_module :: module(), opts :: keyword()) ::
              {:ok, pid()} | {:error, term()}

  @callback prompt(pid(), text :: String.t(), timeout()) ::
              {:ok, Tractor.ACP.Turn.t()} | {:error, term()}

  @callback stop(pid()) :: :ok
end
