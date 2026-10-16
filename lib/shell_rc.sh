#!/usr/bin/env bash
# The rc file of opmexec --shell: an interactive bash with the user's own
# ~/.bashrc, then the directives. The options given to opmexec --shell arrive
# as exported settings (see opmexec::setup_option), which the configuration
# keeps over the files. exit leaves the shell, and with it the environment.

[[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc"

if source "$(dirname "${BASH_SOURCE[0]}")/../opmexec.bash"; then
  # Which Flow @flow runs without -v
  if opmexec::flow::find "$OPMEXEC_FLOW_VERSION" 2> /dev/null; then
    _OPMEXEC_BANNER="$_OPMEXEC_FLOW_FOUND (OPM $_OPMEXEC_FLOW_FOUND_VERSION)"
  else
    _OPMEXEC_BANNER="not found (@flow -l lists the versions)"
  fi
  echo "opmexec shell: scheduler $(opmexec::get_scheduler); Flow $OPMEXEC_FLOW_VERSION: $_OPMEXEC_BANNER" >&2
  echo "@help lists the directives, Tab completes, exit leaves" >&2
  unset _OPMEXEC_BANNER
else
  echo "opmexec shell: could not load the directives" >&2
fi
