#!/usr/bin/env bash
# Helpers for opmexec tests, sourced in each test's own bash process.
# Each test runs in a sandbox: its own HOME, config, fake Flow and work dir.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPMEXEC="$ROOT/opmexec"
TEST_SCHEDULER="${TEST_SCHEDULER:-localq}"

# Create the sandbox and enter its work directory
setup_sandbox() {
  SANDBOX="$1"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/home" "$SANDBOX/work"

  # Fake Flow: prints how it was called; FAKE_SLEEP/FAKE_RC control it
  cat > "$SANDBOX/bin/flowtest" << 'EOF'
#!/bin/sh
[ "$1" = --version ] && { echo "flow 2099.10"; exit 0; }
[ "$1" = --build-info ] && { printf '%s\n' version=2099.10 hash=abc1234 "build_time=2099-01-02 at 03:04:05 hrs" build_type=Release "mpi=Fake MPI 1.0"; exit 0; }
echo "FLOW exe=$0 args=$* np=${OMPI_COMM_WORLD_SIZE:-${PMI_SIZE:-1}} pythonpath=${PYTHONPATH%%:*}"
printf 'ARGV'; printf ' [%s]' "$@"; echo
[ -n "$FAKE_SLEEP" ] && sleep "$FAKE_SLEEP"
exit "${FAKE_RC:-0}"
EOF
  chmod +x "$SANDBOX/bin/flowtest"

  # Only the test configuration is read (OPMEXEC_CONFIG); nothing from the
  # user's environment or files gets in
  unset $(compgen -v OPMEXEC_) XDG_CONFIG_HOME XDG_STATE_HOME
  cat > "$SANDBOX/opmexec.conf" << EOF
# Test configuration
OPMEXEC_SCHEDULER=$TEST_SCHEDULER
OPMEXEC_FLOW_BIN_PATHS=("$SANDBOX/bin")
OPMEXEC_FLOW_VERSION=flowtest
OPMEXEC_FLOW_PYTHONPATH="$SANDBOX/lib/python{python}/site-packages/{version}"
OPMEXEC_FLOW_PYTHON_MAP=('flowrc4[7-9]:3.12' 'flow*:3.11')
EOF
  
  export SANDBOX TEST_SCHEDULER
  export HOME="$SANDBOX/home"
  export OPMEXEC_CONFIG="$SANDBOX/opmexec.conf"
  export OPMEXEC_LOCALQ_SLOTS=4 OPMEXEC_LOCALQ_POLL=0.2 OPMEXEC_POLL=0.2
  export OPMEXEC_LOCALQ_DIR="$SANDBOX/localq"
  unset FAKE_SLEEP FAKE_RC

  cd "$SANDBOX/work" || exit 1
  touch A.DATA B.DATA
}

# Cancel jobs a test left active in its sandbox (localq only)
teardown_sandbox() {
  local sandbox="$1"
  [[ -d "$sandbox/localq/active" ]] || return 0
  HOME="$sandbox/home" OPMEXEC_CONFIG="$sandbox/opmexec.conf" OPMEXEC_LOCALQ_DIR="$sandbox/localq" bash -c '
    source "$1/lib/opmexec.sh"
    opmexec::load_queue_backend localq
    for id in $(ls "$OPMEXEC_LOCALQ_DIR/active"); do opmexec::backend_cancel_job "$id"; done
  ' _ "$ROOT" > /dev/null 2>&1
}

# Run a command, capturing combined output in OUT and exit code in RC
run() {
  OUT=$("$@" 2>&1)
  RC=$?
}

# Write a workflow script from stdin and run it with opmexec [OPTIONS]
run_script() {
  cat > workflow.sh
  run "$OPMEXEC" "$@" workflow.sh
}

fail() {
  echo "FAIL: $*"
  if [[ -n "${OUT+x}" ]]; then
    echo "--- last output (rc=$RC):"
    echo "$OUT"
  fi
  exit 1
}

skip() {
  echo "SKIP: $*"
  exit 77
}

assert_rc() {
  [[ "$RC" == "$1" ]] || fail "expected exit code $1, got $RC"
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"
}

assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "expected output not to contain: $2"
}

assert_file_contains() {
  [[ -f "$1" ]] || fail "file not found: $1"
  grep -qF -- "$2" "$1" || fail "expected $1 to contain: $2 (has: $(cat "$1"))"
}

require_localq() {
  [[ "$TEST_SCHEDULER" == localq ]] || skip "localq-specific test"
}

require_cmd() {
  command -v "$1" > /dev/null || skip "$1 not available"
}

# Wait up to SECONDS for a command to succeed
wait_for() {
  local seconds="$1" end
  shift
  end=$(( $(date +%s) + seconds ))
  until "$@"; do
    (( $(date +%s) >= end )) && return 1
    sleep 0.2
  done
}

# localq state directory and the number of session files left behind
localq_dir() {
  echo "$OPMEXEC_LOCALQ_DIR"
}

session_files() {
  ls "$HOME/.local/state/opmexec" 2>/dev/null | grep -c '^session\.'
}
