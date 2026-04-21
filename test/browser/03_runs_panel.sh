#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-runs-panel-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

trap 'ab_close' EXIT

run_id="$(tractor_reap "examples/wait_human_review.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"

ab_assert_text ".runs-list-panel .runs-panel-header .eyebrow" "Runs"
ab_assert_class ".runs-row.is-current .status-pill" "status-running"

current_rows="$(ab eval "document.querySelectorAll('.runs-row.is-current').length")"
[[ "$current_rows" == "1" ]] || {
  printf 'Expected exactly one current run row, got %s\n' "$current_rows" >&2
  exit 1
}

current_run_id="$(ab get text ".runs-row.is-current .runs-row-id")"
[[ "$current_run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9_-]+$ ]] || {
  printf 'Expected run id line to look like a Tractor run id, got: %s\n' "$current_run_id" >&2
  exit 1
}

meta_line="$(ab eval "document.querySelectorAll('.runs-row.is-current .runs-row-meta')[1]?.textContent || ''")"
[[ "$meta_line" == *"—"* ]] || {
  printf 'Expected unfinished run duration line to include an em dash, got: %s\n' "$meta_line" >&2
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
