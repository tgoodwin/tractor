defmodule Tractor.Agent do
  @moduledoc """
  Provider adapter behaviour for resolving ACP bridge commands.
  """

  @callback command(opts :: keyword()) ::
              {executable :: String.t(), args :: [String.t()], env :: [{String.t(), String.t()}]}
end
