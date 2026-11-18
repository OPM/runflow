#!/usr/bin/env bash
# localq stress test: many short jobs with random slot needs.
# Checks that every job runs exactly once and completes, that the slots in
# use never exceed FLOWRUN_LOCALQ_SLOTS, and reports throughput.
#
# Usage: tests/stress_localq.sh [NJOBS] [SLOTS]   (default: 100 jobs, 8 slots)

set -o pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/lib.sh"

njobs="${1:-100}"
slots="${2:-8}"

TEST_SCHEDULER=localq
sandbox=$(mktemp -d "${TMPDIR:-/tmp}/flowrun-stress.XXXXXX")
setup_sandbox "$sandbox"
export FLOWRUN_LOCALQ_SLOTS="$slots"

echo "localq stress test: $njobs jobs, $slots slots (sandbox: $sandbox)"

# Each job logs start/end with its index and slot count, then sleeps briefly
cat > workflow.sh << 'EOF'
for i in $(seq 1 "$1"); do
  np=$(( RANDOM % 4 + 1 ))
  @submit -n "$np" sh -c '
    echo "S $("$SANDBOX/tools/now") $1 $2" >> events.log
    sleep 0.1
    echo "E $("$SANDBOX/tools/now") $1 $2" >> events.log
  ' job "$i" "$np" > /dev/null || exit 1
done
@wait > /dev/null 2>&1
EOF

start=$(now)
"$FLOWRUN" workflow.sh "$njobs"
rc=$?
end=$(now)

errors=0
check() {
  if [[ "$2" == ok ]]; then
    echo "  ok    $1"
  else
    echo "  FAIL  $1: $2"
    errors=$((errors + 1))
  fi
}

check "workflow exit code" "$([[ $rc -eq 0 ]] && echo ok || echo "rc=$rc")"

completed=$("$FLOWRUN" -s localq --jobs=all | grep -c ' COMPLETED ')
check "all jobs COMPLETED" "$([[ $completed -eq $njobs ]] && echo ok || echo "$completed of $njobs")"

starts=$(grep -c '^S ' events.log)
unique=$(awk '$1 == "S" && !seen[$3]++ { n++ } END { print n + 0 }' events.log)
check "every job ran exactly once" \
  "$([[ $starts -eq $njobs && $unique -eq $njobs ]] && echo ok || echo "$starts starts, $unique unique")"

# Sweep start/end events in time order; ends first at equal timestamps
max_used=$(awk '{ print $2, ($1 == "S" ? 1 : 0), ($1 == "S" ? $4 : -$4) }' events.log \
  | sort -k1,1n -k2,2n | awk '{ used += $3; if (used > max) max = used } END { print max + 0 }')
check "slots in use never above $slots (max seen: $max_used)" \
  "$([[ $max_used -le $slots ]] && echo ok || echo "max $max_used")"

awk -v n="$njobs" -v s="$start" -v e="$end" \
  'BEGIN { printf "  info  %d jobs in %.1fs (%.1f jobs/s)\n", n, e - s, n / (e - s) }'

if [[ $errors -eq 0 ]]; then
  [[ "$sandbox" == "${TMPDIR:-/tmp}"/flowrun-stress.* ]] && rm -rf -- "$sandbox"
  echo "PASS"
else
  echo "FAIL ($errors checks; sandbox kept: $sandbox)"
  exit 1
fi
