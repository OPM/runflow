#!/usr/bin/env bash
# The rc file of flowrun --shell: an interactive bash with the user's own
# ~/.bashrc, then the directives. The options given to flowrun --shell arrive
# as exported settings (see flowrun::setup_option), which the configuration
# keeps over the files. exit leaves the shell, and with it the environment.

[[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc"

if source "$(dirname "${BASH_SOURCE[0]}")/../flowrun.bash"; then
  # Which Flow @flow runs without -v
  if flowrun::flow::find "$FLOWRUN_FLOW_VERSION" 2> /dev/null; then
    _FLOWRUN_BANNER="$_FLOWRUN_FLOW_FOUND (OPM $_FLOWRUN_FLOW_FOUND_VERSION)"
  else
    _FLOWRUN_BANNER="not found (@flow -l lists the versions)"
  fi
  echo "flowrun shell: scheduler $(flowrun::get_scheduler); Flow $FLOWRUN_FLOW_VERSION: $_FLOWRUN_BANNER" >&2
  echo "@help lists the directives, Tab completes, exit leaves" >&2
  unset _FLOWRUN_BANNER
else
  echo "flowrun shell: could not load the directives" >&2
fi
