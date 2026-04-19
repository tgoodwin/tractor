defmodule TractorTest do
  use ExUnit.Case

  test "starts the sprint-one supervision skeleton" do
    assert Process.whereis(Tractor.RunRegistry)
    assert Process.whereis(Tractor.AgentRegistry)
    assert Process.whereis(Tractor.HandlerTasks)
    assert Process.whereis(Tractor.ACP.SessionSup)
    assert Process.whereis(Tractor.RunSup)
  end
end
