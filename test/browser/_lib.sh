#!/usr/bin/env bash
set -euo pipefail

TRACTOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TRACTOR_BROWSER_PORT="${TRACTOR_BROWSER_PORT:-4001}"
TRACTOR_BASE_URL="${TRACTOR_BASE_URL:-http://127.0.0.1:${TRACTOR_BROWSER_PORT}}"
TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-tractor-browser-${PPID:-$$}}"

ab() {
  AGENT_BROWSER_SESSION="$TRACTOR_AB_SESSION" agent-browser "$@"
}

ab_open() {
  ab open "$1"
  ab_wait_event load networkidle
}

ab_close() {
  ab close >/dev/null
}

ab_reload() {
  ab reload >/dev/null
  ab_wait_event load networkidle
}

ab_click() {
  case "${1:-}" in
    role | text | label | placeholder | alt | title | testid | first | last | nth)
      local locator="$1"
      local value="$2"
      shift 2
      ab find "$locator" "$value" click "$@" >/dev/null
      ;;
    *)
      ab click "$@" >/dev/null
      ;;
  esac
}

ab_assert_visible() {
  case "${1:-}" in
    role | text | label | placeholder | alt | title | testid | first | last | nth)
      local locator="$1"
      local value="$2"
      shift 2
      ab find "$locator" "$value" text "$@" >/dev/null
      ;;
    *)
      ab is visible "$1" >/dev/null
      ;;
  esac
}

ab_assert_text() {
  local actual

  case "${1:-}" in
    role | text | label | placeholder | alt | title | testid | first | last | nth)
      local locator="$1"
      local value="$2"
      local expected="$3"
      shift 3
      actual="$(ab find "$locator" "$value" text "$@")"
      ;;
    *)
      local selector="$1"
      local expected="$2"
      actual="$(ab get text "$selector")"
      ;;
  esac

  if [[ "$actual" != *"$expected"* ]]; then
    printf 'Expected text containing %q, got: %s\n' "$expected" "$actual" >&2
    return 1
  fi
}

ab_assert_class() {
  local selector="$1"
  local expected_class="$2"
  local classes
  classes="$(ab get attr class "$selector")"

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
  local response
  response="$(curl -fsS -X POST "${TRACTOR_BASE_URL}/dev/reap?path=${path}")"
  ruby -rjson -e 'print JSON.parse(STDIN.read).fetch("run_id")' <<<"$response"
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
