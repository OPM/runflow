#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Does another Flow version change the results? Run the same case with two
# versions, one after the other, and compare a few summary vectors: PASS or
# FAIL.
# New here: @flow -v chooses the Flow version: a name from
# RUNFLOW_FLOW_VERSIONS, an executable in PATH, or a path.
#   runflow -n 2 examples/2_compare_versions.sh 2025.04 dev
#   TOLERANCE=1e-6 runflow examples/2_compare_versions.sh dev /path/to/build/bin/flow

[[ $# -ge 2 ]] || { echo "usage: runflow ${BASH_SOURCE[0]} VERSION_A VERSION_B [DECK]" >&2; exit 1; }
deck=${3:-${OPM_DECKS:?set OPM_DECKS to the directory with the decks (see examples/README.md)}/SPE1CASE2.DATA}
python=$(dirname "${BASH_SOURCE[0]}")/python

# One run per version, each in its own directory
cases=()
for side in A B; do
  version=$1
  [[ $side == A ]] || version=$2
  dir=$PWD/runs/compare_versions/${side}_$version
  mkdir -p "$dir" && cp "$deck" "$dir/" || exit 1
  cases+=("$dir/$(basename "$deck")")
  @mpi @flow -v "$version" "${cases[-1]}" > "$dir/flow.log" || { echo "Flow failed: see $dir/flow.log" >&2; exit 1; }
done

# Compare: each vector of run B against run A
status=0
for vector in ${VECTORS:-FOPR FGOR}; do
  @flowpy "$python/summary.py" --compare "${TOLERANCE:-1e-3}" "$vector" "${cases[@]}" || status=1
done
exit $status
