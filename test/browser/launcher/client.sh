#!/usr/bin/env bash
set -euo pipefail

detect_transport() {
  if command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q -- '-U'; then
    printf 'nc\n'
    return 0
  fi

  if command -v socat >/dev/null 2>&1; then
    printf 'socat\n'
    return 0
  fi

  if command -v ruby >/dev/null 2>&1; then
    printf 'ruby\n'
    return 0
  fi

  return 1
}

usage() {
  printf 'Usage: %s [--probe] SOCKET [JSON]\n' "${0##*/}" >&2
}

if [[ "${1:-}" == "--probe" ]]; then
  detect_transport
  exit $?
fi

socket_path="${1:-}"

if [[ -z "$socket_path" ]]; then
  usage
  exit 64
fi

shift || true

if [[ $# -gt 0 ]]; then
  payload="$1"
else
  payload="$(cat)"
fi

transport="$(detect_transport)" || {
  printf 'No unix socket client available; need nc -U, socat, or ruby.\n' >&2
  exit 69
}

case "$transport" in
  nc)
    printf '%s\n' "$payload" | nc -U "$socket_path"
    ;;
  socat)
    printf '%s\n' "$payload" | socat - UNIX-CONNECT:"$socket_path"
    ;;
  ruby)
    ruby -rsocket -e '
      socket = UNIXSocket.new(ARGV[0])
      socket.puts(ARGV[1])
      while (line = socket.gets)
        print line
      end
    ' "$socket_path" "$payload"
    ;;
esac
