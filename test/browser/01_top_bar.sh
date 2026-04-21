#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-top-bar-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"

trap 'ab_close' EXIT

run_id="$(tractor_reap "examples/wait_human_review.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${run_id}"

ab_assert_text ".top-bar-mark" "Tractor"
ab_assert_visible "#theme-toggle"

version="$(ab get text ".top-bar-version")"

if [[ ! "$version" =~ ^v[0-9] ]]; then
  printf 'Expected version pill to start with v, got: %s\n' "$version" >&2
  exit 1
fi
