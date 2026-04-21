#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-theme-toggle-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

trap 'ab_close' EXIT

run_id="$(tractor_reap "examples/wait_human_review.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"

ab_assert_visible "#theme-toggle"
ab_assert_visible ".theme-toggle-slot-light svg"
ab_assert_visible ".theme-toggle-slot-dark svg"

if [[ "$(ab_attr "#theme-toggle" "aria-label")" != "Toggle dark mode" ]]; then
  printf 'Expected stable theme-toggle aria-label\n' >&2
  exit 1
fi

if [[ "$(ab_attr "#theme-toggle" "aria-pressed")" != "false" ]]; then
  printf 'Expected theme toggle to start unpressed\n' >&2
  exit 1
fi

ab_click role button --name "Toggle dark mode"
ab_wait_event fn "document.documentElement.getAttribute('data-theme') === 'dark'"

if [[ "$(ab_attr "#theme-toggle" "aria-pressed")" != "true" ]]; then
  printf 'Expected theme toggle to be pressed after dark-mode toggle\n' >&2
  exit 1
fi

ab_reload
ab_wait_event fn "document.documentElement.getAttribute('data-theme') === 'dark'"

if [[ "$(ab_attr "#theme-toggle" "aria-pressed")" != "true" ]]; then
  printf 'Expected dark-mode preference to persist after reload\n' >&2
  exit 1
fi
