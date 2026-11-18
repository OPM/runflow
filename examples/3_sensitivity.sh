#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Which uncertain parameter matters most for recovery? Run the case with each
# grid property scaled down and up, all runs at once, then compare the oil
# produced against the base case.
# New here: jobs. @submit queues a command as a job and prints its ID at once;
# @wait waits for the jobs and fails if one failed. The local queue runs as
# many jobs at once as the machine has cores; on a cluster (-s slurm, ...,
# planned) the scheduler will. Here: many jobs from edited copies of one deck.
#   flowrun examples/3_sensitivity.sh
#   flowrun --dry-run -s slurm examples/3_sensitivity.sh   # the jobs, for SLURM

deck=${1:-${OPM_DECKS:?set OPM_DECKS to the directory with the decks (see examples/README.md)}/SPE9_CP_PACKED.DATA}
dir=$PWD/runs/sensitivity
python=$(dirname "${BASH_SOURCE[0]}")/python

# A copy of the deck with PROPERTY multiplied by FACTOR, at the end of the
# GRID section (before PROPS). Prints the copy's path.
variant() {  # NAME PROPERTY FACTOR
  mkdir -p "$dir/$1" || return 1
  local text="MULTIPLY
  '$2' $3 /
/"
  # Copy the deck line by line, adding the text before the PROPS line (awk
  # reads it from the environment variable TEXT)
  TEXT=$text awk '/^PROPS/ { print ENVIRON["TEXT"] } { print }' "$deck" > "$dir/$1/$1.DATA" || return 1
  echo "$dir/$1/$1.DATA"
}

# Submit every run without waiting: the base case, then each variant
cases=("$(variant BASE PORO 1)")
for change in PERMX:0.5 PERMX:2 PERMZ:0.1 PERMZ:10 PORO:0.85 PORO:1.15; do
  name=${change/:/_}  # e.g. PERMX_0p5: Flow cuts its output names at a "."
  cases+=("$(variant "${name//./p}" "${change%:*}" "${change#*:}")")
done
jobs=()
for case in "${cases[@]}"; do
  jobs+=("$(@submit -o "${case%.DATA}.log" @flow "$case")") || exit 1
done
@wait "${jobs[@]}" || exit 1

# The oil produced by each run, and its change against the base case
@flowpy "$python/summary.py" FOPR "${cases[@]}"
