#!/usr/bin/env bash
# opmexec test suite - plain bash, no dependencies.
#
# Usage: tests/run_tests.sh [PATTERN]
#   PATTERN        run only tests whose "file:function" contains it
#   TEST_SCHEDULER    scheduler for queue tests (default: localq); on a cluster,
#                  e.g. TEST_SCHEDULER=slurm, once that backend exists
#   TEST_TIMEOUT   seconds per test (default: 60)
#   KEEP_FAILED=1  keep the sandbox of failed tests for inspection
#   TMPDIR         where sandboxes are created (default: /tmp)

set -o pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/lib.sh"

pattern="${1:-}"
timeout_s="${TEST_TIMEOUT:-60}"
passed=0 failed=0 skipped=0
failures=()

echo "opmexec tests (scheduler: $TEST_SCHEDULER)"

for file in "$TESTS_DIR"/test_*.sh; do
  name=$(basename "$file")
  header_done=false

  for fn in $(grep -oE '^test_[a-z0-9_]+\(\)' "$file" | tr -d '()'); do
    [[ -n "$pattern" && "$name:$fn" != *"$pattern"* ]] && continue

    if [[ "$header_done" == false ]]; then
      echo
      echo "$name"
      header_done=true
    fi

    sandbox=$(mktemp -d "${TMPDIR:-/tmp}/opmexec-test.XXXXXX")
    start=$(date +%s.%N)

    timeout "$timeout_s" bash -c '
      source "$1"; source "$2"; setup_sandbox "$3"; "$4"
    ' _ "$TESTS_DIR/lib.sh" "$file" "$sandbox" "$fn" > "$sandbox/test.log" 2>&1
    rc=$?

    teardown_sandbox "$sandbox"
    elapsed=$(awk -v s="$start" -v e="$(date +%s.%N)" 'BEGIN { printf "%.1fs", e - s }')

    case "$rc" in
      0)
        echo "  PASS  $fn ($elapsed)"
        passed=$((passed + 1))
        ;;
      77)
        echo "  SKIP  $fn ($(sed -n 's/^SKIP: //p' "$sandbox/test.log" | tail -1))"
        skipped=$((skipped + 1))
        ;;
      *)
        [[ "$rc" == 124 ]] && echo "FAIL: timed out after ${timeout_s}s" >> "$sandbox/test.log"
        echo "  FAIL  $fn ($elapsed)"
        sed 's/^/        /' "$sandbox/test.log"
        failed=$((failed + 1))
        failures+=("$name:$fn")
        ;;
    esac

    if [[ "$rc" != 0 && "$rc" != 77 && -n "${KEEP_FAILED:-}" ]]; then
      echo "        sandbox kept: $sandbox"
    elif [[ "$sandbox" == "${TMPDIR:-/tmp}"/opmexec-test.* ]]; then
      rm -rf -- "$sandbox"
    fi
  done
done

echo
echo "$passed passed, $failed failed, $skipped skipped"
for f in "${failures[@]}"; do
  echo "  failed: $f"
done

[[ "$failed" -eq 0 ]]
