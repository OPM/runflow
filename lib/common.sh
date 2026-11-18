#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Shared by the library and the localq runner: bash version check,
# configuration loading, messages

# flowrun needs bash 4.4 or newer, the oldest tested (RHEL 8; see
# .github/workflows/tests.yml). Checked before anything that needs it runs.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "[ERROR] flowrun needs bash 4.4 or newer (running bash $BASH_VERSION)" >&2
  if [[ "$(uname -s)" == Darwin ]]; then
    echo "        On macOS: brew install bash, with Homebrew's bin first in PATH" >&2
  fi
  return 1 2>/dev/null || exit 1
fi

# Print an install hint for missing commands, for the current platform
flowrun::install_hint() {
  if [[ "$(uname -s 2>/dev/null)" == Darwin ]]; then
    echo "        On macOS: brew install $*" >&2
  else
    echo "        Install them with your package manager (usually: util-linux, coreutils, procps)" >&2
  fi
}

# Configuration, later wins (see flowrun(1), CONFIGURATION):
#   1. the defaults, etc/defaults/flowrun.conf (flowrun's own: not edited);
#   2. the configuration files /etc/flowrun/flowrun.conf, then
#      <installation>/etc/flowrun.conf, then
#      ${XDG_CONFIG_HOME:-~/.config}/flowrun/flowrun.conf;
#      or, if FLOWRUN_CONFIG is set, only that file;
#   3. settings already set when the library loads: the environment, or a
#      script that sets them before sourcing (jobs get theirs this way);
#   4. flowrun options and flowrun::setup; 5. the directive's own options.
# Configuration files are bash, sourced by everyone who runs flowrun: a file
# someone besides its owner (or root) can write is refused (see below).
if [[ -z "${_FLOWRUN_CONFIG_LOADED:-}" ]]; then
  if [[ -n "${FLOWRUN_CONFIG:-}" && "$FLOWRUN_CONFIG" != /* ]]; then
    FLOWRUN_CONFIG="$PWD/$FLOWRUN_CONFIG"  # absolute: jobs get it too
  fi
  _FLOWRUN_PRESET=""
  _FLOWRUN_NAMES=$(compgen -v FLOWRUN_)
  [[ -z "$_FLOWRUN_NAMES" ]] || _FLOWRUN_PRESET=$(declare -p $_FLOWRUN_NAMES 2> /dev/null)
  unset _FLOWRUN_NAMES

  source "$(dirname "${BASH_SOURCE[0]}")/../etc/defaults/flowrun.conf"

  if [[ -n "${FLOWRUN_CONFIG:-}" ]]; then
    if [[ ! -f "$FLOWRUN_CONFIG" ]]; then
      echo "[ERROR] Configuration file not found: $FLOWRUN_CONFIG (FLOWRUN_CONFIG)" >&2
      return 1 2>/dev/null || exit 1
    fi
    _FLOWRUN_CONFIG_FILES=("$FLOWRUN_CONFIG")
  else
    _FLOWRUN_CONFIG_FILES=(
      /etc/flowrun/flowrun.conf
      "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/etc/flowrun.conf"
      "${XDG_CONFIG_HOME:-$HOME/.config}/flowrun/flowrun.conf"
    )
  fi

  for _FLOWRUN_FILE in "${_FLOWRUN_CONFIG_FILES[@]}"; do
    [[ -f "$_FLOWRUN_FILE" ]] || continue
    # Writable by everyone, or by a group other than the owner's own (a
    # private group named like the user, as most Linux systems create) is
    # refused: its writers could run code as everyone who reads it. ls
    # shows an ACL's mask as the group bits, so ACL writers count too.
    read -r _FLOWRUN_MODE _ _FLOWRUN_OWNER _FLOWRUN_GROUP _ <<< "$(ls -ld "$_FLOWRUN_FILE" 2> /dev/null)"
    if [[ "${_FLOWRUN_MODE:8:1}" == w ]]; then
      _FLOWRUN_WRITERS=everyone
    elif [[ "${_FLOWRUN_MODE:5:1}" == w && "$_FLOWRUN_GROUP" != "$_FLOWRUN_OWNER" ]]; then
      _FLOWRUN_WRITERS="group $_FLOWRUN_GROUP"
    else
      _FLOWRUN_WRITERS=""
    fi
    if [[ -n "$_FLOWRUN_WRITERS" ]]; then
      echo "[ERROR] Configuration file is writable by $_FLOWRUN_WRITERS, not reading it: $_FLOWRUN_FILE (chmod go-w on it)" >&2
      return 1 2>/dev/null || exit 1
    fi
    source "$_FLOWRUN_FILE" || {
      echo "[ERROR] Could not read configuration file: $_FLOWRUN_FILE" >&2
      return 1 2>/dev/null || exit 1
    }
  done

  # Settings set before loading win over the files
  [[ -z "$_FLOWRUN_PRESET" ]] || eval "$(sed 's/^declare -/declare -g -/' <<< "$_FLOWRUN_PRESET")" 2> /dev/null

  # Derived defaults
  FLOWRUN_LOG_DIR="${FLOWRUN_LOG_DIR:-$FLOWRUN_STATE_DIR/logs}"

  unset _FLOWRUN_PRESET _FLOWRUN_CONFIG_FILES _FLOWRUN_FILE _FLOWRUN_MODE _FLOWRUN_OWNER _FLOWRUN_GROUP _FLOWRUN_WRITERS
  _FLOWRUN_CONFIG_LOADED=true
fi

# Utility: Print debug message
flowrun::debug() {
  if [[ "$FLOWRUN_DEBUG" == true ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

# Utility: Print error message
flowrun::error() {
  echo "[ERROR] $*" >&2
}

# Utility: Print warning message (something will likely go wrong, but runs)
flowrun::warning() {
  echo "[WARNING] $*" >&2
}

# Utility: Print info message (stderr: stdout carries data such as job IDs)
flowrun::info() {
  echo "[INFO] $*" >&2
}

# Create state directories if needed
flowrun::ensure_state_dirs() {
  mkdir -p "$FLOWRUN_STATE_DIR" "$FLOWRUN_LOG_DIR" 2>/dev/null || true
}
