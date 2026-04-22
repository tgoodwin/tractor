#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/test/browser/_lib.sh"

LOG_DIR="$ROOT/test/browser/logs"
mkdir -p "$LOG_DIR"

TRACTOR_DATA_DIR="${TRACTOR_DATA_DIR:-$ROOT/.tmp/browser-data}"
export TRACTOR_DATA_DIR
export TRACTOR_BROWSER_PORT="${TRACTOR_BROWSER_PORT:-4000}"
export TRACTOR_BASE_URL="http://127.0.0.1:${TRACTOR_BROWSER_PORT}"
export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-tractor-browser-run-all}"
export TRACTOR_BROWSER_LOG_DIR="$LOG_DIR"
export TRACTOR_BROWSER_SERVER_PID_FILE="$LOG_DIR/phoenix.pid"
export TRACTOR_BROWSER_SERVER_LOG="$LOG_DIR/phoenix.log"
export TRACTOR_BROWSER_HEALTH_URL="${TRACTOR_BASE_URL}/runs/browser-health"

cleanup() {
  local exit_code=$?

  tractor_runs_stop_all
  tractor_server_stop
  AGENT_BROWSER_SESSION="$TRACTOR_AB_SESSION" agent-browser close >/dev/null 2>&1 || true
  ab_force_kill_daemon
  exit "$exit_code"
}

trap cleanup EXIT

ab_reap_stale_daemons

rm -rf "$TRACTOR_DATA_DIR"
mkdir -p "$TRACTOR_DATA_DIR"

tractor_server_start

mapfile -t suites < <(
  find "$ROOT/test/browser" -maxdepth 1 -type f -name '*.sh' \
    ! -name '_lib.sh' \
    ! -name 'run-all.sh' | sort
)

pass_count=0
skip_count=0

for suite in "${suites[@]}"; do
  name="$(basename "$suite")"
  printf '==> %s\n' "$name"

  if bash "$suite"; then
    printf 'PASS %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    status=$?
    if [[ "$status" -eq 200 ]]; then
      printf 'SKIP %s\n' "$name"
      skip_count=$((skip_count + 1))
    else
      printf 'FAIL %s\n' "$name" >&2
      exit "$status"
    fi
  fi
done

printf 'browser suites complete: %d passed, %d skipped\n' "$pass_count" "$skip_count"
