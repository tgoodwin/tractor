#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-runs-panel-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

trap 'ab_close' EXIT

run_id="$(tractor_reap "examples/wait_human_review.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"

ab_assert_text ".runs-list-panel .runs-panel-header .eyebrow" "Runs"

current_rows="$(ab eval "document.querySelectorAll('.runs-row.is-current').length")"
[[ "$current_rows" == "1" ]] || {
  printf 'Expected exactly one current run row, got %s\n' "$current_rows" >&2
  exit 1
}

current_run_id="$(ab get text ".runs-row.is-current .runs-row-id")"
[[ "$current_run_id" == "$run_id" ]] || {
  printf 'Expected current run row id %s, got: %s\n' "$run_id" "$current_run_id" >&2
  exit 1
}

status_text="$(ab eval "document.querySelector('.runs-row.is-current .status-pill')?.textContent.trim() || ''" | ruby -rjson -e 'print JSON.parse(STDIN.read)')"
[[ "$status_text" == "running" || "$status_text" == "completed" ]] || {
  printf 'Expected current run status to be running or completed, got: %s\n' "$status_text" >&2
  exit 1
}

initial_count="$(ab get text ".runs-count")"
next_run_id="$(tractor_reap "examples/resilience.dot")"

ab_wait_event fn "Array.from(document.querySelectorAll('.runs-row-link')).some((link) => link.getAttribute('href') === '/runs/${next_run_id}')"

row_count="$(ab eval "document.querySelectorAll('.runs-row').length")"
panel_count="$(ab get text ".runs-count")"

[[ "$row_count" == "$panel_count" ]] || {
  printf 'Expected runs-count %s to match rendered rows %s\n' "$panel_count" "$row_count" >&2
  exit 1
}

[[ "$panel_count" -gt "$initial_count" ]] || {
  printf 'Expected auto-refresh to increase runs count beyond %s, got %s\n' "$initial_count" "$panel_count" >&2
  exit 1
}
