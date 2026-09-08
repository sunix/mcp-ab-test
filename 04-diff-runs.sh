#!/usr/bin/env bash
# Diffs the actual code a run (or two runs) produced. Every run from 01/02 is
# kept as its own branch (run-<N>-without / run-<N>-with) in the same repo
# as $MAIN_DIR, since git worktrees share one .git — so this works whether
# or not the worktree directory itself still exists, as long as the branch
# wasn't deleted.
set -euo pipefail
source "$(dirname "$0")/config.sh"

usage() {
  cat <<EOF >&2
Usage:
  $0 --list                       list run branches available to diff
  $0 <run-label>                  diff that run against the pinned base commit
  $0 <run-label-a> <run-label-b>  diff between two runs' resulting content

Examples:
  $0 --list
  $0 run-1-without
  $0 run-1-without run-2-with
EOF
  exit 1
}

require_branch() {
  git -C "$MAIN_DIR" rev-parse --verify --quiet "refs/heads/$1" >/dev/null || {
    echo "FAIL: no such run branch: $1 (see: $0 --list)" >&2; exit 1
  }
}

[ "$#" -ge 1 ] || usage

if [ "$1" == "--list" ]; then
  git -C "$MAIN_DIR" branch --list 'run-*'
  exit 0
fi

case "$#" in
  1)
    require_branch "$1"
    if [ ! -f "$BASE_COMMIT_FILE" ]; then
      echo "FAIL: no base commit recorded yet — run 01 or 02 at least once" >&2; exit 1
    fi
    base=$(cat "$BASE_COMMIT_FILE")
    echo "== diff: base commit ($base) -> $1 =="
    git -C "$MAIN_DIR" diff "$base" "$1"
    ;;
  2)
    require_branch "$1"
    require_branch "$2"
    echo "== diff: $1 -> $2 =="
    git -C "$MAIN_DIR" diff "$1" "$2"
    ;;
  *)
    usage
    ;;
esac
