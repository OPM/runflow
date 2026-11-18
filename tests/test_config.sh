#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Configuration: the defaults file, the configuration files and their order,
# RUNFLOW_CONFIG, the environment's precedence, standard file locations.
# (The /etc file is not tested: it needs root.)

# A copy of runflow in the sandbox, so that its etc/ can be written, and no
# RUNFLOW_CONFIG: the files are searched
use_installation_copy() {
  mkdir -p "$SANDBOX/install/etc"
  cp -r "$ROOT/runflow" "$ROOT/runflow.bash" "$ROOT/lib" "$ROOT/VERSION" "$SANDBOX/install/"
  cp -r "$ROOT/etc/defaults" "$SANDBOX/install/etc/"
  RUNFLOW="$SANDBOX/install/runflow"
  unset RUNFLOW_CONFIG
  export XDG_CONFIG_HOME="$SANDBOX/xdg-config" XDG_STATE_HOME="$SANDBOX/xdg-state"
  mkdir -p "$XDG_CONFIG_HOME/runflow"
}

# Print a setting as runflow sees it
setting() {
  "$RUNFLOW" -c bash -c 'source "$1/lib/runflow.sh"; echo "${!2}"' _ "$(dirname "$RUNFLOW")" "$1"
}

test_neutral_built_in_defaults() {
  use_installation_copy
  assert_eq "$(setting RUNFLOW_FLOW_VERSION)" flow
  assert_eq "$(setting RUNFLOW_SCHEDULER)" auto
  assert_eq "$(setting RUNFLOW_FLOW_PYTHONPATH)" auto
  assert_eq "$(setting RUNFLOW_DEFAULT_QUEUE_SLURM)" ""
  run "$RUNFLOW" -c bash -c 'source "$1/lib/runflow.sh"; echo "${RUNFLOW_FLOW_BIN_PATHS[*]}"' _ "$SANDBOX/install"
  assert_eq "$OUT" "PATH"
}

test_standard_file_locations() {
  use_installation_copy
  assert_eq "$(setting RUNFLOW_STATE_DIR)" "$XDG_STATE_HOME/runflow"
  assert_eq "$(setting RUNFLOW_LOG_DIR)" "$XDG_STATE_HOME/runflow/logs"
  assert_eq "$(setting RUNFLOW_DIRECTIVE_PATH)" "$XDG_CONFIG_HOME/runflow/directives"

  unset XDG_CONFIG_HOME XDG_STATE_HOME
  assert_eq "$(setting RUNFLOW_STATE_DIR)" "$HOME/.local/state/runflow"
  assert_eq "$(setting RUNFLOW_DIRECTIVE_PATH)" "$HOME/.config/runflow/directives"
}

test_installation_file_then_user_file() {
  use_installation_copy
  printf '%s\n' "RUNFLOW_FLOW_VERSION=site" "RUNFLOW_JOB_SETUP=site-setup" > "$SANDBOX/install/etc/runflow.conf"
  assert_eq "$(setting RUNFLOW_FLOW_VERSION)" site

  printf '%s\n' "RUNFLOW_FLOW_VERSION=mine" > "$XDG_CONFIG_HOME/runflow/runflow.conf"
  assert_eq "$(setting RUNFLOW_FLOW_VERSION)" mine
  assert_eq "$(setting RUNFLOW_JOB_SETUP)" site-setup
}

test_user_file_extends_site_lists() {
  # += in the user's file keeps the site's items; = replaces them
  use_installation_copy
  printf '%s\n' "RUNFLOW_FLOW_VERSIONS=('stable=/site/flow')" "RUNFLOW_FLOW_BIN_PATHS=(/site/bin PATH)" \
    > "$SANDBOX/install/etc/runflow.conf"
  printf '%s\n' "RUNFLOW_FLOW_VERSIONS+=('dev=/mine/flow')" \
    'RUNFLOW_FLOW_BIN_PATHS=(/mine/bin "${RUNFLOW_FLOW_BIN_PATHS[@]}")' \
    > "$XDG_CONFIG_HOME/runflow/runflow.conf"
  run "$RUNFLOW" -c bash -c 'source "$1/lib/runflow.sh"; echo "versions=${RUNFLOW_FLOW_VERSIONS[*]} paths=${RUNFLOW_FLOW_BIN_PATHS[*]}"' _ "$SANDBOX/install"
  assert_contains "$OUT" "versions=stable=/site/flow dev=/mine/flow paths=/mine/bin /site/bin PATH"
}

test_runflow_config_replaces_the_files() {
  use_installation_copy
  printf '%s\n' "RUNFLOW_FLOW_VERSION=site" "RUNFLOW_JOB_SETUP=site-setup" > "$SANDBOX/install/etc/runflow.conf"
  printf '%s\n' "RUNFLOW_FLOW_VERSION=mine" > "$XDG_CONFIG_HOME/runflow/runflow.conf"
  printf '%s\n' "RUNFLOW_FLOW_VERSION=explicit" > "$SANDBOX/explicit.conf"

  export RUNFLOW_CONFIG="$SANDBOX/explicit.conf"
  assert_eq "$(setting RUNFLOW_FLOW_VERSION)" explicit
  assert_eq "$(setting RUNFLOW_JOB_SETUP)" ""          # built-in default, files not read
}

test_environment_wins_over_files() {
  use_installation_copy
  printf '%s\n' "RUNFLOW_FLOW_VERSION=mine" "RUNFLOW_FLOW_OPTIONS=--from-file" > "$XDG_CONFIG_HOME/runflow/runflow.conf"
  export RUNFLOW_FLOW_VERSION=fromenv
  assert_eq "$(setting RUNFLOW_FLOW_VERSION)" fromenv
  assert_eq "$(setting RUNFLOW_FLOW_OPTIONS)" --from-file
}

test_script_settings_win_over_files() {
  use_installation_copy
  printf '%s\n' "RUNFLOW_FLOW_VERSION=mine" > "$XDG_CONFIG_HOME/runflow/runflow.conf"
  cat > script.sh << EOF
RUNFLOW_FLOW_VERSION=fromscript
source "$SANDBOX/install/runflow.bash" || exit 1
echo "version=\$RUNFLOW_FLOW_VERSION"
EOF
  run bash script.sh
  assert_contains "$OUT" "version=fromscript"
}

test_options_win_over_files_and_add_to_options() {
  use_installation_copy
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flowrc47"
  printf '%s\n' "RUNFLOW_FLOW_BIN_PATHS=(\"$SANDBOX/bin\")" "RUNFLOW_FLOW_VERSION=flowtest" \
    "RUNFLOW_FLOW_OPTIONS=--site" > "$XDG_CONFIG_HOME/runflow/runflow.conf"
  run "$RUNFLOW" --flow-version flowrc47 --flow-options "--workflow" -c @flow --call A.DATA
  assert_rc 0
  assert_contains "$OUT" "exe=$SANDBOX/bin/flowrc47"
  assert_contains "$OUT" "ARGV [--site] [--workflow] [--call] [$PWD/A.DATA]"
}

test_world_writable_configuration_is_refused() {
  use_installation_copy
  printf '%s\n' "RUNFLOW_FLOW_VERSION=evil" > "$XDG_CONFIG_HOME/runflow/runflow.conf"
  chmod o+w "$XDG_CONFIG_HOME/runflow/runflow.conf"
  run "$RUNFLOW" -c true
  assert_rc 1
  assert_contains "$OUT" "Configuration file is writable by everyone, not reading it: $XDG_CONFIG_HOME/runflow/runflow.conf"
}

test_group_writable_configuration_is_refused() {
  # Writable by a group other than the owner's private one: its members could
  # run code as everyone reading the file
  local file group
  use_installation_copy
  file="$SANDBOX/install/etc/runflow.conf"
  for group in $(id -Gn); do
    [[ "$group" != "$(id -un)" ]] && break
  done
  [[ -n "$group" && "$group" != "$(id -un)" ]] || skip "no group besides a private one"
  printf '%s\n' "RUNFLOW_FLOW_VERSION=site" > "$file"
  chgrp "$group" "$file" && chmod g+w "$file" || skip "cannot change the file's group"
  run "$RUNFLOW" -c true
  assert_rc 1
  assert_contains "$OUT" "Configuration file is writable by group $group, not reading it: $file (chmod go-w on it)"

  chmod g-w "$file"
  assert_eq "$(setting RUNFLOW_FLOW_VERSION)" site
}

test_private_group_writable_configuration_is_read() {
  # umask 002 with a group named like the user (most Linux systems)
  use_installation_copy
  [[ "$(id -gn)" == "$(id -un)" ]] || skip "no private group"
  printf '%s\n' "RUNFLOW_FLOW_VERSION=mine" > "$XDG_CONFIG_HOME/runflow/runflow.conf"
  chmod g+w "$XDG_CONFIG_HOME/runflow/runflow.conf"
  assert_eq "$(setting RUNFLOW_FLOW_VERSION)" mine
}

test_missing_runflow_config_fails() {
  export RUNFLOW_CONFIG="$SANDBOX/nope.conf"
  run "$RUNFLOW" -c true
  assert_rc 1
  assert_contains "$OUT" "Configuration file not found: $SANDBOX/nope.conf (RUNFLOW_CONFIG)"
}

test_defaults_file_explains_every_setting() {
  # Each group of settings in etc/defaults/runflow.conf follows a comment,
  # and it sets only RUNFLOW_ settings
  local problems
  problems=$(awk '
    /^RUNFLOW_[A-Z_]+=/ { if (prev !~ /^#/ && prev !~ /^RUNFLOW_/ && prev !~ /^ /) print "no comment before " $0; prev = $0; next }
    /^[^#[:space:]]/ && !/^RUNFLOW_/ { print "not a setting: " $0 }
    { prev = $0 }' "$ROOT/etc/defaults/runflow.conf")
  [[ -z "$problems" ]] || fail "$problems"
}

test_site_configuration_is_not_tracked() {
  # The site's file is edited by each installation: git pull never touches it
  require_cmd git
  # (the sandbox's HOME has no safe.directory for a checkout another user owns)
  local git=(git -c "safe.directory=$ROOT" -C "$ROOT")
  "${git[@]}" rev-parse 2> /dev/null || skip "not a Git checkout"
  "${git[@]}" check-ignore -q etc/runflow.conf || fail "etc/runflow.conf is not ignored by Git"
}
