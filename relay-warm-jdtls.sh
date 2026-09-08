#!/usr/bin/env bash
# Bridges Claude Code's stdio expectations to an already-running, pre-warmed
# jdtls-mcp process. Claude Code spawns this script AS "the server" (per its
# --mcp-config), unaware that the real jdtls-mcp process was started earlier
# and is already fully indexed.
#
# Since Claude Code always performs its own MCP handshake (initialize ->
# notifications/initialized) on every connection, and the real server has
# already gone through that handshake once during pre-warming (its session
# has no clean path for a second initialize), this script intercepts and
# locally fake-answers just those first two messages using the real result
# captured during pre-warming, then transparently relays everything after
# that (tools/list, tools/call, ...) to/from the real warm process.
#
# Usage: relay-warm-jdtls.sh <in-fifo> <out-log> <init-result-file> <offset>
#   in-fifo           FIFO feeding the real server's stdin (shared with the
#                      pre-warm script, which also holds a writer open on it)
#   out-log            Regular file the real server's stdout is redirected to
#   init-result-file   Contains the cached `result` object from the real
#                      server's own initialize response, captured during
#                      pre-warming
#   offset              Byte offset into out-log marking "already consumed by
#                      pre-warming" — this script only relays bytes after it
set -euo pipefail
IN_FIFO="$1"
OUT_LOG="$2"
INIT_RESULT_FILE="$3"
OFFSET="$4"

# Stream only new server output (from the recorded offset onward) to our own
# stdout, which Claude Code reads as this "server's" output.
tail -f -c "+$((OFFSET + 1))" "$OUT_LOG" &
TAIL_PID=$!
trap 'kill "$TAIL_PID" 2>/dev/null || true' EXIT

# A fresh writer fd into the server's stdin FIFO, for forwarding Claude's
# requests once the fake handshake is done.
exec 9>"$IN_FIFO"

did_init=false
did_notif=false
while IFS= read -r line; do
  if [[ "$did_init" == false && "$line" == *'"method":"initialize"'* ]]; then
    id=$(printf '%s' "$line" | jq -c '.id')
    result=$(cat "$INIT_RESULT_FILE")
    jq -cn --argjson id "$id" --argjson result "$result" '{jsonrpc:"2.0", id:$id, result:$result}'
    did_init=true
    continue
  fi
  if [[ "$did_notif" == false && "$line" == *'"method":"notifications/initialized"'* ]]; then
    did_notif=true
    continue
  fi
  printf '%s\n' "$line" >&9
done
