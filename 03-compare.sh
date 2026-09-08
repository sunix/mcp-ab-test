#!/usr/bin/env bash
# Compares token usage/cost across every run-*-without.json and
# run-*-with.json found in results/ — as many of each as you've collected.
set -euo pipefail
source "$(dirname "$0")/config.sh"

cd "$RESULTS_DIR"

mapfile -t WITHOUT_FILES < <(ls run-*-without.json 2>/dev/null | sort -t- -k2,2n)
mapfile -t WITH_FILES    < <(ls run-*-with.json 2>/dev/null | sort -t- -k2,2n)

if [ ${#WITHOUT_FILES[@]} -eq 0 ] && [ ${#WITH_FILES[@]} -eq 0 ]; then
  echo "FAIL: no run-*.json files found in $RESULTS_DIR — run 01/02 first"; exit 1
fi

print_runs() {
  local label="$1"; shift
  echo "== $label (${#@} run(s)) =="
  local f
  for f in "$@"; do
    echo "-- $f --"
    jq -r '
      "input_tokens:        \(.usage.input_tokens // 0)",
      "output_tokens:       \(.usage.output_tokens // 0)",
      "cache_read_tokens:   \(.usage.cache_read_input_tokens // 0)",
      "cache_write_tokens:  \(.usage.cache_creation_input_tokens // 0)",
      "num_turns:           \(.num_turns // "n/a")",
      "total_cost_usd:      \(.total_cost_usd // "n/a")"
    ' "$f"
  done
  echo
}

mean_of() {
  # mean_of <jq-field-expr> <files...>
  local expr="$1"; shift
  if [ "$#" -eq 0 ]; then echo 0; return; fi
  jq -s "map($expr) | add / length" "$@"
}

print_average() {
  local label="$1"; shift
  if [ "$#" -eq 0 ]; then
    echo "$label: no runs yet"
    return
  fi
  echo "$label (n=$#):"
  echo "  avg input_tokens:       $(mean_of '.usage.input_tokens // 0' "$@")"
  echo "  avg output_tokens:      $(mean_of '.usage.output_tokens // 0' "$@")"
  echo "  avg cache_read_tokens:  $(mean_of '.usage.cache_read_input_tokens // 0' "$@")"
  echo "  avg cache_write_tokens: $(mean_of '.usage.cache_creation_input_tokens // 0' "$@")"
  echo "  avg total_cost_usd:     $(mean_of '.total_cost_usd // 0' "$@")"
}

SUMMARY="$RESULTS_DIR/comparison.txt"

{
  echo "jdtls-mcp A/B comparison"
  echo "generated: $(date -u +%FT%TZ)"
  echo "repo: $REPO"
  echo "task prompt:"
  echo "$TASK_PROMPT" | sed 's/^/  /'
  echo

  print_runs "without jdtls-mcp" "${WITHOUT_FILES[@]}"
  print_runs "with jdtls-mcp"    "${WITH_FILES[@]}"

  echo "-- averages --"
  print_average "without jdtls-mcp" "${WITHOUT_FILES[@]}"
  echo
  print_average "with jdtls-mcp" "${WITH_FILES[@]}"
  echo

  if [ ${#WITHOUT_FILES[@]} -gt 0 ] && [ ${#WITH_FILES[@]} -gt 0 ]; then
    echo "-- delta of averages (with - without) --"
    for field in input_tokens output_tokens cache_read_tokens cache_write_tokens; do
      expr=".usage.${field%_tokens}_tokens // 0"
      case "$field" in
        cache_read_tokens) expr='.usage.cache_read_input_tokens // 0' ;;
        cache_write_tokens) expr='.usage.cache_creation_input_tokens // 0' ;;
      esac
      w=$(mean_of "$expr" "${WITH_FILES[@]}")
      wo=$(mean_of "$expr" "${WITHOUT_FILES[@]}")
      echo "  $field: $(jq -n --argjson w "$w" --argjson wo "$wo" '$w - $wo')"
    done
    w_cost=$(mean_of '.total_cost_usd // 0' "${WITH_FILES[@]}")
    wo_cost=$(mean_of '.total_cost_usd // 0' "${WITHOUT_FILES[@]}")
    echo "  total_cost_usd: $(jq -n --argjson w "$w_cost" --argjson wo "$wo_cost" '$w - $wo')"
  else
    echo "-- delta skipped: need at least one run in each arm --"
  fi
} | tee "$SUMMARY"

echo
echo "Saved summary: $SUMMARY"
echo "Note: plain --output-format json only reports final usage/cost, not which"
echo "tools were called mid-task. To confirm jdtls-mcp's tools were actually"
echo "invoked (vs. just sitting unused in context), rerun 02-run-with-jdtls.sh's"
echo "claude -p line by hand with --output-format stream-json --verbose and"
echo "grep the stream for the tool name, or inspect the session transcript"
echo "under ~/.claude/projects/. To compare what each run actually changed in"
echo "the code, use ./04-diff-runs.sh instead."
