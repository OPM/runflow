#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# CLI: modes, options and errors

test_help_lists_directives_and_options() {
  run "$FLOWRUN" -h
  assert_rc 0
  for word in @flow @mpi @wait @submit @cancel @help --dry-run --jobs --shell --slurm-options; do
    assert_contains "$OUT" "$word"
  done
}

test_version_is_the_release_and_in_the_changelog() {
  # The VERSION file is the one source: --version and -h print it, and
  # CHANGELOG.md has its section. A copy without Git history, as installed
  # from a release, prints the version alone.
  local version
  read -r version < "$ROOT/VERSION"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION is not MAJOR.MINOR.PATCH: $version"
  grep -q "^## \[$version\] - " "$ROOT/CHANGELOG.md" || fail "CHANGELOG.md has no section for $version"

  mkdir -p "$SANDBOX/install"
  cp -r "$ROOT/flowrun" "$ROOT/lib" "$ROOT/etc" "$ROOT/VERSION" "$SANDBOX/install/"
  run "$SANDBOX/install/flowrun" --version
  assert_rc 0
  assert_eq "$OUT" "flowrun $version"
  run "$SANDBOX/install/flowrun" -h
  assert_contains "$OUT" "flowrun $version - the execution environment for OPM"
}

test_source_files_carry_the_license_header() {
  # Every script, library file, example, the man page and the defaults
  # start with the license and copyright (after a #! line): see README.md
  local file missing=() files=(
    "$ROOT/flowrun" "$ROOT/flowrun.bash" "$ROOT"/lib/*.sh "$ROOT"/lib/*/*.sh
    "$ROOT"/tests/*.sh "$ROOT"/examples/*.sh "$ROOT"/examples/python/*.py
    "$ROOT"/.github/ci/*.sh "$ROOT"/etc/defaults/*.conf "$ROOT"/man/man1/*.1
  )
  for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    head -n 3 "$file" | grep -q 'SPDX-License-Identifier: GPL-3.0-or-later' &&
      head -n 3 "$file" | grep -q 'Copyright (C) [0-9-]* OPM-OP AS' ||
      missing+=("${file#"$ROOT"/}")
  done
  [[ ${#missing[@]} -eq 0 ]] || fail "no license header: ${missing[*]}"
}

test_unknown_option_fails() {
  run "$FLOWRUN" --bogus
  assert_rc 1
  assert_contains "$OUT" "Unknown option: --bogus"
}

test_no_arguments_fails() {
  run "$FLOWRUN"
  assert_rc 1
  assert_contains "$OUT" "Script or -c command required"
}

test_command_mode_requires_command() {
  run "$FLOWRUN" -c
  assert_rc 1
  assert_contains "$OUT" "Command required after -c"
}

test_missing_script_fails() {
  run "$FLOWRUN" nope.sh
  assert_rc 1
  assert_contains "$OUT" "Script not found: nope.sh"
}

test_script_mode_passes_arguments_and_exit_code() {
  cat > workflow.sh << 'EOF'
echo "args=$# [$1] [$2]"
exit 3
EOF
  run "$FLOWRUN" workflow.sh one "two words"
  assert_rc 3
  assert_contains "$OUT" "args=2 [one] [two words]"
}

test_script_without_arguments_has_none() {
  # source without arguments would keep flowrun's own: the script itself
  echo 'echo "args=$# [${1:-}]"' > noargs.sh
  run "$FLOWRUN" noargs.sh
  assert_rc 0
  assert_contains "$OUT" "args=0 []"
}

test_command_mode_runs_plain_commands() {
  run "$FLOWRUN" -c echo hello
  assert_rc 0
  assert_eq "$OUT" "hello"
}

test_queue_options_become_defaults() {
  run_script -n 8 -q gpu -s localq --depends-on 1 --depends-on 2 << 'EOF'
echo "np=$FLOWRUN_NP queue=$FLOWRUN_QUEUE scheduler=$FLOWRUN_SCHEDULER deps=$FLOWRUN_DEPENDS_ON"
EOF
  assert_rc 0
  assert_contains "$OUT" "np=8 queue=gpu scheduler=localq deps=1,2"
}

test_empty_depends_on_rejected() {
  run "$FLOWRUN" --depends-on "" -c true
  assert_rc 1
  assert_contains "$OUT" "needs a job ID"
}

test_workflow_names_do_not_collide() {
  # Common names in workflow scripts must not affect flowrun, and vice versa
  run_script << 'EOF'
error() { echo "user error: $*"; }
info() { echo "user info: $*"; }
main() { echo "user main"; }
jobs=(a b)
DEBUG=1
SCHEDULER=nonsense
@wait @submit true
@wait "$TEST_SCHEDULER:999999"
echo "jobs=${jobs[*]} DEBUG=$DEBUG SCHEDULER=$SCHEDULER"
error "from the script"
EOF
  assert_contains "$OUT" "[INFO] Job $TEST_SCHEDULER:1 completed successfully"
  assert_contains "$OUT" "[ERROR] Job $TEST_SCHEDULER:999999 not found"
  assert_contains "$OUT" "jobs=a b DEBUG=1 SCHEDULER=nonsense"
  assert_contains "$OUT" "user error: from the script"
  assert_not_contains "$OUT" "user info"
}

test_auto_ignores_planned_schedulers() {
  # A cluster's commands in PATH: their backends are planned, so localq
  mkdir -p "$SANDBOX/cluster"
  local cmd
  for cmd in bsub sinfo qstat; do
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/cluster/$cmd"
    chmod +x "$SANDBOX/cluster/$cmd"
  done
  PATH="$SANDBOX/cluster:$PATH" FLOWRUN_SCHEDULER=auto run "$FLOWRUN" -c @wait @submit true
  assert_rc 0
  assert_contains "$OUT" "Job localq:1 completed successfully"
}

test_planned_scheduler_works_in_dry_runs_only() {
  run "$FLOWRUN" -s slurm -c @submit true
  assert_rc 1
  assert_contains "$OUT" "The SLURM backend is planned, not part of this release; --dry-run -s slurm shows the jobs"
  run "$FLOWRUN" --dry-run -s slurm -c @submit true
  assert_rc 0
  assert_contains "$OUT" "submit slurm:dry1"
  run "$FLOWRUN" -s nosuch -c @submit true
  assert_rc 1
  assert_contains "$OUT" "Unknown scheduler: nosuch"
}

test_options_without_value_fail() {
  local call
  for call in "@mpi -n" "@mpi -o" "@submit -q" "@submit --slurm-options" "@flow -v" "@flowpy -v"; do
    # shellcheck disable=SC2086  # the call's words
    run timeout 10 "$FLOWRUN" -c $call
    assert_rc 1
    assert_contains "$OUT" "option ${call#* } needs a value"
  done
  run "$FLOWRUN" -c @submit -n abc true
  assert_rc 1
  assert_contains "$OUT" "@submit: number of processes must be a positive integer (got: abc)"
}

test_auto_detection_falls_back_to_localq() {
  local cmd
  for cmd in bsub sinfo qstat; do
    command -v "$cmd" > /dev/null && skip "$cmd found: a cluster scheduler is detected here"
  done
  FLOWRUN_SCHEDULER=auto run "$FLOWRUN" -c @wait @submit true
  assert_rc 0
  assert_contains "$OUT" "localq:1"
  assert_contains "$OUT" "Job localq:1 completed successfully"
  
  FLOWRUN_SCHEDULER=auto run "$FLOWRUN" --jobs=all
  assert_rc 0
  assert_contains "$OUT" "localq: slots"
}

test_man_page_renders_without_warnings() {
  require_cmd groff
  run groff -man -ww -z "$ROOT/man/man1/flowrun.1"
  assert_rc 0
  assert_eq "$OUT" ""
}
