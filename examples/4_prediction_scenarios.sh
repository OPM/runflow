#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Which development option is best? Run the history once, then prediction
# scenarios that restart from its end. All jobs are submitted at once: the
# scenarios wait for the history by themselves.
# New here: @submit --depends-on JOB starts a job only after JOB completed
# (and never if it failed); the scenarios restart from the history's results.
#   flowrun examples/4_prediction_scenarios.sh
# The case: SPE1 (SPE1CASE2, gas injection). History: 5 years, to the end of
# 2019 (report step 60); the scenarios change the well controls from then on.

deck=${OPM_DECKS:?set OPM_DECKS to the directory with the decks (see examples/README.md)}/SPE1CASE2.DATA
dir=$PWD/runs/prediction_scenarios
python=$(dirname "${BASH_SOURCE[0]}")/python
mkdir -p "$dir/HISTORY" || exit 1

# The history: the deck, ended (END) after the DATES record of 31 Dec 2019
awk '{ print } /31 .DEC. 2019/ { at = 1 } at && /^\/$/ { print "END"; exit }' \
  "$deck" > "$dir/HISTORY/HISTORY.DATA" || exit 1
history=$(@submit -o "$dir/HISTORY/job.log" @flow "$dir/HISTORY/HISTORY.DATA") || exit 1

# A scenario: the whole deck, restarting from the history's step 60 (RESTART
# instead of EQUIL, UNIFIN to read its unified restart file, SKIPREST to skip
# the schedule up to then), with KEYWORDS from 31 Dec 2019 on
scenario() {  # NAME KEYWORDS
  mkdir -p "$dir/$1" || return 1
  # Copy the deck line by line, changing it as described above (awk reads
  # the keywords from the environment variable KEYWORDS)
  KEYWORDS=$2 awk '
    /^RUNSPEC/  { print; print "UNIFIN"; next }
    /^EQUIL/    { print "RESTART"; print "  \047../HISTORY/HISTORY\047 60 /"; skip = 1; next }
    skip        { if (/\//) skip = 0; next }
    /^SCHEDULE/ { print; print "SKIPREST"; next }
    { print }
    /31 .DEC. 2019/ { at = 1 }
    at && /^\/$/ { print ENVIRON["KEYWORDS"]; at = 0 }
  ' "$deck" > "$dir/$1/$1.DATA" || return 1
  echo "$dir/$1/$1.DATA"
}

cases=(
  "$(scenario BASE "")"
  "$(scenario MORE_GAS "WCONINJE
  'INJ' 'GAS' 'OPEN' 'RATE' 200000 1* 9014 /
/")"
  "$(scenario LOWER_RATE "WCONPROD
  'PROD' 'OPEN' 'ORAT' 10000 4* 1000 /
/")"
)
jobs=("$history")
for case in "${cases[@]}"; do
  jobs+=("$(@submit --depends-on "$history" -o "${case%.DATA}.log" @flow "$case")") || exit 1
done
@wait "${jobs[@]}" || exit 1

# The producer's cumulative oil by 2024, against the base scenario
@flowpy "$python/summary.py" WOPT:PROD "${cases[@]}"
