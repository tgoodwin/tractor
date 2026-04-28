defmodule Tractor.ContextTest do
  use ExUnit.Case, async: true

  alias Tractor.Context

  test "clone_for_branch creates a JSON-safe isolated snapshot" do
    parent = %{"one" => %{"outcome" => "ok"}}

    assert {:ok, branch} = Context.clone_for_branch(parent, "audit:a")
    assert branch["parallel.branch_id"] == "audit:a"

    _branch = put_in(branch, ["one", "outcome"], "changed")
    assert parent["one"]["outcome"] == "ok"
  end

  test "snapshot rejects non JSON-safe values" do
    assert {:error, :non_json_safe_context} = Context.snapshot(%{"pid" => self()})
    assert {:error, :non_json_safe_context} = Context.snapshot(%{"ref" => make_ref()})
    assert {:error, :non_json_safe_context} = Context.snapshot(%{"fun" => fn -> :ok end})
  end

  describe "with_run_metadata/2" do
    test "injects goal and run_dir when both are non-empty strings" do
      context = Context.with_run_metadata(%{}, %{goal: "make it work", run_dir: "/tmp/run/abc"})

      assert context["goal"] == "make it work"
      assert context["run_dir"] == "/tmp/run/abc"
    end

    test "skips goal when nil or empty so unresolved {{goal}} surfaces in prompts" do
      assert Context.with_run_metadata(%{}, %{goal: nil, run_dir: "/tmp/r"}) == %{
               "run_dir" => "/tmp/r"
             }

      assert Context.with_run_metadata(%{}, %{goal: "", run_dir: "/tmp/r"}) == %{
               "run_dir" => "/tmp/r"
             }
    end

    test "is idempotent — re-injecting overwrites with the same values" do
      context = Context.with_run_metadata(%{"existing" => "v"}, %{goal: "g", run_dir: "/r"})
      context = Context.with_run_metadata(context, %{goal: "g", run_dir: "/r"})

      assert context == %{"existing" => "v", "goal" => "g", "run_dir" => "/r"}
    end

    test "preserves other context entries" do
      context =
        Context.with_run_metadata(%{"prior_node.last_output" => "x"}, %{
          goal: "g",
          run_dir: "/r"
        })

      assert context["prior_node.last_output"] == "x"
    end
  end

  test "reserved_keys lists the canonical well-known context keys" do
    assert Context.reserved_keys() == ["goal", "run_dir"]
  end
end
