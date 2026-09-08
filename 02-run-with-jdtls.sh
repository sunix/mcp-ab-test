#!/usr/bin/env bash
# Runs the identical task in a fresh "with jdtls-mcp" worktree, attaching
# the server via --mcp-config so its presence is scoped to this one
# invocation. Each call creates its own worktree (run-<N>-with) off the
# same pinned base commit and leaves it in place afterward, so the
# generated code is still there to inspect or diff later with
# 04-diff-runs.sh.
set -euo pipefail
source "$(dirname "$0")/config.sh"

if [ ! -x "$JDTLS_MCP_START" ]; then
  echo "FAIL: jdtls-mcp not installed, run 00-install-jdtls-mcp.sh first: $JDTLS_MCP_START"; exit 1
fi
require_java21

RUN_NUM=$(next_run_number)
LABEL="run-${RUN_NUM}-with"
OUT_FILE="$RESULTS_DIR/${LABEL}.json"

WORKTREE=$(create_run_worktree "$LABEL")
echo "== Run #$RUN_NUM: with jdtls-mcp, in $WORKTREE =="

# MCP tool schemas are deferred by default — only bare names enter context,
# and Claude must proactively call ToolSearch to see descriptions before it
# can use them. It never did across several earlier runs (nor did
# ENABLE_TOOL_SEARCH=auto help — that threshold is evaluated against the
# *total* deferred-tool budget across the whole session, which blew past 10%
# once every other deferred built-in was counted too). alwaysLoad is the
# precise, per-server fix: it forces jdtls-mcp's 8 tool schemas into context
# at session start regardless of ENABLE_TOOL_SEARCH or anything else deferred
# — but alwaysLoad's own connect wait is capped at ~5s, far short of
# jdtls-mcp's ~60-100s cold start. So we pre-warm the real server ourselves
# first (prewarm_jdtls), and point --mcp-config at relay-warm-jdtls.sh, which
# bridges Claude Code's stdio expectations to that already-warm process —
# from Claude Code's perspective the "server" it spawns responds instantly.
trap cleanup_prewarm_jdtls EXIT
prewarm_jdtls "$WORKTREE" "$LABEL"

cd "$WORKTREE"

MCP_CONFIG=$(jq -n \
  --arg relay "$RELAY_SCRIPT" \
  --arg fifo "$WARM_IN_FIFO" \
  --arg log "$WARM_OUT_LOG" \
  --arg initres "$WARM_INIT_RESULT_FILE" \
  --arg offset "$WARM_OFFSET" \
  '{mcpServers: {jdtls: {type: "stdio", command: $relay, args: [$fifo, $log, $initres, $offset], alwaysLoad: true}}}')

claude -p "$TASK_PROMPT" \
  --output-format json \
  --permission-mode "$PERMISSION_MODE" \
  --allowedTools "$ALLOWED_TOOLS" \
  --mcp-config "$MCP_CONFIG" > "$OUT_FILE"

snapshot_run_worktree "$WORKTREE" "$LABEL"

echo "Saved: $OUT_FILE"
echo "Worktree kept for inspection: $WORKTREE"
jq '{cost: .total_cost_usd, usage: .usage}' "$OUT_FILE"
