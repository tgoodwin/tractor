defmodule TractorWeb.RunLive.ToolCallViewTest do
  use ExUnit.Case, async: true

  alias TractorWeb.RunLive.ToolCallView

  test "bash tool calls render as a $-prefixed shell line with output" do
    body = %{
      "call" => %{
        "kind" => "execute",
        "rawInput" => %{"command" => ["bash", "-lc", "ls /tmp"]},
        "status" => "pending"
      },
      "updates" => [
        %{
          "status" => "completed",
          "content" => [%{"content" => %{"text" => "foo\nbar\n"}, "type" => "content"}]
        }
      ]
    }

    {:safe, html} = ToolCallView.render(body)
    rendered = IO.iodata_to_binary(html)

    assert rendered =~ ~s(<pre class="tool-call-bash">)
    assert rendered =~ "ls /tmp"
    assert rendered =~ ~s(<span class="tool-call-bash-prompt">$</span>)
    assert rendered =~ "tool-call-status-completed"
    assert rendered =~ "↪ output"
    assert rendered =~ "foo\nbar"
  end

  test "shell-meta args get single-quoted in the rendered command line" do
    body = %{
      "call" => %{
        "kind" => "bash",
        "rawInput" => %{"command" => ["sh", "-c", "echo hi && ls"]}
      },
      "updates" => []
    }

    {:safe, html} = ToolCallView.render(body)
    rendered = IO.iodata_to_binary(html)

    assert rendered =~ "sh -c &#39;echo hi &amp;&amp; ls&#39;"
  end

  test "read tool calls render the file path list" do
    body = %{
      "call" => %{
        "kind" => "read",
        "locations" => [%{"path" => "/tmp/foo.ex"}, %{"path" => "/tmp/bar.ex"}],
        "rawInput" => %{}
      },
      "updates" => []
    }

    {:safe, io} = ToolCallView.render(body)
    rendered = IO.iodata_to_binary(io)

    assert rendered =~ "/tmp/foo.ex"
    assert rendered =~ "/tmp/bar.ex"
    assert rendered =~ ~s(<ul class="tool-call-paths">)
  end

  test "edit tool calls render diff hunks for each edit" do
    body = %{
      "call" => %{
        "kind" => "edit",
        "rawInput" => %{
          "path" => "/tmp/foo.ex",
          "edits" => [
            %{"oldText" => "foo bar", "newText" => "foo baz"}
          ]
        }
      },
      "updates" => []
    }

    {:safe, io} = ToolCallView.render(body)
    rendered = IO.iodata_to_binary(io)

    assert rendered =~ "/tmp/foo.ex"
    assert rendered =~ "edit 1"
    assert rendered =~ ~s(<span class="diff-del">- foo bar</span>)
    assert rendered =~ ~s(<span class="diff-add">+ foo baz</span>)
  end

  test "search tool calls render pattern + locations" do
    body = %{
      "call" => %{
        "kind" => "search",
        "rawInput" => %{"pattern" => "TODO", "path" => "lib/"},
        "locations" => [%{"path" => "lib/foo.ex"}]
      },
      "updates" => []
    }

    {:safe, io} = ToolCallView.render(body)
    rendered = IO.iodata_to_binary(io)

    assert rendered =~ "pattern"
    assert rendered =~ "TODO"
    assert rendered =~ "lib/foo.ex"
  end

  test "unknown tool kinds fall back to a JSON view of rawInput" do
    body = %{
      "call" => %{"kind" => "novel_tool", "rawInput" => %{"foo" => "bar"}},
      "updates" => []
    }

    {:safe, io} = ToolCallView.render(body)
    rendered = IO.iodata_to_binary(io)

    assert rendered =~ "tractor-raw-json"
    assert rendered =~ "&quot;foo&quot;: &quot;bar&quot;"
  end

  test "user-provided text is HTML-escaped" do
    body = %{
      "call" => %{"kind" => "bash", "rawInput" => %{"command_string" => "echo <script>"}},
      "updates" => []
    }

    {:safe, io} = ToolCallView.render(body)
    rendered = IO.iodata_to_binary(io)

    refute rendered =~ "<script>"
    assert rendered =~ "echo &lt;script&gt;"
  end
end
