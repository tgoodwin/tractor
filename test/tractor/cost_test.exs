defmodule Tractor.CostTest do
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias Tractor.Cost

  test "estimates configured provider/model cost from token usage" do
    assert D.eq?(
             Cost.estimate("codex", "gpt-5", %{input_tokens: 1_000_000, output_tokens: 500_000}),
             D.new("6.25")
           )
  end

  test "normalizes provider/model casing before lookup" do
    assert D.eq?(
             Cost.estimate("Claude", " Claude-Haiku-4-5 ", %{
               "input_tokens" => 1_000_000,
               "output_tokens" => 1_000_000
             }),
             D.new("6")
           )
  end

  test "returns nil for unknown pricing pairs" do
    assert Cost.estimate("claude", "claude-opus-5", %{input_tokens: 10, output_tokens: 10}) ==
             nil
  end

  test "treats missing token counts as zero" do
    assert D.eq?(
             Cost.estimate("gemini", "gemini-3-flash", %{input_tokens: 500_000}),
             D.new("0.25")
           )
  end
end
