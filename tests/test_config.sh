#!/usr/bin/env bash
# Configuration: the defaults file, the configuration files and their order,
# OPMEXEC_CONFIG, the environment's precedence, standard file locations.
# (The /etc file is not tested: it needs root.)

# A copy of opmexec in the sandbox, so that its etc/ can be written, and no
# OPMEXEC_CONFIG: the files are searched
use_installation_copy() {
  mkdir -p "$SANDBOX/install/etc"
  cp -r "$ROOT/opmexec" "$ROOT/opmexec.bash" "$ROOT/lib" "$SANDBOX/install/"
  cp -r "$ROOT/etc/defaults" "$SANDBOX/install/etc/"
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

test_user_file_extends_site_lists() {
  # += in the user's file keeps the site's items; = replaces them
  use_installation_copy
  printf '%s\n' "OPMEXEC_FLOW_VERSIONS=('stable=/site/flow')" "OPMEXEC_FLOW_BIN_PATHS=(/site/bin PATH)" \
    > "$SANDBOX/install/etc/opmexec.conf"
  printf '%s\n' "OPMEXEC_FLOW_VERSIONS+=('dev=/mine/flow')" \
    'OPMEXEC_FLOW_BIN_PATHS=(/mine/bin "${OPMEXEC_FLOW_BIN_PATHS[@]}")' \
    > "$XDG_CONFIG_HOME/opmexec/opmexec.conf"
  run "$OPMEXEC" -c bash -c 'source "$1/lib/opmexec.sh"; echo "versions=${OPMEXEC_FLOW_VERSIONS[*]} paths=${OPMEXEC_FLOW_BIN_PATHS[*]}"' _ "$SANDBOX/install"
  assert_contains "$OUT" "versions=stable=/site/flow dev=/mine/flow paths=/mine/bin /site/bin PATH"
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

test_group_writable_configuration_is_refused() {
  # Writable by a group other than the owner's private one: its members could
  # run code as everyone reading the file
  local file group
  use_installation_copy
  file="$SANDBOX/install/etc/opmexec.conf"
  for group in $(id -Gn); do
    [[ "$group" != "$(id -un)" ]] && break
  done
  [[ -n "$group" && "$group" != "$(id -un)" ]] || skip "no group besides a private one"
  printf '%s\n' "OPMEXEC_FLOW_VERSION=site" > "$file"
  chgrp "$group" "$file" && chmod g+w "$file" || skip "cannot change the file's group"
  run "$OPMEXEC" -c true
  assert_rc 1
  assert_contains "$OUT" "Configuration file is writable by group $group, not reading it: $file (chmod go-w on it)"

  chmod g-w "$file"
  assert_eq "$(setting OPMEXEC_FLOW_VERSION)" site
}

test_private_group_writable_configuration_is_read() {
  # umask 002 with a group named like the user (most Linux systems)
  use_installation_copy
  [[ "$(id -gn)" == "$(id -un)" ]] || skip "no private group"
  printf '%s\n' "OPMEXEC_FLOW_VERSION=mine" > "$XDG_CONFIG_HOME/opmexec/opmexec.conf"
  chmod g+w "$XDG_CONFIG_HOME/opmexec/opmexec.conf"
  assert_eq "$(setting OPMEXEC_FLOW_VERSION)" mine
}

test_missing_opmexec_config_fails() {
  export OPMEXEC_CONFIG="$SANDBOX/nope.conf"
  run "$OPMEXEC" -c true
  assert_rc 1
  assert_contains "$OUT" "Configuration file not found: $SANDBOX/nope.conf (OPMEXEC_CONFIG)"
}

test_defaults_file_explains_every_setting() {
  # Each group of settings in etc/defaults/opmexec.conf follows a comment,
  # and it sets only OPMEXEC_ settings
  local problems
  problems=$(awk '
    /^OPMEXEC_[A-Z_]+=/ { if (prev !~ /^#/ && prev !~ /^OPMEXEC_/ && prev !~ /^ /) print "no comment before " $0; prev = $0; next }
    /^[^#[:space:]]/ && !/^OPMEXEC_/ { print "not a setting: " $0 }
    { prev = $0 }' "$ROOT/etc/defaults/opmexec.conf")
  [[ -z "$problems" ]] || fail "$problems"
}

test_site_configuration_is_not_tracked() {
  # The site's file is edited by each installation: git pull never touches it
  require_cmd git
  # (the sandbox's HOME has no safe.directory for a checkout another user owns)
  local git=(git -c "safe.directory=$ROOT" -C "$ROOT")
  "${git[@]}" rev-parse 2> /dev/null || skip "not a Git checkout"
  "${git[@]}" check-ignore -q etc/opmexec.conf || fail "etc/opmexec.conf is not ignored by Git"
}
