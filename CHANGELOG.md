# Changelog

What changed in each version of flowrun. `flowrun --version` prints the
version you have.

Versions follow [semantic versioning](https://semver.org): `MAJOR.MINOR.PATCH`.
A new PATCH version only fixes bugs; a new MINOR version adds features that
work with existing scripts and configurations. Before 1.0, a MINOR version
may also change them; such changes are listed under **Changed** and say what
to do.

## [Unreleased]

## [0.1.0] - 2026-11-18

The first release: everything runs in the built-in local queue; the LSF,
SLURM and PBS backends are planned (`--dry-run -s slurm` shows their jobs).

### Added

- **Running Flow:** `@flow` runs Flow as `flow` does, with its own options;
  `@mpi` runs it, or any program, with MPI; `@flowpy` runs the Python a
  Flow version's bindings were built for, with those bindings.
- **Flow versions:** chosen by path, by name (`FLOWRUN_FLOW_VERSIONS`), by
  executable name in the search directories, or by OPM version. `@flow -l`
  lists them with OPM version, git hash, build type, build time and Python;
  `@flow -w` prints one's executable. Build information comes from
  `flow --build-info` where Flow has it, else from Flow's log header.
- **Python per version:** found from the bindings' module name or the
  libpython Flow embeds, or configured (`FLOWRUN_FLOW_PYTHON_MAP`,
  `FLOWRUN_FLOW_PYTHONPATH`); a different Python is never used.
- **Jobs:** `@submit`, `@wait` and `@cancel`, with dependencies, time
  limits, niceness, job names and exclusive jobs, in the local queue
  (localq), which runs as many jobs at once as the machine has cores.
- **Workflows:** plain bash scripts run with `flowrun SCRIPT`, single
  commands with `flowrun -c`, and an interactive shell (`flowrun --shell`)
  with Tab completion and notices of finished jobs. `--dry-run` checks a
  workflow and prints the jobs it would submit, for any scheduler.
- **Configuration** in layers: defaults (`etc/defaults/flowrun.conf`), the
  machine, the site, the user, the environment and options. Users extend
  the site's lists with `+=`, and the last item of a version name wins.
- **Extension directives** that can be loaded from a site's or a user's
  directories.
- **Examples:** six reservoir engineering workflows on SPE1 and SPE9.
- **Documentation:** `man flowrun`, and docs/ for Flow versions, writing
  directives, backends and development.
- **Tests** on Ubuntu, macOS, Rocky Linux 8–10, Debian 12–13, Ubuntu 22.04
  and openSUSE Leap 15.6, and with real Flow from Debian's and OPM's
  packages.
