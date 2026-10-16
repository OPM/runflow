# Examples

Short workflows of reservoir engineering, each a plain bash script run with
`opmexec`, in order: each uses what the ones before it introduced, and
explains itself at its top.

| Example | The question | New here |
|---|---|---|
| [1_run_case.sh](1_run_case.sh) | Run this case: how much oil does it produce? | `@mpi @flow` on this machine; `@flowpy` reads the results |
| [2_compare_versions.sh](2_compare_versions.sh) | Does another Flow version change the results? | `@flow -v`: Flow versions |
| [3_sensitivity.sh](3_sensitivity.sh) | Which uncertain parameter matters most for recovery? | jobs: `@submit`, `@wait`; many from edited copies of a deck |
| [4_prediction_scenarios.sh](4_prediction_scenarios.sh) | From the history, which development option is best? | `--depends-on`; restarting from another run |
| [5_scaling.sh](5_scaling.sh) | How many cores should I ask for? | MPI jobs: `@submit -n` with `@mpi` |
| [6_history_match.sh](6_history_match.sh) | Calibrate the model to the observed data (ES-MDA) | a loop of ensembles with a Python update |

They use two cases of OPM's test data, SPE1 (`SPE1CASE2`) and SPE9
(`SPE9_CP_PACKED`), and write their runs to `./runs/`. Tell them where the
decks are, e.g. an opm-common checkout's `tests/` or an opm-tests checkout:

```bash
export OPM_DECKS=/path/to/opm-common/tests
```

Without a checkout, download the two decks (12 KB and 931 KB) from an
opm-common release; they are under the Open Database License:

```bash
mkdir -p decks
for deck in SPE1CASE2 SPE9_CP_PACKED; do
  curl -fsSL -o "decks/$deck.DATA" \
    "https://raw.githubusercontent.com/OPM/opm-common/release/2026.04/final/tests/$deck.DATA"
done
export OPM_DECKS=$PWD/decks
```

The results are read with Flow's own Python, so at least one Flow build needs
its Python bindings (`opm.io`).

## Tutorial

The scripts say what to run; how and where to run it comes from opmexec's
options, the environment or the configuration. The same script therefore
runs with 1 or 32 MPI ranks, with any Flow version, on a workstation or a
cluster, without being edited.

### 1. A run on this machine

```bash
opmexec examples/1_run_case.sh
```

runs SPE9 with `@mpi @flow`: Flow on this machine, on one MPI rank. The
script never says how many ranks; `-n` does:

```bash
opmexec -n 4 examples/1_run_case.sh
```

Nothing has to run to see what would happen: `--dry-run` prints the exact
commands, here `mpirun -np 4 ... flow .../SPE9_CP_PACKED.DATA`, and which
Flow build that is:

```bash
opmexec --dry-run -n 4 examples/1_run_case.sh
```

Options for Flow and for the MPI launcher are given the same way, and apply
to every `@flow` and `@mpi` of the script:

```bash
opmexec -n 4 --flow-options "--threads-per-process=2" --mpi-options "--bind-to core" examples/1_run_case.sh
```

### 2. Choosing the Flow version

`@flow -v VERSION` runs a given Flow. A version is a path, an executable name
found in `PATH` (e.g. `flow`), a name you give a build, or an OPM version
such as `2025.04` when only one installed build reports it:

```bash
opmexec -c @flow -l                          # the versions found (* the default), with their build and Python
opmexec -c @flow --version                   # the default Flow's own --version, as for flow
opmexec -c @flow -w                          # its executable, e.g. for ldd "$(opmexec -c @flow -w)"
opmexec examples/2_compare_versions.sh flow /opt/opm/2025.04/bin/flow
```

Builds that share an executable name, e.g. one install per version, or a
build tree's Release and Debug builds, are told apart by names in the
configuration, `~/.config/opmexec/opmexec.conf`:

```bash
OPMEXEC_FLOW_VERSIONS=('2025.04=/opt/opm/2025.04/bin/flow' 'dev=~/opm/build/bin/Release')
```

The version every `@flow` without `-v` uses is chosen from outside too, for
one run, for a shell, or for good:

```bash
opmexec --flow-version 2025.04 examples/1_run_case.sh   # this run
export OPMEXEC_FLOW_VERSION=2025.04                      # this shell
echo "OPMEXEC_FLOW_VERSION=2025.04" >> ~/.config/opmexec/opmexec.conf   # always
```

If the Flow that runs the cases has no Python bindings, the results can be
read with another build's Python: `--flowpy-version VERSION`.

### 3. Jobs

`@submit` queues a command as a job and prints its ID at once; `@wait` waits
for jobs. The script decides what runs as a job; the scheduler is chosen
from outside. Without a cluster's commands, opmexec uses its local queue,
which runs as many jobs at once as the machine has cores:

```bash
opmexec examples/3_sensitivity.sh            # 7 jobs in the local queue
opmexec --jobs                               # the jobs, from another terminal
```

On a cluster, the same script will run with the scheduler's own options for
every job; options for other schedulers are ignored, so one command line can
serve several clusters. The LSF, SLURM and PBS backends are planned; a dry run
already shows the jobs a script would submit:

```bash
opmexec --dry-run -s slurm --slurm-options "--time=1:00:00" --lsf-options "-W 60" examples/3_sensitivity.sh
```

### 4. Dependencies

`@submit --depends-on JOB` starts a job only after JOB completed, and never
if it failed. The prediction scenarios are all submitted at once and start
by themselves when the history is done; the dry run shows the chain:

```bash
opmexec --dry-run examples/4_prediction_scenarios.sh   # ... depends_on=dry1 ...
```

### 5. MPI jobs

In a job, `-n` reserves the tasks: `@submit -n 8` asks the scheduler (or the
local queue: 8 of its slots) for 8, and `@mpi` inside the job starts Flow on
them with the scheduler's launcher: `mpirun` locally, `srun` on SLURM. Which
launcher, and how, is configuration, e.g.
`OPMEXEC_MPI_LAUNCHER_SLURM='srun --mpi=pmix --ntasks={np}'`; the script
does not change.

```bash
opmexec examples/5_scaling.sh                          # SPE9 on 1, 2, 4, 8 ranks
opmexec examples/5_scaling.sh "$OPM_DECKS/SPE9_CP_PACKED.DATA" 1 2 4 8 16
```

Several MPI jobs side by side on one machine need `--mpi-options "--bind-to
none"` (Open MPI), or they all run on the same cores.

### 6. An ensemble loop

The history match puts it together: every iteration submits the whole
ensemble, waits for it, and computes the next one with Python from the
results. Its size is set from outside:

```bash
ENSEMBLE=64 ITERATIONS=4 opmexec examples/6_history_match.sh
```

### Trying it by hand

`opmexec --shell` starts a bash with the directives, Tab completion and
notices of finished jobs, and the options apply as for a script:

```bash
opmexec --shell -n 4 --flow-version 2025.04
(opmexec localq 2025.04) $ @mpi @flow CASE.DATA
(opmexec localq 2025.04) $ @help @submit
```

The full reference is `man opmexec`.
