#!/usr/bin/env bash
# Runs the task in a fresh "without jdtls-mcp" worktree — no MCP config at
# all. Each call creates its own worktree (run-<N>-without) off the same
# pinned base commit and leaves it in place afterward, so the generated
# code is still there to inspect or diff later with 04-diff-runs.sh.
set -euo pipefail
source "$(dirname "$0")/config.sh"

RUN_NUM=$(next_run_number)
LABEL="run-${RUN_NUM}-without"
OUT_FILE="$RESULTS_DIR/${LABEL}.json"

WORKTREE=$(create_run_worktree "$LABEL")
echo "== Run #$RUN_NUM: without jdtls-mcp, in $WORKTREE =="
cd "$WORKTREE"

claude -p "$TASK_PROMPT" \
  --output-format json \
  --permission-mode "$PERMISSION_MODE" \
  --allowedTools "$ALLOWED_TOOLS" > "$OUT_FILE"

snapshot_run_worktree "$WORKTREE" "$LABEL"

echo "Saved: $OUT_FILE"
echo "Worktree kept for inspection: $WORKTREE"
jq '{cost: .total_cost_usd, usage: .usage}' "$OUT_FILE"
