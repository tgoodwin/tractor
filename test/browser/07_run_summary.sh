#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-run-summary-$$}"
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

assert_text_includes() {
  local selector="$1"
  local expected="$2"
  local escaped_selector="${selector//\\/\\\\}"
  escaped_selector="${escaped_selector//\'/\\\'}"
  local escaped_expected="${expected//\\/\\\\}"
  escaped_expected="${escaped_expected//\'/\\\'}"

  local matches
  matches="$(ab eval "document.querySelector('${escaped_selector}')?.textContent.includes('${escaped_expected}') ?? false")"
  [[ "$matches" == "true" ]] || {
    printf 'Expected %s to include %q\n' "$selector" "$expected" >&2
    exit 1
  }
}

cost_text() {
  ab eval "document.querySelector('.run-summary-card .pill-model')?.textContent.trim() ?? ''"
}

run_id="$(tractor_reap "test/browser/fixtures/goal_gate_tool_fail.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"

ab_wait_event fn "document.querySelector('.run-summary-card .status-pill')?.textContent.includes('goal gate failed')"

heading_text="$(ab eval "document.querySelector('.run-summary-card h2')?.textContent.trim() ?? ''")"
[[ "$heading_text" == "\"${run_id}\"" ]] || {
  printf 'Expected run-summary heading %s, got %s\n' "$run_id" "$heading_text" >&2
  exit 1
}

ab_assert_class ".run-summary-card .status-pill" "status-goal_gate_failed"
assert_text_includes ".run-summary-card .run-summary-note" "Goal-gate failure terminated the run"
assert_text_includes ".run-summary-card .pill-model" "cost "

if [[ -f "$TRACTOR_BROWSER_SERVER_PID_FILE" ]]; then
  export TRACTOR_ACP_CLAUDE_ENV_JSON='{}'
  export TRACTOR_FAKE_ACP_MODE="usage_result"
  export FAKE_ACP_EVENTS="full"
  tractor_server_stop
  tractor_server_start
  restore_needed=1

  usage_run_id="$(tractor_reap "test/browser/fixtures/run_summary_usage.dot")"
  ab_open "${TRACTOR_BASE_URL}/runs/${usage_run_id}"

  initial_cost="$(cost_text)"
  [[ "$initial_cost" == '"cost $0"' || "$initial_cost" == '"cost $0.0"' || "$initial_cost" == '"cost $0.00"' ]] || {
    printf 'Expected initial cost pill to start at zero, got %s\n' "$initial_cost" >&2
    exit 1
  }

  ab_wait_event fn "(function() {
    const pill = document.querySelector('.run-summary-card .pill-model');
    return Boolean(pill && pill.textContent.includes('cost $') && !['cost $0', 'cost $0.0', 'cost $0.00'].includes(pill.textContent.trim()));
  })()"
  ab_wait_event fn "document.querySelector('.run-summary-card .status-pill')?.textContent.includes('completed')"

  final_cost="$(cost_text)"
  [[ "$final_cost" != "$initial_cost" ]] || {
    printf 'Expected cost pill to change, got %s\n' "$final_cost" >&2
    exit 1
  }

  assert_text_includes ".run-summary-card .status-pill" "completed"
fi
