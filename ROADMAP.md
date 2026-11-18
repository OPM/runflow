# Roadmap

| Part | Status |
|---|---|
| Directives: `@flow`, `@flowpy`, `@mpi`, `@submit`, `@wait`, `@cancel`, `@help` | Done |
| Flow versions: named builds, build information, Python of each version | Done |
| Local queue (localq), dry runs, interactive shell, extension directives | Done |
| Examples (SPE1, SPE9), man page, tests | Done |
| Scheduler backends: LSF, SLURM, PBS | Planned |
| Tests on real clusters | After the backends |

## Next

- **LSF backend** (`lib/queue/lsf.sh` is its skeleton), then **SLURM** and
  **PBS**: four functions each, see [docs/BACKENDS.md](docs/BACKENDS.md).
  Until then, jobs run in the local queue, and `--dry-run -s slurm` (or `lsf`,
  `pbs`) shows what a workflow would submit.
- **`flow --build-info`** upstream: added to opm-simulators alongside flowrun;
  older Flow is probed instead (see [docs/FLOW.md](docs/FLOW.md)).

## Known limitations

- **ERT and Everest** look for an executable named `flowrun` (in
  `$FLOWRUN_PATH`, else `PATH`) to start Flow, and call it with their own
  arguments (`flowrun --version V CASE.DATA --np N`), which this `flowrun`
  does not accept: on a machine where it is in `PATH`, their FLOW forward
  model fails. Keep it out of the `PATH` of ERT's jobs.

- **macOS** needs Homebrew's `bash` and `flock`; the tests run on it in CI.
- **localq** starts a job up to `FLOWRUN_LOCALQ_POLL` seconds (default 1)
  after it could, and does not enforce its slots: more threads than slots
  oversubscribe the machine.
- **`kill -9` of a localq job's runner** marks the job FAILED, but its child
  processes keep running.
- **Open MPI 5.0's `mpirun`** (e.g. on RHEL 10) may split a program argument
  that contains quotes and spaces, as in `@mpi sh -c 'echo "a b"'`, although
  flowrun passes it as one word. Put such commands in a script.
- **Hybrid MPI and threads** (ranks × threads) are set with native, launcher
  and Flow options; there is no dedicated setting.
