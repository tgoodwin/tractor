defmodule Tractor.HandlerToolTest do
  use ExUnit.Case, async: false

  alias Tractor.Handler.Tool
  alias Tractor.Node

  @tag :tmp_dir
  test "returns merged output, context updates, and command artifact on success", %{
    tmp_dir: tmp_dir
  } do
    run_dir = Path.join(tmp_dir, "run-tool-success")
    File.mkdir_p!(run_dir)

    node = %Node{
      id: "tool",
      type: "tool",
      attrs: %{"command" => ["sh", "-c", "printf out; printf err >&2"]}
    }

    context = %{"__run_id__" => "run-tool-success", "__attempt__" => 1}

    assert {:ok, output, updates} = Tool.run(node, context, run_dir)
    assert output["exit_status"] == 0
    assert output["stdout"] == "outerr"
    assert output["stderr"] == ""
    assert output["command"] == ["sh", "-c", "printf out; printf err >&2"]
    assert updates.context["tool.stdout"] == "outerr"
    assert updates.context["tool.stderr"] == ""

    artifact =
      run_dir
      |> Path.join("tool/attempt-1/command.json")
      |> File.read!()
      |> Jason.decode!()

    assert artifact["stderr_to_stdout"] == true
    assert artifact["exit_status"] == 0
    assert artifact["command"] == ["sh", "-c", "printf out; printf err >&2"]
  end

  @tag :tmp_dir
  test "renders stdin and respects env and cwd", %{tmp_dir: tmp_dir} do
    run_dir = Path.join(tmp_dir, "run-tool-stdin")
    working_dir = Path.join(run_dir, "workspace")
    File.mkdir_p!(working_dir)

    node = %Node{
      id: "tool",
      type: "tool",
      attrs: %{
        "command" => [
          "sh",
          "-c",
          "printf %s \"$TRACTOR_TOOL_ENV\"; printf \":\"; pwd; printf \":\"; cat"
        ],
        "cwd" => "workspace",
        "env" => %{"TRACTOR_TOOL_ENV" => "env-ok"},
        "stdin" => "{{pattern}}"
      }
    }

    assert {:ok, output, _updates} = Tool.run(node, %{"pattern" => "stdin-ok"}, run_dir)
    assert output["stdout"] == "env-ok:#{working_dir}\n:stdin-ok"
  end

  @tag :tmp_dir
  test "classifies missing binaries as tool_not_found", %{tmp_dir: tmp_dir} do
    run_dir = Path.join(tmp_dir, "run-tool-missing")
    File.mkdir_p!(run_dir)

    node = %Node{
      id: "tool",
      type: "tool",
      attrs: %{"command" => ["nonexistent-binary-tractor-xyz"]}
    }

    assert {:error, {:tool_not_found, "nonexistent-binary-tractor-xyz"}} =
             Tool.run(node, %{}, run_dir)
  end

  @tag :tmp_dir
  test "command argv remains literal and is not template rendered", %{tmp_dir: tmp_dir} do
    run_dir = Path.join(tmp_dir, "run-tool-literal")
    File.mkdir_p!(run_dir)

    node = %Node{
      id: "tool",
      type: "tool",
      attrs: %{"command" => ["printf", "%s", "{{pattern}}"]}
    }

    assert {:ok, output, _updates} = Tool.run(node, %{"pattern" => "render-me"}, run_dir)
    assert output["stdout"] == "{{pattern}}"
  end

  @tag :tmp_dir
  test "emits truncation events and caps captured output", %{tmp_dir: tmp_dir} do
    run_dir = Path.join(tmp_dir, "run-tool-truncate")
    File.mkdir_p!(run_dir)

    node = %Node{
      id: "tool",
      type: "tool",
      attrs: %{
        "command" => ["sh", "-c", "yes X | head -c 200"],
        "max_output_bytes" => "20"
      }
    }

    assert {:ok, output, _updates} =
             Tool.run(node, %{"__run_id__" => "run-tool-truncate", "__attempt__" => 1}, run_dir)

    assert byte_size(output["stdout"]) == 20
  end

  @tag :tmp_dir
  test "returns non-zero exits as tool_failed with merged stderr output", %{tmp_dir: tmp_dir} do
    run_dir = Path.join(tmp_dir, "run-tool-fail")
    File.mkdir_p!(run_dir)

    node = %Node{
      id: "tool",
      type: "tool",
      attrs: %{"command" => ["sh", "-c", "printf bad >&2; exit 17"]}
    }

    assert {:error, {:tool_failed, %{exit_status: 17, stderr: "bad"}}} =
             Tool.run(node, %{}, run_dir)
  end
end
