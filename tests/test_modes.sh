#!/usr/bin/env bash
# The three ways to use opmexec: script, inline command, sourcing the library

# A workflow that sources the library itself (mode 3)
write_sourcing_workflow() {
  cat > sourcing.sh << EOF
#!/usr/bin/env bash
source "$ROOT/lib/opmexec.sh" || exit 1
EOF
  cat >> sourcing.sh
  chmod +x sourcing.sh
}

test_same_workflow_in_all_three_modes() {
  local body='j=$(@wait @submit -o "$PWD/out-$1.log" @flow A.DATA) && echo "mode $1 ok $j"'

  # 1. script run by opmexec
  printf '%s\n' "$body" > workflow.sh
  run "$OPMEXEC" workflow.sh script
  assert_rc 0
  assert_contains "$OUT" "mode script ok $TEST_SCHEDULER:"

  # 2. inline command
  run "$OPMEXEC" -c @wait @submit -o "$PWD/out-inline.log" @flow A.DATA
  assert_rc 0

  # 3. script that sources the library, run directly
  write_sourcing_workflow <<< "$body"
  run ./sourcing.sh sourced
  assert_rc 0
  assert_contains "$OUT" "mode sourced ok $TEST_SCHEDULER:"

  for mode in script inline sourced; do
    assert_file_contains "out-$mode.log" "args=$PWD/A.DATA"
  done
}

test_sourcing_script_also_runs_under_opmexec() {
  # Loading twice is harmless: the library loads once
  write_sourcing_workflow << 'EOF'
echo "directives: $(compgen -A function -- @ | tr '\n' ' ')"
EOF
  run "$OPMEXEC" ./sourcing.sh
  assert_rc 0
  assert_contains "$OUT" "@flow @flowpy @help @mpi @submit @wait"
}

test_setup_takes_the_command_options() {
  write_sourcing_workflow << 'EOF'
opmexec::setup -s slurm -n 8 --slurm-options "--time=1:00" --dry-run || exit 1
@submit @mpi @flow A.DATA > /dev/null
EOF
  run ./sourcing.sh
  assert_rc 0
  assert_contains "$OUT" "[DRY-RUN] submit slurm:dry1: queue=default np=8 options=--time=1:00"
  assert_contains "$OUT" "run: srun --ntasks=8"
  assert_contains "$OUT" "done: 1 job(s) would be submitted"
}

test_setup_rejects_unknown_options() {
  write_sourcing_workflow << 'EOF'
opmexec::setup --bogus
echo "rc=$?"
EOF
  run ./sourcing.sh
  assert_contains "$OUT" "opmexec::setup: unknown option: --bogus"
  assert_contains "$OUT" "rc=1"
}

test_sourcing_script_uses_environment_defaults() {
  write_sourcing_workflow << 'EOF'
@submit @flow A.DATA > /dev/null
EOF
  OPMEXEC_DRY_RUN=true OPMEXEC_SCHEDULER=pbs OPMEXEC_NP=3 run ./sourcing.sh
  assert_rc 0
  assert_contains "$OUT" "submit pbs:dry1: queue=default np=3"
}

test_sourcing_script_cleans_up_session() {
  write_sourcing_workflow << 'EOF'
@submit true > /dev/null
@wait
EOF
  run ./sourcing.sh
  assert_rc 0
  assert_eq "$(session_files)" 0
}

test_source_opmexec_bash_through_path() {
  # The documented way: no installation path in the script
  cat > script.sh << 'EOF'
#!/usr/bin/env bash
source opmexec.bash || exit 1
@flow A.DATA
EOF
  PATH="$ROOT:$PATH" run bash script.sh
  assert_rc 0
  assert_contains "$OUT" "ARGV [$PWD/A.DATA]"
}

test_opmexec_bash_must_be_sourced() {
  run bash "$ROOT/opmexec.bash"
  assert_rc 1
  assert_contains "$OUT" "opmexec.bash is meant to be sourced"
}

test_library_option_prints_sourceable_path() {
  run "$OPMEXEC" --library
  assert_rc 0
  assert_eq "$OUT" "$ROOT/lib/opmexec.sh"
  
  cat > script.sh << EOF
source "\$("$OPMEXEC" --library)" || exit 1
@flow A.DATA
EOF
  run bash script.sh
  assert_rc 0
  assert_contains "$OUT" "ARGV [$PWD/A.DATA]"
}
