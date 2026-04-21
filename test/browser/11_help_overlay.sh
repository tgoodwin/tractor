#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-help-overlay-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

trap 'ab_close' EXIT

run_id="$(tractor_reap "test/browser/fixtures/node_panel_header.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"

click_result="$(ab_dom_click "[data-testid='node-modelled']")"
[[ "$click_result" == '"ok"' ]] || {
  printf 'Expected modelled node click to succeed, got: %s\n' "$click_result" >&2
  exit 1
}

ab_wait_event fn "document.querySelector('.node-panel')?.textContent.includes('modelled')"

ab eval "document.dispatchEvent(new KeyboardEvent('keydown', { key: '?', bubbles: true }))" >/dev/null
ab_wait_event fn "document.querySelector('.help-overlay[aria-label=\"Keyboard help\"]') !== null"

ab_assert_visible ".help-overlay[aria-label='Keyboard help']"
ab_assert_visible ".help-overlay h2"

for key_text in Keys Esc '?' Tab Enter; do
  ab_wait_event fn "document.querySelector('.help-overlay')?.textContent.includes('${key_text}')"
done

ab eval "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))" >/dev/null
ab_wait_event fn "document.querySelector('.help-overlay') === null"
ab_wait_event fn "document.querySelector('.empty-sidebar') !== null"
