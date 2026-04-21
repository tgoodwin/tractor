#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-graph-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

trap 'ab_close' EXIT

run_id="$(tractor_reap "examples/wait_human_loop.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"

ab_assert_visible "#graph svg"
ab_assert_visible "[data-testid='node-draft']"
ab_assert_visible "[data-testid='node-review']"

ab_wait_event fn "document.querySelector('g.tractor-node[data-node-id=\"review\"]')?.classList.contains('waiting')"
ab_assert_class "g.tractor-node[data-node-id='review']" "waiting"
ab_assert_class "g.tractor-edge[data-from='review'][data-to='draft']" "tractor-edge-back"

click_result="$(ab_dom_click "[data-testid='node-review']")"
[[ "$click_result" == '"ok"' ]] || {
  printf 'Expected node click to succeed, got: %s\n' "$click_result" >&2
  exit 1
}
ab_wait_event text "Decision Required"

ab_click role button --name "revise" --exact
ab_wait_event fn "document.querySelector('g.tractor-edge[data-from=\"review\"][data-to=\"draft\"]')?.classList.contains('is-taken')"
ab_wait_event fn "document.querySelector('g.tractor-node[data-node-id=\"review\"]')?.classList.contains('waiting')"

iterations_badge="$(ab get text "g.tractor-node[data-node-id='draft'] .tractor-badge-iterations")"
[[ "$iterations_badge" =~ ^×2$ ]] || {
  printf 'Expected draft iteration badge ×2, got: %s\n' "$iterations_badge" >&2
  exit 1
}

cumulative_badge="$(ab get text "g.tractor-node[data-node-id='draft'] .tractor-badge-cumulative")"
[[ "$cumulative_badge" == Σ* ]] || {
  printf 'Expected cumulative badge after loop, got: %s\n' "$cumulative_badge" >&2
  exit 1
}

ab_click role button --name "reject" --exact
ab_wait_event fn "document.querySelector('.run-summary-card .status-pill')?.textContent.includes('completed')"
