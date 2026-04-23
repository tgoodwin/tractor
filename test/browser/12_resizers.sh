#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-resizers-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"
tractor_suite_setup

trap 'ab_close' EXIT

run_id="$(tractor_reap "test/browser/fixtures/node_panel_header.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"

ab_assert_visible "#resizer-left[phx-hook='Resizer']"
ab_assert_visible "#resizer-right[phx-hook='Resizer']"

measure_width() {
  local selector="$1"
  local escaped_selector="${selector//\\/\\\\}"
  escaped_selector="${escaped_selector//\'/\\\'}"
  ab eval "Math.round(document.querySelector('${escaped_selector}')?.getBoundingClientRect().width ?? 0)"
}

drag_resizer() {
  local selector="$1"
  local delta_x="$2"
  local escaped_selector="${selector//\\/\\\\}"
  escaped_selector="${escaped_selector//\'/\\\'}"
  ab eval "(function() {
    const handle = document.querySelector('${escaped_selector}');
    if (!handle) return 'missing';
    const rect = handle.getBoundingClientRect();
    const startX = rect.left + rect.width / 2;
    const startY = rect.top + rect.height / 2;
    handle.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: startX, clientY: startY }));
    document.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: startX + ${delta_x}, clientY: startY }));
    document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, clientX: startX + ${delta_x}, clientY: startY }));
    return 'ok';
  })()"
}

left_before="$(measure_width ".runs-panel")"
drag_result="$(drag_resizer "#resizer-left" -60)"
[[ "$drag_result" == '"ok"' ]] || {
  printf 'Expected left resizer drag to succeed, got %s\n' "$drag_result" >&2
  exit 1
}
left_after="$(measure_width ".runs-panel")"
(( left_before - left_after >= 20 )) || {
  printf 'Expected left panel width to shrink by at least 20px, before=%s after=%s\n' "$left_before" "$left_after" >&2
  exit 1
}

right_before="$(measure_width ".node-panel")"
drag_result="$(drag_resizer "#resizer-right" 60)"
[[ "$drag_result" == '"ok"' ]] || {
  printf 'Expected right resizer drag to succeed, got %s\n' "$drag_result" >&2
  exit 1
}
right_after="$(measure_width ".node-panel")"
(( right_before - right_after >= 20 )) || {
  printf 'Expected right panel width to shrink by at least 20px, before=%s after=%s\n' "$right_before" "$right_after" >&2
  exit 1
}

ab_reload

left_reload="$(measure_width ".runs-panel")"
right_reload="$(measure_width ".node-panel")"

(( left_reload == left_after )) || {
  printf 'Expected left panel width to persist, after=%s reload=%s\n' "$left_after" "$left_reload" >&2
  exit 1
}

(( right_reload == right_after )) || {
  printf 'Expected right panel width to persist, after=%s reload=%s\n' "$right_after" "$right_reload" >&2
  exit 1
}
