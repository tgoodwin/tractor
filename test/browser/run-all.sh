#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/test/browser/_lib.sh"

LOG_DIR="$ROOT/test/browser/logs"
mkdir -p "$LOG_DIR"

TRACTOR_DATA_DIR="${TRACTOR_DATA_DIR:-$ROOT/.tmp/browser-data}"
export TRACTOR_DATA_DIR
export TRACTOR_BROWSER_PORT="${TRACTOR_BROWSER_PORT:-4001}"
export TRACTOR_BASE_URL="http://127.0.0.1:${TRACTOR_BROWSER_PORT}"
export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-tractor-browser-run-all}"

SERVER_LOG="$LOG_DIR/phoenix.log"

cleanup() {
  local exit_code=$?

  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill -TERM "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi

  AGENT_BROWSER_SESSION="$TRACTOR_AB_SESSION" agent-browser close >/dev/null 2>&1 || true
  exit "$exit_code"
}

trap cleanup EXIT

rm -rf "$TRACTOR_DATA_DIR"
mkdir -p "$TRACTOR_DATA_DIR"

(
  cd "$ROOT"
  PORT="$TRACTOR_BROWSER_PORT" mix phx.server >"$SERVER_LOG" 2>&1
) &
SERVER_PID=$!

wait_for_http "$TRACTOR_BASE_URL/nope"

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
