#!/usr/bin/env bash
# Flow versions: named versions, selection by OPM version, build information
# (flow --build-info, or the fallbacks for older Flow), and the record of the
# build a run used

# A fake Flow at PATH of an older kind: no --build-info. With "probe", it
# writes the header of its log, as Flow does before reading a deck: version
# VERSION, hash HASH, built at TIME.
fake_old_flow() {
  local path="$1" version="$2" hash="${3:-}" time="${4:-}"
  mkdir -p "$(dirname "$path")"
  cat > "$path" << EOF
#!/bin/sh
[ "\$1" = --version ] && { echo "flow $version"; exit 0; }
for arg; do
  case "\$arg" in
    --output-dir=*)
      [ -n "$hash" ] || exit 1
      dir=\${arg#--output-dir=}
      printf '%s\n' "Flow Version     =  $version ($hash)" "Build time       =  $time hrs" > "\$dir/PROBE.PRT"
      echo "Error: the last section of a valid deck must be SCHEDULE" >&2
      exit 1
      ;;
  esac
done
echo "FLOW exe=\$0 args=\$*"
EOF
  chmod +x "$path"
}

# --- Named versions ---

test_named_versions_select_builds_with_the_same_name() {
  mkdir -p "$SANDBOX/build/bin/Release" "$SANDBOX/build/bin/Debug" "$HOME/opm/bin"
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/build/bin/Release/flow"
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/build/bin/Debug/flow"
  cp "$SANDBOX/bin/flowtest" "$HOME/opm/bin/flow"
  cat >> "$OPMEXEC_CONFIG" << EOF
OPMEXEC_FLOW_VERSIONS=('dev=$SANDBOX/build/bin/Release' 'dev-debug=$SANDBOX/build/bin/Debug/flow' 'mine=~/opm/bin')
EOF
  run "$OPMEXEC" -c @flow -v dev A.DATA
  assert_contains "$OUT" "exe=$SANDBOX/build/bin/Release/flow"
  run "$OPMEXEC" -c @flow -v dev-debug A.DATA
  assert_contains "$OUT" "exe=$SANDBOX/build/bin/Debug/flow"
  run "$OPMEXEC" -c @flow -v mine A.DATA
  assert_contains "$OUT" "exe=$HOME/opm/bin/flow"
}

test_named_versions_win_over_executable_names() {
  mkdir -p "$SANDBOX/other"
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/other/flow"
  printf '%s\n' "OPMEXEC_FLOW_VERSIONS=('flowtest=$SANDBOX/other/flow')" >> "$OPMEXEC_CONFIG"
  run "$OPMEXEC" -c @flow A.DATA
  assert_contains "$OUT" "exe=$SANDBOX/other/flow"
}

test_named_version_problems() {
  fake_other_flow() { printf '%s\n' '#!/bin/sh' 'echo "Flow, a static type checker"' > "$1"; chmod +x "$1"; }
  fake_other_flow "$SANDBOX/jsflow"
  printf '%s\n' "OPMEXEC_FLOW_VERSIONS=('gone=/nowhere/flow' 'js=$SANDBOX/jsflow')" >> "$OPMEXEC_CONFIG"
  run "$OPMEXEC" -c @flow -v gone A.DATA
  assert_rc 1
  assert_contains "$OUT" "Flow version gone (OPMEXEC_FLOW_VERSIONS): executable not found: /nowhere/flow"
  run "$OPMEXEC" -c @flow -v js A.DATA
  assert_rc 1
  assert_contains "$OUT" "Flow version js (OPMEXEC_FLOW_VERSIONS): not OPM Flow: $SANDBOX/jsflow"
}

test_named_versions_reach_jobs() {
  require_localq
  mkdir -p "$SANDBOX/build"
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/build/flow"
  printf '%s\n' "OPMEXEC_FLOW_VERSIONS=('dev=$SANDBOX/build')" >> "$OPMEXEC_CONFIG"
  run "$OPMEXEC" -c @wait @submit -o "$PWD/out.log" @flow -v dev A.DATA
  assert_rc 0
  assert_file_contains out.log "exe=$SANDBOX/build/flow"
}

# --- Selection by OPM version ---

test_opm_version_selects_the_only_build_reporting_it() {
  fake_old_flow "$SANDBOX/opm2024/flow" 2024.10
  printf '%s\n' "OPMEXEC_FLOW_VERSIONS=('old=$SANDBOX/opm2024')" >> "$OPMEXEC_CONFIG"
  run "$OPMEXEC" -c @flow -v 2024.10 A.DATA
  assert_rc 0
  assert_contains "$OUT" "FLOW exe=$SANDBOX/opm2024/flow"
}

test_opm_version_never_guesses_among_builds() {
  mkdir -p "$SANDBOX/rel" "$SANDBOX/dbg/bin/Debug"
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/rel/flow"
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flow"
  printf '%s\n' "OPMEXEC_FLOW_VERSIONS=('dev=$SANDBOX/rel')" >> "$OPMEXEC_CONFIG"
  run "$OPMEXEC" -c @flow -v 2099.10 A.DATA
  assert_rc 1
  assert_contains "$OUT" "Flow version 2099.10 is ambiguous: 2 builds report it; name one in OPMEXEC_FLOW_VERSIONS or give its path:"
  assert_contains "$OUT" "        $SANDBOX/rel/flow (2099.10 (abc1234), Release, built 2099-01-02 03:04:05)"
  assert_contains "$OUT" "        $SANDBOX/bin/flow (2099.10 (abc1234)"

  # In a dry run, the same reason
  run "$OPMEXEC" --dry-run -c @flow -v 2099.10 A.DATA
  assert_contains "$OUT" "warning: Flow version 2099.10 is ambiguous"
}

# --- Build information ---

test_build_info_from_flow() {
  run "$OPMEXEC" -c @flow -l flowtest
  assert_rc 0
  assert_contains "$OUT" "  Executable   $SANDBOX/bin/flowtest"
  assert_contains "$OUT" "  OPM version  2099.10"
  assert_contains "$OUT" "  Git hash     abc1234"
  assert_contains "$OUT" "  Build type   Release"
  assert_contains "$OUT" "  Built        2099-01-02 03:04:05"
  assert_contains "$OUT" "  MPI          Fake MPI 1.0"
  assert_contains "$OUT" "  Source       flow --build-info"
}

test_build_info_of_older_flow_from_its_log_header() {
  mkdir -p "$SANDBOX/tmp"
  export TMPDIR="$SANDBOX/tmp"
  fake_old_flow "$SANDBOX/old/flow" 2024.10 "deadbee*" "2024-10-30 at 12:00:00"
  run "$OPMEXEC" -c @flow -l "$SANDBOX/old/flow"
  assert_rc 0
  assert_contains "$OUT" "  OPM version  2024.10"
  assert_contains "$OUT" "  Git hash     deadbee* (built with local changes)"
  assert_contains "$OUT" "  Built        2024-10-30 12:00:00"
  assert_contains "$OUT" "  Source       Flow's log header (this Flow has no --build-info)"
  assert_eq "$(ls "$SANDBOX/tmp")" ""   # the probe's directory is removed
}

test_build_info_of_flow_with_version_only() {
  fake_old_flow "$SANDBOX/older/flow" 2019.04
  run "$OPMEXEC" -c @flow -l "$SANDBOX/older/flow"
  assert_rc 0
  assert_contains "$OUT" "  OPM version  2019.04"
  assert_contains "$OUT" "  Git hash     -"
  assert_contains "$OUT" "  Source       flow --version only"
}

test_build_type_fallbacks() {
  # From the configuration directory of a multi-config build tree
  fake_old_flow "$SANDBOX/tree/bin/RelWithDebInfo/flow" 2025.04 abc "2025-04-01 at 10:00:00"
  run "$OPMEXEC" -c @flow -l "$SANDBOX/tree/bin/RelWithDebInfo/flow"
  assert_contains "$OUT" "  Build type   RelWithDebInfo"

  # From the CMakeCache.txt of a single-config build tree
  fake_old_flow "$SANDBOX/single/bin/flow" 2025.04 abc "2025-04-01 at 10:00:00"
  echo "CMAKE_BUILD_TYPE:STRING=Release" > "$SANDBOX/single/CMakeCache.txt"
  run "$OPMEXEC" -c @flow -l "$SANDBOX/single/bin/flow"
  assert_contains "$OUT" "  Build type   Release"

  # OPM's Debug builds write the hash "debug"
  fake_old_flow "$SANDBOX/dbg/flow" 2025.04 debug "2025-04-01 at 10:00:00"
  run "$OPMEXEC" -c @flow -l "$SANDBOX/dbg/flow"
  assert_contains "$OUT" "  Build type   Debug"
}

test_list_shows_named_versions_and_builds() {
  mkdir -p "$SANDBOX/rel"
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/rel/flow"
  fake_old_flow "$SANDBOX/old/flow" 2024.10 "deadbee" "2024-10-30 at 12:00:00"
  printf '%s\n' "OPMEXEC_FLOW_VERSIONS=('dev=$SANDBOX/rel' 'old=$SANDBOX/old' 'gone=/nowhere/flow')" >> "$OPMEXEC_CONFIG"
  run "$OPMEXEC" -c @flow -l
  assert_rc 0
  assert_contains "$OUT" "  NAME      VERSION  HASH     TYPE     BUILT                PYTHON"
  assert_contains "$OUT" "Named versions (OPMEXEC_FLOW_VERSIONS)"
  # (the test configuration's Python map knows flow* names only: "?")
  [[ "$OUT" =~ "  dev       2099.10  abc1234  Release  2099-01-02 03:04:05  ?"\ +"$SANDBOX/rel/flow" ]] || fail "dev row"
  [[ "$OUT" =~ "  old       2024.10  deadbee  -        2024-10-30 12:00:00  ?"\ +"$SANDBOX/old/flow" ]] || fail "old row"
  assert_contains "$OUT" "  gone      executable not found: /nowhere/flow"
  assert_contains "$OUT" "$SANDBOX/bin
 * flowtest  2099.10"
}

# --- The record of the build a run used ---

test_run_records_the_build() {
  run "$OPMEXEC" -c @flow A.DATA
  assert_rc 0
  assert_contains "$OUT" "[INFO] @flow: flow flowtest: $SANDBOX/bin/flowtest (OPM 2099.10)"

  run "$OPMEXEC" --dry-run -c @flow A.DATA
  assert_contains "$OUT" "[DRY-RUN] flow flowtest: $SANDBOX/bin/flowtest (OPM 2099.10)"
}

test_job_log_records_the_build() {
  require_localq
  run "$OPMEXEC" -c @wait @submit -o "$PWD/out.log" @mpi -n 1 @flow A.DATA
  assert_rc 0
  assert_file_contains out.log "[INFO] @flow: flow flowtest: $SANDBOX/bin/flowtest (OPM 2099.10)"
}
