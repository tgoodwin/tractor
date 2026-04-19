defmodule Tractor.ValidationBeforeSpawnTest do
  use ExUnit.Case, async: false

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    original = Application.get_env(:tractor, :agent_client)
    Application.put_env(:tractor, :agent_client, Tractor.AgentClientMock)

    on_exit(fn ->
      if original do
        Application.put_env(:tractor, :agent_client, original)
      else
        Application.delete_env(:tractor, :agent_client)
      end
    end)
  end

  test "invalid DOT exits 10 before starting agent subprocesses" do
    path = Path.expand("../fixtures/dot/missing_provider.dot", __DIR__)

    assert {10, "", stderr} = Tractor.CLI.run(["reap", path])
    assert stderr =~ "missing_provider"
  end
end
