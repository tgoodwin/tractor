defmodule Tractor.TextTest do
  use ExUnit.Case, async: true

  test "truncate_after keeps multibyte prefixes valid" do
    text = "aaaaa—tail"

    truncated = Tractor.Text.truncate_after(text, 6, "\n[truncated]")

    assert String.valid?(truncated)
    assert truncated == "aaaaa\n[truncated]"
  end

  test "truncate_middle keeps both sides valid" do
    text = "head—middle—tail"

    truncated = Tractor.Text.truncate_middle(text, 12, "\n[truncated]\n")

    assert String.valid?(truncated)
    assert truncated =~ "head"
    assert truncated =~ "tail"
  end

  test "sanitize renders invalid binaries as inspectable text" do
    invalid = binary_part("prefix—tail", 0, 7)
    refute String.valid?(invalid)

    sanitized = Tractor.Text.sanitize(invalid)

    assert String.valid?(sanitized)
    assert sanitized =~ "\\xE2"
  end
end
