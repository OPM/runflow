#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Shared by the library and the localq runner: bash version check,
# configuration loading, messages

# runflow needs bash 4.4 or newer, the oldest tested (RHEL 8; see
# .github/workflows/tests.yml). Checked before anything that needs it runs.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "[ERROR] runflow needs bash 4.4 or newer (running bash $BASH_VERSION)" >&2
  if [[ "$(uname -s)" == Darwin ]]; then
    echo "        On macOS: brew install bash, with Homebrew's bin first in PATH" >&2
  fi
  return 1 2>/dev/null || exit 1
fi

# Print an install hint for missing commands, for the current platform
runflow::install_hint() {
  if [[ "$(uname -s 2>/dev/null)" == Darwin ]]; then
    echo "        On macOS: brew install $*" >&2
  else
    echo "        Install them with your package manager (usually: util-linux, coreutils, procps)" >&2
  fi
}

# Configuration, later wins (see runflow(1), CONFIGURATION):
#   1. the defaults, etc/defaults/runflow.conf (runflow's own: not edited);
#   2. the configuration files /etc/runflow/runflow.conf, then
#      <installation>/etc/runflow.conf, then
#      ${XDG_CONFIG_HOME:-~/.config}/runflow/runflow.conf;
#      or, if RUNFLOW_CONFIG is set, only that file;
#   3. settings already set when the library loads: the environment, or a
#      script that sets them before sourcing (jobs get theirs this way);
#   4. runflow options and runflow::setup; 5. the directive's own options.
# Configuration files are bash, sourced by everyone who runs runflow: a file
# someone besides its owner (or root) can write is refused (see below).
if [[ -z "${_RUNFLOW_CONFIG_LOADED:-}" ]]; then
  if [[ -n "${RUNFLOW_CONFIG:-}" && "$RUNFLOW_CONFIG" != /* ]]; then
    RUNFLOW_CONFIG="$PWD/$RUNFLOW_CONFIG"  # absolute: jobs get it too
  fi
  _RUNFLOW_PRESET=""
  _RUNFLOW_NAMES=$(compgen -v RUNFLOW_)
  [[ -z "$_RUNFLOW_NAMES" ]] || _RUNFLOW_PRESET=$(declare -p $_RUNFLOW_NAMES 2> /dev/null)
  unset _RUNFLOW_NAMES

  source "$(dirname "${BASH_SOURCE[0]}")/../etc/defaults/runflow.conf"

  if [[ -n "${RUNFLOW_CONFIG:-}" ]]; then
    if [[ ! -f "$RUNFLOW_CONFIG" ]]; then
      echo "[ERROR] Configuration file not found: $RUNFLOW_CONFIG (RUNFLOW_CONFIG)" >&2
      return 1 2>/dev/null || exit 1
    fi
    _RUNFLOW_CONFIG_FILES=("$RUNFLOW_CONFIG")
  else
    _RUNFLOW_CONFIG_FILES=(
      /etc/runflow/runflow.conf
      "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/etc/runflow.conf"
      "${XDG_CONFIG_HOME:-$HOME/.config}/runflow/runflow.conf"
    )
  fi

  for _RUNFLOW_FILE in "${_RUNFLOW_CONFIG_FILES[@]}"; do
    [[ -f "$_RUNFLOW_FILE" ]] || continue
    # Writable by everyone, or by a group other than the owner's own (a
    # private group named like the user, as most Linux systems create) is
    # refused: its writers could run code as everyone who reads it. ls
    # shows an ACL's mask as the group bits, so ACL writers count too.
    read -r _RUNFLOW_MODE _ _RUNFLOW_OWNER _RUNFLOW_GROUP _ <<< "$(ls -ld "$_RUNFLOW_FILE" 2> /dev/null)"
    if [[ "${_RUNFLOW_MODE:8:1}" == w ]]; then
      _RUNFLOW_WRITERS=everyone
    elif [[ "${_RUNFLOW_MODE:5:1}" == w && "$_RUNFLOW_GROUP" != "$_RUNFLOW_OWNER" ]]; then
      _RUNFLOW_WRITERS="group $_RUNFLOW_GROUP"
    else
      _RUNFLOW_WRITERS=""
    fi
    if [[ -n "$_RUNFLOW_WRITERS" ]]; then
      echo "[ERROR] Configuration file is writable by $_RUNFLOW_WRITERS, not reading it: $_RUNFLOW_FILE (chmod go-w on it)" >&2
      return 1 2>/dev/null || exit 1
    fi
    source "$_RUNFLOW_FILE" || {
      echo "[ERROR] Could not read configuration file: $_RUNFLOW_FILE" >&2
      return 1 2>/dev/null || exit 1
    }
  done

  # Settings set before loading win over the files
  [[ -z "$_RUNFLOW_PRESET" ]] || eval "$(sed 's/^declare -/declare -g -/' <<< "$_RUNFLOW_PRESET")" 2> /dev/null

  # Derived defaults
  RUNFLOW_LOG_DIR="${RUNFLOW_LOG_DIR:-$RUNFLOW_STATE_DIR/logs}"

  unset _RUNFLOW_PRESET _RUNFLOW_CONFIG_FILES _RUNFLOW_FILE _RUNFLOW_MODE _RUNFLOW_OWNER _RUNFLOW_GROUP _RUNFLOW_WRITERS
  _RUNFLOW_CONFIG_LOADED=true
fi

# Utility: Print debug message
runflow::debug() {
  if [[ "$RUNFLOW_DEBUG" == true ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

# Utility: Print error message
runflow::error() {
  echo "[ERROR] $*" >&2
}

# Utility: Print warning message (something will likely go wrong, but runs)
runflow::warning() {
  echo "[WARNING] $*" >&2
}

# Utility: Print info message (stderr: stdout carries data such as job IDs)
runflow::info() {
  echo "[INFO] $*" >&2
}

# Create state directories if needed
runflow::ensure_state_dirs() {
  mkdir -p "$RUNFLOW_STATE_DIR" "$RUNFLOW_LOG_DIR" 2>/dev/null || true
}
