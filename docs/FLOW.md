# Finding Flow and its Python

How `@flow` and `@flowpy` find a Flow version, describe its build and choose
its Python. The man page has the user's view; this is what happens.

## The executable (`@flow -v VERSION`)

The first that applies (`runflow::flow::find`):

1. **A path** (contains `/`): that executable.
2. **A name in `RUNFLOW_FLOW_VERSIONS`** (`'NAME=PATH'` items, the last of a
   name winning, so `+=` in a later file redefines it; `PATH` is the
   executable or its directory, `~/` for the home directory).
3. **An executable** `flow<VERSION>` or `<VERSION>` in the search directories,
   in order: `RUNFLOW_FLOW_BIN_PATHS`, where the entry `PATH` stands for the
   directories of `$PATH` at the time of the lookup (in a job: after
   `RUNFLOW_JOB_SETUP`). Relative entries are skipped, so a deck directory
   never provides Flow. The first OPM Flow found wins.
4. **An OPM version** such as `2025.04`, if exactly one of the named versions
   and the executables named `flow` in the search directories reports it.
   Several: an error listing them, never a guess.

An executable is OPM Flow if its `--version` prints `flow <YYYY.MM...>`, or,
for OPM simulators without that option (e.g. `flow_comp`), OPM's usage line
`[OPTIONS] [DECK_FILENAME]`. Other programs named `flow` (e.g. the JavaScript
type checker) are skipped. Before a run, `@flow` reports the executable and
its OPM version: that one `--version` is all it costs.

## The build (`@flow -l`)

`@flow -l` shows each build's OPM version, git hash, build type and build
time (`runflow::flow::build_info`); `@flow -l VERSION` adds the MPI library
and the build ID (`runflow::flow::build_details`):

- **`flow --build-info`**, if Flow supports it (added to opm-simulators
  alongside runflow), prints `version=`, `hash=`, `build_time=`,
  `build_type=` and `mpi=` lines.
- **Otherwise**, Flow is run on a one-line deck in a temporary directory: it
  writes the header of its log (`Flow Version = 2025.04 (hash)`, `Build time
  = ...`) before rejecting the deck. Only OPM Flow is probed.
- **The build type**, if Flow did not report it: a `bin/<CONFIG>` directory
  (multi-config builds), `CMAKE_BUILD_TYPE` in the build tree's
  `CMakeCache.txt`, or the hash `debug` that OPM's Debug builds write.
- **MPI** from the libraries linked (`ldd`); **the build ID** from the ELF
  note (`readelf`, `file`), or the Mach-O UUID (`otool`) on macOS.

The executables of a listing are examined in parallel, a batch of one per
CPU.

## The Python (`@flowpy`, and `PYTHONPATH` for `@flow`)

For each version, the configuration wins over detection
(`runflow::flow::python_info`):

- **The Python version:** `RUNFLOW_FLOW_PYTHON_MAP`; else the name of the
  bindings' compiled module, which Python itself uses to decide what it can
  import (`opmcommon_python.cpython-313-...so`: 3.13; `cpython-313t`,
  free-threaded: 3.13t; `cpython-313d`, debug: 3.13d); else the libpython Flow
  is linked against (`ldd`, or `otool -L` on macOS), which only Flow builds
  that embed Python have.
- **The bindings** (`RUNFLOW_FLOW_PYTHONPATH`): a template, or with `auto`
  found next to Flow: `PREFIX/lib/python3.X/site-packages` for
  `PREFIX/bin/flow`, or, in a CMake build tree, the `python` directories of
  the opm-common build named in `CMakeCache.txt` and of the build itself
  (`python/<CONFIG>` in multi-config builds, for `bin/<CONFIG>/flow`). Only
  bindings with their compiled module count; with bindings for several
  Pythons, those of the configured version, else of the embedded one.
- **The interpreter:** the one installed with the linked libpython, else
  `python3.X` in `PATH`, else `python3` if it is that version. A different
  version is never used: before running, `@flowpy` checks that the
  interpreter accepts the bindings' module (its
  `importlib.machinery.EXTENSION_SUFFIXES`), then reports the interpreter and
  the bindings on stderr, as `@flow` reports its executable.

`@flow` sets `PYTHONPATH` to the bindings when Flow embeds Python (PYACTION
needs them) or a template is configured. If the embedded Python differs from
the bindings' one, PYACTION cannot import them: `@flow` warns, and `@flow -l`
shows the mismatch.
