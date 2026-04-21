defmodule Tractor.ContextTemplateTest do
  use ExUnit.Case, async: true

  alias Tractor.Context
  alias Tractor.Context.Template

  test "context keeps latest output and iteration history" do
    context =
      %{}
      |> Context.add_iteration("ask", %{seq: 1, output: "first", status: :success})
      |> Context.add_iteration("ask", %{
        seq: 2,
        output: "second",
        status: :success,
        critique: "tighten"
      })

    assert context["ask"] == "second"
    assert context["ask.last_output"] == "second"
    assert get_in(context, ["iterations", "ask"]) |> length() == 2
  end

  test "template resolves latest, critique, indexed iterations, and preserves unknowns" do
    context =
      %{}
      |> Context.add_iteration("ask", %{seq: 1, output: "first", status: :success})
      |> Context.add_iteration("judge", %{
        seq: 1,
        output: "review",
        status: :success,
        critique: "fix meter"
      })

    assert Template.render(
             "{{ask}} {{ask.last}} {{ask.iteration(1)}} {{ask.iterations.length}} {{judge.last_critique}} {{missing}}",
             context
           ) == "first first first 1 fix meter {{missing}}"
  end
end
