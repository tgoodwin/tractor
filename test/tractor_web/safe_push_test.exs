defmodule TractorWeb.SafePushTest do
  use ExUnit.Case, async: true

  alias TractorWeb.SafePush

  test "sanitizes invalid UTF-8 strings before pushing to the socket" do
    socket = %Phoenix.LiveView.Socket{
      private: %{__changed__: %{}, live_temp: %{}}
    }

    payload = %{"text" => <<"oops", 0xE2>>, "nested" => %{"more" => <<"x", 0x80>>}}
    out = SafePush.push_event(socket, "graph:test", payload)

    [["graph:test", pushed]] = Phoenix.LiveView.Utils.get_push_events(out)

    assert is_binary(pushed["text"])
    refute pushed["text"] == <<"oops", 0xE2>>
    assert is_binary(pushed["nested"]["more"])
    refute pushed["nested"]["more"] == <<"x", 0x80>>
  end

  test "passes valid-UTF-8 payloads through unchanged" do
    socket = %Phoenix.LiveView.Socket{
      private: %{__changed__: %{}, live_temp: %{}}
    }

    payload = %{"node_id" => "n1", "state" => "running"}
    out = SafePush.push_event(socket, "graph:node_state", payload)

    [["graph:node_state", pushed]] = Phoenix.LiveView.Utils.get_push_events(out)
    assert pushed == payload
  end
end
