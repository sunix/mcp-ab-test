#!/usr/bin/env bash
# Single place to configure the jdtls-mcp A/B token-usage test.
# Edit REPO and TASK_PROMPT below, then run: 00 -> (01/02 as many times as
# you like, in any order) -> 03, and 04 whenever you want to diff content.
set -euo pipefail

# ============================================================================
# EDIT THESE TWO — same repo for both arms, only MCP presence differs
# ============================================================================

REPO="erasmus"

read -r -d '' TASK_PROMPT <<'PROMPT_EOF' || true
We're working on Erasmus, a from-scratch Jakarta Bean Validation 3.1 implementation. Your
current directory is a checkout of the erasmus repository — read `CLAUDE.md` and
`ROADMAP.md` right here first, for conventions and the full milestone plan. Make all your
changes within this directory; don't reference or touch any other checkout of this repo.

## Where things stand

M0–M2 are done: bootstrapping, all 21 built-in constraints, locale-aware message
interpolation with a homegrown EL-subset evaluator, and custom constraint authoring
(composed constraints, `@ReportAsSingleViolation`). `ErasmusValidator` currently validates a
single flat bean — every property, every constraint, no groups filtering, no cascading into
nested beans.

Start M3: object-graph cascading via `@Valid`, groups, and `@GroupSequence` short-circuiting.
`ROADMAP.md`'s M3 section has the full scope spec — read it before starting.

## Design constraints to keep in mind

- **Don't regress composed constraints / `@ReportAsSingleViolation`.** `ErasmusValidator`
  already has a recursive `evaluateConstraint`/`evaluateOwnValidator` pair that walks a
  constraint's composing constraints and collapses to one violation under
  `@ReportAsSingleViolation`. Whatever cascading/groups mechanism you add has to compose with
  that, not replace it — a cascaded, grouped, composed constraint still needs to work.
- **Cascading**: recursive descent into `@Valid`-annotated properties. `PathImpl` currently
  only supports a single-segment path; it'll need to accumulate segments as you descend
  (`address.city`). Cycle detection needs to be by bean *identity*, not `equals()` — an
  `IdentityHashMap`-backed set is the natural fit, scoped per top-level `validate()` call
  (never a static/shared cache).
- **Groups**: `ConstraintDescriptorImpl.getGroups()` is currently hardcoded to
  `Set.of(Default.class)` — it needs to actually read the constraint annotation's `groups()`
  attribute instead. Group inheritance (a group interface extending others) needs to expand
  correctly.
- **`@GroupSequence`**: short-circuit evaluation — stop at the first group in the sequence
  that produces any violation, don't evaluate the rest.
- Follow this project's TDD convention: write the test first (a dedicated integration test
  class covering cascading + groups + sequences, circular graphs, mixed cascading and
  groups), then the implementation, then refactor.

## Documentation

- Update `ROADMAP.md`'s M3 section with the actual status once implemented — narrow the
  scope explicitly and document the narrowing (same pattern used for M1's array-constraint
  gap and M2's temporal-type gap) if full spec coverage isn't practical in one pass, rather
  than silently shipping a partial implementation as if it were complete.
- Add a new post for M3 under `doc/making-of/`, the project's per-milestone build-log series.
  Read `doc/making-of/AGENTS.md` first — it's the style guide for this series (opening
  structure, the verbatim `ROADMAP.md` Scope-spec/Deliverable quote, the "1-2 real examples
  each backed by an actually-run test with captured output" rule, frozen closing sections).
  Follow it exactly rather than improvising a different structure. Add the new post to the
  numbered list in the root `MAKING-OF.md`.

Focus purely on the code and the docs — implementation, tests, `ROADMAP.md`, the new
making-of post. No need to touch git history or anything Codeberg/PR-related as part of this.
PROMPT_EOF

# ============================================================================
# Usually fine as defaults
# ============================================================================

WORKSPACE_ROOT="${WORKSPACE_ROOT:-/root/codeberg/vidocq/vidocq-workspace}"
BASE_BRANCH="${BASE_BRANCH:-main}"

MAIN_DIR="$WORKSPACE_ROOT/$REPO/main"

JDTLS_MCP_DIR="${JDTLS_MCP_DIR:-$HOME/.local/opt/jdtls-mcp}"
JDTLS_MCP_START="$JDTLS_MCP_DIR/scripts/start-mcp-server.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/results}"
RELAY_SCRIPT="$SCRIPT_DIR/relay-warm-jdtls.sh"
BASE_COMMIT_FILE="$RESULTS_DIR/base-commit.txt"

# Permission handling for the non-interactive (-p) runs. acceptEdits lets
# Claude write files and run common fs commands without prompting; add
# whatever Bash prefixes your task actually needs (mvn, mvnw, etc).
PERMISSION_MODE="${PERMISSION_MODE:-acceptEdits}"
ALLOWED_TOOLS="${ALLOWED_TOOLS:-Bash,Read,Edit,Write,Grep,Glob}"

mkdir -p "$RESULTS_DIR"

# Next shared run number across BOTH arms, so successive 01/02 calls in any
# order number their result files 1, 2, 3, ... continuously.
next_run_number() {
  local max=0 n
  shopt -s nullglob
  for f in "$RESULTS_DIR"/run-*-*.json; do
    n=$(basename "$f")
    n="${n#run-}"; n="${n%%-*}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    (( n > max )) && max=$n
  done
  shopt -u nullglob
  echo $((max + 1))
}

# Pins the commit every run starts from, the first time it's needed, so all
# runs across the whole test (any arm, any run number) are comparable even
# if $BASE_BRANCH moves on later.
ensure_base_commit() {
  [ -f "$BASE_COMMIT_FILE" ] && return
  if [ ! -d "$MAIN_DIR" ]; then
    echo "FAIL: $MAIN_DIR not found" >&2; exit 1
  fi
  local commit
  commit=$(git -C "$MAIN_DIR" rev-parse "$BASE_BRANCH")
  echo "$commit" > "$BASE_COMMIT_FILE"
  echo "Recorded base commit for all runs: $commit (from $MAIN_DIR@$BASE_BRANCH)" >&2
}

# Creates a fresh worktree for one run, named after that run (e.g.
# run-3-without), branched off the pinned base commit. Kept around
# afterward — nothing resets or removes it — so its content can be diffed
# later with 04-diff-runs.sh. Prints the new worktree's path on stdout.
create_run_worktree() {
  local label="$1"
  ensure_base_commit
  local base_commit path
  base_commit=$(cat "$BASE_COMMIT_FILE")
  path="$WORKSPACE_ROOT/$REPO/$label"
  if [ -d "$path" ]; then
    echo "FAIL: worktree already exists: $path" >&2; exit 1
  fi
  git -C "$MAIN_DIR" worktree add -b "$label" "$path" "$base_commit" >&2
  echo "$path"
}

# Commits whatever the run left behind (staged, unstaged, or untracked) onto
# its own branch, so the branch tip actually reflects what happened even
# though the task prompt tells Claude not to touch git history itself. Without
# this, 04-diff-runs.sh's branch-to-branch diff would show nothing — it
# compares commits, not working-tree state. --allow-empty so a run that
# genuinely changed nothing doesn't fail the script.
snapshot_run_worktree() {
  local worktree="$1" label="$2"
  git -C "$worktree" add -A
  git -C "$worktree" commit --allow-empty -m "snapshot: $label run output" >/dev/null
}

# Launches jdtls-mcp early against $worktree and blocks until it has
# genuinely finished its ~60-100s cold start (real initialize +
# notifications/initialized handshake, not a fixed sleep), so it's already
# warm by the time claude -p connects to it via relay-warm-jdtls.sh. Sets
# WARM_IN_FIFO, WARM_OUT_LOG, WARM_INIT_RESULT_FILE, WARM_OFFSET,
# WARM_SERVER_PID, WARM_DATA_DIR as globals for the caller to use and later
# pass to cleanup_prewarm_jdtls.
prewarm_jdtls() {
  local worktree="$1" label="$2"
  local tmp_prefix="/tmp/jdtls-warm-${label}"
  WARM_IN_FIFO="${tmp_prefix}.in"
  WARM_OUT_LOG="${tmp_prefix}.out.log"
  WARM_ERR_LOG="${tmp_prefix}.err.log"
  WARM_INIT_RESULT_FILE="${tmp_prefix}.init-result.json"
  WARM_DATA_DIR="${tmp_prefix}-data"

  rm -f "$WARM_IN_FIFO"
  mkfifo "$WARM_IN_FIFO"
  : > "$WARM_OUT_LOG"

  # Launch the server (the FIFO's reader) first, backgrounded, so its own
  # blocking open-for-read doesn't block this script — then open our writer
  # fd. Opening a FIFO for writing blocks until a reader exists, so doing
  # this in the other order (writer before reader) deadlocks the script
  # before the server is even launched.
  echo "Pre-warming jdtls-mcp against $worktree (this takes ~60-100s)..." >&2
  "$JDTLS_MCP_START" "$worktree" "$WARM_DATA_DIR" < "$WARM_IN_FIFO" > "$WARM_OUT_LOG" 2>"$WARM_ERR_LOG" &
  WARM_SERVER_PID=$!

  # Keep a writer open so the FIFO never sees EOF between our probe below and
  # the relay's later writes.
  exec 8>"$WARM_IN_FIFO"

  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"prewarm","version":"1.0"}}}' >&8

  local deadline=$((SECONDS + 150))
  while (( SECONDS < deadline )); do
    grep -q '"id":1' "$WARM_OUT_LOG" 2>/dev/null && break
    kill -0 "$WARM_SERVER_PID" 2>/dev/null || {
      echo "FAIL: jdtls-mcp died during pre-warm" >&2; cat "$WARM_ERR_LOG" >&2; exit 1
    }
    sleep 2
  done
  if ! grep -q '"id":1' "$WARM_OUT_LOG" 2>/dev/null; then
    echo "FAIL: jdtls-mcp did not respond to initialize within 150s during pre-warm" >&2
    exit 1
  fi

  grep '"id":1' "$WARM_OUT_LOG" | tail -1 | jq -c '.result' > "$WARM_INIT_RESULT_FILE"
  echo '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' >&8

  WARM_OFFSET=$(stat -c%s "$WARM_OUT_LOG")
  echo "jdtls-mcp warm and ready (pid $WARM_SERVER_PID)" >&2
}

# Safe to call even if prewarm_jdtls failed partway (e.g. before
# WARM_SERVER_PID was ever set) — meant to be trapped on EXIT so a failure
# mid-warm-up never leaks an orphaned java process.
cleanup_prewarm_jdtls() {
  [ -n "${WARM_SERVER_PID:-}" ] && { kill "$WARM_SERVER_PID" 2>/dev/null || true; wait "$WARM_SERVER_PID" 2>/dev/null || true; }
  [ -n "${WARM_IN_FIFO:-}" ] && rm -f "$WARM_IN_FIFO"
  [ -n "${WARM_OUT_LOG:-}" ] && rm -f "$WARM_OUT_LOG"
  [ -n "${WARM_ERR_LOG:-}" ] && rm -f "$WARM_ERR_LOG"
  [ -n "${WARM_INIT_RESULT_FILE:-}" ] && rm -f "$WARM_INIT_RESULT_FILE"
  [ -n "${WARM_DATA_DIR:-}" ] && rm -rf "$WARM_DATA_DIR"
}

# jdtls-mcp's launcher needs Java 21+. This environment's default `java` on
# PATH is often an older version (SDKMAN candidates must be selected per
# shell, e.g. `sdk use java 25.0.2-tem`, since shell state isn't inherited
# across separate commands) — check explicitly so a mismatch fails fast with
# a clear message instead of a silent MCP handshake timeout later.
require_java21() {
  if ! command -v java >/dev/null; then
    echo "FAIL: java not found on PATH (need Java 21+, e.g. run: sdk use java 25.0.2-tem)" >&2
    exit 1
  fi
  local major
  major=$(java -version 2>&1 | head -1 | grep -oE '"[0-9]+' | tr -d '"')
  if [ "$major" -lt 21 ]; then
    echo "FAIL: java on PATH is version $major, need 21+ (run: sdk use java 25.0.2-tem)" >&2
    exit 1
  fi
  echo "OK: java $major"
}
