#!/usr/bin/env bash
set -euo pipefail

TRACTOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TRACTOR_BROWSER_PORT="${TRACTOR_BROWSER_PORT:-4000}"
TRACTOR_BASE_URL="${TRACTOR_BASE_URL:-http://127.0.0.1:${TRACTOR_BROWSER_PORT}}"
TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-tractor-browser-${PPID:-$$}}"
TRACTOR_BROWSER_LOG_DIR="${TRACTOR_BROWSER_LOG_DIR:-$TRACTOR_ROOT/test/browser/logs}"
TRACTOR_BROWSER_SERVER_PID_FILE="${TRACTOR_BROWSER_SERVER_PID_FILE:-$TRACTOR_BROWSER_LOG_DIR/phoenix.pid}"
TRACTOR_BROWSER_SERVER_LOG="${TRACTOR_BROWSER_SERVER_LOG:-$TRACTOR_BROWSER_LOG_DIR/phoenix.log}"
TRACTOR_BROWSER_HEALTH_URL="${TRACTOR_BROWSER_HEALTH_URL:-$TRACTOR_BASE_URL/runs/browser-health}"
TRACTOR_BROWSER_RUN_LOG_DIR="${TRACTOR_BROWSER_RUN_LOG_DIR:-$TRACTOR_BROWSER_LOG_DIR/runs}"
TRACTOR_BROWSER_RUN_PID_DIR="${TRACTOR_BROWSER_RUN_PID_DIR:-$TRACTOR_BROWSER_LOG_DIR/pids}"
TRACTOR_BROWSER_RUN_STATUS_DIR="${TRACTOR_BROWSER_RUN_STATUS_DIR:-$TRACTOR_BROWSER_LOG_DIR/status}"

ab() {
  local attempts=0
  local max_attempts=4
  local rc
  local stderr_file
  stderr_file="$(mktemp)"

  while :; do
    AGENT_BROWSER_SESSION="$TRACTOR_AB_SESSION" agent-browser "$@" 2>"$stderr_file"
    rc=$?

    if [[ $rc -eq 0 ]]; then
      rm -f "$stderr_file"
      return 0
    fi

    attempts=$((attempts + 1))

    if [[ $attempts -lt $max_attempts ]] \
       && grep -qE "Resource temporarily unavailable|daemon may be busy|Broken pipe" "$stderr_file" 2>/dev/null; then
      sleep 0.4
      : >"$stderr_file"
      continue
    fi

    cat "$stderr_file" >&2
    rm -f "$stderr_file"
    return "$rc"
  done
}

ab_open() {
  ab open "$1"
  ab_wait_event load networkidle
}

ab_close() {
  ab close >/dev/null 2>&1 || true
  ab_force_kill_daemon
  tractor_runs_stop_all
}

# agent-browser's `close` command is best-effort — if the socket is stale or the
# request errors, the daemon (and its chromium children) stay alive. Reap the
# PID file directly so interrupted suites don't leak processes.
ab_force_kill_daemon() {
  local session="${TRACTOR_AB_SESSION:-default}"
  local pidfile="${HOME}/.agent-browser/${session}.pid"

  [[ -f "$pidfile" ]] || return 0

  local pid
  pid="$(cat "$pidfile" 2>/dev/null || true)"

  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    kill -TERM "$pid" >/dev/null 2>&1 || true
    sleep 0.3
    kill -0 "$pid" >/dev/null 2>&1 && kill -KILL "$pid" >/dev/null 2>&1 || true
  fi

  rm -f "$pidfile" "${HOME}/.agent-browser/${session}.sock" 2>/dev/null || true
}

# Reap any stale agent-browser daemons whose PID files point to dead processes.
# Call at the start of a suite or run-all to prevent layering on top of orphans.
ab_reap_stale_daemons() {
  local dir="${HOME}/.agent-browser"
  [[ -d "$dir" ]] || return 0

  local pidfile pid
  for pidfile in "$dir"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    pid="$(cat "$pidfile" 2>/dev/null || true)"

    if [[ -z "$pid" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
      local sock="${pidfile%.pid}.sock"
      rm -f "$pidfile" "$sock" 2>/dev/null || true
    fi
  done
}

ab_reload() {
  ab reload >/dev/null
  ab_wait_event load networkidle
}

ab_click() {
  case "${1:-}" in
    role)
      local locator="$1"
      local value="$2"
      shift 2
      ab find "$locator" "$value" click "$@" >/dev/null
      ;;
    text | label | placeholder | alt | title | testid | first | last | nth)
      local locator="$1"
      local value="$2"
      shift 2
      ab find "$locator" "$value" "$@" click >/dev/null
      ;;
    *)
      ab click "$@" >/dev/null
      ;;
  esac
}

ab_dom_click() {
  local selector="$1"
  local escaped_selector="${selector//\\/\\\\}"
  escaped_selector="${escaped_selector//\'/\\\'}"

  ab eval "(function() {
    const el = document.querySelector('${escaped_selector}');
    if (!el) return 'missing';
    el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    return 'ok';
  })()"
}

ab_assert_visible() {
  ab is visible "$1" >/dev/null
}

ab_assert_text() {
  local selector="$1"
  local expected="$2"
  local actual
  actual="$(ab get text "$selector")"

  if [[ "$actual" != *"$expected"* ]]; then
    printf 'Expected text containing %q, got: %s\n' "$expected" "$actual" >&2
    return 1
  fi
}

ab_attr() {
  local selector="$1"
  local attr_name="$2"
  local escaped_selector="${selector//\\/\\\\}"
  escaped_selector="${escaped_selector//\'/\\\'}"
  local escaped_attr="${attr_name//\\/\\\\}"
  escaped_attr="${escaped_attr//\'/\\\'}"

  local value
  value="$(ab eval "document.querySelector('${escaped_selector}')?.getAttribute('${escaped_attr}') ?? ''")"
  ruby -rjson -e 'print JSON.parse(STDIN.read)' <<<"$value"
}

ab_assert_class() {
  local selector="$1"
  local expected_class="$2"
  local classes
  classes="$(ab_attr "$selector" "class")"

  if [[ " $classes " != *" $expected_class "* ]]; then
    printf 'Expected class %q on %s, got: %s\n' "$expected_class" "$selector" "$classes" >&2
    return 1
  fi
}

ab_wait_event() {
  case "${1:-}" in
    load)
      ab wait --load "${2:-networkidle}" >/dev/null
      ;;
    text)
      ab wait --text "$2" >/dev/null
      ;;
    fn)
      ab wait --fn "$2" >/dev/null
      ;;
    url)
      ab wait --url "$2" >/dev/null
      ;;
    *)
      ab wait "$1" >/dev/null
      ;;
  esac
}

tractor_reap() {
  local path="$1"
  local token
  token="run-$$_$(date +%s%N)"
  token="$(tractor_launch "$token" bin/tractor reap "$path")"
  wait_for_run_id "$(tractor_log_path "$token")" "$(tractor_pid "$token")"
}

tractor_reap_serve() {
  local path="$1"
  shift || true

  local token
  token="serve-$$_$(date +%s%N)"
  tractor_launch "$token" bin/tractor reap "$path" --serve --no-open "$@"
}

tractor_launch() {
  local token="$1"
  shift

  mkdir -p "$TRACTOR_BROWSER_RUN_LOG_DIR" "$TRACTOR_BROWSER_RUN_PID_DIR" "$TRACTOR_BROWSER_RUN_STATUS_DIR"
  tractor_export_fake_acp_env

  local log_path
  log_path="$(tractor_log_path "$token")"

  local pid_path
  pid_path="$(tractor_pid_path "$token")"

  local status_path
  status_path="$(tractor_status_path "$token")"

  (
    cd "$TRACTOR_ROOT"
    env TRACTOR_DATA_DIR="$TRACTOR_DATA_DIR" "$@" >"$log_path" 2>&1
    local status=$?
    printf '%s\n' "$status" >"$status_path"
    exit "$status"
  ) &

  local pid=$!
  printf '%s\n' "$pid" >"$pid_path"
  printf '%s\n' "$token"
}

tractor_log_path() {
  local token="$1"
  printf '%s\n' "$TRACTOR_BROWSER_RUN_LOG_DIR/${token}.log"
}

tractor_pid_path() {
  local token="$1"
  printf '%s\n' "$TRACTOR_BROWSER_RUN_PID_DIR/${token}.pid"
}

tractor_pid() {
  local token="$1"
  cat "$(tractor_pid_path "$token")"
}

tractor_status_path() {
  local token="$1"
  printf '%s\n' "$TRACTOR_BROWSER_RUN_STATUS_DIR/${token}.status"
}

wait_for_run_id() {
  local log_path="$1"
  local pid="$2"
  local attempts="${3:-600}"
  local run_id

  for _ in $(seq 1 "$attempts"); do
    if [[ -f "$log_path" ]]; then
      run_id="$(ruby -e 'if (m = STDIN.read.match(/run: ([A-Za-z0-9_-]+)/)) then print m[1] end' <"$log_path")"
      if [[ -n "$run_id" ]]; then
        printf '%s\n' "$run_id"
        return 0
      fi
    fi

    if ! kill -0 "$pid" >/dev/null 2>&1; then
      [[ -f "$log_path" ]] && cat "$log_path" >&2
      printf 'tractor reap exited before printing a run id\n' >&2
      return 1
    fi

    sleep 0.1
  done

  [[ -f "$log_path" ]] && cat "$log_path" >&2
  printf 'Timed out waiting for run id in %s\n' "$log_path" >&2
  return 1
}

wait_for_log_text() {
  local log_path="$1"
  local expected="$2"
  local pid="$3"
  local attempts="${4:-100}"

  for _ in $(seq 1 "$attempts"); do
    if [[ -f "$log_path" ]] && grep -Fq "$expected" "$log_path"; then
      return 0
    fi

    if ! kill -0 "$pid" >/dev/null 2>&1; then
      [[ -f "$log_path" ]] && cat "$log_path" >&2
      printf 'Process exited before log contained %s\n' "$expected" >&2
      return 1
    fi

    sleep 0.1
  done

  [[ -f "$log_path" ]] && cat "$log_path" >&2
  printf 'Timed out waiting for log text %s in %s\n' "$expected" "$log_path" >&2
  return 1
}

tractor_wait() {
  local token="$1"
  local pid
  pid="$(tractor_pid "$token")"
  local status_path
  status_path="$(tractor_status_path "$token")"

  while true; do
    if [[ -f "$status_path" ]]; then
      local status
      status="$(cat "$status_path")"
      rm -f "$(tractor_pid_path "$token")" "$status_path"
      printf '%s\n' "$status"
      return 0
    fi

    if ! kill -0 "$pid" >/dev/null 2>&1; then
      if [[ -f "$status_path" ]]; then
        continue
      fi

      rm -f "$(tractor_pid_path "$token")"
      printf 'missing\n'
      return 1
    fi

    sleep 0.1
  done
}

tractor_runs_stop_all() {
  local pidfile pid statusfile

  [[ -d "$TRACTOR_BROWSER_RUN_PID_DIR" ]] || return 0

  for pidfile in "$TRACTOR_BROWSER_RUN_PID_DIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    pid="$(cat "$pidfile" 2>/dev/null || true)"

    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill -TERM "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      kill -0 "$pid" >/dev/null 2>&1 && kill -KILL "$pid" >/dev/null 2>&1 || true
    fi

    rm -f "$pidfile"
  done

  [[ -d "$TRACTOR_BROWSER_RUN_STATUS_DIR" ]] || return 0

  for statusfile in "$TRACTOR_BROWSER_RUN_STATUS_DIR"/*.status; do
    [[ -f "$statusfile" ]] || continue
    rm -f "$statusfile"
  done
}

wait_for_http() {
  local url="$1"
  local attempts="${2:-50}"

  for _ in $(seq 1 "$attempts"); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done

  printf 'Timed out waiting for %s\n' "$url" >&2
  return 1
}

tractor_export_fake_acp_env() {
  export TRACTOR_ACP_CLAUDE_COMMAND="${TRACTOR_ACP_CLAUDE_COMMAND:-$(command -v elixir)}"
  export TRACTOR_ACP_CLAUDE_ARGS="${TRACTOR_ACP_CLAUDE_ARGS:-[\"--erl\",\"-kernel logger_level emergency\",\"-pa\",\"$TRACTOR_ROOT/_build/dev/lib/jason/ebin\",\"$TRACTOR_ROOT/test/support/fake_acp_agent.exs\"]}"
  export TRACTOR_ACP_CODEX_COMMAND="${TRACTOR_ACP_CODEX_COMMAND:-$(command -v elixir)}"
  export TRACTOR_ACP_CODEX_ARGS="${TRACTOR_ACP_CODEX_ARGS:-[\"--erl\",\"-kernel logger_level emergency\",\"-pa\",\"$TRACTOR_ROOT/_build/dev/lib/jason/ebin\",\"$TRACTOR_ROOT/test/support/fake_acp_agent.exs\"]}"
  export TRACTOR_ACP_GEMINI_COMMAND="${TRACTOR_ACP_GEMINI_COMMAND:-$(command -v elixir)}"
  export TRACTOR_ACP_GEMINI_ARGS="${TRACTOR_ACP_GEMINI_ARGS:-[\"--erl\",\"-kernel logger_level emergency\",\"-pa\",\"$TRACTOR_ROOT/_build/dev/lib/jason/ebin\",\"$TRACTOR_ROOT/test/support/fake_acp_agent.exs\"]}"

  if [[ -z "${TRACTOR_ACP_CLAUDE_ENV_JSON+x}" ]]; then
    export TRACTOR_ACP_CLAUDE_ENV_JSON='{"TRACTOR_FAKE_ACP_MODE":"plan","FAKE_ACP_EVENTS":"full"}'
  fi

  if [[ -z "${TRACTOR_ACP_CODEX_ENV_JSON+x}" ]]; then
    export TRACTOR_ACP_CODEX_ENV_JSON='{"FAKE_ACP_EVENTS":"full"}'
  fi

  if [[ -z "${TRACTOR_ACP_GEMINI_ENV_JSON+x}" ]]; then
    export TRACTOR_ACP_GEMINI_ENV_JSON='{"FAKE_ACP_EVENTS":"full"}'
  fi
}

tractor_server_start() {
  mkdir -p "$TRACTOR_BROWSER_LOG_DIR"
  tractor_export_fake_acp_env

  (
    cd "$TRACTOR_ROOT"
    mix escript.build >/dev/null
    exec env PORT="$TRACTOR_BROWSER_PORT" mix phx.server >"$TRACTOR_BROWSER_SERVER_LOG" 2>&1
  ) &

  wait_for_http "$TRACTOR_BROWSER_HEALTH_URL"

  local pid
  pid="$(lsof -tiTCP:"$TRACTOR_BROWSER_PORT" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
  printf '%s\n' "$pid" >"$TRACTOR_BROWSER_SERVER_PID_FILE"
}

tractor_server_stop() {
  local pid=""

  if [[ -f "$TRACTOR_BROWSER_SERVER_PID_FILE" ]]; then
    pid="$(cat "$TRACTOR_BROWSER_SERVER_PID_FILE")"
  fi

  if [[ -z "$pid" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
    pid="$(lsof -tiTCP:"$TRACTOR_BROWSER_PORT" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    kill -TERM "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi

  if [[ -f "$TRACTOR_BROWSER_SERVER_PID_FILE" ]]; then
    python3 - <<'PY' "$TRACTOR_BROWSER_SERVER_PID_FILE"
from pathlib import Path
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
PY
  fi
}
