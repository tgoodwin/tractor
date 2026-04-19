defmodule TractorWeb.ServerTest do
  use ExUnit.Case, async: false

  test "normal reap does not open the default Phoenix listener" do
    assert {:error, _reason} = :gen_tcp.connect({127, 0, 0, 1}, 4000, [], 100)
  end

  test "server config binds only to loopback" do
    original = Application.get_env(:tractor, TractorWeb.Endpoint)

    on_exit(fn ->
      if original do
        Application.put_env(:tractor, TractorWeb.Endpoint, original)
      else
        Application.delete_env(:tractor, TractorWeb.Endpoint)
      end
    end)

    assert :ok = TractorWeb.Server.configure(port: 0)

    config = Application.fetch_env!(:tractor, TractorWeb.Endpoint)
    assert get_in(config, [:http, :ip]) == {127, 0, 0, 1}
    assert config[:server] == true
  end
end
