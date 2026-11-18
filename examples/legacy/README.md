# From a site's runflow script to runflow

Some sites have a small `runflow` script: it picks a Flow version from one
directory, sets `PYTHONPATH` for it, and either submits the run to the
scheduler or, with `-i`, runs it here. [legacy-runflow](legacy-runflow) does
the same with runflow's library, with the same options, in a few lines; what
such a script hard-codes is the site's configuration instead,
[site.conf](site.conf).

```bash
legacy-runflow -v flowrc47 -n 8 -q long -o "--enable-esmry=true" CASE.DATA   # a job
legacy-runflow -i -n 4 CASE.DATA                                             # here and now
legacy-runflow -l                                                            # the versions
```

| A typical runflow script | Here |
|---|---|
| `-v VERSION`: an executable in one hard-coded directory | `RUNFLOW_FLOW_BIN_PATHS` (any number of directories), names in `RUNFLOW_FLOW_VERSIONS`, or an OPM version |
| a hard-coded default version | `RUNFLOW_FLOW_VERSION`, the site's; users may set their own |
| `PYTHONPATH` from a rule on the version's name, edited for each new version | found from the bindings next to Flow; otherwise `RUNFLOW_FLOW_PYTHONPATH` and `RUNFLOW_FLOW_PYTHON_MAP` |
| `-n NP`: `mpirun --bind-to none -np NP`, from a fixed path | `@mpi`, with `RUNFLOW_MPI_LAUNCHER_LOCAL` here and `RUNFLOW_MPI_LAUNCHER_LSF` in jobs |
| `-o "OPTIONS"`, split on spaces | `--flow-options`, with shell quoting |
| writes a job script next to the deck, then `bsub -n NP -q QUEUE -R span[hosts=1] -J NAME` | `@submit`, with `RUNFLOW_DEFAULT_QUEUE_LSF` and `RUNFLOW_LSF_OPTIONS`; nothing is written next to the deck but Flow's output and `CASE.LOG` |
| `-i`: Flow here | the same, with `@flow`, or `@mpi @flow` |
| `-l`: the directory's executables | `@flow -l`: also their OPM version, git hash, build type, build time and Python |

**Differences:**
- Flow's output and errors go to one file, `CASE.LOG` (a typical script
  splits them into `.LOG` and `.ERR`).
- The LSF backend is planned: until then jobs run in runflow's local queue.
  `runflow --dry-run -s lsf legacy-runflow ...` shows the job LSF would get.

**What comes on top:** waiting for jobs and chaining them (`@wait`,
`--depends-on`), dry runs, users' own builds next to the site's, a record of
the exact build each run used, and the same configuration for workflow
scripts, `runflow -c` and the interactive shell.

**Installing it at a site:** put the site's values into the installation's
`etc/runflow.conf` (see site.conf), and `legacy-runflow` where users find it.
It cannot be called `runflow` in the same `PATH` as runflow itself: keep the
name `legacy-runflow`, or the site's own, while users move over.
