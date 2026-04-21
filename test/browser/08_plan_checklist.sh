#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-plan-checklist-$$}"
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

export TRACTOR_ACP_CLAUDE_ENV_JSON='{"TRACTOR_FAKE_ACP_MODE":"plan_replace","FAKE_ACP_EVENTS":"full"}'
unset TRACTOR_FAKE_ACP_MODE
unset FAKE_ACP_EVENTS
tractor_server_stop
tractor_server_start
restore_needed=1

run_id="$(tractor_reap "examples/plan_probe.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"

click_result="$(ab_dom_click "[data-testid='node-ask_claude']")"
[[ "$click_result" == '"ok"' ]] || {
  printf 'Expected ask_claude node click to succeed, got: %s\n' "$click_result" >&2
  exit 1
}

ab_wait_event fn "document.querySelectorAll('.tractor-plan .tractor-plan-item').length === 2"

heading_visible="$(ab eval "document.querySelector('.panel-section-heading .eyebrow')?.textContent.trim() === 'Plan'")"
[[ "$heading_visible" == "true" ]] || {
  printf 'Expected plan heading to be visible\n' >&2
  exit 1
}

item_count="$(ab eval "document.querySelectorAll('.tractor-plan .tractor-plan-item').length")"
[[ "$item_count" == "2" ]] || {
  printf 'Expected replaced plan length 2, got %s\n' "$item_count" >&2
  exit 1
}

status_count="$(ab eval "document.querySelectorAll('.tractor-plan .tractor-plan-status[aria-hidden=\"true\"]').length")"
[[ "$status_count" == "2" ]] || {
  printf 'Expected 2 status dots, got %s\n' "$status_count" >&2
  exit 1
}

plan_text="$(ab eval "document.querySelector('.tractor-plan')?.textContent ?? ''")"
plan_has_ship="$(ab eval "document.querySelector('.tractor-plan')?.textContent.includes('Ship') ?? false")"
[[ "$plan_has_ship" == "true" ]] || {
  printf 'Expected replaced plan to include Ship, got %s\n' "$plan_text" >&2
  exit 1
}

plan_has_verify="$(ab eval "document.querySelector('.tractor-plan')?.textContent.includes('Verify') ?? false")"
[[ "$plan_has_verify" == "true" ]] || {
  printf 'Expected replaced plan to include Verify, got %s\n' "$plan_text" >&2
  exit 1
}

plan_has_sketch="$(ab eval "document.querySelector('.tractor-plan')?.textContent.includes('Sketch') ?? false")"
[[ "$plan_has_sketch" == "false" ]] || {
  printf 'Expected replaced plan to drop Sketch, got %s\n' "$plan_text" >&2
  exit 1
}

ab_assert_class ".tractor-plan .tractor-plan-item:nth-child(1)" "in_progress"
ab_assert_class ".tractor-plan .tractor-plan-item:nth-child(2)" "completed"

priority_text="$(ab eval "document.querySelector('.tractor-plan .tractor-plan-priority')?.textContent.trim() ?? ''")"
[[ "$priority_text" == '"high"' ]] || {
  printf 'Expected priority badge high, got %s\n' "$priority_text" >&2
  exit 1
}
