#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_ALL="$ROOT/test/browser/run-all.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"
BASE_LOG_DIR="$ROOT/test/browser/logs/repeat-$STAMP"

mkdir -p "$BASE_LOG_DIR"

durations=()
rss_samples=()

median_seconds() {
  ruby -e '
    values = ARGV.map(&:to_i).sort
    if values.empty?
      puts 0
    elsif values.length.odd?
      puts values[values.length / 2]
    else
      mid = values.length / 2
      puts ((values[mid - 1] + values[mid]) / 2.0).round
    end
  ' "$@"
}

for iteration in 1 2 3 4 5; do
  run_log_dir="$BASE_LOG_DIR/iter-$iteration"
  run_data_dir="$ROOT/.tmp/browser-repeat-$STAMP-$iteration"
  run_log="$run_log_dir/run-all.log"
  launcher_pid_file="$run_log_dir/launcher.pid"
  launcher_mode_env=()

  mkdir -p "$run_log_dir"
  rm -rf "$run_data_dir"

  if [[ "$iteration" -eq 3 ]]; then
    launcher_mode_env=(TRACTOR_BROWSER_NO_LAUNCHER=1)
  fi

  start_epoch="$(date +%s)"

  (
    cd "$ROOT"
    env \
      TRACTOR_DATA_DIR="$run_data_dir" \
      TRACTOR_BROWSER_LOG_DIR="$run_log_dir" \
      TRACTOR_BROWSER_LAUNCHER_PID_FILE="$launcher_pid_file" \
      "${launcher_mode_env[@]}" \
      bash "$RUN_ALL"
  ) >"$run_log" 2>&1 &
  run_pid=$!

  if [[ "$iteration" -ne 3 ]]; then
    for _ in $(seq 1 100); do
      if [[ -f "$launcher_pid_file" ]]; then
        launcher_pid="$(cat "$launcher_pid_file" 2>/dev/null || true)"
        if [[ -n "$launcher_pid" ]] && kill -0 "$launcher_pid" >/dev/null 2>&1; then
          rss_kb="$(ps -o rss= -p "$launcher_pid" | tr -d ' ' || true)"
          [[ -n "$rss_kb" ]] && rss_samples+=("$rss_kb")
          break
        fi
      fi
      sleep 0.1
    done
  fi

  if ! wait "$run_pid"; then
    printf 'run-all iteration %s failed; see %s\n' "$iteration" "$run_log" >&2
    exit 1
  fi

  end_epoch="$(date +%s)"
  duration="$((end_epoch - start_epoch))"
  durations+=("$duration")
  printf 'iteration %s complete in %ss\n' "$iteration" "$duration"
done

median="$(median_seconds "${durations[@]}")"
printf 'repeat median: %ss\n' "$median"

if [[ "$median" -gt 120 ]]; then
  printf 'median wall time %ss exceeds 120s\n' "$median" >&2
  exit 1
fi

if [[ "${#rss_samples[@]}" -ge 2 ]]; then
  first_rss="${rss_samples[0]}"
  last_rss="${rss_samples[-1]}"
  rss_growth_mb="$(ruby -e 'print(((ARGV[1].to_i - ARGV[0].to_i) / 1024.0).round(1))' "$first_rss" "$last_rss")"
  printf 'launcher RSS growth: %s MB\n' "$rss_growth_mb"

  if ruby -e 'exit((((ARGV[1].to_i - ARGV[0].to_i) / 1024.0) > 50.0) ? 0 : 1)' "$first_rss" "$last_rss"; then
    printf 'launcher RSS grew by more than 50 MB (%s MB)\n' "$rss_growth_mb" >&2
    exit 1
  fi
fi
