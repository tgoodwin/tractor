#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"
tractor_suite_setup

token="$(tractor_reap_subprocess "examples/wait_human_review.dot" --serve --no-open --port "$TRACTOR_BROWSER_PORT")"
log_path="$(tractor_log_path "$token")"
pid="$(tractor_pid "$token")"
run_id="$(wait_for_run_id "$log_path" "$pid")"

wait_for_log_text "$log_path" "adopting observer at ${TRACTOR_BASE_URL}/runs/${run_id}" "$pid"

curl -fsS "${TRACTOR_BASE_URL}/runs/${run_id}" >/dev/null
wait_for_file_exists "${TRACTOR_DATA_DIR}/runs/${run_id}/review_gate/attempt-1/wait.json" 100

submit_cmd=("$(command -v elixir)")
while IFS= read -r ebin; do
  submit_cmd+=(-pa "$ebin")
done < <(cd "$TRACTOR_ROOT" && printf '%s\n' _build/test/lib/*/ebin)

"${submit_cmd[@]}" \
  "$TRACTOR_ROOT/test/support/cross_beam_submit_wait_choice.exs" \
  "$run_id" \
  "$TRACTOR_DATA_DIR/runs" \
  "review_gate" \
  "approve" >/dev/null

[[ "$(tractor_wait "$token")" == "0" ]] || {
  printf 'Expected cross-process wait run to exit 0\n' >&2
  exit 1
}

control_path="${TRACTOR_DATA_DIR}/runs/${run_id}/control/wait-review_gate.json"
[[ ! -e "$control_path" ]] || {
  printf 'Expected control file to be consumed, found %s\n' "$control_path" >&2
  exit 1
}
