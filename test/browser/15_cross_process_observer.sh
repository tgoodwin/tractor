#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0010-cross-process-observer-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"
tractor_suite_setup

trap 'ab_close' EXIT

token="$(tractor_reap_subprocess "test/browser/fixtures/run_summary_usage.dot" --serve --no-open --port "$TRACTOR_BROWSER_PORT")"
log_path="$(tractor_log_path "$token")"
pid="$(tractor_pid "$token")"
run_id="$(wait_for_run_id "$log_path" "$pid")"

wait_for_log_text "$log_path" "adopting observer at ${TRACTOR_BASE_URL}/runs/${run_id}" "$pid"

ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"
ab_wait_event fn "document.querySelector('g.tractor-node[data-node-id=\"warmup\"]')?.classList.contains('succeeded')"
ab_wait_event fn "document.querySelector('g.tractor-node[data-node-id=\"priced_step\"]')?.classList.contains('succeeded')"
ab_wait_event fn "document.querySelector('.run-summary-card .status-pill')?.textContent.includes('completed')"

[[ "$(tractor_wait "$token")" == "0" ]] || {
  printf 'Expected cross-process serve run to exit 0\n' >&2
  exit 1
}
