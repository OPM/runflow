#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Native scheduler options (--<scheduler>-options)

test_scheduler_options_apply_per_scheduler() {
  # Configuration, then flowrun, then @submit options; other schedulers' ignored
  printf '%s\n' "FLOWRUN_SLURM_OPTIONS='--account=site'" >> "$FLOWRUN_CONFIG"
  run "$FLOWRUN" --dry-run -s slurm --slurm-options "--qos=wf" --lsf-options "-q wf" \
    -c @submit --slurm-options "--time=1:00" --lsf-options "-W 1:00" true
  assert_rc 0
  assert_contains "$OUT" "options=--account=site --qos=wf --time=1:00"
  assert_not_contains "$OUT" "-W 1:00"
  assert_not_contains "$OUT" "-q wf"

  run "$FLOWRUN" --dry-run -s lsf --slurm-options "--qos=wf" \
    -c @submit --slurm-options "--time=1:00" --lsf-options "-R 'span[hosts=1]'" true
  assert_rc 0
  assert_contains "$OUT" "options=-R 'span[hosts=1]'"
  assert_not_contains "$OUT" "--time"
}

test_scheduler_options_without_matching_options() {
  run "$FLOWRUN" --dry-run -s slurm -c @submit --lsf-options "-W 1:00" true
  assert_rc 0
  assert_not_contains "$OUT" "options="
}

test_scheduler_options_reject_unbalanced_quotes() {
  run "$FLOWRUN" --dry-run -s slurm -c @submit --slurm-options "--comment='x" true
  assert_rc 1
  assert_contains "$OUT" "Unbalanced quotes in --slurm-options"
}

# "STRING" then the expected words, each in brackets
split_case() {
  local expected="$2" got=""
  flowrun::split_options "$1" test || { fail "rejected: $1"; return; }
  [[ ${#_FLOWRUN_WORDS[@]} -eq 0 ]] || got=$(printf '[%s]' "${_FLOWRUN_WORDS[@]}")
  [[ "$got" == "$expected" ]] || fail "split of <$1>: expected $expected, got $got"
}

test_split_options_follows_shell_quoting() {
  source "$ROOT/lib/flowrun.sh"
  split_case "" ""
  split_case "   " ""
  split_case "mpirun -np 1" "[mpirun][-np][1]"
  split_case "  a   b  " "[a][b]"
  split_case "--a='x y' --b=\"p q\" --c=r\\ s" "[--a=x y][--b=p q][--c=r s]"
  split_case "'it''s' \"\" ''" "[its][][]"
  split_case "'a \"b\" \\c'" "[a \"b\" \\c]"
  split_case "\"\\\" \\\\ \\\$ \\\` \\n\"" "[\" \\ \$ \` \\n]"
  split_case "a\\'b \$HOME *" "[a'b][\$HOME][*]"
  split_case "x\"y z\"w" "[xy zw]"
  split_case $'a\tb\nc' "[a][b][c]"
}

test_split_options_rejects_unclosed_quotes_and_trailing_backslash() {
  source "$ROOT/lib/flowrun.sh"
  local s
  for s in "'a" "\"a" "a 'b\" c" "\"a\\\""; do
    flowrun::split_options "$s" test 2> err.txt && fail "accepted: $s"
    grep -q "Unbalanced quotes in test" err.txt || fail "message for: $s"
    [[ ${#_FLOWRUN_WORDS[@]} -eq 0 ]] || fail "words left for: $s"
  done
  flowrun::split_options "a\\" test 2> err.txt && fail "accepted a trailing backslash"
  grep -q "Trailing backslash in test" err.txt || fail "message for a trailing backslash"
  return 0
}

test_split_options_needs_no_external_commands() {
  # BSD xargs and printf behave differently: the parser uses neither
  source "$ROOT/lib/flowrun.sh"
  local PATH="$SANDBOX/empty"
  mkdir -p "$PATH"
  split_case "mpirun --bind-to 'no ne' -np 1" "[mpirun][--bind-to][no ne][-np][1]"
}

test_scheduler_options_ignored_by_localq() {
  require_localq
  run "$FLOWRUN" -c @wait @submit --slurm-options "--time=1:00" --lsf-options "-W 1:00" true
  assert_rc 0
  assert_contains "$OUT" "completed successfully"
}

test_unknown_scheduler_options_rejected() {
  run "$FLOWRUN" -c @submit --foo-options "x" true
  assert_rc 1
  assert_contains "$OUT" "Unknown option: --foo-options"
}

# --- Options for every invocation of a directive (--<directive>-options) ---

test_flow_options_apply_to_every_flow() {
  run "$FLOWRUN" --flow-options "--a='x y'" -c @flow --b=2 A.DATA
  assert_rc 0
  assert_contains "$OUT" "ARGV [--a=x y] [--b=2] [$PWD/A.DATA]"
}

test_flow_options_layers_and_jobs() {
  # Site default (configuration), then flowrun --flow-options, then -o; the
  # workflow's options reach @flow inside jobs
  printf '%s\n' "FLOWRUN_FLOW_OPTIONS='--site=1'" >> "$FLOWRUN_CONFIG"
  run "$FLOWRUN" --flow-options "--wf=2" -c @wait @submit -o "$PWD/out.log" @flow --call=3 A.DATA
  assert_rc 0
  assert_file_contains out.log "ARGV [--site=1] [--wf=2] [--call=3] [$PWD/A.DATA]"
}

test_flow_options_under_mpi() {
  run "$FLOWRUN" --dry-run --flow-options "--x=1" --mpi-options "--y=2" -c @mpi -n 2 @flow A.DATA
  assert_rc 0
  assert_contains "$OUT" "run: mpirun -np 2 --y=2 env PYTHONPATH="
  assert_contains "$OUT" "flowtest --x=1 $PWD/A.DATA"
}

test_flow_options_with_setup_when_sourcing() {
  cat > sourcing.sh << EOF
source "$ROOT/lib/flowrun.sh" || exit 1
flowrun::setup --flow-options "--from-setup" || exit 1
@flow A.DATA
EOF
  run bash sourcing.sh
  assert_rc 0
  assert_contains "$OUT" "ARGV [--from-setup] [$PWD/A.DATA]"
}

test_flowpy_options() {
  run "$FLOWRUN" --dry-run --flowpy-options "-u -X dev" -c @flowpy script.py
  [[ "$OUT" =~ run:\ env\ PYTHONPATH=[^\ ]+\ [^\ ]*python3\.11\ -u\ -X\ dev\ script\.py ]] || fail "unexpected command: $OUT"
}

test_directive_without_options_rejects_them() {
  mkdir "$SANDBOX/directives"
  printf '%s\n' 'flowrun::directive hello "" "Say hello"' '@hello() { echo hello; }' \
    > "$SANDBOX/directives/hello.sh"
  export FLOWRUN_DIRECTIVE_PATH="$SANDBOX/directives"
  run "$FLOWRUN" --hello-options "x" -c @hello
  assert_rc 1
  assert_contains "$OUT" "Unknown option: --hello-options (@hello takes no options)"
}

test_unknown_name_options_list_alternatives() {
  run "$FLOWRUN" --foo-options "x" -c true
  assert_rc 1
  assert_contains "$OUT" "native scheduler options exist for: lsf, slurm, pbs, localq"
  assert_contains "$OUT" "Directive options exist for: mpi flow flowpy"
}

test_directive_cannot_take_a_scheduler_name() {
  mkdir "$SANDBOX/directives"
  printf '%s\n' 'flowrun::directive slurm "" "Clash" "Options"' '@slurm() { echo clash; }' \
    > "$SANDBOX/directives/slurm.sh"
  export FLOWRUN_DIRECTIVE_PATH="$SANDBOX/directives"
  run "$FLOWRUN" -c true
  assert_contains "$OUT" "@slurm: the name of a scheduler cannot be used for a directive"
}

test_help_shows_directive_options() {
  run "$FLOWRUN" -c @help @flow
  assert_contains "$OUT" "--flow-options OPTS"
  assert_contains "$OUT" "Flow options for every @flow"
  run "$FLOWRUN" -c @help @mpi
  assert_contains "$OUT" "MPI launcher options for every @mpi"
}
