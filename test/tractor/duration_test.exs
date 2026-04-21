defmodule Tractor.DurationTest do
  use ExUnit.Case, async: true

  alias Tractor.Duration

  test "parses milliseconds and unit-suffixed durations" do
    assert Duration.parse(500) == {:ok, 500}
    assert Duration.parse("500") == {:ok, 500}
    assert Duration.parse("500ms") == {:ok, 500}
    assert Duration.parse("30s") == {:ok, 30_000}
    assert Duration.parse("5m") == {:ok, 300_000}
    assert Duration.parse("1h") == {:ok, 3_600_000}
  end

  test "rejects invalid duration strings" do
    assert Duration.parse("5x") == {:error, :invalid_duration}
    assert Duration.parse("soon") == {:error, :invalid_duration}
  end
end
