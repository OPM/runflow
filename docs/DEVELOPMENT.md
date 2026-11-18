# Developing runflow

How the code is organised, how to test it, and the conventions it follows.
For using runflow see `man runflow` ([man/man1/runflow.1](../man/man1/runflow.1)).

## LAYOUT

```
runflow                      CLI: parses options, then runs a script or command
VERSION                      runflow's version, the one place it is written (see RELEASES)
CHANGELOG.md                 what changed in each version
LICENSE                      the GNU GPL, version 3 (runflow: version 3 or later, see README.md)
runflow.bash                 for "source runflow.bash" (found through PATH): loads lib/runflow.sh
lib/runflow.sh               core: module loading, runflow::setup, workflow mode, helpers
lib/common.sh                bash version check, configuration loading, messages
lib/config.sh                scheduler detection, backend loading
lib/directives/*.sh          core directives: @submit, @wait, @cancel, @mpi, @help
lib/extensions/flow.sh       bundled extension: @flow and its runflow::flow:: helpers
lib/extensions/flowpy.sh     bundled extension: @flowpy (uses the runflow::flow:: helpers)
lib/interactive.sh           interactive shells: prompt marker, notifications, completion
lib/shell_rc.sh              rc file of runflow --shell
lib/queue/<scheduler>.sh     scheduler backends (localq; lsf is a stub)
lib/queue/localq_runner.sh   per-job runner of localq
etc/defaults/runflow.conf    every setting: its default and explanation (read first)
etc/runflow.conf             the site's configuration (ignored by Git; not shipped)
man/man1/runflow.1           user reference (roff); check with: groff -man -ww -z
examples/                    example workflows (README.md) and their post-processing (python/)
tests/                       test suite, localq stress test
```

## STRUCTURE

The design has three layers, each owned by one kind of module:

| Layer | Owned by | Responsibility |
|---|---|---|
| allocation | `@submit` and the backends | reserve resources and queue jobs |
| launch | `@mpi` | start the ranks inside the reservation |
| program | `@flow` and extensions | build the program's command line |

A layer communicates with the next only through the job's command and the
`RUNFLOW_*` variables. That is why a backend runs the job's command exactly
once, and why `@mpi` reads `RUNFLOW_NP` and `RUNFLOW_JOB_SCHEDULER`.

**Startup:**
1. The core loads the configuration: defaults, configuration files, then
   what was already set.
2. It loads the modules in this order: `lib/directives`, `lib/extensions`,
   then `RUNFLOW_DIRECTIVE_PATH`.
3. It removes the job lists of this host's sessions whose process is gone.
4. It turns on workflow mode, except under the CLI (which turns it on after
   parsing its options). Interactive shells get `lib/interactive.sh` instead:
   no traps, nothing may exit the shell, and `_RUNFLOW_INTERACTIVE` is set
   (e.g. `@cancel` then needs job IDs).

Loading the library a second time does nothing.

**Jobs:** `@submit` wraps the command in
`bash -c '...' runflow-job DIR SETUP` and adds the job's settings as
`RUNFLOW_*=value` words (see docs/BACKENDS.md). Directives inside a job run
through `runflow -n NP -c ...`, which loads everything again on the compute
node.

## TESTS

```bash
tests/run_tests.sh [PATTERN]           # all tests, or those whose file:function contains PATTERN
tests/stress_localq.sh [JOBS] [SLOTS]  # concurrency and slot accounting (default 100, 8)
```

| Variable | Meaning |
|---|---|
| `TEST_SCHEDULER` | Scheduler for the queue tests (default `localq`). Scheduler-specific tests are skipped for other schedulers. |
| `TEST_TIMEOUT` | Seconds per test (default 60). |
| `KEEP_FAILED=1` | Keep the sandbox of failed tests. |
| `TMPDIR` | Where sandboxes are created. On a cluster it must be shared with the compute nodes. |
| `TEST_FLOW`, `TEST_FLOWPY`, `TEST_DECKS` | A real Flow executable, one with Python bindings (default: `TEST_FLOW`) and a directory with SPE1CASE2.DATA (e.g. opm-common's `tests/`): the examples' real-run tests use them; skipped without. |

Ctrl-C stops the running test, removes its sandbox and ends the run. Tests
run detached from the terminal (`setsid`, or perl on macOS), so they behave
the same in a terminal and in CI: an interactive shell under test (`bash -i`)
would otherwise be stopped by the kernel for trying to take over a terminal
it does not own.

Each test runs in a separate bash process with its own sandbox:
- a `HOME`, a configuration and a localq directory;
- a fake Flow (`flowtest`) that prints its arguments, its MPI size and its
  `PYTHONPATH`, plus one `ARGV [arg]...` line per run;
- the work directory as the current directory.

`tests/lib.sh` provides the helpers: `run`, `run_script`, `assert_*`,
`require_localq`, `require_cmd` and `skip`. Test functions are named
`test_*`. The runner finds them by name, cancels jobs left in the sandbox,
and removes the sandbox afterwards.

**Requirements:** what runflow needs, plus perl (which starts each test with
the default signal handling, in its own session, and times it) and GNU
`timeout`; `mpirun` and `python3` for the tests that use them (they are
skipped otherwise). On macOS: `brew install bash flock coreutils`; the tests
use Homebrew's `gtimeout` and otherwise macOS's own tools, so nothing else
goes in `PATH`. Tests use only what Linux and macOS share: no GNU-only
options (`sed -i`, `stat -c`, `date +%N`), and counts from `awk`, not
`wc -l`, which pads them with spaces on macOS.

**Continuous integration** ([.github/workflows/tests.yml](../.github/workflows/tests.yml))
runs the suite on every push and pull request, and weekly:

| For | Systems |
|---|---|
| workstations | Ubuntu 24.04 (with the localq stress test), macOS 15 on Apple silicon and on Intel |
| clusters (containers) | Rocky Linux 8, 9 and 10 (RHEL), Debian 12 and 13, Ubuntu 22.04, openSUSE Leap 15.6 (SLES) |
| real Flow | Debian 13's OPM packages (2024.10, no `--build-info`), the OPM PPA's on Ubuntu 24.04 |

Each job runs `.github/ci/run-tests.sh`. It installs the requirements with
the system's package manager, then runs the tests as an ordinary user, never
as root. The sandboxes of failed tests are uploaded as the job's artifact.
To run a cluster job locally:

```bash
docker run --rm --init -v "$PWD:/src" -w /src rockylinux/rockylinux:9 bash .github/ci/run-tests.sh
```

Rocky Linux 8 has bash 4.4, the oldest supported.

**Rules for tests:**
- Never touch the real `HOME`, `/var/tmp` or the user's queue. Use the sandbox
  and `RUNFLOW_LOCALQ_DIR`.
- Check outputs through the fake Flow's `ARGV` line or through job logs, not
  through timing. Where timing matters, use generous bounds.

## CONVENTIONS

- **Names:** everything defined in the user's shell is scoped:

  | Kind of name | Form |
  |---|---|
  | directives | `@name` |
  | core functions | `runflow::name` |
  | backend functions and globals | `runflow::<scheduler>::name`, `RUNFLOW_<SCHEDULER>_NAME` |
  | bundled extension helpers | `runflow::<extension>::name`, e.g. `runflow::flow::find` |
  | user and site extension helpers | `<extension>::name` (see docs/DIRECTIVES.md) |
  | settings and globals | `RUNFLOW_NAME` |
  | internal variables | `_RUNFLOW_NAME` |

- **Portability:** the code runs on bash 4.4 or newer, on Linux and on macOS
  (with Homebrew). No GNU-only options outside the tests. Linux-only paths
  (`/proc`, `setsid`) need a fallback, defined on every platform so the tests
  run it on Linux too (e.g. `runflow::localq::pstart_into_ps`).
- **Functions that set the caller's variable** (`printf -v "$1"`, the
  `..._into VAR` helpers) prefix their locals with their own name, e.g.
  `_pstart_start`: `printf -v` writes the innermost variable of that name, so
  a local named like the caller's variable silently swallows the value.
- **Clean-up on exit:** workflow mode cleans up in an `EXIT` trap whose first
  step ignores further signals (signals often arrive in twos), and keeps
  per-run state that is harmless if left behind: each run reads only its own
  session file, and the next run on the host removes those of ended runs.
- **License header:** every script, library file and example starts (after
  its `#!` line) with
  `# SPDX-License-Identifier: GPL-3.0-or-later` and
  `# Copyright (C) YEAR OPM-OP AS`; a test checks it.
- **Library side effects:** the library must not change the shell's options
  (no `set -o pipefail`) or traps outside workflow mode.
- **Output:** stdout carries data (job IDs, listings). Messages go to stderr
  through `runflow::error`, `runflow::warning`, `runflow::info` and
  `runflow::debug`.
- **Option strings** are split with `runflow::split_options`, never with
  `eval` or word splitting.
- **Configuration:** a new setting gets its default, after a comment that
  explains it, in `etc/defaults/runflow.conf` (a test checks the comment).
  A list setting where a name or pattern selects an item uses the last
  matching item, so that `+=` in a later file redefines it.
  `lib/common.sh` loads defaults, then the configuration files, then restores
  what was set before loading, so the environment, and the settings jobs get
  from their workflow, win.
- **localq's scheduling path** forks no processes: it uses `read` instead of
  `cat`, globs instead of `ls`, and `printf '%(%s)T'` instead of `date`.
- **No backward compatibility shims:** when a name changes, it changes
  everywhere.
- **Documentation:** user-facing behaviour is documented in the man page,
  development in docs/. Keep the README to installation, basic usage and
  pointers.
- **Checks before a change is done:** `bash -n` on every script; the full test
  suite; the stress test for localq changes.

## RELEASES

The version is in the `VERSION` file, the one place it is written; runflow
reads it for `--version`, `-h` and its debug output. Versions follow semantic
versioning (`CHANGELOG.md` says what each part means for users). Every change
users notice gets a line under **Unreleased** in `CHANGELOG.md`, as it is made.

Between releases, `main` is the development version of the next one, e.g.
`0.2.0-dev`: only a release's tagged commit carries a plain number. To
release, e.g. 0.2.0:

1. In `CHANGELOG.md`, rename **Unreleased** to `[0.2.0] - YYYY-MM-DD`, and
   start a new, empty **Unreleased** above it.
2. Write `0.2.0` into `VERSION` (dropping `-dev`).
3. Commit, and tag the commit `v0.2.0` (`git tag -a v0.2.0 -m "runflow 0.2.0"`),
   then push it with the tags: checkouts report how far they are from it.
4. Write the next development version, e.g. `0.3.0-dev`, into `VERSION`, and
   commit.

A test checks that `VERSION` is `MAJOR.MINOR.PATCH` (with a `-dev` or other
pre-release suffix between releases), that `CHANGELOG.md` has its section
(**Unreleased** for a development version), and that `runflow --version`
prints it.

## EXTENDING

| Task | Read |
|---|---|
| a new directive | [DIRECTIVES.md](DIRECTIVES.md) |
| a new scheduler | [BACKENDS.md](BACKENDS.md) |
| status, limitations, planned work | [ROADMAP.md](../ROADMAP.md) |
| what changed in each version | [CHANGELOG.md](../CHANGELOG.md) |
