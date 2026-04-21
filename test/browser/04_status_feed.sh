#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-status-feed-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

trap 'ab_close' EXIT

status_off_run="$(tractor_reap "examples/wait_human_review.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${status_off_run}"
ab_assert_text "#status-feed-empty" "Status agent disabled"

status_on_run="$(tractor_reap "test/browser/fixtures/status_feed_wait.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${status_on_run}"

ab_assert_text "#status-feed-empty" "Waiting for first node..."
click_result="$(ab_dom_click "[data-testid='node-review_gate']")"
[[ "$click_result" == '"ok"' ]] || {
  printf 'Expected node click to succeed, got: %s\n' "$click_result" >&2
  exit 1
}
ab_wait_event text "Decision Required"
ab_click role button --name "approve" --exact

ab_wait_event fn "document.querySelector('.run-summary-card .status-pill')?.textContent?.includes('completed')"
ab_wait_event fn "document.querySelectorAll('.status-feed-row').length >= 2"
ab_assert_text ".status-feed-row:first-child .status-feed-node" "approved"
ab_assert_text ".status-feed-row:first-child .status-feed-summary" "Node: approved"
ab_assert_text ".status-feed-row:nth-child(2) .status-feed-node" "review_gate"
ab_assert_text ".status-feed-row:nth-child(2) .status-feed-summary" "resolved_label"

iteration_text="$(ab get text ".status-feed-row:first-child .status-feed-iteration")"
[[ "$iteration_text" == "x1" ]] || {
  printf 'Expected status feed iteration badge x1, got: %s\n' "$iteration_text" >&2
  exit 1
}
