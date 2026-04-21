defmodule TractorWeb.ServerTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "normal reap does not start an observer server", %{tmp_dir: tmp_dir} do
    dot = Path.join(tmp_dir, "minimal.dot")

    File.write!(dot, """
    digraph {
      start [shape=Mdiamond]
      exit [shape=Msquare]
      start -> exit
    }
    """)

    before_children = DynamicSupervisor.which_children(Tractor.WebSup)

    assert {0, _stdout, _stderr} =
             Tractor.CLI.run(["reap", dot, "--runs-dir", tmp_dir, "--timeout", "5s"])

    after_children = DynamicSupervisor.which_children(Tractor.WebSup)
    assert after_children == before_children
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
