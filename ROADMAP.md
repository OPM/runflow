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
- **`flow --build-info`** upstream: added to opm-simulators alongside opmexec;
  older Flow is probed instead (see [docs/FLOW.md](docs/FLOW.md)).

## Known limitations

- **macOS** is supported (with Homebrew's `bash` and `flock`) but not yet
  tested automatically.
- **localq** starts a job up to `OPMEXEC_LOCALQ_POLL` seconds (default 1)
  after it could, and does not enforce its slots: more threads than slots
  oversubscribe the machine.
- **`kill -9` of a localq job's runner** marks the job FAILED, but its child
  processes keep running.
- **Hybrid MPI and threads** (ranks × threads) are set with native, launcher
  and Flow options; there is no dedicated setting.
