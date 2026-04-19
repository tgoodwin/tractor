defmodule TractorWeb.ToolCallFormatterTest do
  use ExUnit.Case, async: true

  alias TractorWeb.ToolCallFormatter

  test "prefers concise ACP titles" do
    assert ToolCallFormatter.format(%{"kind" => "read", "title" => "Open mix.exs"}) ==
             {"[READ]", "Open mix.exs"}
  end

  test "falls back to read path" do
    assert ToolCallFormatter.format(%{
             "kind" => "read",
             "rawInput" => %{"path" => "/tmp/project/lib/app.ex"}
           }) == {"[READ]", "app.ex"}
  end

  test "formats edit change counts" do
    assert ToolCallFormatter.format(%{
             "kind" => "edit",
             "rawInput" => %{"path" => "/tmp/app.ex", "edits" => [%{}, %{}]}
           }) == {"[EDIT]", "app.ex (2 changes)"}
  end

  test "formats write byte counts" do
    assert ToolCallFormatter.format(%{
             "kind" => "write",
             "rawInput" => %{"path" => "/tmp/out.txt", "content" => String.duplicate("x", 2_048)}
           }) == {"[WRITE]", "out.txt (2KB)"}
  end

  test "formats shell commands" do
    assert {"[BASH]", summary} =
             ToolCallFormatter.format(%{
               "kind" => "bash",
               "rawInput" => %{"command" => String.duplicate("mix test ", 10)}
             })

    assert byte_size(summary) <= 60
    assert String.ends_with?(summary, "...")
  end

  test "formats grep and search patterns" do
    assert ToolCallFormatter.format(%{
             "kind" => "grep",
             "rawInput" => %{"pattern" => "needle", "path" => "lib"}
           }) == {"[GREP]", ~s("needle" in lib)}
  end

  test "formats glob patterns" do
    assert ToolCallFormatter.format(%{"kind" => "glob", "rawInput" => %{"pattern" => "*.ex"}}) ==
             {"[GLOB]", "*.ex"}
  end

  test "formats fetch URLs by host" do
    assert ToolCallFormatter.format(%{
             "kind" => "fetch",
             "rawInput" => %{"url" => "https://example.com/path"}
           }) == {"[FETCH]", "example.com"}
  end

  test "falls back to title or tool call id" do
    assert ToolCallFormatter.format(%{"kind" => "custom", "title" => nil, "toolCallId" => "tc_1"}) ==
             {"[TOOL]", "custom: tc_1"}

    assert ToolCallFormatter.format(%{"toolCallId" => "tc_2"}) == {"[TOOL]", "tc_2"}
    assert ToolCallFormatter.format(%{}) == {"[TOOL]", "unknown"}
  end
end
