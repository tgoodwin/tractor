#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/tgoodwin/projects/tractor"
BRANCH="chore/audit-fixes"
WT="$ROOT/.worktrees/audit-fixes-2026-04-28"
LOG="$ROOT/.tractor-audit-setup.log"

{
  printf '=== setup_audit_worktree run @ %s ===\n' "$(date -u +%FT%TZ)"

  cd "$ROOT"
  mkdir -p .worktrees

  if [ ! -f .gitignore ] || ! grep -qE '^\.worktrees/?$' .gitignore; then
    printf '\n.worktrees/\n' >> .gitignore
  fi

  if ! git worktree list | grep -qF "$WT"; then
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
      git worktree add "$WT" "$BRANCH"
    else
      git worktree add "$WT" -b "$BRANCH" HEAD
    fi
  fi

  if [ -d "$ROOT/docs/audits" ]; then
    mkdir -p "$WT/docs"
    rm -rf "$WT/docs/audits"
    cp -R "$ROOT/docs/audits" "$WT/docs/audits"

    exclude_file="$(git -C "$WT" rev-parse --git-path info/exclude)"
    mkdir -p "$(dirname "$exclude_file")"
    if ! grep -qxF "docs/audits/" "$exclude_file" 2>/dev/null; then
      printf '\ndocs/audits/\n' >> "$exclude_file"
    fi
  fi

  (cd "$WT" && mix deps.get)
} >> "$LOG" 2>&1

printf '%s' "$WT"
