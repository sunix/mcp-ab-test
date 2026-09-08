#!/usr/bin/env bash
# Installs jdtls-mcp and runs a protocol-level smoke test against it, using
# the server's own source tree as the "Java project" to import (it's a Maven
# project itself, so no external repo is needed just to prove the server works).
set -euo pipefail
source "$(dirname "$0")/config.sh"

echo "== Checking prerequisites =="
require_java21

if ! command -v jq >/dev/null; then
  echo "FAIL: jq not found on PATH (used to parse MCP JSON-RPC and Claude Code JSON output)"; exit 1
fi

echo "== Installing jdtls-mcp into $JDTLS_MCP_DIR =="
if [ -x "$JDTLS_MCP_START" ]; then
  echo "Already present, skipping install (delete $JDTLS_MCP_DIR to force a reinstall)"
else
  ARCH=$(uname -m)
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ASSET="${JDTLS_MCP_ASSET:-jdtls-mcp-${OS}-${ARCH}.tar.gz}"
  mkdir -p "$JDTLS_MCP_DIR"

  if curl -fsSL "https://github.com/sunix/jdtls-mcp/releases/latest/download/${ASSET}" \
       -o /tmp/jdtls-mcp.tar.gz 2>/dev/null; then
    echo "Downloaded release asset $ASSET"
    tar xzf /tmp/jdtls-mcp.tar.gz -C "$JDTLS_MCP_DIR" --strip-components=1
    rm -f /tmp/jdtls-mcp.tar.gz
  else
    echo "No prebuilt release for ${OS}/${ARCH}, building from source"
    if ! command -v mvn >/dev/null; then
      echo "FAIL: mvn not found and no release asset available"; exit 1
    fi
    git clone https://github.com/sunix/jdtls-mcp.git "$JDTLS_MCP_DIR"
    (cd "$JDTLS_MCP_DIR" && mvn package -DskipTests)
  fi
fi

if [ ! -x "$JDTLS_MCP_START" ]; then
  echo "FAIL: $JDTLS_MCP_START missing or not executable after install"; exit 1
fi
echo "OK: $JDTLS_MCP_START present"

echo "== Smoke-testing the server (initialize + tools/list) =="
IN_FIFO=$(mktemp -u)
OUT_FILE=$(mktemp)
ERR_FILE=$(mktemp)
mkfifo "$IN_FIFO"
trap 'rm -f "$IN_FIFO" "$OUT_FILE" "$ERR_FILE"' EXIT

"$JDTLS_MCP_START" "$JDTLS_MCP_DIR" < "$IN_FIFO" > "$OUT_FILE" 2>"$ERR_FILE" &
SERVER_PID=$!
exec 3>"$IN_FIFO"

echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ab-test-smoke","version":"1.0"}}}' >&3

echo "Waiting up to 100s for initialize response (first run imports the project + builds the JDT index)..."
deadline=$((SECONDS + 100))
while (( SECONDS < deadline )); do
  grep -q '"id":1' "$OUT_FILE" 2>/dev/null && break
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "FAIL: server process died during initialize"; cat "$ERR_FILE"; exit 1; }
  sleep 2
done

if ! grep -q '"id":1' "$OUT_FILE" 2>/dev/null; then
  echo "FAIL: no initialize response within timeout"; echo "--- stderr ---"; cat "$ERR_FILE"; exit 1
fi
echo "OK: initialize responded"

# MCP requires the client to send this notification before any further
# request; some servers silently ignore requests sent before it arrives.
echo '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' >&3

echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' >&3
deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
  grep -q '"id":2' "$OUT_FILE" 2>/dev/null && break
  sleep 1
done

exec 3>&-
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

TOOLS_LINE=$(grep '"id":2' "$OUT_FILE" | tail -1 || true)
if [ -z "$TOOLS_LINE" ]; then
  echo "FAIL: no tools/list response within timeout"
  echo "--- last stdout lines ---"; tail -20 "$OUT_FILE"
  echo "--- last stderr lines ---"; tail -20 "$ERR_FILE"
  exit 1
fi
TOOL_COUNT=$(echo "$TOOLS_LINE" | jq '.result.tools | length' 2>/dev/null || echo 0)
if [ "$TOOL_COUNT" -lt 1 ]; then
  echo "FAIL: tools/list returned no tools"; echo "$TOOLS_LINE"; exit 1
fi

echo "OK: server exposes $TOOL_COUNT tools"
echo "PASS: jdtls-mcp is installed and responding correctly"
