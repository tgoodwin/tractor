#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_DIR="$ROOT/test/browser/logs"
TRACTOR_DATA_DIR="${TRACTOR_DATA_DIR:-$ROOT/.tmp/browser-data}"
export TRACTOR_DATA_DIR
export TRACTOR_BROWSER_PORT="${TRACTOR_BROWSER_PORT:-4000}"
export TRACTOR_BASE_URL="http://127.0.0.1:${TRACTOR_BROWSER_PORT}"
export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-tractor-browser-run-all}"
export TRACTOR_BROWSER_LOG_DIR="${TRACTOR_BROWSER_LOG_DIR:-$LOG_DIR}"
source "$ROOT/test/browser/_lib.sh"

mkdir -p "$TRACTOR_BROWSER_LOG_DIR"

export TRACTOR_BROWSER_SERVER_PID_FILE="${TRACTOR_BROWSER_SERVER_PID_FILE:-$TRACTOR_BROWSER_LOG_DIR/phoenix.pid}"
export TRACTOR_BROWSER_SERVER_LOG="${TRACTOR_BROWSER_SERVER_LOG:-$TRACTOR_BROWSER_LOG_DIR/phoenix.log}"
export TRACTOR_BROWSER_HEALTH_URL="${TRACTOR_BASE_URL}/runs/browser-health"
export TRACTOR_BROWSER_LAUNCHER_SOCK="${TRACTOR_BROWSER_LAUNCHER_SOCK:-$TRACTOR_BROWSER_LOG_DIR/launcher.sock}"
export TRACTOR_BROWSER_LAUNCHER_PID_FILE="${TRACTOR_BROWSER_LAUNCHER_PID_FILE:-$TRACTOR_BROWSER_LOG_DIR/launcher.pid}"

launcher_pid=""

wait_for_launcher() {
  local attempts="${2:-100}"

  for _ in $(seq 1 "$attempts"); do
    if "$TRACTOR_BROWSER_LAUNCHER_CLIENT" "$TRACTOR_BROWSER_LAUNCHER_SOCK" '{"op":"status"}' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  printf 'Timed out waiting for launcher readiness on %s\n' "$TRACTOR_BROWSER_LAUNCHER_SOCK" >&2
  return 1
}

wait_for_pid_exit() {
  local pid="$1"
  local attempts="${2:-50}"

  for _ in $(seq 1 "$attempts"); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  return 1
}

tractor_launcher_start() {
  local transport
  if ! transport="$("$TRACTOR_BROWSER_LAUNCHER_CLIENT" --probe 2>/dev/null)"; then
    printf 'Launcher client unavailable; need nc -U, socat, or ruby before running browser suites.\n' >&2
    return 1
  fi

  local args=()
  local ebin
  for ebin in "$ROOT"/_build/dev/lib/*/ebin; do
    args+=(-pa "$ebin")
  done

  (
    cd "$ROOT"
    exec env TRACTOR_BROWSER_LAUNCHER_DISABLE_STDIN_WATCH=1 \
      elixir --no-halt "${args[@]}" test/browser/launcher/launcher.exs >>"$TRACTOR_BROWSER_LOG_DIR/launcher.stdout.log" 2>>"$TRACTOR_BROWSER_LOG_DIR/launcher.stderr.log"
  ) &

  launcher_pid="$!"
  printf '%s\n' "$launcher_pid" >"$TRACTOR_BROWSER_LAUNCHER_PID_FILE"
  wait_for_launcher "$TRACTOR_BROWSER_LAUNCHER_SOCK" 100
  printf 'launcher transport: %s\n' "$transport"
}

cleanup() {
  local exit_code=$?
  set +e

  tractor_runs_stop_all || true
  if [[ -n "$launcher_pid" ]] && kill -0 "$launcher_pid" >/dev/null 2>&1; then
    "$TRACTOR_BROWSER_LAUNCHER_CLIENT" "${TRACTOR_BROWSER_LAUNCHER_SOCK:-}" '{"op":"shutdown"}' >/dev/null 2>&1 || true
    wait_for_pid_exit "$launcher_pid" 50 || kill -KILL "$launcher_pid" >/dev/null 2>&1 || true
  fi
  rm -f "${TRACTOR_BROWSER_LAUNCHER_SOCK:-}" "$TRACTOR_BROWSER_LAUNCHER_PID_FILE" >/dev/null 2>&1 || true
  tractor_server_stop || true
  AGENT_BROWSER_SESSION="$TRACTOR_AB_SESSION" agent-browser close >/dev/null 2>&1 || true
  ab_force_kill_daemon
  exit "$exit_code"
}

trap cleanup EXIT

ab_reap_stale_daemons
assert_ambient_load_ok || exit $?

rm -rf "$TRACTOR_DATA_DIR"
mkdir -p "$TRACTOR_DATA_DIR"
rm -rf "$TRACTOR_BROWSER_RUN_LOG_DIR" "$TRACTOR_BROWSER_RUN_PID_DIR" "$TRACTOR_BROWSER_RUN_STATUS_DIR"
rm -f "$TRACTOR_BROWSER_SERVER_PID_FILE" "$TRACTOR_BROWSER_SERVER_LOG" "${TRACTOR_BROWSER_LAUNCHER_SOCK:-}"

if [[ -f "$TRACTOR_BROWSER_LAUNCHER_PID_FILE" ]]; then
  stale_launcher_pid="$(cat "$TRACTOR_BROWSER_LAUNCHER_PID_FILE" 2>/dev/null || true)"

  if [[ -n "$stale_launcher_pid" ]] && kill -0 "$stale_launcher_pid" >/dev/null 2>&1; then
    kill -TERM "$stale_launcher_pid" >/dev/null 2>&1 || true
    wait_for_pid_exit "$stale_launcher_pid" 50 || kill -KILL "$stale_launcher_pid" >/dev/null 2>&1 || true
  fi
fi

rm -f "$TRACTOR_BROWSER_LAUNCHER_PID_FILE"

git_sha="$(git rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
load_avg="$(tractor_current_load)"
hogs="$(tractor_known_hogs)"
launcher_mode="on"

tractor_export_fake_acp_env

if [[ "${TRACTOR_BROWSER_NO_LAUNCHER:-0}" == "1" ]]; then
  launcher_mode="off"
  export TRACTOR_BROWSER_LAUNCHER_SOCK=""
else
  tractor_launcher_start
fi

printf 'browser run start: git=%s launcher=%s observer_port=%s data_dir=%s load=%s' \
  "$git_sha" "$launcher_mode" "$TRACTOR_BROWSER_PORT" "$TRACTOR_DATA_DIR" "$load_avg"

if [[ -n "$hogs" ]]; then
  printf ' hogs=%s' "$hogs"
fi

printf '\n'

tractor_server_start

mapfile -t suites < <(
  find "$ROOT/test/browser" -maxdepth 1 -type f -name '*.sh' \
    ! -name '_lib.sh' \
    ! -name 'run-all.sh' \
    ! -name 'run-all-repeat.sh' | sort
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
