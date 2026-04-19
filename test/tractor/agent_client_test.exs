defmodule Tractor.AgentClientTest do
  use ExUnit.Case, async: true

  test "Mox mock is defined for AgentClient" do
    assert Code.ensure_loaded?(Tractor.AgentClientMock)
    assert function_exported?(Tractor.AgentClientMock, :prompt, 3)
  end
end
