# Writing a Scheduler Backend

A backend connects runflow to one scheduler. It is a file
`lib/queue/<scheduler>.sh` that defines four functions, and optionally two
more. The directives do everything else: option parsing, defaults, job ID
prefixes, dependency checks, dry runs and session tracking.

Reference implementation: `lib/queue/localq.sh`. Skeleton: `lib/queue/lsf.sh`.
LSF, SLURM and PBS are planned: they are listed in `_RUNFLOW_PLANNED_SCHEDULERS`
(`lib/config.sh`), which keeps them out of `auto` and refuses submitting to
them, while `--dry-run -s NAME` already works.

## CHECKLIST

1. Write `lib/queue/<scheduler>.sh`, and remove the scheduler from
   `_RUNFLOW_PLANNED_SCHEDULERS` (or add it to `_RUNFLOW_SCHEDULERS`).
2. In `lib/config.sh`, add the scheduler to `runflow::validate_scheduler` and
   `runflow::get_default_queue`. If it can be auto-detected, also add it to
   `runflow::detect_scheduler`, before the fallback to localq.
3. In `etc/defaults/runflow.conf`, with their comments, add:
   - `RUNFLOW_DEFAULT_QUEUE_<SCHEDULER>=''` (empty: the scheduler's default);
   - `RUNFLOW_<SCHEDULER>_OPTIONS=''`;
   - `RUNFLOW_MPI_LAUNCHER_<SCHEDULER>='...'`.

   `--<scheduler>-options` is then accepted automatically.
4. Run `TEST_SCHEDULER=<scheduler> tests/run_tests.sh` on the cluster (see
   docs/DEVELOPMENT.md).

## RULES

- **Loading:** the file is sourced, possibly several times and after other
  backends. Define only functions and variables. The optional functions of a
  previous backend are unset first.
- **Names:** use `runflow::<scheduler>::` and `RUNFLOW_<SCHEDULER>_` for
  everything except the interface functions. Bare `slurm::`/`SLURM_` would
  collide with the schedulers' own `SLURM_*`, `LSB_*` and `PBS_*` variables.
  `RUNFLOW_<SCHEDULER>_OPTIONS` is reserved.
- **Job IDs:** they are passed in and printed bare (`4567`). `@submit` adds the
  prefix.
- **Errors:** report with `runflow::error` and return non-zero. stdout carries
  only what the function's contract specifies.
- **Portability:** bash 4.4 or newer, on Linux and on macOS. No GNU-only
  options.

## INTERFACE

### runflow::backend_submit_job QUEUE NP OUTPUT DEPENDS_ON OPTIONS COMMAND...

Submits COMMAND and prints the job ID.

| Argument | Meaning |
|---|---|
| QUEUE | Queue or partition; empty: the scheduler's default (omit the option). |
| NP | Number of tasks (processes) to reserve: `--ntasks`, `bsub -n`, PBS `mpiprocs`. |
| OUTPUT | File for stdout and stderr. If empty, use `$RUNFLOW_LOG_DIR/<scheduler>.<host>.<id>.log`. |
| DEPENDS_ON | Comma-separated bare IDs, or empty. Run only after all of them completed successfully; never if any failed. |
| OPTIONS | Native options as one string (site, workflow and call combined). Split them with `runflow::split_options` and pass them after your own options; the scheduler rejects what it does not know. A scheduler that has no command of its own (localq) parses them itself and refuses unknown ones. |
| COMMAND | The command as separate arguments. Keep their boundaries: quote each argument with `printf %q` when writing a job script. |

COMMAND looks like this:

```
bash -c '...' runflow-job DIR SETUP RUNFLOW_JOB_SCHEDULER=slurm RUNFLOW_NP=8 RUNFLOW_...=... /path/runflow -n 8 -c @mpi @flow CASE.DATA
```

- **Run it exactly once,** on the job's first node, from a batch script or
  `sbatch --wrap`. Never run it under `srun`, `mpirun`, `blaunch` or `pbsdsh`:
  `@mpi` starts the ranks itself.
- **Request tasks only:** threads, GPUs and memory come from native options.
- **Fail early:** reject an unknown dependency, or an NP the queue can never
  satisfy.

| Scheduler | Dependencies `12,13` |
|---|---|
| LSF | `bsub -w "done(12) && done(13)"` |
| SLURM | `sbatch --dependency=afterok:12:13 --kill-on-invalid-dep=yes` |
| PBS | `qsub -W depend=afterok:12:13` |

### runflow::backend_job_status ID

Prints one word: `PENDING`, `RUNNING`, `COMPLETED`, `FAILED`, `CANCELLED`, or
`UNKNOWN` (no such job; return 1).

- **Finished jobs:** they must still be found. Fall back to `sacct`,
  `qstat -x`, or `bjobs -a`/`bhist`.
- **Other output** counts as a transient error. After 5 in a row, `@wait`
  gives up and shows the function's stderr.
- **CANCELLED vs FAILED:** if they cannot be told apart, report FAILED.

| Status | LSF | SLURM | PBS |
|---|---|---|---|
| PENDING | PEND, PSUSP | PENDING, CONFIGURING | Q, H, W, T |
| RUNNING | RUN, USUSP, SSUSP | RUNNING, COMPLETING, SUSPENDED | R, E, S |
| COMPLETED | DONE | COMPLETED | F, exit status 0 |
| FAILED | EXIT | FAILED, TIMEOUT, OUT_OF_MEMORY, NODE_FAIL, BOOT_FAIL, DEADLINE, PREEMPTED | F, exit status non-zero |
| CANCELLED | EXIT after `bkill` | CANCELLED | F after `qdel` |

### runflow::backend_cancel_job ID

Cancels a pending or running job; its status becomes CANCELLED or FAILED.
Returns 1 with an error for an unknown or finished job, and prints nothing on
success.

### runflow::backend_list_jobs [active|all]

Lists the user's jobs: pending and running ones, or, with `all`, finished
ones too.
- Start with a summary line, then the columns
  `ID STATUS NP QUEUE NAME DEPENDS EXIT ELAPSED COMMAND` (`-` for an empty field).
- Show commands without what `@submit` added: the `bash -c ... runflow-job DIR SETUP`
  prefix, the `RUNFLOW_*=value` words and `runflow -n N -c`.

### runflow::backend_wait_job ID TIMEOUT (optional)

Blocks until the job is final, then prints its status. TIMEOUT is in seconds;
0 means never. Returns 2 on timeout. Without this function, `@wait` polls
`backend_job_status` every `RUNFLOW_POLL` seconds.

Define it only if the scheduler can block without polling, and re-check the
status after every wake-up:

| Scheduler | How to block |
|---|---|
| localq | a shared `flock` on a lock the runner holds for its lifetime |
| LSF | `bwait -w "ended(ID)"` |
| SLURM, PBS | no equivalent: leave it undefined |

### runflow::backend_check_requirements (optional)

Runs whenever the backend is loaded.
- Check the commands the backend needs. If any is missing, report it with
  `runflow::error` and `runflow::install_hint PACKAGE...` and return 1.
- localq also creates its state directory here and checks its owner.

## RUNNING ON CLUSTERS

What a backend's jobs rely on, and what to check on a new cluster.

**On the compute node,** `@submit`'s wrapper changes to the submission
directory, runs `RUNFLOW_JOB_SETUP` (the job fails if it fails), then starts
`runflow -n NP -c COMMAND...` again. The compute nodes therefore need
runflow, the submission directory, the Flow builds and the extension
directives at the same paths (a shared filesystem), and bash 4.4 or newer
and the MPI launcher in `PATH`, e.g. with
`RUNFLOW_JOB_SETUP='source /etc/profile.d/modules.sh && module load openmpi opm'`.

**Settings travel in the job's command,** so jobs do not depend on the site
passing the environment on: the job's scheduler and process count
(`RUNFLOW_NP`), `RUNFLOW_CONFIG` (made absolute), `RUNFLOW_DIRECTIVE_PATH`,
`RUNFLOW_SCHEDULER`, `RUNFLOW_DEBUG`, and all directive options and settings.
The workflow's queue, dependencies and native options are not passed.

**MPI inside jobs:** `@submit -n N` reserves N tasks and `@mpi` starts as many
ranks. runflow does not model threads, GPUs or memory: request them with
native options, tune the launcher and set Flow's thread count, e.g. SLURM, 8
ranks of 4 threads:

```bash
runflow --slurm-options "--cpus-per-task=4" --mpi-options "--cpus-per-task=4" \
        --flow-options "--threads-per-process=4" -c @submit -n 8 @mpi @flow CASE.DATA
```

- Recent Slurm versions do not pass `--cpus-per-task` from `sbatch` to `srun`;
  repeat it for the launcher.
- If `srun` starts N single-process runs instead of one N-rank run, add the
  site's PMI type: `RUNFLOW_MPI_LAUNCHER_SLURM='srun --mpi=pmix --ntasks={np}'`.
- With `mpirun` (LSF, PBS), concurrent runs inside one allocation start their
  ranks on the same first node and cores.

**Checking a new cluster** from a login node, once its backend exists:

```bash
runflow -s slurm -c @wait @submit -o "$PWD/check.log" @flow -l            # Flow on a compute node
runflow -s slurm -c @wait @submit -n 2 -o "$PWD/mpi.log" @mpi @flow SMALL.DATA
TEST_SCHEDULER=slurm tests/run_tests.sh                                   # the suite, on the cluster
```
