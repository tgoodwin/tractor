defmodule Tractor.Handler do
  @moduledoc """
  Behaviour for executable pipeline node handlers.
  """

  alias Tractor.Node

  @callback run(node :: Node.t(), context :: map(), run_dir :: Path.t()) ::
              {:ok, outcome :: String.t(), updates :: map()}
              | {:wait, %{kind: :wait_human, payload: map()}}
              | {:error, reason :: term()}

  @callback default_timeout_ms() :: pos_integer() | nil

  @optional_callbacks default_timeout_ms: 0
end
