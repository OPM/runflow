#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# The rc file of runflow --shell: an interactive bash with the user's own
# ~/.bashrc, then the directives. The options given to runflow --shell arrive
# as exported settings (see runflow::setup_option), which the configuration
# keeps over the files. exit leaves the shell, and with it the environment.

[[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc"

if source "$(dirname "${BASH_SOURCE[0]}")/../runflow.bash"; then
  # Which Flow @flow runs without -v
  if runflow::flow::find "$RUNFLOW_FLOW_VERSION" 2> /dev/null; then
    _RUNFLOW_BANNER="$_RUNFLOW_FLOW_FOUND (OPM $_RUNFLOW_FLOW_FOUND_VERSION)"
  else
    _RUNFLOW_BANNER="not found (@flow -l lists the versions)"
  fi
  echo "runflow shell: scheduler $(runflow::get_scheduler); Flow $RUNFLOW_FLOW_VERSION: $_RUNFLOW_BANNER" >&2
  echo "@help lists the directives, Tab completes, exit leaves" >&2
  unset _RUNFLOW_BANNER
else
  echo "runflow shell: could not load the directives" >&2
fi
