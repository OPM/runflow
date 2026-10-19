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

# Sandboxes go in TMPDIR, without trailing slashes: macOS sets TMPDIR to
# /var/folders/.../T/, and tests compare paths as text with what opmexec
# prints, which never has "//" (directories are made absolute with pwd)
TMPDIR=${TMPDIR:-/tmp}
while [[ "$TMPDIR" == */ && "$TMPDIR" != / ]]; do TMPDIR=${TMPDIR%/}; done
export TMPDIR
source "$TESTS_DIR/lib.sh"

pattern="${1:-}"
timeout_s="${TEST_TIMEOUT:-60}"
passed=0 failed=0 skipped=0
failures=()

# Run a command in a new session, without a controlling terminal, with INT,
# QUIT, HUP, TERM and PIPE at their defaults: a test must start as from a
# terminal, but bash starts & commands with INT and QUIT ignored, and whatever
# started the runner may ignore others (nohup: HUP; GitHub's runners: PIPE).
# perl does both (and has setsid on macOS); without perl, setsid alone.
detached() {
  if command -v perl > /dev/null; then
    exec perl -MPOSIX -e '
      $SIG{$_} = "DEFAULT" for qw(INT QUIT HUP TERM PIPE);
      POSIX::setsid() or die "setsid: $!\n";
      exec { $ARGV[0] } @ARGV or die "exec: $!\n"' "$@"
  fi
  exec setsid "$@"
}

# Ctrl-C (or TERM): stop the running test (timeout passes TERM on to it),
# clean up its sandbox, and stop
test_pid="" sandbox=""
interrupted() {
  if [[ -n "$test_pid" ]]; then
    kill -TERM "$test_pid" 2> /dev/null
    wait "$test_pid" 2> /dev/null
    teardown_sandbox "$sandbox"
    [[ "$sandbox" != "$TMPDIR"/opmexec-test.* ]] || rm -rf -- "$sandbox"
  fi
  echo
  echo "interrupted: $passed passed, $failed failed, $skipped skipped so far"
  exit 130
}
trap interrupted INT TERM

if [[ -z "$TIMEOUT" ]]; then
  echo "The tests need GNU timeout (coreutils; on macOS: brew install coreutils)" >&2
  exit 1
fi

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

    sandbox=$(mktemp -d "$TMPDIR/opmexec-test.XXXXXX")
    start=$(now)

    # In the background, so that the trap above runs at once on Ctrl-C (bash
    # postpones it until a foreground command ends); detached from the
    # terminal, which an interactive test shell (bash -i) would otherwise try
    # to take over, and be stopped for, outside the foreground process group.
    detached "$TIMEOUT" "$timeout_s" bash -c '
      source "$1"; source "$2"; setup_sandbox "$3"; "$4"
    ' _ "$TESTS_DIR/lib.sh" "$file" "$sandbox" "$fn" > "$sandbox/test.log" 2>&1 < /dev/null &
    test_pid=$!
    wait "$test_pid"
    rc=$?
    test_pid=""

    teardown_sandbox "$sandbox"
    elapsed=$(awk -v s="$start" -v e="$(now)" 'BEGIN { printf "%.1fs", e - s }')

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
    elif [[ "$sandbox" == "$TMPDIR"/opmexec-test.* ]]; then
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
