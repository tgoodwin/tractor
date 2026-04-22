#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-dev-endpoints-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

trap 'ab_close' EXIT

health_json="$(curl -fsS "${TRACTOR_BASE_URL}/api/health")"
health_ok="$(ruby -rjson -e 'print JSON.parse(STDIN.read).fetch("ok")' <<<"$health_json")"
health_runs_dir="$(ruby -rjson -e 'print JSON.parse(STDIN.read).fetch("runs_dir")' <<<"$health_json")"

[[ "$health_ok" == "true" ]] || {
  printf 'Expected /api/health ok=true, got %s\n' "$health_ok" >&2
  exit 1
}

[[ "$health_runs_dir" == "$TRACTOR_DATA_DIR/runs" ]] || {
  printf 'Expected /api/health runs_dir=%s, got %s\n' "$TRACTOR_DATA_DIR/runs" "$health_runs_dir" >&2
  exit 1
}

run_id="$(tractor_reap "test/browser/fixtures/node_panel_header.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"
ab_assert_visible ".top-bar"
ab_wait_event fn "document.querySelector('.run-summary-card .status-pill')?.textContent.includes('completed')"

for path in \
  "/dev/reap?path=test/browser/fixtures/node_panel_header.dot" \
  "/dev/stop/not-a-run" \
  "/dev/stop-all"
do
  status="$(curl -sS -o /tmp/tractor-dev-retired.txt -w '%{http_code}' -X POST "${TRACTOR_BASE_URL}${path}")"
  [[ "$status" == "404" ]] || {
    printf 'Expected %s to return 404, got %s\n' "$path" "$status" >&2
    exit 1
  }
done
