defmodule Tractor.Runner.FailureTest do
  use ExUnit.Case, async: true

  alias Tractor.Runner.Failure

  test "classifies known transient reasons" do
    for reason <- [
          {:handler_crash, :boom},
          :acp_disconnect,
          {:provider_timeout, :claude},
          :node_timeout,
          {:error, :overloaded},
          {:port_exit, 1},
          {:jsonrpc_error, %{"code" => -32_000}},
          :timeout
        ] do
      assert Failure.classify(reason) == :transient
    end
  end

  test "classifies known permanent reasons and unknown reasons" do
    for reason <- [
          :judge_parse_error,
          {:invalid_timeout, "500ms"},
          {:invalid_retry_config, "wobble"},
          {:unknown_tuple, :boom}
        ] do
      assert Failure.classify(reason) == :permanent
    end
  end
end
