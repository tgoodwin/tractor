#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-error-states-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

trap 'ab_close' EXIT

missing_run_id="missing-run-$RANDOM-$$"

ab_open "${TRACTOR_BASE_URL}/runs/${missing_run_id}"
ab_assert_visible ".missing-run-state"
ab_assert_text ".missing-run-state" "Run not found."
ab_assert_text ".missing-run-state" "The requested run could not be loaded."

not_found_status="$(curl -sS -o /tmp/tractor-browser-nope.txt -w '%{http_code}' "${TRACTOR_BASE_URL}/nope")"
[[ "$not_found_status" == "404" ]] || {
  printf 'Expected /nope to return 404, got %s\n' "$not_found_status" >&2
  exit 1
}

grep -qx 'not found' /tmp/tractor-browser-nope.txt
