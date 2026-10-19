#!/usr/bin/env bash
# Calibrate a model to observed data: an ensemble history match (ES-MDA).
# Each iteration runs every member at once, waits, and updates the members
# from how well they fit (examples/python/esmda.py).
# New here: a loop of ensembles, each waiting for the previous update; the
# runs' results feed a Python computation that writes the next members.
# Failed runs do not stop the loop.
#   opmexec examples/6_history_match.sh
#   ENSEMBLE=64 ITERATIONS=4 opmexec examples/6_history_match.sh
# The case: SPE1 (SPE1CASE2), 5 years of history. The unknowns: the
# horizontal permeability multiplier of each of its 3 layers. The data come
# from a run with known multipliers (TRUTH), plus noise, to check the result:
# the middle layer, where no well is completed, is the least certain.

ENSEMBLE=${ENSEMBLE:-32} ITERATIONS=${ITERATIONS:-4}
TRUTH="0.4 2 1.26"
deck=${OPM_DECKS:?set OPM_DECKS to the directory with the decks (see examples/README.md)}/SPE1CASE2.DATA
dir=$PWD/runs/history_match
esmda=$(dirname "${BASH_SOURCE[0]}")/python/esmda.py
mkdir -p "$dir" || exit 1

# A member: the history (to 31 Dec 2019) with layer K's PERMX and PERMY
# multiplied by the K-th multiplier. Prints the deck's path.
member() {  # DIR MULTIPLIER...
  local grid="" k=0 m
  for m in "${@:2}"; do
    k=$((k + 1))
    grid+="MULTIPLY
  'PERMX' $m 1 10 1 10 $k $k /
  'PERMY' $m 1 10 1 10 $k $k /
/
"
  done
  mkdir -p "$1" || return 1
  # Copy the deck line by line: the multipliers before the PROPS line, and END
  # after the 31 Dec 2019 dates (awk reads the multipliers from the
  # environment variable GRID)
  GRID=$grid awk '
    /^PROPS/ { print ENVIRON["GRID"] }
    { print }
    /31 .DEC. 2019/ { at = 1 }
    at && /^\/$/ { print "END"; exit }
  ' "$deck" > "$1/CASE.DATA" || return 1
  echo "$1/CASE"
}

# The observations: the truth run's data, plus noise
truth=$(member "$dir/truth" $TRUTH) || exit 1
@wait @submit -o "$dir/truth/job.log" @flow "$truth.DATA" > /dev/null || exit 1
@flowpy "$esmda" observe "$truth" 1 "$dir/observed.txt" || exit 1
@flowpy "$esmda" prior "$ENSEMBLE" 2 "$dir/params_0.txt" || exit 1
[[ $OPMEXEC_DRY_RUN != true ]] || { echo "(dry run: the iterations need the results)"; exit 0; }

for (( i = 0; i <= ITERATIONS; i++ )); do
  # Run every member at once (log10 multipliers in params_$i.txt)
  cases=() jobs=() n=0
  while read -r -a logs; do
    case=$(member "$dir/iter_$i/$n" $(printf '%s\n' "${logs[@]}" | awk '{ printf "%.4g ", 10 ^ $1 }')) || exit 1
    jobs+=("$(@submit -o "$dir/iter_$i/$n/job.log" @flow "$case.DATA")") || exit 1
    cases+=("$case") n=$((n + 1))
  done < "$dir/params_$i.txt"
  @wait "${jobs[@]}" > /dev/null || echo "Some runs failed"

  # Update the members: alpha = ITERATIONS spreads the data over the iterations
  if (( i < ITERATIONS )); then
    echo -n "Iteration $((i + 1)): "
    @flowpy "$esmda" update "$dir/observed.txt" "$dir/params_$i.txt" "$ITERATIONS" \
      "$dir/params_$((i + 1)).txt" "${cases[@]}" || exit 1
  fi
done

echo -n "Final ensemble: "
@flowpy "$esmda" misfit "$dir/observed.txt" "${cases[@]}"
echo "Truth: multipliers $TRUTH"
