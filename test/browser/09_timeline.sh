#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-timeline-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

restore_needed=0
original_claude_env="${TRACTOR_ACP_CLAUDE_ENV_JSON-}"
original_fake_mode="${TRACTOR_FAKE_ACP_MODE-}"
original_fake_events="${FAKE_ACP_EVENTS-}"

cleanup() {
  if [[ "$restore_needed" == "1" ]]; then
    if [[ -n "$original_claude_env" ]]; then
      export TRACTOR_ACP_CLAUDE_ENV_JSON="$original_claude_env"
    else
      unset TRACTOR_ACP_CLAUDE_ENV_JSON
    fi

    if [[ -n "$original_fake_mode" ]]; then
      export TRACTOR_FAKE_ACP_MODE="$original_fake_mode"
    else
      unset TRACTOR_FAKE_ACP_MODE
    fi

    if [[ -n "$original_fake_events" ]]; then
      export FAKE_ACP_EVENTS="$original_fake_events"
    else
      unset FAKE_ACP_EVENTS
    fi

    tractor_server_stop
    tractor_server_start
  fi

  ab_close
}

trap cleanup EXIT

text_includes() {
  local selector="$1"
  local expected="$2"
  local escaped_selector="${selector//\\/\\\\}"
  escaped_selector="${escaped_selector//\'/\\\'}"
  local escaped_expected="${expected//\\/\\\\}"
  escaped_expected="${escaped_expected//\'/\\\'}"
  ab eval "document.querySelector('${escaped_selector}')?.textContent.includes('${escaped_expected}') ?? false"
}

export TRACTOR_ACP_CLAUDE_ENV_JSON='{"TRACTOR_FAKE_ACP_MODE":"timeline_rich","FAKE_ACP_EVENTS":"full"}'
unset TRACTOR_FAKE_ACP_MODE
unset FAKE_ACP_EVENTS
tractor_server_stop
tractor_server_start
restore_needed=1

markdown_run_id="$(tractor_reap "test/browser/fixtures/timeline_markdown.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${markdown_run_id}"

click_result="$(ab_dom_click "[data-testid='node-narrator']")"
[[ "$click_result" == '"ok"' ]] || {
  printf 'Expected narrator node click to succeed, got: %s\n' "$click_result" >&2
  exit 1
}

ab_wait_event fn "document.querySelectorAll('#timeline .tl-entry').length >= 6"
ab_assert_visible "#timeline.timeline"
ab_assert_visible "#timeline .tl-entry.tl-prompt"
ab_assert_visible "#timeline .tl-entry.tl-thinking"
ab_assert_visible "#timeline .tl-entry.tl-tool_call"
ab_assert_visible "#timeline .tl-entry.tl-response"
ab_assert_visible "#timeline .tl-entry.tl-usage"
ab_assert_visible "#timeline .tl-entry.tl-stderr"
ab_assert_visible "#timeline .tl-entry.tl-tool_call pre.tractor-raw-json"
ab_assert_visible "#timeline .tl-entry.tl-prompt .tl-body-prompt ul"
ab_assert_visible "#timeline .tl-entry.tl-prompt .tl-body-prompt pre code"

lifecycle_count="$(ab eval "document.querySelectorAll('#timeline .tl-entry.tl-lifecycle .tl-static').length")"
[[ "$lifecycle_count" != "0" ]] || {
  printf 'Expected at least one lifecycle timeline entry\n' >&2
  exit 1
}

prompt_open="$(ab eval "document.querySelector('#timeline .tl-entry.tl-prompt details')?.hasAttribute('open') ?? false")"
[[ "$prompt_open" == "false" ]] || {
  printf 'Expected prompt details to start collapsed\n' >&2
  exit 1
}

response_open="$(ab eval "document.querySelector('#timeline .tl-entry.tl-response details')?.hasAttribute('open') ?? false")"
[[ "$response_open" == "true" ]] || {
  printf 'Expected response details to start open\n' >&2
  exit 1
}

ab_wait_event fn "document.querySelector('#timeline .tl-entry.tl-usage .tl-summary')?.textContent.includes('250 tokens')"
ab_wait_event fn "document.querySelector('#timeline .tl-entry.tl-stderr .tl-summary')?.textContent.includes('fake stderr line one')"

ab_click testid "timeline-toggle-prompt"
prompt_open="$(ab eval "document.querySelector('#timeline .tl-entry.tl-prompt details')?.hasAttribute('open') ?? false")"
[[ "$prompt_open" == "true" ]] || {
  printf 'Expected prompt details to toggle open after click\n' >&2
  exit 1
}

tool_run_id="$(tractor_reap "test/browser/fixtures/timeline_tool_runtime.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${tool_run_id}"

click_result="$(ab_dom_click "[data-testid='node-shell']")"
[[ "$click_result" == '"ok"' ]] || {
  printf 'Expected shell node click to succeed, got: %s\n' "$click_result" >&2
  exit 1
}

ab_wait_event fn "document.querySelectorAll('#timeline .tl-entry.tl-tool_runtime').length === 2"

ab_wait_event fn "document.querySelector('#timeline')?.textContent.includes('[TOOL] invoked')"
ab_wait_event fn "document.querySelector('#timeline')?.textContent.includes('[TOOL] output truncated')"

wait_run_id="$(tractor_reap "examples/wait_human_review.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${wait_run_id}"
ab_wait_event fn "document.querySelector('g.tractor-node[data-node-id=\"review_gate\"]')?.classList.contains('waiting')"

click_result="$(ab_dom_click "[data-testid='node-review_gate']")"
[[ "$click_result" == '"ok"' ]] || {
  printf 'Expected review_gate node click to succeed, got: %s\n' "$click_result" >&2
  exit 1
}

ab_wait_event fn "document.querySelector('#timeline .tl-entry.tl-wait_runtime.tl-accent') !== null"
pending_wait_open="$(ab eval "document.querySelector('#timeline .tl-entry.tl-wait_runtime.tl-accent details')?.hasAttribute('open') ?? false")"
[[ "$pending_wait_open" == "true" ]] || {
  printf 'Expected pending wait details to start open\n' >&2
  exit 1
}

ab_click role button --name "approve" --exact
ab_wait_event fn "document.querySelector('#timeline .tl-entry.tl-wait_runtime.tl-success') !== null"

ab_wait_event fn "document.querySelector('#timeline .tl-entry.tl-wait_runtime.tl-success')?.textContent.includes('approve via operator')"

resolved_wait_open="$(ab eval "document.querySelector('#timeline .tl-entry.tl-wait_runtime.tl-success details')?.hasAttribute('open') ?? false")"
[[ "$resolved_wait_open" == "false" ]] || {
  printf 'Expected resolved wait details to start collapsed\n' >&2
  exit 1
}

haiku_run_id="$(tractor_reap "examples/haiku_feedback.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${haiku_run_id}"

click_result="$(ab_dom_click "[data-testid='node-ask_claude']")"
[[ "$click_result" == '"ok"' ]] || {
  printf 'Expected ask_claude node click to succeed, got: %s\n' "$click_result" >&2
  exit 1
}

ab_wait_event fn "document.querySelector('#timeline .tl-entry.tl-iteration_header') !== null"

ab_wait_event fn "document.querySelector('#timeline .tl-entry.tl-iteration_header')?.textContent.includes('Iteration 1')"

click_result="$(ab_dom_click "[data-testid='node-codex_review']")"
[[ "$click_result" == '"ok"' ]] || {
  printf 'Expected codex_review node click to succeed, got: %s\n' "$click_result" >&2
  exit 1
}

ab_wait_event fn "document.querySelector('#timeline .tl-entry.tl-verdict') !== null"
verdict_count="$(ab eval "document.querySelectorAll('#timeline .tl-entry.tl-verdict').length")"
[[ "$verdict_count" != "0" ]] || {
  printf 'Expected at least one verdict entry\n' >&2
  exit 1
}
