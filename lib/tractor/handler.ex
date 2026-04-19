defmodule Tractor.Handler do
  @moduledoc """
  Behaviour for executable pipeline node handlers.
  """

  alias Tractor.Node

  @callback run(node :: Node.t(), context :: map(), run_dir :: Path.t()) ::
              {:ok, outcome :: String.t(), updates :: map()}
              | {:error, reason :: term()}
end
