#!/usr/bin/env bash
# Configuration: built-in defaults, the configuration files and their order,
# OPMEXEC_CONFIG, the environment's precedence, standard file locations.
# (The /etc file is not tested: it needs root.)

# A copy of opmexec in the sandbox, so that its etc/ can be written, and no
# OPMEXEC_CONFIG: the files are searched
use_installation_copy() {
  mkdir -p "$SANDBOX/install/etc"
  cp -r "$ROOT/opmexec" "$ROOT/opmexec.bash" "$ROOT/lib" "$SANDBOX/install/"
  OPMEXEC="$SANDBOX/install/opmexec"
  unset OPMEXEC_CONFIG
  export XDG_CONFIG_HOME="$SANDBOX/xdg-config" XDG_STATE_HOME="$SANDBOX/xdg-state"
  mkdir -p "$XDG_CONFIG_HOME/opmexec"
}

# Print a setting as opmexec sees it
setting() {
  "$OPMEXEC" -c bash -c 'source "$1/lib/opmexec.sh"; echo "${!2}"' _ "$(dirname "$OPMEXEC")" "$1"
}

test_neutral_built_in_defaults() {
  use_installation_copy
  assert_eq "$(setting OPMEXEC_FLOW_VERSION)" flow
  assert_eq "$(setting OPMEXEC_SCHEDULER)" auto
  assert_eq "$(setting OPMEXEC_FLOW_PYTHONPATH)" auto
  assert_eq "$(setting OPMEXEC_DEFAULT_QUEUE_SLURM)" ""
  run "$OPMEXEC" -c bash -c 'source "$1/lib/opmexec.sh"; echo "${OPMEXEC_FLOW_BIN_PATHS[*]}"' _ "$SANDBOX/install"
  assert_eq "$OUT" "PATH"
}

test_standard_file_locations() {
  use_installation_copy
  assert_eq "$(setting OPMEXEC_STATE_DIR)" "$XDG_STATE_HOME/opmexec"
  assert_eq "$(setting OPMEXEC_LOG_DIR)" "$XDG_STATE_HOME/opmexec/logs"
  assert_eq "$(setting OPMEXEC_DIRECTIVE_PATH)" "$XDG_CONFIG_HOME/opmexec/directives"

  unset XDG_CONFIG_HOME XDG_STATE_HOME
  assert_eq "$(setting OPMEXEC_STATE_DIR)" "$HOME/.local/state/opmexec"
  assert_eq "$(setting OPMEXEC_DIRECTIVE_PATH)" "$HOME/.config/opmexec/directives"
}

test_installation_file_then_user_file() {
  use_installation_copy
  printf '%s\n' "OPMEXEC_FLOW_VERSION=site" "OPMEXEC_JOB_SETUP=site-setup" > "$SANDBOX/install/etc/opmexec.conf"
  assert_eq "$(setting OPMEXEC_FLOW_VERSION)" site

  printf '%s\n' "OPMEXEC_FLOW_VERSION=mine" > "$XDG_CONFIG_HOME/opmexec/opmexec.conf"
  assert_eq "$(setting OPMEXEC_FLOW_VERSION)" mine
  assert_eq "$(setting OPMEXEC_JOB_SETUP)" site-setup
}

test_opmexec_config_replaces_the_files() {
  use_installation_copy
  printf '%s\n' "OPMEXEC_FLOW_VERSION=site" "OPMEXEC_JOB_SETUP=site-setup" > "$SANDBOX/install/etc/opmexec.conf"
  printf '%s\n' "OPMEXEC_FLOW_VERSION=mine" > "$XDG_CONFIG_HOME/opmexec/opmexec.conf"
  printf '%s\n' "OPMEXEC_FLOW_VERSION=explicit" > "$SANDBOX/explicit.conf"

  export OPMEXEC_CONFIG="$SANDBOX/explicit.conf"
  assert_eq "$(setting OPMEXEC_FLOW_VERSION)" explicit
  assert_eq "$(setting OPMEXEC_JOB_SETUP)" ""          # built-in default, files not read
}

test_environment_wins_over_files() {
  use_installation_copy
  printf '%s\n' "OPMEXEC_FLOW_VERSION=mine" "OPMEXEC_FLOW_OPTIONS=--from-file" > "$XDG_CONFIG_HOME/opmexec/opmexec.conf"
  export OPMEXEC_FLOW_VERSION=fromenv
  assert_eq "$(setting OPMEXEC_FLOW_VERSION)" fromenv
  assert_eq "$(setting OPMEXEC_FLOW_OPTIONS)" --from-file
}

test_script_settings_win_over_files() {
  use_installation_copy
  printf '%s\n' "OPMEXEC_FLOW_VERSION=mine" > "$XDG_CONFIG_HOME/opmexec/opmexec.conf"
  cat > script.sh << EOF
OPMEXEC_FLOW_VERSION=fromscript
source "$SANDBOX/install/opmexec.bash" || exit 1
echo "version=\$OPMEXEC_FLOW_VERSION"
EOF
  run bash script.sh
  assert_contains "$OUT" "version=fromscript"
}

test_options_win_over_files_and_add_to_options() {
  use_installation_copy
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flowrc47"
  printf '%s\n' "OPMEXEC_FLOW_BIN_PATHS=(\"$SANDBOX/bin\")" "OPMEXEC_FLOW_VERSION=flowtest" \
    "OPMEXEC_FLOW_OPTIONS=--site" > "$XDG_CONFIG_HOME/opmexec/opmexec.conf"
  run "$OPMEXEC" --flow-version flowrc47 --flow-options "--workflow" -c @flow --call A.DATA
  assert_rc 0
  assert_contains "$OUT" "exe=$SANDBOX/bin/flowrc47"
  assert_contains "$OUT" "ARGV [--site] [--workflow] [--call] [$PWD/A.DATA]"
}

test_world_writable_configuration_is_refused() {
  use_installation_copy
  printf '%s\n' "OPMEXEC_FLOW_VERSION=evil" > "$XDG_CONFIG_HOME/opmexec/opmexec.conf"
  chmod o+w "$XDG_CONFIG_HOME/opmexec/opmexec.conf"
  run "$OPMEXEC" -c true
  assert_rc 1
  assert_contains "$OUT" "Configuration file is writable by everyone, not reading it: $XDG_CONFIG_HOME/opmexec/opmexec.conf"
}

test_missing_opmexec_config_fails() {
  export OPMEXEC_CONFIG="$SANDBOX/nope.conf"
  run "$OPMEXEC" -c true
  assert_rc 1
  assert_contains "$OUT" "Configuration file not found: $SANDBOX/nope.conf (OPMEXEC_CONFIG)"
}

test_template_lists_every_default() {
  # Every setting of lib/defaults.sh appears in the template
  local name
  for name in $(grep -oE '^OPMEXEC_[A-Z_]+' "$ROOT/lib/defaults.sh"); do
    grep -q "^#$name=" "$ROOT/etc/opmexec.conf.example" || fail "template lacks $name"
  done
}
