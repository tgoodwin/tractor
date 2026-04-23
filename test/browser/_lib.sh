#!/usr/bin/env bash
set -euo pipefail

# waits > 60s should be the exception, with an explanatory comment.

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
TRACTOR_BROWSER_LAUNCHER_SOCK="${TRACTOR_BROWSER_LAUNCHER_SOCK:-}"
TRACTOR_BROWSER_LAUNCHER_CLIENT="${TRACTOR_BROWSER_LAUNCHER_CLIENT:-$TRACTOR_ROOT/test/browser/launcher/client.sh}"
TRACTOR_BROWSER_WAIT_LOAD_TIMEOUT="${TRACTOR_BROWSER_WAIT_LOAD_TIMEOUT:-30s}"
TRACTOR_BROWSER_WAIT_TEXT_TIMEOUT="${TRACTOR_BROWSER_WAIT_TEXT_TIMEOUT:-30s}"
TRACTOR_BROWSER_WAIT_FN_TIMEOUT="${TRACTOR_BROWSER_WAIT_FN_TIMEOUT:-60s}"
TRACTOR_BROWSER_WAIT_URL_TIMEOUT="${TRACTOR_BROWSER_WAIT_URL_TIMEOUT:-30s}"
TRACTOR_BROWSER_LOAD_WARN="${TRACTOR_BROWSER_LOAD_WARN:-6}"
TRACTOR_BROWSER_LOAD_ABORT="${TRACTOR_BROWSER_LOAD_ABORT:-10}"

tractor_export_file_system_env() {
  if [[ -n "${FILESYSTEM_FSMAC_EXECUTABLE_FILE:-}" ]]; then
    export FILESYSTEM_FSMAC_EXECUTABLE_FILE
    return 0
  fi

  local mac_listener="$TRACTOR_ROOT/deps/file_system/priv/mac_listener"

  if [[ -x "$mac_listener" ]]; then
    export FILESYSTEM_FSMAC_EXECUTABLE_FILE="$mac_listener"
  fi
}

tractor_export_file_system_env

tractor_float_ge() {
  ruby -e 'exit(ARGV[0].to_f >= ARGV[1].to_f ? 0 : 1)' "$1" "$2"
}

tractor_float_lt() {
  ruby -e 'exit(ARGV[0].to_f < ARGV[1].to_f ? 0 : 1)' "$1" "$2"
}

tractor_current_load() {
  if command -v sysctl >/dev/null 2>&1 && sysctl -n vm.loadavg >/dev/null 2>&1; then
    sysctl -n vm.loadavg | ruby -e 'if (m = STDIN.read.match(/([0-9]+(?:\.[0-9]+)?)/)) then print m[1] else exit 1 end'
  elif [[ -r /proc/loadavg ]]; then
    awk '{print $1}' /proc/loadavg
  else
    printf '0\n'
  fi
}

tractor_known_hogs() {
  ps -A -o comm= 2>/dev/null | ruby -e '
    patterns = [
      [/backblaze/i, "backblaze"],
      [/backupd/i, "backupd"],
      [/Time Machine/i, "Time Machine"],
      [/mds_stores/i, "mds_stores"],
      [/mdworker/i, "mdworker"],
      [/Xcode/i, "Xcode"],
      [/Simulator/i, "Simulator"]
    ]

    matches = STDIN.each_line.map(&:strip).flat_map do |line|
      patterns.map { |pattern, label| label if line.match?(pattern) }.compact
    end.uniq

    print matches.join(", ")
  '
}

tractor_top_processes() {
  ps -A -o pid=,pcpu=,comm= 2>/dev/null | sort -k2 -nr | head -n 5 | sed 's/^ *//'
}

assert_ambient_load_ok() {
  local threshold_bump="${1:-0}"
  local context="${2:-ambient load too high}"

  if [[ "${TRACTOR_BROWSER_SKIP_LOAD_GUARD:-0}" == "1" ]]; then
    return 0
  fi

  local load warn abort hogs
  load="$(tractor_current_load)"
  warn="$(ruby -e 'print(ARGV[0].to_f + ARGV[1].to_f)' "$TRACTOR_BROWSER_LOAD_WARN" "$threshold_bump")"
  abort="$(ruby -e 'print(ARGV[0].to_f + ARGV[1].to_f)' "$TRACTOR_BROWSER_LOAD_ABORT" "$threshold_bump")"
  hogs="$(tractor_known_hogs)"

  if tractor_float_lt "$load" "$warn"; then
    return 0
  fi

  if tractor_float_ge "$load" "$abort" && [[ "${TRACTOR_BROWSER_FORCE:-0}" != "1" ]]; then
    printf '%s: load %.2f >= abort %.2f' "$context" "$load" "$abort" >&2

    if [[ -n "$hogs" ]]; then
      printf ' (known hogs: %s)' "$hogs" >&2
    fi

    printf '\nTop processes:\n%s\n' "$(tractor_top_processes)" >&2
    return 77
  fi

  printf 'ambient load warning: %.2f >= warn %.2f' "$load" "$warn" >&2

  if [[ -n "$hogs" ]]; then
    printf ' (known hogs: %s)' "$hogs" >&2
  fi

  printf '\n' >&2
}

tractor_launcher_token() {
  [[ "${1:-}" == job-* ]]
}

tractor_launcher_socket_live() {
  [[ "${TRACTOR_BROWSER_NO_LAUNCHER:-0}" != "1" ]] \
    && [[ -n "${TRACTOR_BROWSER_LAUNCHER_SOCK:-}" ]] \
    && [[ -S "$TRACTOR_BROWSER_LAUNCHER_SOCK" ]]
}

tractor_launcher_client_ready() {
  "$TRACTOR_BROWSER_LAUNCHER_CLIENT" --probe >/dev/null 2>&1
}

tractor_launcher_env_json() {
  ruby -rjson -e '
    keys = %w[
      TRACTOR_DATA_DIR
      FILESYSTEM_FSMAC_EXECUTABLE_FILE
      FAKE_ACP_EVENTS
      TRACTOR_FAKE_ACP_MODE
      TRACTOR_ACP_CLAUDE_ENV_JSON
      TRACTOR_ACP_CODEX_ENV_JSON
      TRACTOR_ACP_GEMINI_ENV_JSON
    ]

    env = keys.each_with_object({}) do |key, acc|
      value = ENV[key]
      acc[key] = value if value && value != ""
    end

    print JSON.dump(env)
  '
}

tractor_launcher_request() {
  local op="$1"
  shift

  local payload

  case "$op" in
    reap | reap_serve)
      payload="$(
        TRACTOR_LAUNCHER_ENV_JSON="$(tractor_launcher_env_json)" ruby -rjson -e '
          op = ARGV.shift
          cwd = ARGV.shift
          args = ARGV
          env = JSON.parse(ENV.fetch("TRACTOR_LAUNCHER_ENV_JSON"))
          print JSON.dump({ "op" => op, "args" => args, "env" => env, "cwd" => cwd })
        ' "$op" "$TRACTOR_ROOT" "$@"
      )"
      ;;
    wait | kill)
      payload="$(ruby -rjson -e 'print JSON.dump({ "op" => ARGV[0], "token" => ARGV[1] })' "$op" "$1")"
      ;;
    status | stop_all | shutdown)
      payload="$(ruby -rjson -e 'print JSON.dump({ "op" => ARGV[0] })' "$op")"
      ;;
    *)
      printf 'unknown launcher op: %s\n' "$op" >&2
      return 1
      ;;
  esac

  "$TRACTOR_BROWSER_LAUNCHER_CLIENT" "$TRACTOR_BROWSER_LAUNCHER_SOCK" "$payload"
}

tractor_launcher_response_field() {
  local json="$1"
  local field="$2"

  ruby -rjson -e '
    value = JSON.parse(STDIN.read).fetch(ARGV[0], nil)

    case value
    when nil
      exit 1
    when true, false
      print(value ? "true" : "false")
    else
      print value
    end
  ' "$field" <<<"$json"
}

tractor_log_reap_routing() {
  printf '%s\n' "$1" >&2
}

tractor_launcher_status_count() {
  local response
  response="$(tractor_launcher_request status)" || return 1
  tractor_launcher_response_field "$response" count
}

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
  tractor_runs_stop_all
  ab close >/dev/null 2>&1 || true
  ab_force_kill_daemon
  tractor_assert_suite_end_clean
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

tractor_assert_suite_start_clean() {
  local dirty=0
  local pidfiles=""

  if [[ -d "$TRACTOR_BROWSER_RUN_PID_DIR" ]]; then
    pidfiles="$(find "$TRACTOR_BROWSER_RUN_PID_DIR" -maxdepth 1 -type f -name '*.pid' -print 2>/dev/null || true)"
  fi

  if [[ -n "$pidfiles" ]]; then
    printf 'suite-start assertion failed: leftover subprocess pid files:\n%s\n' "$pidfiles" >&2
    dirty=1
  fi

  if tractor_launcher_socket_live && tractor_launcher_client_ready; then
    local response count
    response="$(tractor_launcher_request status)" || {
      printf 'suite-start assertion failed: launcher status unavailable\n' >&2
      return 1
    }
    count="$(tractor_launcher_response_field "$response" count 2>/dev/null || printf '0')"

    if [[ "$count" != "0" ]]; then
      printf 'suite-start assertion failed: launcher has %s active job(s): %s\n' "$count" "$response" >&2
      dirty=1
    fi
  fi

  [[ "$dirty" -eq 0 ]]
}

tractor_assert_suite_end_clean() {
  if [[ "${TRACTOR_BROWSER_EXPECT_RUNNING_SERVE_AT_TEARDOWN:-0}" == "1" ]]; then
    return 0
  fi

  if [[ -d "$TRACTOR_BROWSER_RUN_PID_DIR" ]] && find "$TRACTOR_BROWSER_RUN_PID_DIR" -maxdepth 1 -type f -name '*.pid' | grep -q .; then
    printf 'suite-end assertion failed: leftover subprocess pid files remain in %s\n' "$TRACTOR_BROWSER_RUN_PID_DIR" >&2
    return 1
  fi

  if tractor_launcher_socket_live && tractor_launcher_client_ready; then
    local response count
    response="$(tractor_launcher_request status)" || {
      printf 'suite-end assertion failed: launcher status unavailable\n' >&2
      return 1
    }
    count="$(tractor_launcher_response_field "$response" count 2>/dev/null || printf '0')"

    if [[ "$count" != "0" ]]; then
      printf 'suite-end assertion failed: launcher still has %s active job(s): %s\n' "$count" "$response" >&2
      return 1
    fi
  fi
}

tractor_suite_setup() {
  assert_ambient_load_ok 2 "ambient load changed during run" || return "$?"
  ab_reap_stale_daemons
  tractor_assert_suite_start_clean
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
  local timeout

  if [[ "${1:-}" == "--timeout" ]]; then
    timeout="$2"
    shift 2
  else
    timeout=""
  fi

  local kind="${1:-}"
  local arg="${2:-}"
  local effective_timeout

  case "$kind" in
    load) effective_timeout="${timeout:-$TRACTOR_BROWSER_WAIT_LOAD_TIMEOUT}" ;;
    text) effective_timeout="${timeout:-$TRACTOR_BROWSER_WAIT_TEXT_TIMEOUT}" ;;
    fn) effective_timeout="${timeout:-$TRACTOR_BROWSER_WAIT_FN_TIMEOUT}" ;;
    url) effective_timeout="${timeout:-$TRACTOR_BROWSER_WAIT_URL_TIMEOUT}" ;;
    *) effective_timeout="${timeout:-$TRACTOR_BROWSER_WAIT_LOAD_TIMEOUT}" ;;
  esac

  if [[ "$kind" == "load" ]] || ! tractor_launcher_socket_live; then
    ab_wait_event_once "$effective_timeout" "$kind" "$arg"
    return 0
  fi

  local total_seconds attempts attempt_timeout
  total_seconds="$(ruby -e 'if (m = ARGV[0].match(/([0-9]+)/)) then print m[1] else print 30 end' "$effective_timeout")"
  attempts=$(( (total_seconds + 4) / 5 ))
  attempt_timeout="5s"

  for attempt in $(seq 1 "$attempts"); do
    if ab_wait_event_once "$attempt_timeout" "$kind" "$arg"; then
      return 0
    fi

    if [[ "$attempt" -lt "$attempts" ]]; then
      ab reload >/dev/null
      ab wait --timeout "$TRACTOR_BROWSER_WAIT_LOAD_TIMEOUT" --load networkidle >/dev/null
    fi
  done

  ab_wait_event_once "$effective_timeout" "$kind" "$arg"
}

ab_wait_event_once() {
  local timeout="$1"
  local kind="$2"
  local arg="${3:-}"

  case "$kind" in
    load)
      ab wait --timeout "$timeout" --load "${arg:-networkidle}" >/dev/null
      ;;
    text)
      ab wait --timeout "$timeout" --text "$arg" >/dev/null
      ;;
    fn)
      ab wait --timeout "$timeout" --fn "$arg" >/dev/null
      ;;
    url)
      ab wait --timeout "$timeout" --url "$arg" >/dev/null
      ;;
    *)
      ab wait --timeout "$timeout" "$kind" >/dev/null
      ;;
  esac
}

tractor_reap() {
  local path="$1"
  shift || true
  tractor_export_fake_acp_env

  if tractor_launcher_socket_live && tractor_launcher_client_ready; then
    tractor_log_reap_routing "routing: launcher"

    local response
    if response="$(tractor_launcher_request reap_serve reap "$path" --runs-dir "$TRACTOR_DATA_DIR/runs" "$@")"; then
      local ok
      ok="$(tractor_launcher_response_field "$response" ok 2>/dev/null || true)"

      if [[ "$ok" == "true" ]]; then
        tractor_launcher_response_field "$response" run_id
        return 0
      fi

      local code stderr error
      code="$(tractor_launcher_response_field "$response" code 2>/dev/null || printf '1')"
      stderr="$(tractor_launcher_response_field "$response" stderr 2>/dev/null || true)"
      error="$(tractor_launcher_response_field "$response" error 2>/dev/null || true)"
      [[ -n "$stderr" ]] && printf '%s\n' "$stderr" >&2
      [[ -n "$error" ]] && printf '%s\n' "$error" >&2
      return "$code"
    fi

    tractor_log_reap_routing "routing: subprocess (reason: launcher protocol error)"
    printf 'launcher warning: launcher request failed, falling back to subprocess\n' >&2
  else
    local reason="launcher unavailable"

    if [[ "${TRACTOR_BROWSER_NO_LAUNCHER:-0}" == "1" ]]; then
      reason="TRACTOR_BROWSER_NO_LAUNCHER=1"
    elif [[ -z "${TRACTOR_BROWSER_LAUNCHER_SOCK:-}" ]]; then
      reason="TRACTOR_BROWSER_LAUNCHER_SOCK not set"
    elif [[ ! -S "${TRACTOR_BROWSER_LAUNCHER_SOCK:-}" ]]; then
      reason="launcher socket not live"
    elif ! tractor_launcher_client_ready; then
      reason="launcher client unavailable"
    fi

    tractor_log_reap_routing "routing: subprocess (reason: ${reason})"
  fi

  tractor_reap_subprocess "$path" "$@"
}

tractor_reap_serve() {
  local path="$1"
  shift || true
  tractor_export_fake_acp_env

  if tractor_launcher_socket_live && tractor_launcher_client_ready; then
    local response
    if response="$(tractor_launcher_request reap_serve reap "$path" --serve --no-open --runs-dir "$TRACTOR_DATA_DIR/runs" "$@")"; then
      local ok
      ok="$(tractor_launcher_response_field "$response" ok 2>/dev/null || true)"

      if [[ "$ok" == "true" ]]; then
        tractor_launcher_response_field "$response" token
        return 0
      fi

      local code stderr error
      code="$(tractor_launcher_response_field "$response" code 2>/dev/null || printf '1')"
      stderr="$(tractor_launcher_response_field "$response" stderr 2>/dev/null || true)"
      error="$(tractor_launcher_response_field "$response" error 2>/dev/null || true)"
      [[ -n "$stderr" ]] && printf '%s\n' "$stderr" >&2
      [[ -n "$error" ]] && printf '%s\n' "$error" >&2
      return "$code"
    fi

    printf 'launcher warning: launcher request failed for reap_serve, falling back to subprocess\n' >&2
  fi

  tractor_reap_subprocess "$path" --serve --no-open "$@"
}

tractor_reap_subprocess() {
  local path="$1"
  shift || true

  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--serve" ]]; then
      local token
      token="serve-$$_$(date +%s%N)"
      tractor_launch "$token" bin/tractor reap "$path" "$@"
      return 0
    fi
  done

  if [[ $# -eq 0 ]]; then
    set -- --runs-dir "$TRACTOR_DATA_DIR/runs"
  elif [[ " $* " != *" --runs-dir "* ]]; then
    set -- --runs-dir "$TRACTOR_DATA_DIR/runs" "$@"
  fi

  {
    local token
    token="run-$$_$(date +%s%N)"
    token="$(tractor_launch "$token" bin/tractor reap "$path" "$@")"
    wait_for_run_id "$(tractor_log_path "$token")" "$(tractor_pid "$token")" "$(tractor_status_path "$token")" "$token"
  }
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
  local status_path="${3:-}"
  local token="${4:-}"
  local attempts="${5:-600}"
  local run_id

  for _ in $(seq 1 "$attempts"); do
    if [[ -f "$log_path" ]]; then
      run_id="$(
        ruby -e '
          data =
            STDIN.read
            .force_encoding("UTF-8")
            .encode("UTF-8", invalid: :replace, undef: :replace, replace: "")

          if (m = data.match(/run: ([A-Za-z0-9_-]+)/))
            print m[1]
          end
        ' <"$log_path"
      )"
      if [[ -n "$run_id" ]]; then
        printf '%s\n' "$run_id"
        return 0
      fi
    fi

    if ! kill -0 "$pid" >/dev/null 2>&1; then
      [[ -f "$log_path" ]] && cat "$log_path" >&2
      if [[ -n "$status_path" && -n "$token" && -f "$status_path" ]]; then
        local status
        status="$(cat "$status_path")"
        rm -f "$(tractor_pid_path "$token")" "$status_path"
        printf 'tractor reap exited before printing a run id\n' >&2
        return "$status"
      fi

      printf 'tractor reap exited before printing a run id\n' >&2
      return 1
    fi

    sleep 0.1
  done

  [[ -f "$log_path" ]] && cat "$log_path" >&2
  if [[ -n "$status_path" && -n "$token" && -f "$status_path" ]]; then
    local status
    status="$(cat "$status_path")"
    rm -f "$(tractor_pid_path "$token")" "$status_path"
    return "$status"
  fi
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

wait_for_file_exists() {
  local path="$1"
  local attempts="${2:-100}"

  for _ in $(seq 1 "$attempts"); do
    [[ -e "$path" ]] && return 0
    sleep 0.1
  done

  printf 'Timed out waiting for file %s\n' "$path" >&2
  return 1
}

tractor_wait() {
  local token="$1"

  if tractor_launcher_token "$token"; then
    local response

    if ! response="$(tractor_launcher_request wait "$token")"; then
      printf 'launcher wait failed for %s\n' "$token" >&2
      return 1
    fi

    tractor_launcher_response_field "$response" code
    return 0
  fi

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

  if tractor_launcher_socket_live && tractor_launcher_client_ready; then
    local response

    if response="$(tractor_launcher_request stop_all)"; then
      :
    else
      printf 'launcher warning: stop_all failed, continuing with subprocess cleanup\n' >&2
    fi
  fi

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
  export FAKE_ACP_EVENTS="${FAKE_ACP_EVENTS:-full}"
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
