#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-wait-form-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

trap 'ab_close' EXIT

assert_node_state() {
  local node_id="$1"
  local state_class="$2"
  ab_assert_class "g.tractor-node[data-node-id='${node_id}']" "$state_class"
}

select_review_gate() {
  local click_result
  click_result="$(ab_dom_click "[data-testid='node-review_gate']")"
  [[ "$click_result" == '"ok"' ]] || {
    printf 'Expected node click to succeed, got: %s\n' "$click_result" >&2
    exit 1
  }
  ab_wait_event text "Decision Required"
}

assert_wait_form_static() {
  ab_assert_visible ".wait-form-panel[aria-label='Human decision required']"
  ab_assert_text ".wait-form-panel" "Decision Required"
  ab_assert_text ".wait-form-panel .wait-form-prompt" "Choose the review outcome"

  local panel_text
  panel_text="$(ab get text ".wait-form-panel")"
  [[ "$panel_text" == *"waiting "* ]] || {
    printf 'Expected waiting-since text in wait form, got: %s\n' "$panel_text" >&2
    exit 1
  }
  [[ "$panel_text" == *"timeout in "* ]] || {
    printf 'Expected timeout text in wait form, got: %s\n' "$panel_text" >&2
    exit 1
  }

  local button_count
  button_count="$(ab eval "document.querySelectorAll('.wait-form-panel .wait-choice-button').length")"
  [[ "$button_count" == "2" ]] || {
    printf 'Expected 2 wait choice buttons, got: %s\n' "$button_count" >&2
    exit 1
  }

  local labels
  labels="$(ab eval "Array.from(document.querySelectorAll('.wait-form-panel .wait-choice-button')).map((el) => el.textContent.trim()).join(',')")"
  [[ "$labels" == '"approve,reject"' ]] || {
    printf 'Expected approve,reject button labels, got: %s\n' "$labels" >&2
    exit 1
  }
}

assert_wait_resolution() {
  local label="$1"
  local source="$2"

  ab_assert_visible ".wait-form-panel[aria-label='Wait resolution']"
  ab_assert_text ".wait-form-panel[aria-label='Wait resolution']" "${label} via ${source}"
  ab_assert_text "#timeline" "${label} via ${source}"
}

run_wait_flow() {
  local label="$1"
  local next_node="$2"

  local run_id
  run_id="$(tractor_reap "examples/wait_human_review.dot")"
  ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"

  assert_node_state "review_gate" "waiting"
  select_review_gate
  assert_wait_form_static

  ab_click role button --name "${label}" --exact

  ab_wait_event fn "document.querySelector('g.tractor-node[data-node-id=\"review_gate\"]')?.classList.contains('succeeded')"
  ab_wait_event fn "document.querySelector('g.tractor-node[data-node-id=\"${next_node}\"]')?.classList.contains('succeeded')"
  ab_wait_event fn "document.querySelector('g.tractor-node[data-node-id=\"exit\"]')?.classList.contains('succeeded')"
  ab_wait_event fn "document.querySelector('.run-summary-card .status-pill')?.textContent.includes('completed')"
  ab_wait_event fn "document.querySelector('g.tractor-edge[data-from=\"review_gate\"][data-to=\"${next_node}\"]')?.classList.contains('is-taken')"

  assert_node_state "review_gate" "succeeded"
  assert_node_state "${next_node}" "succeeded"
  assert_node_state "exit" "succeeded"
  ab_assert_text ".run-summary-card .status-pill" "completed"
  ab_assert_class "g.tractor-edge[data-from='review_gate'][data-to='${next_node}']" "is-taken"
  assert_wait_resolution "$label" "operator"
}

assert_invalid_label() {
  local run_id
  run_id="$(tractor_reap "examples/wait_human_review.dot")"
  ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"

  assert_node_state "review_gate" "waiting"
  select_review_gate
  assert_wait_form_static

  local push_result
  push_result="$(ab eval "(function() {
    const root = document.querySelector('[data-phx-main]');
    if (!root) return 'missing';
    window.liveSocket.main.pushEvent('click', root, null, 'submit_wait_choice', { label: 'bogus' }, {}, () => {});
    return 'sent';
  })()")"
  [[ "$push_result" == '"sent"' ]] || {
    printf 'Expected invalid-label pushEvent to send, got: %s\n' "$push_result" >&2
    exit 1
  }

  ab_wait_event fn "Boolean(document.querySelector('.wait-form-error')?.textContent.includes('Invalid choice'))"
  ab_assert_text ".wait-form-error" "Invalid choice. Expected one of: approve, reject"
  assert_node_state "review_gate" "waiting"
  ab_assert_visible ".wait-form-panel[aria-label='Human decision required']"
}

assert_timeout_path() {
  local run_id
  run_id="$(tractor_reap "examples/wait_human_review.dot")"
  ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"

  assert_node_state "review_gate" "waiting"
  select_review_gate
  assert_wait_form_static

  ab_wait_event fn "document.querySelector('g.tractor-node[data-node-id=\"review_gate\"]')?.classList.contains('succeeded')"
  ab_wait_event fn "document.querySelector('g.tractor-node[data-node-id=\"rejected\"]')?.classList.contains('succeeded')"
  ab_wait_event fn "document.querySelector('.run-summary-card .status-pill')?.textContent.includes('completed')"

  assert_node_state "review_gate" "succeeded"
  assert_node_state "rejected" "succeeded"
  ab_assert_text ".run-summary-card .status-pill" "completed"
  assert_wait_resolution "reject" "timeout"
}

assert_resume_path() {
  [[ -f "$TRACTOR_BROWSER_SERVER_PID_FILE" ]] || return 0

  local run_id
  run_id="$(tractor_reap "examples/wait_human_review.dot")"
  ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"

  assert_node_state "review_gate" "waiting"
  select_review_gate
  assert_wait_form_static

  tractor_server_stop
  tractor_server_start

  ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"
  assert_node_state "review_gate" "waiting"
  select_review_gate
  assert_wait_form_static

  ab_click role button --name "approve" --exact
  ab_wait_event fn "document.querySelector('.run-summary-card .status-pill')?.textContent.includes('completed')"
  assert_node_state "approved" "succeeded"
  assert_node_state "exit" "succeeded"
  assert_wait_resolution "approve" "operator"
}

run_wait_flow "approve" "approved"
run_wait_flow "reject" "rejected"
assert_invalid_label

if [[ "${TRACTOR_BROWSER_LONG:-0}" == "1" ]]; then
  assert_timeout_path
fi

if [[ "${TRACTOR_BROWSER_RESUME:-1}" == "1" ]]; then
  assert_resume_path
fi
