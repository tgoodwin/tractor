#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-dev-endpoints-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

trap 'ab_close' EXIT

json_field() {
  local json="$1"
  local field="$2"
  ruby -rjson -e "print JSON.parse(STDIN.read).fetch('${field}')" <<<"$json"
}

launch_response="$(curl -fsS -X POST "${TRACTOR_BASE_URL}/dev/reap?path=test/browser/fixtures/node_panel_header.dot")"
launch_run_id="$(json_field "$launch_response" "run_id")"
launch_url="$(json_field "$launch_response" "url")"
launch_path="$(json_field "$launch_response" "path")"
[[ "$launch_path" == "test/browser/fixtures/node_panel_header.dot" ]] || {
  printf 'Unexpected launch path %s\n' "$launch_path" >&2
  exit 1
}

ab_open "$launch_url"
ab_assert_visible ".top-bar"

missing_body="$(curl -sS -o /tmp/tractor-dev-missing.json -w '%{http_code}' -X POST "${TRACTOR_BASE_URL}/dev/reap?path=examples/nonexistent.dot")"
[[ "$missing_body" == "404" ]] || {
  printf 'Expected missing file status 404, got %s\n' "$missing_body" >&2
  exit 1
}
grep -q '"error":"file not found"' /tmp/tractor-dev-missing.json

invalid_status="$(curl -sS -o /tmp/tractor-dev-invalid.json -w '%{http_code}' -X POST "${TRACTOR_BASE_URL}/dev/reap?path=test/browser/fixtures/invalid_pipeline.dot")"
[[ "$invalid_status" == "422" ]] || {
  printf 'Expected invalid DOT status 422, got %s\n' "$invalid_status" >&2
  exit 1
}
grep -q '"error":"validation failed"' /tmp/tractor-dev-invalid.json

missing_param_status="$(curl -sS -o /tmp/tractor-dev-param.json -w '%{http_code}' -X POST "${TRACTOR_BASE_URL}/dev/reap")"
[[ "$missing_param_status" == "400" ]] || {
  printf 'Expected missing param status 400, got %s\n' "$missing_param_status" >&2
  exit 1
}
grep -q 'missing ?path=<dot-file> query param' /tmp/tractor-dev-param.json

interrupt_response="$(curl -fsS -X POST "${TRACTOR_BASE_URL}/dev/reap?path=test/browser/fixtures/dev_interruptible.dot")"
interrupt_run_id="$(json_field "$interrupt_response" "run_id")"
ab_open "${TRACTOR_BASE_URL}/runs/${interrupt_run_id}"
ab_wait_event fn "document.querySelector('.run-summary-card .status-pill')?.textContent.includes('running')"

stop_response="$(curl -fsS -X POST "${TRACTOR_BASE_URL}/dev/stop/${interrupt_run_id}")"
[[ "$(json_field "$stop_response" "stopped")" == "$interrupt_run_id" ]] || {
  printf 'Expected stop endpoint to echo interrupted run id\n' >&2
  exit 1
}
ab_wait_event fn "document.querySelector('.run-summary-card .status-pill')?.textContent.includes('interrupted')"

stop_missing_status="$(curl -sS -o /tmp/tractor-dev-stop-missing.json -w '%{http_code}' -X POST "${TRACTOR_BASE_URL}/dev/stop/not-a-run")"
[[ "$stop_missing_status" == "404" ]] || {
  printf 'Expected stop missing status 404, got %s\n' "$stop_missing_status" >&2
  exit 1
}
grep -q '"error":"run not found in registry"' /tmp/tractor-dev-stop-missing.json

stop_all_one="$(json_field "$(curl -fsS -X POST "${TRACTOR_BASE_URL}/dev/reap?path=test/browser/fixtures/dev_interruptible.dot")" "run_id")"
stop_all_two="$(json_field "$(curl -fsS -X POST "${TRACTOR_BASE_URL}/dev/reap?path=test/browser/fixtures/dev_interruptible.dot")" "run_id")"
stop_all_response="$(curl -fsS -X POST "${TRACTOR_BASE_URL}/dev/stop-all")"
[[ "$(json_field "$stop_all_response" "stopped")" == "2" ]] || {
  printf 'Expected stop-all to interrupt 2 runs, got %s\n' "$stop_all_response" >&2
  exit 1
}

ab_open "${TRACTOR_BASE_URL}/runs/${stop_all_one}"
ab_wait_event fn "document.querySelector('.run-summary-card .status-pill')?.textContent.includes('interrupted')"
ab_open "${TRACTOR_BASE_URL}/runs/${stop_all_two}"
ab_wait_event fn "document.querySelector('.run-summary-card .status-pill')?.textContent.includes('interrupted')"
