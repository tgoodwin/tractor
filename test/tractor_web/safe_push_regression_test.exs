defmodule TractorWeb.SafePushRegressionTest do
  use ExUnit.Case, async: true

  alias TractorWeb.SafePush

  test "nested invalid UTF-8 in a graph_state-like payload sanitizes per leaf" do
    socket = %Phoenix.LiveView.Socket{
      private: %{__changed__: %{}, live_temp: %{}}
    }

    payload = %{
      "node_states" => %{
        "n1" => %{"label" => <<"hello ", 0xE2>>, "status" => "running"},
        "n2" => %{"label" => "ok", "status" => "succeeded"}
      },
      "edges" => [
        %{"from" => "n1", "to" => "n2", "condition" => <<"reject ", 0x80>>}
      ]
    }

    out = SafePush.push_event(socket, "graph:state", payload)

    [["graph:state", pushed]] = Phoenix.LiveView.Utils.get_push_events(out)

    assert is_binary(pushed["node_states"]["n1"]["label"])
    refute pushed["node_states"]["n1"]["label"] == <<"hello ", 0xE2>>
    assert pushed["node_states"]["n2"]["label"] == "ok"
    [edge] = pushed["edges"]
    refute edge["condition"] == <<"reject ", 0x80>>
    assert is_binary(edge["condition"])

    # And the whole payload survives Jason serialization (the contract LiveView
    # depends on for the websocket frame).
    assert _ = Jason.encode!(pushed)
  end
end
