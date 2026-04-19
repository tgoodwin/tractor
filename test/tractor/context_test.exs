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
end
