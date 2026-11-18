# flowrun

[![tests](https://github.com/SoilRos/flowrun/actions/workflows/tests.yml/badge.svg)](https://github.com/SoilRos/flowrun/actions/workflows/tests.yml)

The execution environment for [OPM](https://opm-project.org) (Open Porous
Media). flowrun runs Flow, Flow's Python and any other program the same way on
a workstation and on a cluster. It finds the installed Flow versions and the
Python each one needs, runs Flow with MPI, and queues jobs. Use it from the
command line, from workflow scripts, or interactively.

```bash
flowrun -n 4 -c @mpi @flow CASE.DATA            # Flow here, on 4 MPI ranks
flowrun -c @wait @submit @flow CASE.DATA        # as a job, waiting for it
```

**This release** runs jobs in its built-in local queue (*localq*). The LSF,
SLURM and PBS backends are planned; `flowrun --dry-run -s slurm workflow.sh`
already shows the jobs a workflow would submit to them.

## Installation

flowrun is a set of bash scripts and needs no build step. Clone it, and add
its directory to `PATH` and `MANPATH` for this shell:

```bash
git clone <repository URL> flowrun       # not public yet
cd flowrun
export PATH="$PWD:$PATH"                 # the directory: do not symlink the script
export MANPATH="$PWD/man:${MANPATH:-}"   # the ":" at the end keeps the system's man pages
```

For every new shell, add the same to `~/.bashrc`, from the flowrun directory:

```bash
echo "export PATH=\"$PWD:\$PATH\" MANPATH=\"$PWD/man:\${MANPATH:-}\"" >> ~/.bashrc
```

On a cluster, clone it where every node finds it at the same path, e.g. on a
shared filesystem (`man flowrun`, CONFIGURATION, "For administrators").

**Requirements:**
- bash 4.4 or newer, coreutils, util-linux and procps; on macOS:
  `brew install bash flock`, with Homebrew's `bin` first in `PATH`.
- OPM Flow, and an MPI launcher (`mpirun`) for runs with MPI.
- For `@flowpy` and the examples: a Flow build with its Python bindings
  (`opm.io`), and numpy.

Missing tools are reported when flowrun starts.

**Check the installation:**

```bash
flowrun -c @flow -l                      # the Flow versions found, with their build and Python
flowrun -c @wait @submit echo ok         # a job in the local queue
flowrun --jobs=all                       # the jobs, also finished ones
```

## Configuration

flowrun works without configuration: it finds Flow through `PATH` and runs
jobs in its local queue. Every setting, its default and what it does are in
`etc/defaults/flowrun.conf`. Don't edit that file; copy the lines you change
into `~/.config/flowrun/flowrun.conf` (for you), or into `etc/flowrun.conf` in
the flowrun directory (for everyone using it; Git ignores it). The files are
bash and are read in that order, so yours extends the site's lists with `+=`:

```bash
FLOWRUN_FLOW_VERSIONS+=('dev=~/opm/build/bin/Release')   # the site's names stay; "dev" is added or redefined
```

The settings used most:

| Setting | For |
|---|---|
| `FLOWRUN_FLOW_VERSIONS` | named builds, e.g. `('2025.04=/opt/opm/2025.04/bin/flow' 'dev=~/opm/build/bin')` |
| `FLOWRUN_FLOW_VERSION` | the Flow used without `-v` |
| `FLOWRUN_JOB_SETUP` | what jobs run first, e.g. `module load ...` |
| `FLOWRUN_MPI_LAUNCHER_LOCAL` | the MPI launcher and its binding |

The environment and flowrun's options win over the files. For installing it
for a site, see `man flowrun`, CONFIGURATION, "For administrators".

## Usage

A workflow is a plain bash script with directives, commands whose names start
with `@`, run with `flowrun`. Its options are defaults for every directive in
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
flowrun -n 8 --flow-version 2025.04 run.sh      # each run on 8 ranks, with that Flow
flowrun --dry-run run.sh                        # the jobs it would submit
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

`flowrun --shell` starts an interactive bash with the directives, Tab
completion and notices of finished jobs; `flowrun` and `man flowrun` work in
it even without the `PATH` and `MANPATH` lines above.

**Where things go:** a job's output, unless `@submit -o` names a file, is in
`~/.local/state/flowrun/logs/localq.HOST.ID.log`; the local queue's state in
`/var/tmp/flowrun-UID/`. Flow writes its own output next to the deck.

**When something goes wrong:**
- `flowrun --dry-run ...` shows what would run, and the problems it finds.
- `FLOWRUN_DEBUG=true flowrun ...` prints what flowrun decides.
- "Flow version not found": `flowrun -c @flow -l` lists what is found where.
- "MPI launcher not found": load the MPI module, or set
  `FLOWRUN_MPI_LAUNCHER_LOCAL`.
- "Unknown directive" in a job: the job does not find an extension directive
  at the same path.

## Documentation

| Where | What |
|---|---|
| `man flowrun` | the reference: options, directives, schedulers, configuration |
| [examples/](examples/README.md) | short reservoir engineering workflows on SPE1 and SPE9, and a tutorial |
| [docs/FLOW.md](docs/FLOW.md) | how Flow versions, their builds and their Python are found |
| [docs/DIRECTIVES.md](docs/DIRECTIVES.md) | writing your own directives |
| [docs/BACKENDS.md](docs/BACKENDS.md) | adding a scheduler, running on clusters |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | developing flowrun: layout, tests, conventions |
| [ROADMAP.md](ROADMAP.md) | status and known limitations |

## License

To be decided.
