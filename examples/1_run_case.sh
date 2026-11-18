#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Run a case on this machine with MPI, then read how much oil it produced.
# New here: @mpi @flow runs Flow on several MPI ranks (runflow -n); @flowpy
# runs Python with Flow's opm bindings to read the results.
#   runflow -n 4 examples/1_run_case.sh                       # SPE9 on 4 ranks
#   runflow -n 4 --flow-version 2025.04 examples/1_run_case.sh MODEL.DATA

deck=${1:-${OPM_DECKS:?set OPM_DECKS to the directory with the decks (see examples/README.md)}/SPE9_CP_PACKED.DATA}
dir=$PWD/runs/run_case
python=$(dirname "${BASH_SOURCE[0]}")/python

# A copy of the deck in its own directory, where Flow writes its output
mkdir -p "$dir" && cp "$deck" "$dir/" || exit 1
case=$dir/$(basename "$deck")

# Run Flow here, on runflow -n ranks: the terminal shows which Flow build
# runs, Flow's own output goes to flow.log
@mpi @flow "$case" > "$dir/flow.log" || { echo "Flow failed: see $dir/flow.log" >&2; exit 1; }

# Read the results with Flow's Python (opm.io): the last oil rate, and the
# total oil produced
@flowpy "$python/summary.py" FOPR "$case"
