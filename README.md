# runflow

[![tests](https://github.com/OPM/runflow/actions/workflows/tests.yml/badge.svg)](https://github.com/OPM/runflow/actions/workflows/tests.yml)

> **Work in progress.** runflow is still being developed. Until version 1.0
> there is no promise to keep its functionality or its syntax (options,
> directives, settings) as they are: a new version may change or remove
> them. [CHANGELOG.md](CHANGELOG.md) lists every change and what to do about
> it; to stay on a known version, check out its release tag, e.g.
> `git checkout v0.1.0`.

The execution environment for [OPM](https://opm-project.org) (Open Porous
Media). runflow runs Flow, Flow's Python and any other program the same way on
a workstation and on a cluster. It finds the installed Flow versions and the
Python each one needs, runs Flow with MPI, and queues jobs. Use it from the
command line, from workflow scripts, or interactively.

```bash
runflow -n 4 -c @mpi @flow CASE.DATA            # Flow here, on 4 MPI ranks
runflow -c @wait @submit @flow CASE.DATA        # as a job, waiting for it
```

**This release** runs jobs in its built-in local queue (*localq*). The LSF,
SLURM and PBS backends are planned; `runflow --dry-run -s slurm workflow.sh`
already shows the jobs a workflow would submit to them.

## Installation

runflow is a set of bash scripts and needs no build step. Clone it, and add
its directory to `PATH` and `MANPATH` for this shell:

```bash
git clone https://github.com/OPM/runflow.git
cd runflow
export PATH="$PWD:$PATH"                 # the directory: do not symlink the script
export MANPATH="$PWD/man:${MANPATH:-}"   # the ":" at the end keeps the system's man pages
```

For every new shell, add the same to `~/.bashrc`, from the runflow directory:

```bash
echo "export PATH=\"$PWD:\$PATH\" MANPATH=\"$PWD/man:\${MANPATH:-}\"" >> ~/.bashrc
```

On a cluster, clone it where every node finds it at the same path, e.g. on a
shared filesystem (`man runflow`, CONFIGURATION, "For administrators").

**Requirements:**
- bash 4.4 or newer, coreutils, util-linux and procps; on macOS:
  `brew install bash flock`, with Homebrew's `bin` first in `PATH`.
- OPM Flow, and an MPI launcher (`mpirun`) for runs with MPI.
- For `@flowpy` and the examples: a Flow build with its Python bindings
  (`opm.io`), and numpy.

Missing tools are reported when runflow starts.

**Check the installation:**

```bash
runflow --version                        # which runflow this is (CHANGELOG.md: what is in it)
runflow -c @flow -l                      # the Flow versions found, with their build and Python
runflow -c @wait @submit echo ok         # a job in the local queue
runflow --jobs=all                       # the jobs, also finished ones
```

## Configuration

runflow works without configuration: it finds Flow through `PATH` and runs
jobs in its local queue. Every setting, its default and what it does are in
`etc/defaults/runflow.conf`. Don't edit that file; copy the lines you change
into `~/.config/runflow/runflow.conf` (for you), or into `etc/runflow.conf` in
the runflow directory (for everyone using it; Git ignores it). The files are
bash and are read in that order, so yours extends the site's lists with `+=`:

```bash
RUNFLOW_FLOW_VERSIONS+=('dev=~/opm/build/bin/Release')   # the site's names stay; "dev" is added or redefined
```

The settings used most:

| Setting | For |
|---|---|
| `RUNFLOW_FLOW_VERSIONS` | named builds, e.g. `('2025.04=/opt/opm/2025.04/bin/flow' 'dev=~/opm/build/bin')` |
| `RUNFLOW_FLOW_VERSION` | the Flow used without `-v` |
| `RUNFLOW_JOB_SETUP` | what jobs run first, e.g. `module load ...` |
| `RUNFLOW_MPI_LAUNCHER_LOCAL` | the MPI launcher and its binding |

The environment and runflow's options win over the files. For installing it
for a site, see `man runflow`, CONFIGURATION, "For administrators".

## Usage

A workflow is a plain bash script with directives, commands whose names start
with `@`, run with `runflow`. Its options are defaults for every directive in
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
runflow -n 8 --flow-version 2025.04 run.sh      # each run on 8 ranks, with that Flow
runflow --dry-run run.sh                        # the jobs it would submit
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

`runflow --shell` starts an interactive bash with the directives, Tab
completion and notices of finished jobs; `runflow` and `man runflow` work in
it even without the `PATH` and `MANPATH` lines above.

**Where things go:** a job's output, unless `@submit -o` names a file, is in
`~/.local/state/runflow/logs/localq.HOST.ID.log`; the local queue's state in
`/var/tmp/runflow-UID/`. Flow writes its own output next to the deck.

**When something goes wrong:**
- `runflow --dry-run ...` shows what would run, and the problems it finds.
- `RUNFLOW_DEBUG=true runflow ...` prints what runflow decides.
- "Flow version not found": `runflow -c @flow -l` lists what is found where.
- "MPI launcher not found": load the MPI module, or set
  `RUNFLOW_MPI_LAUNCHER_LOCAL`.
- "Unknown directive" in a job: the job does not find an extension directive
  at the same path.

## Documentation

| Where | What |
|---|---|
| `man runflow` | the reference: options, directives, schedulers, configuration |
| [examples/](examples/README.md) | short reservoir engineering workflows on SPE1 and SPE9, and a tutorial |
| [docs/FLOW.md](docs/FLOW.md) | how Flow versions, their builds and their Python are found |
| [docs/DIRECTIVES.md](docs/DIRECTIVES.md) | writing your own directives |
| [docs/BACKENDS.md](docs/BACKENDS.md) | adding a scheduler, running on clusters |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | developing runflow: layout, tests, conventions |
| [ROADMAP.md](ROADMAP.md) | status and known limitations |
| [CHANGELOG.md](CHANGELOG.md) | what changed in each version (`runflow --version`: which you have) |

## License

Copyright (C) 2026 OPM-OP AS.

runflow is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version (SPDX: `GPL-3.0-or-later`), as OPM itself is.

It is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
A PARTICULAR PURPOSE. See the GNU General Public License in
[LICENSE](LICENSE) for more details.
