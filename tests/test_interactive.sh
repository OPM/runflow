#!/usr/bin/env bash
# Interactive use: opmexec --shell, sourcing at a prompt, safety, the prompt
# marker, job notifications and tab completion. The shells read their commands
# from stdin (bash -i without a terminal warns about job control; ignored).

# Run an interactive opmexec shell with OPTIONS, reading commands from stdin
run_shell() {
  run "$OPMEXEC" --shell "$@"
}

test_shell_applies_options_and_loads_directives() {
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flowrc47"
  run_shell -n 3 --flow-version flowrc47 << 'EOF'
echo "np=$OPMEXEC_NP version=$OPMEXEC_FLOW_VERSION @flow=$(type -t @flow)"
EOF
  assert_rc 0
  # The banner names the Flow @flow runs
  assert_contains "$OUT" "opmexec shell: scheduler $TEST_SCHEDULER; Flow flowrc47: $SANDBOX/bin/flowrc47 (OPM 2099.10)"
  assert_contains "$OUT" "np=3 version=flowrc47 @flow=function"
}

test_shell_finds_opmexec_and_its_man_page() {
  # PATH without opmexec, MANPATH unset: both are added, the system's man
  # pages kept (trailing ":"); a second source adds nothing
  export PATH=${PATH//":$ROOT:"/:}
  unset MANPATH
  run_shell << 'EOF'
echo "opmexec=$(command -v opmexec)"
echo "manpath=[$MANPATH]"
source opmexec.bash
echo "path-entries=$(tr : '\n' <<< "$PATH" | grep -cx "$OPMEXEC_HOME")"
EOF
  assert_rc 0
  assert_contains "$OUT" "opmexec=$ROOT/opmexec"
  assert_contains "$OUT" "manpath=[$ROOT/man:]"
  assert_contains "$OUT" "path-entries=1"
  # Only with a working man and the system's pages (Ubuntu's container images
  # replace man with a stub that prints a notice and succeeds)
  if command -v man > /dev/null && [[ -f "$(man -w man 2> /dev/null)" ]]; then
    run_shell <<< 'man -w opmexec; [[ -f "$(man -w man)" ]] && echo system-pages-kept'
    assert_contains "$OUT" "$ROOT/man/man1/opmexec.1"
    assert_contains "$OUT" "system-pages-kept"
  fi
}

test_scripts_keep_their_path() {
  export PATH=${PATH//":$ROOT:"/:}
  unset MANPATH
  run bash -c 'source "$1/opmexec.bash"; echo "path-has-opmexec=$(command -v opmexec || echo no) manpath=[${MANPATH-unset}]"' _ "$ROOT"
  assert_contains "$OUT" "path-has-opmexec=no manpath=[unset]"
}

test_shell_takes_no_script() {
  run "$OPMEXEC" --shell workflow.sh
  assert_rc 1
  assert_contains "$OUT" "--shell starts an interactive shell: no script, -c or --jobs"
}

test_shell_reads_users_bashrc() {
  echo 'MY_SETTING=from-bashrc' > "$HOME/.bashrc"
  run_shell <<< 'echo "setting=$MY_SETTING"'
  assert_contains "$OUT" "setting=from-bashrc"
}

test_shell_prompt_marker() {
  run_shell --dry-run << 'EOF'
echo "marker=[$(opmexec::prompt)]"
OPMEXEC_PROMPT=false
echo "off=[$(opmexec::prompt)]"
EOF
  assert_contains "$OUT" "marker=[(opmexec $TEST_SCHEDULER flowtest dry-run) ]"
  assert_contains "$OUT" "off=[]"
}

test_shell_survives_mistakes_and_sets_no_traps() {
  run_shell << 'EOF'
@flwo
echo "after typo rc=$?"
@flow -v nope A.DATA
echo "after failure rc=$?"
opmexec::setup -n 2
echo "traps=[$(trap -p INT TERM EXIT)]"
EOF
  assert_contains "$OUT" "Unknown directive: @flwo (did you mean @flow?)"
  assert_contains "$OUT" "after typo rc=127"
  assert_contains "$OUT" "after failure rc=1"
  assert_contains "$OUT" "traps=[]"
}

test_shell_cancel_needs_job_ids() {
  run_shell << 'EOF'
@cancel
echo "rc=$?"
EOF
  assert_contains "$OUT" "@cancel: name the jobs to cancel, or use @cancel --all"
  assert_contains "$OUT" "rc=1"
}

test_cancel_all_in_scripts() {
  require_localq
  run_script << 'EOF'
j=$(@submit sleep 30)
@cancel --all
echo "status=$(opmexec::load_queue_backend localq; opmexec::backend_job_status "${j#*:}")"
EOF
  assert_contains "$OUT" "Job localq:1 cancelled"
  assert_contains "$OUT" "status=CANCELLED"

  run "$OPMEXEC" -c @cancel --all localq:1
  assert_rc 1
  assert_contains "$OUT" "@cancel: --all takes no job IDs"
}

test_shell_notifies_finished_jobs_once() {
  require_localq
  OPMEXEC_NOTIFY_INTERVAL=0 run_shell << 'EOF'
j=$(@submit true)
sleep 1
true
true
EOF
  assert_contains "$OUT" "[opmexec] Job localq:1 completed"
  assert_eq "$(grep -c '\[opmexec\] Job' <<< "$OUT")" 1
}

test_shell_does_not_repeat_what_wait_reported() {
  require_localq
  OPMEXEC_NOTIFY_INTERVAL=0 run_shell << 'EOF'
@wait @submit true > /dev/null
true
EOF
  assert_contains "$OUT" "Job localq:1 completed successfully"
  assert_not_contains "$OUT" "[opmexec] Job"
}

test_sourcing_at_a_prompt_takes_options() {
  bash -i << EOF > out.txt 2>&1
source "$ROOT/opmexec.bash" -s localq --flow-version flowrc47
echo "scheduler=\$OPMEXEC_SCHEDULER version=\$OPMEXEC_FLOW_VERSION traps=[\$(trap -p INT EXIT)]"
EOF
  assert_file_contains out.txt "scheduler=localq version=flowrc47 traps=[]"
}

test_stale_session_files_are_removed() {
  local state="$HOME/.local/state/opmexec" alive
  mkdir -p "$state"
  touch "$state/session.${HOSTNAME%%.*}.999999" "$state/session.${HOSTNAME%%.*}.999999.reported"
  sleep 60 &
  alive=$!
  touch "$state/session.${HOSTNAME%%.*}.$alive" "$state/session.otherhost.999999"
  run "$OPMEXEC" -c true
  kill "$alive"
  [[ ! -e "$state/session.${HOSTNAME%%.*}.999999" ]] || fail "stale session file kept"
  [[ ! -e "$state/session.${HOSTNAME%%.*}.999999.reported" ]] || fail "stale reported file kept"
  [[ -e "$state/session.${HOSTNAME%%.*}.$alive" ]] || fail "live session file removed"
  [[ -e "$state/session.otherhost.999999" ]] || fail "other host's session file removed"
}

# --- Completion ---

# Completions for a command line (cursor at its end), one per line. The
# library is loaded in this subshell, with the interactive features, and
# without workflow mode (its exit handler would remove the session's jobs).
complete_line() {
  (
    _OPMEXEC_CLI=true
    source "$ROOT/lib/opmexec.sh" > /dev/null 2>&1
    source "$ROOT/lib/interactive.sh" > /dev/null 2>&1
    COMP_LINE="$1"
    COMP_POINT=${#1}
    opmexec::complete
    printf '%s\n' "${COMPREPLY[@]}"
  )
}

test_complete_directive_names() {
  assert_eq "$(complete_line '@fl' | sort | tr '\n' ' ')" "@flow @flowpy "
}

test_complete_flow_versions() {
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flowrc47"
  assert_eq "$(complete_line '@flow -v flowr')" "flowrc47"
  printf '%s\n' "OPMEXEC_FLOW_VERSIONS=('dev=$SANDBOX/bin/flowtest' 'dev-debug=$SANDBOX/bin/flowtest')" >> "$OPMEXEC_CONFIG"
  assert_eq "$(complete_line '@flow -l de' | tr '\n' ' ')" "dev dev-debug "
  assert_eq "$(complete_line 'opmexec::setup --flow-version flowt')" "flowtest"
}

test_complete_flow_decks() {
  touch notes.txt
  mkdir decks
  assert_eq "$(complete_line '@flow ' | sort | tr '\n' ' ')" "A.DATA B.DATA decks "
}

test_complete_nearest_directive_options() {
  assert_eq "$(complete_line '@submit -n 4 @mpi @flow -' | tr '\n' ' ')" "-v --flow-version -l --list -w --which -- "
  assert_eq "$(complete_line '@submit --sch')" "--scheduler"
  assert_eq "$(complete_line '@submit --scheduler l' | tr '\n' ' ')" "lsf localq "
}

test_complete_job_ids() {
  mkdir -p "$HOME/.local/state/opmexec"
  local session
  session=$(source "$ROOT/lib/opmexec.sh" > /dev/null 2>&1; echo "${OPMEXEC_SESSION_FILE%.*}")
  # The completing shell is a subshell of this test: same $$
  printf '%s\n' localq:12 localq:13 > "$session.$$"
  assert_eq "$(complete_line '@wait localq:1' | tr '\n' ' ')" "12 13 "
  assert_eq "$(complete_line '@cancel ' | tr '\n' ' ')" "localq:12 localq:13 "
}

test_complete_opmexec_options() {
  assert_eq "$(complete_line 'opmexec --sh')" "--shell"
  assert_eq "$(complete_line 'opmexec -s ' | tr '\n' ' ')" "auto lsf slurm pbs localq "
}
