#!/usr/bin/env bash
# localq local queue: scheduling, slots, failures and listing

test_localq_fifo_and_slots() {
  require_localq
  # 4 slots: A takes 3; B (2) must wait for A; C (1) would fit but is behind B
  run_script << 'EOF'
@submit -n 3 sh -c '"$SANDBOX/tools/now" > A.start; sleep 1.5; "$SANDBOX/tools/now" > A.end' > /dev/null
@submit -n 2 sh -c '"$SANDBOX/tools/now" > B.start' > /dev/null
@submit -n 1 sh -c '"$SANDBOX/tools/now" > C.start' > /dev/null
@wait
EOF
  assert_rc 0
  awk -v a="$(cat A.end)" -v b="$(cat B.start)" -v c="$(cat C.start)" \
    'BEGIN { exit !(b >= a && c >= a) }' || fail "B or C started before A finished"
}

test_localq_np_above_slots_rejected() {
  require_localq
  run "$FLOWRUN" -c @submit -n 99 true
  assert_rc 1
  assert_contains "$OUT" "number of processes must be 1..4"
}

test_localq_unknown_dependency_rejected() {
  require_localq
  run "$FLOWRUN" -c @submit --depends-on 12345 true
  assert_rc 1
  assert_contains "$OUT" "unknown dependency job: 12345"
}

test_localq_killed_runner_reported_failed() {
  require_localq
  run_script << 'EOF'
j=$(@submit sleep 30)
until grep -qx RUNNING "$FLOWRUN_LOCALQ_DIR/${j#*:}/status" 2> /dev/null; do sleep 0.1; done
pid=$(cat "$FLOWRUN_LOCALQ_DIR/${j#*:}/pid")
kill -9 "$pid"
@wait "$j"
echo "wait-rc=$?"
kill -- "-$pid" 2> /dev/null  # orphaned children are not stopped by localq
EOF
  assert_contains "$OUT" "failed"
  assert_contains "$OUT" "wait-rc=1"
}

test_localq_cancel_kills_process_group() {
  require_localq
  run_script << 'EOF'
j=$(@submit sh -c 'sleep 30 & sleep 31; wait')
until grep -qx RUNNING "$FLOWRUN_LOCALQ_DIR/${j#*:}/status" 2> /dev/null; do sleep 0.1; done
pid=$(cat "$FLOWRUN_LOCALQ_DIR/${j#*:}/pid")
@cancel "$j"
sleep 0.5
echo "left=$(ps -A -o pgid= | awk -v g="$pid" '$1 == g { n++ } END { print n + 0 }')"
EOF
  assert_contains "$OUT" "left=0"
}

test_localq_jobs_listing() {
  require_localq
  run_script << 'EOF'
@wait @submit true > /dev/null
j=$(@submit -n 2 sleep 30)
until grep -qx RUNNING "$FLOWRUN_LOCALQ_DIR/${j#*:}/status" 2> /dev/null; do sleep 0.1; done
EOF
  run "$FLOWRUN" --jobs
  assert_rc 0
  assert_contains "$OUT" "localq: slots 2/4 in use"
  assert_contains "$OUT" "RUNNING"
  assert_contains "$OUT" "sleep 30"
  assert_not_contains "$OUT" "COMPLETED"

  run "$FLOWRUN" --jobs=all
  assert_contains "$OUT" "COMPLETED"
}

test_localq_listing_hides_wrappers() {
  require_localq
  run "$FLOWRUN" -c @wait @submit @mpi @flow A.DATA
  run "$FLOWRUN" --jobs=all
  assert_contains "$OUT" "@flow A.DATA"
  assert_not_contains "$OUT" "flowrun-cd"
}

test_localq_writes_per_job_logs() {
  require_localq
  run_script << 'EOF'
@wait @submit sh -c 'echo first' > /dev/null
@wait @submit sh -c 'echo second' > /dev/null
EOF
  assert_file_contains "$HOME/.local/state/flowrun/logs/localq.${HOSTNAME%%.*}.1.log" "first"
  assert_file_contains "$HOME/.local/state/flowrun/logs/localq.${HOSTNAME%%.*}.2.log" "second"
}

test_localq_routing_with_other_default_scheduler() {
  require_localq
  # Default scheduler is lsf (not implemented): localq: IDs must still go to localq
  run_script -s lsf << 'EOF'
j=$(@submit --scheduler localq true)
@wait "$j"
EOF
  assert_rc 0
  assert_contains "$OUT" "completed successfully"
}

test_localq_missing_tools_fail_gracefully() {
  require_localq
  # A PATH with only the basics: flock, setsid, perl, getconf, ps, nohup missing
  mkdir "$SANDBOX/minpath"
  for cmd in cat dirname uname mkdir; do
    ln -s "$(command -v "$cmd")" "$SANDBOX/minpath/$cmd"
  done
  run bash -c '
    source "$1/lib/flowrun.sh"
    PATH="$2"
    @submit true
    echo "submit-rc=$?"
  ' _ "$ROOT" "$SANDBOX/minpath"
  assert_contains "$OUT" "localq needs these commands, which were not found: flock getconf ps nohup setsid (or perl)"
  assert_contains "$OUT" "submit-rc=1"
}

test_localq_works_without_setsid() {
  require_localq
  require_cmd perl
  # macOS has no setsid: localq detaches jobs with perl instead. A PATH of
  # one directory: every command of PATH, the first of a name winning as in
  # PATH (e.g. Homebrew's bash before macOS's /bin/bash 3.2), but setsid
  local dir f dirs
  mkdir "$SANDBOX/nosetsid"
  IFS=: read -ra dirs <<< "$PATH"
  for dir in "${dirs[@]}"; do
    for f in "$dir"/*; do
      [[ -e "$SANDBOX/nosetsid/${f##*/}" ]] || ln -s "$f" "$SANDBOX/nosetsid/" 2> /dev/null
    done
  done
  rm -f "$SANDBOX/nosetsid/setsid"
  export PATH="$SANDBOX/nosetsid"
  run_script << 'EOF'
j=$(@submit sleep 30)
until grep -qx RUNNING "$FLOWRUN_LOCALQ_DIR/${j#*:}/status" 2> /dev/null; do sleep 0.1; done
pid=$(cat "$FLOWRUN_LOCALQ_DIR/${j#*:}/pid")
echo "own-group=$([[ $(ps -o pgid= -p "$pid" | tr -d ' ') == "$pid" ]] && echo yes || echo no)"
@cancel "$j"
@wait @submit true
EOF
  assert_rc 0
  # Detached: the leader of its own session, so of its own process group
  # (ps has no session ID field on macOS)
  assert_contains "$OUT" "own-group=yes"
  assert_contains "$OUT" "cancelled"
  assert_contains "$OUT" "completed successfully"
}

test_localq_empty_listing_mentions_finished_jobs() {
  require_localq
  run "$FLOWRUN" --jobs
  assert_contains "$OUT" "(no jobs)"
  
  run "$FLOWRUN" -c @wait @submit true
  run "$FLOWRUN" -c @wait @submit false
  run "$FLOWRUN" --jobs
  assert_contains "$OUT" "(no active jobs; 2 finished, see --jobs=all)"
  
  run "$FLOWRUN" --jobs=all
  assert_contains "$OUT" "COMPLETED"
  assert_contains "$OUT" "FAILED"
}

test_localq_state_is_local_and_fixed_per_user() {
  # Default: a fixed path on local disk, the same in every session
  local dir
  dir=$(env -u FLOWRUN_LOCALQ_DIR -u XDG_RUNTIME_DIR TMPDIR=/somewhere bash -c '
    source "$1/lib/common.sh"; source "$1/lib/queue/localq.sh"; echo "$FLOWRUN_LOCALQ_DIR"' _ "$ROOT")
  assert_eq "$dir" "/var/tmp/flowrun-$UID/localq"
}

test_localq_state_dir_is_private() {
  require_localq
  run "$FLOWRUN" -c @wait @submit true
  assert_rc 0
  assert_eq "$(ls -ld "$FLOWRUN_LOCALQ_DIR" | cut -c 1-10)" drwx------
}

test_localq_refuses_state_dir_it_does_not_own() {
  # A symlink planted where the state directory should be is not followed
  require_localq
  mkdir "$SANDBOX/elsewhere"
  ln -s "$SANDBOX/elsewhere" "$SANDBOX/planted"
  export FLOWRUN_LOCALQ_DIR="$SANDBOX/planted"
  run "$FLOWRUN" -c @submit true
  assert_rc 1
  assert_contains "$OUT" "localq: $SANDBOX/planted is not a directory owned by you"
}

test_localq_log_and_session_names_include_host() {
  require_localq
  run_script << 'EOF'
echo "session=$FLOWRUN_SESSION_FILE"
@wait @submit sh -c 'echo logged' > /dev/null
EOF
  assert_rc 0
  assert_contains "$OUT" "/session.${HOSTNAME%%.*}."
  assert_file_contains "$HOME/.local/state/flowrun/logs/localq.${HOSTNAME%%.*}.1.log" "logged"
}

# --- Native options (--localq-options) ---

test_localq_time_limit_stops_the_job() {
  require_localq
  run_script << 'EOF2'
j=$(@submit --localq-options "--time=0:01" sh -c 'sleep 30 & sleep 31; wait')
pid=$(cat "$FLOWRUN_LOCALQ_DIR/${j#*:}/pid")
@wait "$j"
echo "wait-rc=$?"
sleep 0.5
echo "left=$(ps -A -o pgid= | awk -v g="$pid" '$1 == g { n++ } END { print n + 0 }')"
EOF2
  assert_contains "$OUT" "wait-rc=1"
  assert_contains "$OUT" "left=0"
  assert_file_contains "$HOME/.local/state/flowrun/logs/localq.${HOSTNAME%%.*}.1.log" \
    "localq: job 1 reached its time limit (0:00:01) and was stopped"
}

test_localq_time_limit_not_reached() {
  require_localq
  run "$FLOWRUN" -c @wait @submit --localq-options "--time 5" true
  assert_rc 0
  assert_contains "$OUT" "completed successfully"
}

test_localq_start_time_variants_store_the_value() {
  local start
  require_cmd ps
  source "$ROOT/lib/common.sh"
  source "$ROOT/lib/queue/localq.sh"
  sleep 30 &
  local pid=$!
  # Each variant, through the wrapper that submit uses (macOS: ps); a
  # local of the same name inside a variant once swallowed the value
  for variant in ps proc; do
    [[ $variant == proc && ! -d /proc/self ]] && continue
    eval "flowrun::localq::pstart_into() { flowrun::localq::pstart_into_$variant \"\$@\"; }"
    start=$(flowrun::localq::pstart "$pid")
    [[ -n "$start" ]] || fail "$variant: no start time for a live process"
    [[ "$(flowrun::localq::pstart "$pid")" == "$start" ]] || fail "$variant: start time not stable"
  done
  kill "$pid"; wait "$pid" 2> /dev/null
  [[ -z "$(flowrun::localq::pstart "$pid")" ]] || fail "start time for an ended process"
  return 0
}

test_localq_reaped_job_never_starts() {
  require_localq
  # B waits for A; B's runner is then reaped as dead (a wrong start time).
  # When A completes, B must stay FAILED and never run.
  run_script << 'EOF'
a=$(@submit sleep 1)
b=$(@submit --depends-on "$a" touch B.ran)
d="$FLOWRUN_LOCALQ_DIR/${b#*:}"
runner=$(cat "$d/pid")
echo wrong > "$d/pstart"
@wait "$b"
echo "b-rc=$?"
@wait "$a"
while kill -0 "$runner" 2> /dev/null; do sleep 0.1; done
echo "b-status=$(cat "$d/status")"
EOF
  assert_contains "$OUT" "b-rc=1"
  assert_contains "$OUT" "b-status=FAILED"
  [[ ! -e B.ran ]] || fail "a reaped job ran"
}

test_localq_time_formats() {
  local value expected
  source "$ROOT/lib/common.sh"
  source "$ROOT/lib/queue/localq.sh"
  for pair in 5:300 05:30:330 1:02:03:3723 2-0:172800 1-2:3:93780 1-0:0:9:86409; do
    value=${pair%:*}
    expected=${pair##*:}
    assert_eq "$(flowrun::localq::time_seconds "$value")" "$expected"
  done
  flowrun::localq::time_seconds 1h > /dev/null && fail "1h accepted"
  flowrun::localq::time_seconds 1:2:3:4 > /dev/null && fail "1:2:3:4 accepted"
  return 0
}

test_localq_nice() {
  require_localq
  # nice adds to the niceness the tests run with (not always 0: GitHub's
  # macOS runners run at -10); the result is at most 19
  local base
  base=$(ps -o nice= -p $$ | tr -d ' ')
  run "$FLOWRUN" --localq-options "--nice=7" -c @wait @submit -o "$PWD/nice.log" sh -c 'ps -o nice= -p $$'
  assert_rc 0
  assert_eq "$(tr -d ' ' < nice.log)" "$(( base + 7 > 19 ? 19 : base + 7 ))"

  # From the configuration; --nice alone: 10
  printf '%s\n' "FLOWRUN_LOCALQ_OPTIONS=--nice" >> "$FLOWRUN_CONFIG"
  run "$FLOWRUN" -c @wait @submit -o "$PWD/nice.log" sh -c 'ps -o nice= -p $$'
  assert_eq "$(tr -d ' ' < nice.log)" "$(( base + 10 > 19 ? 19 : base + 10 ))"
}

test_localq_job_name_listed() {
  require_localq
  run "$FLOWRUN" -c @wait @submit --localq-options "--job-name=base-case" true
  run "$FLOWRUN" --jobs=all
  assert_contains "$OUT" "NAME"
  assert_contains "$OUT" "base-case"
}

test_localq_exclusive_takes_every_slot() {
  require_localq
  # 4 slots: A needs 1 but is exclusive; B (1) must wait for A
  run_script << 'EOF2'
@submit --localq-options --exclusive sh -c '"$SANDBOX/tools/now" > A.start; sleep 1.5; "$SANDBOX/tools/now" > A.end' > /dev/null
sleep 0.5
@submit sh -c '"$SANDBOX/tools/now" > B.start' > /dev/null
@wait
EOF2
  assert_rc 0
  awk -v a="$(cat A.end)" -v b="$(cat B.start)" 'BEGIN { exit !(b >= a) }' || fail "B started while A was running"
}

test_localq_rejects_unsupported_options() {
  require_localq
  run "$FLOWRUN" -c @submit --localq-options "--mem=4G" true
  assert_rc 1
  assert_contains "$OUT" "localq: unknown option --mem=4G (supported: --time, --nice, --job-name, --exclusive)"

  run "$FLOWRUN" -c @submit --localq-options "--time=soon" true
  assert_rc 1
  assert_contains "$OUT" "localq: invalid --time: soon"

  run "$FLOWRUN" -c @submit --localq-options "--nice=-5" true
  assert_rc 1
  assert_contains "$OUT" "localq: --nice must be 0..19 (got: -5)"

  # Only the scheduler the job goes to checks its options
  run "$FLOWRUN" -c @wait @submit --slurm-options "--mem=4G" true
  assert_rc 0
}
