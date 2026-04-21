#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-node-panel-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

trap 'ab_close' EXIT

assert_text_includes() {
  local selector="$1"
  local expected="$2"
  local escaped_selector="${selector//\\/\\\\}"
  escaped_selector="${escaped_selector//\'/\\\'}"
  local escaped_expected="${expected//\\/\\\\}"
  escaped_expected="${escaped_expected//\'/\\\'}"

  local matches
  matches="$(ab eval "document.querySelector('${escaped_selector}')?.textContent.includes('${escaped_expected}') ?? false")"
  [[ "$matches" == "true" ]] || {
    printf 'Expected %s to include %q\n' "$selector" "$expected" >&2
    exit 1
  }
}

run_id="$(tractor_reap "test/browser/fixtures/node_panel_header.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"

click_result="$(ab_dom_click "[data-testid='node-modelled']")"
[[ "$click_result" == '"ok"' ]] || {
  printf 'Expected modelled node click to succeed, got: %s\n' "$click_result" >&2
  exit 1
}

ab_wait_event text "Node"
assert_text_includes ".node-panel" "modelled"
assert_text_includes ".node-panel" "Opus 4.7"
assert_text_includes ".node-panel" "high"

heading_text="$(ab eval "(function() {
  const headings = Array.from(document.querySelectorAll('.node-panel h2')).map((el) => el.textContent.trim());
  return headings[1] || '';
})()")"
[[ "$heading_text" == '"modelled"' ]] || {
  printf 'Expected selected node heading to be modelled, got: %s\n' "$heading_text" >&2
  exit 1
}
