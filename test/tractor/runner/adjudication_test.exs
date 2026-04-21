defmodule Tractor.Runner.AdjudicationTest do
  use ExUnit.Case, async: true

  alias Tractor.Node
  alias Tractor.Runner.Adjudication

  test "continues on partial_success when allow_partial is enabled" do
    node = %Node{id: "judge", type: "judge", allow_partial: true}

    assert {:continue, %{status: :partial_success}, metadata} =
             Adjudication.classify(node, %{status: "partial_success"}, %{})

    assert metadata.reason == :allowed_partial_success
    assert metadata.allow_partial
  end

  test "fails on partial_success when allow_partial is disabled" do
    node = %Node{id: "judge", type: "judge", allow_partial: false}

    assert {:fail, %{status: :partial_success}, metadata} =
             Adjudication.classify(node, %{status: :partial_success}, %{})

    assert metadata.reason == :partial_success_not_allowed
    refute metadata.continuation?
  end

  test "parallel fan-in preserves partial_success continuation without allow_partial" do
    node = %Node{id: "fan", type: "parallel.fan_in", allow_partial: false}

    assert {:continue, %{status: :partial_success}, metadata} =
             Adjudication.classify(node, %{status: "partial_success"}, %{})

    assert metadata.reason == :fan_in_partial_success
  end

  test "unknown status fails closed" do
    node = %Node{id: "judge", type: "judge"}

    assert {:fail, %{status: :unknown}, metadata} =
             Adjudication.classify(node, %{status: "mystery"}, %{"raw" => "value"})

    assert metadata.reason == :unknown_status
  end
end
