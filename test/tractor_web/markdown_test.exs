defmodule TractorWeb.MarkdownTest do
  use ExUnit.Case, async: true

  test "falls back to escaped raw text when Earmark raises" do
    body =
      ~S(2026-04-29T03:43:16.006935Z  INFO codex_core::stream_events_utils: ToolCall: shell {"command":["bash","-lc","printf 'classify callers/tests:\\n'; rg -n \"Failure\\.classify|classify\\(|Runner\\.Failure|:partial_success_not_allowed|:tool_failed|:provider_timeout|:handler_crash|:jsonrpc_error|:invalid_|:port_exit\" /Users/tgoodwin/projects/tractor/.worktrees/audit-fixes-2026-04-28/lib /Users/tgoodwin/projects/tractor/.worktrees/audit-fixes-2026-04-28/test | head -n 200; printf '\\nHandler error returns:\\n'; rg -n \"\\{:error,|return \\{:error|error_reason|failure_reason|runtime_error\" /Users/tgoodwin/projects/tractor/.worktrees/audit-fixes-2026-04-28/lib/tractor/handler /Users/tgoodwin/projects/tractor/.worktrees/audit-fixes-2026-04-28/lib/tractor/runner.ex | head -n 240"],"workdir":"/Users/tgoodwin/projects/tractor/.worktrees/audit-fixes-2026-04-28","timeout_ms":10000})

    assert {:safe, html} = TractorWeb.Markdown.to_html(body)
    html = IO.iodata_to_binary(html)

    assert html =~ "tractor-raw-json"
    assert html =~ "codex_core::stream_events_utils"
    assert html =~ "&quot;command&quot;"
  end
end
