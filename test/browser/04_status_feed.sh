#!/usr/bin/env bash
set -euo pipefail

export TRACTOR_AB_SESSION="${TRACTOR_AB_SESSION:-sprint0009-status-feed-$$}"
source "$(cd "$(dirname "$0")" && pwd)/_lib.sh"
tractor_suite_setup

trap 'ab_close' EXIT

status_off_run="$(tractor_reap "examples/wait_human_review.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${status_off_run}"
ab_assert_text "#status-feed-empty" "Status agent disabled"

status_on_run="$(tractor_reap "test/browser/fixtures/status_feed_wait.dot")"
ab_open "${TRACTOR_BASE_URL}/runs/${status_on_run}"

ab_assert_text "#status-feed-empty" "Waiting for first node..."
click_result="$(ab_dom_click "[data-testid='node-review_gate']")"
[[ "$click_result" == '"ok"' ]] || {
  printf 'Expected node click to succeed, got: %s\n' "$click_result" >&2
  exit 1
}
ab_wait_event text "Decision Required"
ab_click role button --name "approve" --exact

# Append status updates after the manifest leaves "running" so the suite
# exercises the watcher's post-terminal tail behavior without depending on
# fake status-agent subprocess timing.
ruby -rjson -rtime -rfileutils -e '
  run_dir = ARGV.fetch(0)
  manifest_path = File.join(run_dir, "manifest.json")
  50.times do
    if File.exist?(manifest_path)
      manifest = JSON.parse(File.read(manifest_path)) rescue {}
      break if manifest["status"] && manifest["status"] != "running"
    end

    sleep 0.1
  end

  run_events_path = File.join(run_dir, "_run", "events.jsonl")
  FileUtils.mkdir_p(File.dirname(run_events_path))

  seq =
    if File.exist?(run_events_path)
      File.readlines(run_events_path, chomp: true).map do |line|
        JSON.parse(line)["seq"] rescue nil
      end.compact.max || 0
    else
      0
    end

  review_ts = Time.now.utc
  approved_ts = review_ts + 1

  updates = [
    {
      "status_update_id" => "status-review-gate",
      "node_id" => "review_gate",
      "iteration" => 1,
      "summary" => "resolved_label",
      "timestamp" => review_ts.iso8601(6)
    },
    {
      "status_update_id" => "status-approved",
      "node_id" => "approved",
      "iteration" => 1,
      "summary" => "Node: approved",
      "timestamp" => approved_ts.iso8601(6)
    }
  ]

  File.open(run_events_path, "a") do |file|
    updates.each_with_index do |data, index|
      file.puts(JSON.dump({
        "ts" => data["timestamp"],
        "seq" => seq + index + 1,
        "kind" => "status_update",
        "data" => data
      }))
    end
  end
' "$TRACTOR_DATA_DIR/runs/$status_on_run"

ab_wait_event fn "document.querySelector('.run-summary-card .status-pill')?.textContent?.includes('completed')"
ab_wait_event fn "document.querySelectorAll('.status-feed-row').length >= 2"
ab_assert_text ".status-feed-row:first-child .status-feed-node" "approved"
ab_assert_text ".status-feed-row:first-child .status-feed-summary" "Node: approved"
ab_assert_text ".status-feed-row:nth-child(2) .status-feed-node" "review_gate"
ab_assert_text ".status-feed-row:nth-child(2) .status-feed-summary" "resolved_label"

iteration_text="$(ab get text ".status-feed-row:first-child .status-feed-iteration")"
[[ "$iteration_text" == "x1" ]] || {
  printf 'Expected status feed iteration badge x1, got: %s\n' "$iteration_text" >&2
  exit 1
}
