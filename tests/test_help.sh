#!/usr/bin/env bash
# Help for directives: @help (the only help of a directive), declared options
# (also used by Tab completion), and the man page covering them

test_help_lists_directives() {
  run "$OPMEXEC" -c @help
  assert_rc 0
  assert_contains "$OUT" "  @flow    Run Flow as one process"
  assert_contains "$OUT" "  @submit  Queue a job"
  assert_contains "$OUT" "@help @NAME: the options of one."
  assert_contains "$OUT" "Full reference: man "
}

test_help_shows_a_directive() {
  run "$OPMEXEC" -c @help @flow
  assert_rc 0
  assert_contains "$OUT" "@flow [-v VERSION] [FLOW_ARGUMENTS...]"
  [[ "$OUT" =~ "  -v, --flow-version VERSION"[[:space:]]+"Flow version: a path, a name in OPMEXEC_FLOW_VERSIONS" ]] || fail "no -v line"
  assert_not_contains "$OUT" "--help"
  assert_contains "$OUT" "Defaults for every @flow (options of opmexec and opmexec::setup):"
  [[ "$OUT" =~ "  --flow-version VERSION"\ +"Flow version for every @flow and @flowpy without -v (default: flowtest)" ]] || fail "no setting line"
  assert_contains "$OUT" "Full reference: LESS='+/^   @flow' man "

  run "$OPMEXEC" -c @help flow
  assert_contains "$OUT" "@flow [-v VERSION]"
}

test_directives_have_no_help_option() {
  local name
  # @help @NAME is the only help: --help is an unknown option that points to
  # it (@flow and @flowpy pass --help to Flow and Python: test_flow.sh)
  for name in mpi submit wait cancel help; do
    run "$OPMEXEC" -c "@$name" --help
    assert_rc 1
    assert_contains "$OUT" "@$name: unknown option: --help (@help @$name shows the options"
  done
  run "$OPMEXEC" -c @help @submit
  assert_not_contains "$OUT" "--help"
}

test_help_after_a_program_is_the_programs() {
  run "$OPMEXEC" --dry-run -c @flowpy -- --help
  assert_contains "$OUT" "run: env PYTHONPATH="
  assert_contains "$OUT" " --help"
}

test_help_for_unknown_directive() {
  run "$OPMEXEC" -c @help @nope
  assert_rc 1
  assert_contains "$OUT" "@help: unknown directive: @nope (@help lists them)"
}

test_help_long_options_wrap() {
  run "$OPMEXEC" -c @help @submit
  assert_contains "$OUT" "  --lsf-options, --slurm-options, --pbs-options, --localq-options OPTS
                            Native options"
}

# An extension directive that declares its options gets help and completion
use_greet_directive() {
  mkdir -p "$SANDBOX/directives"
  cat > "$SANDBOX/directives/greet.sh" << 'EOD'
opmexec::directive greet "[-t TIMES] [--job ID] NAME" "Greet someone"
opmexec::directive_option "-t, --times TIMES" text "How often"
opmexec::directive_option "--job ID" job "A job to mention"
opmexec::directive_arguments none
@greet() { echo "hello $*"; }
EOD
  export OPMEXEC_DIRECTIVE_PATH="$SANDBOX/directives"
}

test_extension_directive_help() {
  use_greet_directive
  run "$OPMEXEC" -c @help @greet
  assert_rc 0
  assert_contains "$OUT" "  -t, --times TIMES  How often"
  assert_contains "$OUT" "Defined in $SANDBOX/directives/greet.sh"

  run "$OPMEXEC" -c @help
  assert_contains "$OUT" "  @greet   Greet someone"
}

test_extension_directive_completion() {
  use_greet_directive
  mkdir -p "$HOME/.local/state/opmexec"
  local out
  out=$(
    _OPMEXEC_CLI=true
    source "$ROOT/lib/opmexec.sh" > /dev/null 2>&1
    source "$ROOT/lib/interactive.sh" > /dev/null 2>&1
    echo localq:7 > "$OPMEXEC_SESSION_FILE"
    for line in "@greet -" "@greet --job " "@greet x"; do
      COMP_LINE=$line COMP_POINT=${#line}
      opmexec::complete
      echo "[$line] ${COMPREPLY[*]}"
    done
  )
  assert_contains "$out" "[@greet -] -t --times --job"
  assert_contains "$out" "[@greet --job ] localq:7"
  assert_contains "$out" "[@greet x] "
}

test_man_page_covers_declared_options() {
  # Every declared option of the bundled directives appears in the man page
  # section of its directive (.SS @NAME up to the next section)
  local missing
  missing=$(
    _OPMEXEC_CLI=true
    source "$ROOT/lib/opmexec.sh" > /dev/null 2>&1
    for name in "${_OPMEXEC_DIRECTIVE_ORDER[@]}"; do
      section=$(awk -v s=".SS @$name" '$0 == s { on = 1; next } on && /^\.S[SH] / { exit } on' "$ROOT/man/man1/opmexec.1" | sed 's/\\-/-/g')
      [[ -n "$section" ]] || { echo "@$name: no man page section"; continue; }
      while IFS=$'\t' read -r spec kind description; do
        [[ -n "$spec" ]] || continue
        found=false
        for option in $(opmexec::option_names "$spec"); do
          grep -qF -- "$option" <<< "$section" && found=true
        done
        $found || echo "@$name: $spec"
      done <<< "${_OPMEXEC_DIRECTIVE_OPTION_LIST[$name]}"
    done
  )
  assert_eq "$missing" ""
}

# A stub man in front of PATH: -w finds the page if MAN_FINDS is set; else it
# prints its pager settings and arguments, and whether the page exists
use_stub_man() {
  mkdir -p "$SANDBOX/stubbin"
  cat > "$SANDBOX/stubbin/man" << 'EOD'
#!/bin/sh
if [ "$1" = -w ]; then [ -n "$MAN_FINDS" ] && { echo /usr/share/man/man1/opmexec.1; exit 0; }; exit 16; fi
echo "MAN LESS=[$LESS] page=[$1] exists=$([ -f "$1" ] && echo yes || echo no)"
EOD
  chmod +x "$SANDBOX/stubbin/man"
  export PATH="$SANDBOX/stubbin:$PATH"
}

test_full_reference_is_a_working_command() {
  use_stub_man
  local line
  # Not in MANPATH: the page's path
  run "$OPMEXEC" -c @help @flow
  line=$(sed -n 's/^Full reference: //p' <<< "$OUT")
  assert_eq "$line" "LESS='+/^   @flow' man $ROOT/man/man1/opmexec.1"
  assert_eq "$(bash -c "$line")" "MAN LESS=[+/^   @flow] page=[$ROOT/man/man1/opmexec.1] exists=yes"

  # In MANPATH: by name
  MAN_FINDS=1 run "$OPMEXEC" -c @help @flow
  assert_contains "$OUT" "Full reference: LESS='+/^   @flow' man opmexec"

  run "$OPMEXEC" -c @help
  assert_contains "$OUT" "Full reference: man $ROOT/man/man1/opmexec.1"
  run "$OPMEXEC" -h
  assert_contains "$OUT" "Full reference: man $ROOT/man/man1/opmexec.1"
}

test_man_sections_have_the_searched_heading() {
  # The search LESS='+/^   @NAME' needs each bundled directive's .SS @NAME
  local name
  for name in $(_OPMEXEC_CLI=true; source "$ROOT/lib/opmexec.sh" > /dev/null 2>&1; echo "${_OPMEXEC_DIRECTIVE_ORDER[*]}"); do
    grep -qx ".SS @$name" "$ROOT/man/man1/opmexec.1" || fail "no .SS @$name in the man page"
  done
}
