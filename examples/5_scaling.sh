#!/usr/bin/env bash
# How many cores should I ask for? Run the same case on more and more MPI
# ranks, one after another (so that the runs do not compete), then compare
# Flow's own simulation times.
# New here: MPI jobs. @submit -n NP reserves NP tasks for the job (in the
# local queue: NP of its slots, one per core), and @mpi inside the job starts
# Flow on them with the scheduler's MPI launcher (mpirun, or srun on SLURM).
#   flowrun examples/5_scaling.sh                        # SPE9 on 1, 2, 4, 8 ranks
#   flowrun examples/5_scaling.sh MODEL.DATA 1 2 4 8 16
# SPE9 is small (9,000 cells) and stops scaling after a few ranks.

deck=${1:-${OPM_DECKS:?set OPM_DECKS to the directory with the decks (see examples/README.md)}/SPE9_CP_PACKED.DATA}
shift
dir=$PWD/runs/scaling

# The rank counts given, else 1, 2, 4 and 8 as far as this machine has cores
ranks=("$@")
if [[ $# -eq 0 ]]; then
  for np in 1 2 4 8; do
    (( np <= $(getconf _NPROCESSORS_ONLN) )) && ranks+=("$np")
  done
fi

for np in "${ranks[@]}"; do
  mkdir -p "$dir/np_$np" && cp "$deck" "$dir/np_$np/" || exit 1
  # -n reserves the ranks; waiting before the next run keeps them apart
  @wait @submit -n "$np" -o "$dir/np_$np/job.log" @mpi @flow "$dir/np_$np/$(basename "$deck")" > /dev/null || exit 1
done

[[ $FLOWRUN_DRY_RUN != true ]] || exit 0   # (a dry run has no results)

# "Simulation time: 3.93 s" in each run's .PRT log; speedup against the first
for np in "${ranks[@]}"; do
  echo "$np $(grep -h "^Simulation time:" "$dir/np_$np/"*.PRT | awk '{ print $3 }')"
done | awk '{ if (NR == 1) { n1 = $1; t1 = $2 }
              printf "%3d ranks: %6.2f s, speedup %.2f, efficiency %3.0f%%\n", $1, $2, t1 / $2, 100 * t1 / $2 / ($1 / n1) }'
