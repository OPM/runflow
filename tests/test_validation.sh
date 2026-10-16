#!/usr/bin/env bash
# Directive validation: unknown directives stop the workflow

test_unknown_directive_stops_workflow() {
  run_script << 'EOF'
@flwo A.DATA
echo "after"
EOF
  assert_rc 127
  assert_contains "$OUT" "Unknown directive: @flwo (did you mean @flow?)"
  assert_not_contains "$OUT" "after"
}

test_unknown_directive_in_command_substitution() {
  run_script << 'EOF'
j=$(@sumbit true)
echo "after"
EOF
  assert_rc 127
  assert_contains "$OUT" "did you mean @submit?"
  assert_not_contains "$OUT" "after"
}

test_unknown_directive_suggestions() {
  local typo expected
  for pair in @cancle:@cancel @mpo:@mpi @wiat:@wait @flow2:@flow; do
    typo=${pair%%:*}
    expected=${pair#*:}
    run "$OPMEXEC" -c "$typo"
    assert_rc 127
    assert_contains "$OUT" "Unknown directive: $typo (did you mean $expected?)"
  done
}

test_unknown_directive_without_suggestion() {
  run "$OPMEXEC" -c @xyz
  assert_rc 127
  assert_contains "$OUT" "Unknown directive: @xyz"
  assert_not_contains "$OUT" "did you mean"
}

test_plain_missing_command_does_not_stop_workflow() {
  run_script << 'EOF'
not_a_real_command_xyz
echo "after"
EOF
  assert_rc 0
  assert_contains "$OUT" "not_a_real_command_xyz: command not found"
  assert_contains "$OUT" "after"
}

test_sourcing_script_stops_on_unknown_directive() {
  # A script that sources the library is in workflow mode
  run bash -c 'source "$1/lib/opmexec.sh"; @flwo; echo "after"' _ "$ROOT"
  assert_rc 127
  assert_contains "$OUT" "Unknown directive: @flwo"
  assert_not_contains "$OUT" "after"
}

test_interactive_shell_survives_unknown_directive() {
  # Interactive shells are not in workflow mode
  run bash --norc --noprofile -i -c 'source "$1/lib/opmexec.sh"; @flwo; echo "alive"' _ "$ROOT"
  assert_contains "$OUT" "Unknown directive: @flwo"
  assert_contains "$OUT" "alive"
}
