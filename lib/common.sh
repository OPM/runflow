#!/usr/bin/env bash
# Shared by the library and the localq runner: bash version check,
# configuration loading, messages

# opmexec needs bash 4.2 or newer (printf '%(...)T', declare -g)
# Checked before anything that needs it runs.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
  echo "[ERROR] opmexec needs bash 4.2 or newer (running bash $BASH_VERSION)" >&2
  if [[ "$(uname -s)" == Darwin ]]; then
    echo "        On macOS: brew install bash, with Homebrew's bin first in PATH" >&2
  fi
  return 1 2>/dev/null || exit 1
fi

# Print an install hint for missing commands, for the current platform
opmexec::install_hint() {
  if [[ "$(uname -s 2>/dev/null)" == Darwin ]]; then
    echo "        On macOS: brew install $*" >&2
  else
    echo "        Install them with your package manager (usually: util-linux, coreutils, procps)" >&2
  fi
}

# Configuration, later wins (see opmexec(1), CONFIGURATION):
#   1. built-in defaults (lib/defaults.sh);
#   2. the configuration files /etc/opmexec/opmexec.conf, then
#      <installation>/etc/opmexec.conf, then
#      ${XDG_CONFIG_HOME:-~/.config}/opmexec/opmexec.conf;
#      or, if OPMEXEC_CONFIG is set, only that file;
#   3. settings already set when the library loads: the environment, or a
#      script that sets them before sourcing (jobs get theirs this way);
#   4. opmexec options and opmexec::setup; 5. the directive's own options.
# Configuration files are bash; world-writable ones are refused.
if [[ -z "${_OPMEXEC_CONFIG_LOADED:-}" ]]; then
  if [[ -n "${OPMEXEC_CONFIG:-}" && "$OPMEXEC_CONFIG" != /* ]]; then
    OPMEXEC_CONFIG="$PWD/$OPMEXEC_CONFIG"  # absolute: jobs get it too
  fi
  _OPMEXEC_PRESET=""
  _OPMEXEC_NAMES=$(compgen -v OPMEXEC_)
  [[ -z "$_OPMEXEC_NAMES" ]] || _OPMEXEC_PRESET=$(declare -p $_OPMEXEC_NAMES 2> /dev/null)
  unset _OPMEXEC_NAMES

  source "$(dirname "${BASH_SOURCE[0]}")/defaults.sh"

  if [[ -n "${OPMEXEC_CONFIG:-}" ]]; then
    if [[ ! -f "$OPMEXEC_CONFIG" ]]; then
      echo "[ERROR] Configuration file not found: $OPMEXEC_CONFIG (OPMEXEC_CONFIG)" >&2
      return 1 2>/dev/null || exit 1
    fi
    _OPMEXEC_CONFIG_FILES=("$OPMEXEC_CONFIG")
  else
    _OPMEXEC_CONFIG_FILES=(
      /etc/opmexec/opmexec.conf
      "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/etc/opmexec.conf"
      "${XDG_CONFIG_HOME:-$HOME/.config}/opmexec/opmexec.conf"
    )
  fi

  for _OPMEXEC_FILE in "${_OPMEXEC_CONFIG_FILES[@]}"; do
    [[ -f "$_OPMEXEC_FILE" ]] || continue
    if [[ -n "$(find "$_OPMEXEC_FILE" -maxdepth 0 -perm -0002 2> /dev/null)" ]]; then
      echo "[ERROR] Configuration file is writable by everyone, not reading it: $_OPMEXEC_FILE" >&2
      return 1 2>/dev/null || exit 1
    fi
    source "$_OPMEXEC_FILE" || {
      echo "[ERROR] Could not read configuration file: $_OPMEXEC_FILE" >&2
      return 1 2>/dev/null || exit 1
    }
  done

  # Settings set before loading win over the files
  [[ -z "$_OPMEXEC_PRESET" ]] || eval "$(sed 's/^declare -/declare -g -/' <<< "$_OPMEXEC_PRESET")" 2> /dev/null

  # Derived defaults
  OPMEXEC_LOG_DIR="${OPMEXEC_LOG_DIR:-$OPMEXEC_STATE_DIR/logs}"

  unset _OPMEXEC_PRESET _OPMEXEC_CONFIG_FILES _OPMEXEC_FILE
  _OPMEXEC_CONFIG_LOADED=true
fi

# Utility: Print debug message
opmexec::debug() {
  if [[ "$OPMEXEC_DEBUG" == true ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

# Utility: Print error message
opmexec::error() {
  echo "[ERROR] $*" >&2
}

# Utility: Print warning message (something will likely go wrong, but runs)
opmexec::warning() {
  echo "[WARNING] $*" >&2
}

# Utility: Print info message (stderr: stdout carries data such as job IDs)
opmexec::info() {
  echo "[INFO] $*" >&2
}

# Create state directories if needed
opmexec::ensure_state_dirs() {
  mkdir -p "$OPMEXEC_STATE_DIR" "$OPMEXEC_LOG_DIR" 2>/dev/null || true
}
