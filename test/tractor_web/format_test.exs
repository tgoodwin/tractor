defmodule TractorWeb.FormatTest do
  use ExUnit.Case, async: true

  alias TractorWeb.Format

  test "duration_ms formats missing, millisecond, second, minute, and hour ranges" do
    assert Format.duration_ms(nil) == "n/a"
    assert Format.duration_ms(412) == "412ms"
    assert Format.duration_ms(1_200) == "1.2s"
    assert Format.duration_ms(12_000) == "12s"
    assert Format.duration_ms(61_000) == "1m 1s"
    assert Format.duration_ms(3_660_000) == "1h 1m"
  end

  test "token_count formats raw, thousands, and millions" do
    assert Format.token_count(nil) == "n/a"
    assert Format.token_count(412) == "412"
    assert Format.token_count(28_000) == "28k"
    assert Format.token_count(1_250) == "1.3k"
    assert Format.token_count(1_200_000) == "1.2M"
  end

  test "humanize_bytes formats byte, kibibyte, mebibyte, and gibibyte ranges" do
    assert Format.humanize_bytes(nil) == "n/a"
    assert Format.humanize_bytes(42) == "42 B"
    assert Format.humanize_bytes(2_048) == "2KB"
    assert Format.humanize_bytes(1_572_864) == "1.5MB"
    assert Format.humanize_bytes(1_073_741_824) == "1GB"
  end

  test "truncate handles short, long, nil, and tiny limits" do
    assert Format.truncate("short", 10) == "short"
    assert Format.truncate("abcdefghij", 8) == "abcde..."
    assert Format.truncate(nil, 8) == ""
    assert Format.truncate("abcdef", 3) == "..."
    assert Format.truncate("abcdef", 2) == ".."
  end

  test "usd formats decimal strings and missing values" do
    assert Format.usd(nil) == "n/a"
    assert Format.usd("0") == "$0"
    assert Format.usd("0.0100") == "$0.01"
    assert Format.usd("12.345600") == "$12.3456"
  end
end
