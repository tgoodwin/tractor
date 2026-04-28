defmodule Tractor.Agent do
  @moduledoc """
  Provider adapter behaviour for resolving ACP bridge commands and per-session
  parameter overrides.

  The optional `session_params/1` callback lets an adapter contribute extra
  fields to the `session/new` JSON-RPC params — for example, to opt out of an
  agent's default behavior of loading global MCP servers / user settings.
  Adapters that don't need overrides can omit the callback (the default is
  an empty map).
  """

  @callback command(opts :: keyword()) ::
              {executable :: String.t(), args :: [String.t()], env :: [{String.t(), String.t()}]}

  @callback session_params(opts :: keyword()) :: map()

  @optional_callbacks session_params: 1

  @spec session_params(module(), keyword()) :: map()
  def session_params(agent_module, opts) do
    if function_exported?(agent_module, :session_params, 1) do
      agent_module.session_params(opts) || %{}
    else
      %{}
    end
  end
end
