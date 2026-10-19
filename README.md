# opmexec

The execution environment for [OPM](https://opm-project.org) (Open Porous
Media). opmexec runs Flow, Flow's Python and any other program the same way on
a workstation and on a cluster. It finds the installed Flow versions and the
Python each one needs, runs Flow with MPI, and queues jobs. Use it from the
command line, from workflow scripts, or interactively.

```bash
opmexec -n 4 -c @mpi @flow CASE.DATA            # Flow here, on 4 MPI ranks
opmexec -c @wait @submit @flow CASE.DATA        # as a job, waiting for it
```

**This release** runs jobs in its built-in local queue (*localq*). The LSF,
SLURM and PBS backends are planned; `opmexec --dry-run -s slurm workflow.sh`
already shows the jobs a workflow would submit to them.

## Installation

opmexec is a set of bash scripts and needs no build step. Put it where every
machine that runs jobs can reach it at the same path (on a cluster: a shared
filesystem), and add it to `PATH` and `MANPATH`:

```bash
git clone <repository URL> /shared/apps/opmexec    # not public yet
export PATH="/shared/apps/opmexec:$PATH"           # the directory; do not symlink the script
export MANPATH="/shared/apps/opmexec/man:$MANPATH"
```

**Requirements:**
- bash 4.2 or newer, coreutils, util-linux and procps; on macOS:
  `brew install bash flock`, with Homebrew's `bin` first in `PATH`.
- OPM Flow, and an MPI launcher (`mpirun`) for runs with MPI.
- For `@flowpy` and the examples: a Flow build with its Python bindings
  (`opm.io`), and numpy.

Missing tools are reported when opmexec starts.

**Check the installation:**

```bash
opmexec -c @flow -l                      # the Flow versions found, with their build and Python
opmexec -c @wait @submit echo ok         # a job in the local queue
opmexec --jobs=all                       # the jobs, also finished ones
```

## Configuration

opmexec works without configuration: it finds Flow through `PATH` and runs
jobs in its local queue. Every setting, its default and what it does are in
`etc/defaults/opmexec.conf`. Don't edit that file; copy the lines you change
into `~/.config/opmexec/opmexec.conf` (for you), or into `etc/opmexec.conf` in
the opmexec directory (for everyone using it; Git ignores it). The files are
bash and are read in that order, so yours extends the site's lists with `+=`:

```bash
OPMEXEC_FLOW_VERSIONS+=('dev=~/opm/build/bin/Release')   # the site's names stay; "dev" is added or redefined
```

The settings used most:

| Setting | For |
|---|---|
| `OPMEXEC_FLOW_VERSIONS` | named builds, e.g. `('2025.04=/opt/opm/2025.04/bin/flow' 'dev=~/opm/build/bin')` |
| `OPMEXEC_FLOW_VERSION` | the Flow used without `-v` |
| `OPMEXEC_JOB_SETUP` | what jobs run first, e.g. `module load ...` |
| `OPMEXEC_MPI_LAUNCHER_LOCAL` | the MPI launcher and its binding |

The environment and opmexec's options win over the files. For installing it
for a site, see `man opmexec`, CONFIGURATION, "For administrators".

## Usage

A workflow is a plain bash script with directives, commands whose names start
with `@`, run with `opmexec`. Its options are defaults for every directive in
the script:

```bash
#!/usr/bin/env bash
# run.sh: two cases in parallel, then a comparison when both completed
a=$(@submit @mpi @flow CASE_A.DATA)
b=$(@submit @mpi @flow CASE_B.DATA)
@submit --depends-on "$a,$b" @flowpy compare.py
@wait
```

```bash
opmexec -n 8 --flow-version 2025.04 run.sh      # each run on 8 ranks, with that Flow
opmexec --dry-run run.sh                        # the jobs it would submit
```

| Directive | Does |
|---|---|
| `@flow` | runs Flow |
| `@flowpy` | runs the Python of a Flow version, with its opm bindings |
| `@mpi` | runs a program, or `@flow`, with MPI |
| `@submit` | queues a job and prints its ID |
| `@wait` | waits for jobs, or submits and waits: `@wait @submit ...` |
| `@cancel` | cancels jobs |
| `@help` | lists the directives; `@help @flow` shows the options of one |

`opmexec --shell` starts an interactive bash with the directives, Tab
completion and notices of finished jobs; `opmexec` and `man opmexec` work in
it even without the `PATH` and `MANPATH` lines above.

**Where things go:** a job's output, unless `@submit -o` names a file, is in
`~/.local/state/opmexec/logs/localq.HOST.ID.log`; the local queue's state in
`/var/tmp/opmexec-UID/`. Flow writes its own output next to the deck.

**When something goes wrong:**
- `opmexec --dry-run ...` shows what would run, and the problems it finds.
- `OPMEXEC_DEBUG=true opmexec ...` prints what opmexec decides.
- "Flow version not found": `opmexec -c @flow -l` lists what is found where.
- "MPI launcher not found": load the MPI module, or set
  `OPMEXEC_MPI_LAUNCHER_LOCAL`.
- "Unknown directive" in a job: the job does not find an extension directive
  at the same path.

## Documentation

| Where | What |
|---|---|
| `man opmexec` | the reference: options, directives, schedulers, configuration |
| [examples/](examples/README.md) | short reservoir engineering workflows on SPE1 and SPE9, and a tutorial |
| [docs/FLOW.md](docs/FLOW.md) | how Flow versions, their builds and their Python are found |
| [docs/DIRECTIVES.md](docs/DIRECTIVES.md) | writing your own directives |
| [docs/BACKENDS.md](docs/BACKENDS.md) | adding a scheduler, running on clusters |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | developing opmexec: layout, tests, conventions |
| [ROADMAP.md](ROADMAP.md) | status and known limitations |

## License

To be decided.
