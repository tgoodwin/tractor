defmodule TractorWeb.RunLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Tractor.{DotParser, Run, RunEvents, Validator}

  @endpoint TractorWeb.Endpoint

  setup %{tmp_dir: tmp_dir} do
    start_supervised!({TractorWeb.Server, port: 0})
    {:ok, pipeline} = DotParser.parse_file(dot_file(tmp_dir))
    assert :ok = Validator.validate(pipeline)
    run_id = "live-run-#{System.unique_integer([:positive])}"
    {:ok, ^run_id} = Run.start(pipeline, runs_dir: tmp_dir, run_id: run_id)
    {:ok, info} = Run.info(run_id)
    {:ok, conn: build_conn(), run_id: run_id, run_dir: info.run_dir}
  end

  @tag :tmp_dir
  test "node_started flips DOM class to running", %{conn: conn, run_id: run_id} do
    {:ok, view, _html} = live(conn, "/runs/#{run_id}")

    :ok = RunEvents.emit(run_id, "start", :node_started, %{})

    assert render(view) =~ "tractor-node running"
  end

  @tag :tmp_dir
  test "multiple node_started events show multiple running nodes", %{conn: conn, run_id: run_id} do
    {:ok, view, _html} = live(conn, "/runs/#{run_id}")

    :ok = RunEvents.emit(run_id, "start", :node_started, %{})
    :ok = RunEvents.emit(run_id, "exit", :node_started, %{})

    html = render(view)
    assert html |> String.split("tractor-node running") |> length() == 3
  end

  @tag :tmp_dir
  test "select_node loads prompt, response, chunks, and stderr from disk", %{
    conn: conn,
    run_id: run_id,
    run_dir: run_dir
  } do
    assert {:ok, _result} = Run.await(run_id, 1_000)

    node_dir = Path.join(run_dir, "start")
    File.mkdir_p!(node_dir)
    File.write!(Path.join(node_dir, "prompt.md"), "Prompt text")
    File.write!(Path.join(node_dir, "response.md"), "Response text")
    File.write!(Path.join(node_dir, "stderr.log"), "stderr text")

    :ok = RunEvents.emit(run_id, "start", :agent_message_chunk, %{"text" => "chunk one"})
    :ok = RunEvents.emit(run_id, "start", :agent_thought_chunk, %{"text" => "thought one"})

    {:ok, view, _html} = live(conn, "/runs/#{run_id}")
    html = render_click(view, :select_node, %{"node-id" => "start"})

    assert html =~ "Prompt text"
    assert html =~ "Response text"
    assert html =~ "chunk one"
    assert html =~ "thought one"
    assert html =~ "stderr text"
  end

  @tag :tmp_dir
  test "late mount rebuilds complete state from disk", %{conn: conn, run_id: run_id} do
    assert {:ok, _result} = Run.await(run_id, 1_000)
    {:ok, _view, html} = live(conn, "/runs/#{run_id}")

    assert html =~ "tractor-node succeeded"
  end

  defp dot_file(tmp_dir) do
    path = Path.join(tmp_dir, "live.dot")

    File.write!(path, """
    digraph {
      start [shape=Mdiamond]
      exit [shape=Msquare]
      start -> exit
    }
    """)

    path
  end
end
