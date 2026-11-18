# Writing a Directive

A directive is a bash function `@NAME` in a module file that registers it.
Once loaded, it works:
- inline (`runflow -c @NAME`) and in scripts;
- inside `@submit` jobs;
- in `runflow -h`;
- optionally under `@mpi`.

The bundled [lib/extensions/flow.sh](../lib/extensions/flow.sh) and
[lib/extensions/flowpy.sh](../lib/extensions/flowpy.sh) are complete examples:
options, a setting, `@mpi` support, and helpers shared between modules.

## SYNOPSIS

```bash
#!/usr/bin/env bash
# ~/.config/runflow/directives/hello.sh
runflow::directive hello "[-n] [NAME]" "Say hello" "echo options for every @hello"
runflow::directive_setting hello-greeting HELLO_GREETING "Greeting for every @hello"
runflow::directive_option "-n" - "No newline at the end"   # for @help and Tab completion
runflow::directive_arguments none

runflow::command_hello() {                     # optional: makes @mpi @hello possible
  local flags=()
  [[ "${1:-}" == -n ]] && { flags=(-n); shift; }
  runflow::directive_options hello || return 1 # --hello-options
  _RUNFLOW_ARGV=(echo "${flags[@]}" "${_RUNFLOW_WORDS[@]}" "${HELLO_GREETING:-hello}" "${1:-world}")
}

@hello() {
  runflow::command_hello "$@" || return 1
  if runflow::dry_run; then
    runflow::dry "run: $(runflow::quoted "${_RUNFLOW_ARGV[@]}")"
    return 0
  fi
  "${_RUNFLOW_ARGV[@]}"
}
```

Try it:

```bash
runflow --directives ./hello.sh -c @hello you
runflow --directives ./hello.sh -c @help @hello
runflow --directives ./hello.sh --hello-greeting Hi --hello-options "-e" -c @hello 'you\n'
runflow --directives ./hello.sh --dry-run -c @mpi -n 4 @hello you
runflow --directives ./hello.sh -s localq -c @wait @submit @hello job
```

## LOADING

Modules load at startup in this order. A later module replaces a directive of
the same name, except a core one: replacing `@submit`, `@wait`, `@cancel`,
`@mpi` or `@help` is an error and is undone.

1. `lib/directives/*.sh` (core);
2. `lib/extensions/*.sh` (bundled: `@flow`, `@flowpy`);
3. each entry of `RUNFLOW_DIRECTIVE_PATH`, a `:`-separated list of directories
   or files (default `${XDG_CONFIG_HOME:-~/.config}/runflow/directives`);
4. `runflow --directives PATH` or `runflow::use PATH`. These are added to
   `RUNFLOW_DIRECTIVE_PATH`, so jobs load them too.

The current directory is never searched. A module that fails to load is
reported and skipped. `RUNFLOW_DEBUG=true` shows which module replaced which.

## REGISTRATION

**`runflow::directive NAME USAGE SUMMARY [OPTIONS]`**
Registers `@NAME` for `runflow -h` and `@help`. NAME must not be a scheduler's name.

With OPTIONS, which describes them, the directive accepts `--NAME-options`.
Read them with `runflow::directive_options NAME`, which leaves the words in
`_RUNFLOW_WORDS`, and place them before the call's own options. They come from
`RUNFLOW_<NAME>_OPTIONS`: the configuration's site defaults plus
`--NAME-options`. For example, `my-tool` uses `RUNFLOW_MY_TOOL_OPTIONS`.

**`runflow::directive_option "NAMES [VALUE]" KIND DESCRIPTION`**
Describes an option of the directive registered last, for `@help @NAME`
and Tab completion; the directive still parses its arguments
itself. NAMES are comma-separated spellings (`"-v, --flow-version VERSION"`); KIND
is how its value is completed: `version` (a Flow version), `deck`, `file`,
`job` (this run's job IDs), `scheduler`, `text` (not completed), or `-` for an
option without a value. A test checks that the bundled directives' options
appear in their man page section.

**`runflow::directive_arguments KIND`**
What follows the options, for Tab completion: `deck`, `file`, `job`,
`command` (a program or a directive), `directive`, or `none`. Default: `file`.

**`runflow::unknown_option NAME OPTION [HINT]`**
Reports an option `@NAME` does not take and returns 1. The message points to
`@help @NAME`.

**`runflow::directive_setting OPTION VARIABLE DESCRIPTION [KIND]`**
Adds a setting `--OPTION VALUE` to the directive registered last; KIND as for
`runflow::directive_option` (default `text`).
- `runflow` and `runflow::setup` accept it, and it sets and exports VARIABLE.
- The directive's own options should win over it, as `@flow -v` wins over
  `--flow-version`.
- Core option names (`np`, `queue`, `scheduler`, `depends-on`, `directives`,
  `dry-run`, `*-options`, ...) are refused.

Options and settings are passed to jobs. Give a setting its default in the
module only if it is unset (`: "${HELLO_GREETING:=hello}"`), so that the
configuration files and the environment can set it.

## CONVENTIONS

- **Options:** parse your options with a `while`/`case` loop, stop at the
  first non-option, accept `--`, and reject unknown `-options` with
  `runflow::error`.
- **Option strings:** split them with `runflow::split_options STRING WHAT`,
  which honours quotes and expands nothing; it returns 1 on unbalanced
  quotes.
- **Output:** stdout carries data only; messages go to stderr.
- **Exit status:** return 0 on success, the program's own status, or 1 after
  an `runflow::error`.
- **Names:** name helpers `NAME::...` and globals `NAME_...`. Define no
  `runflow::` functions except `runflow::command_NAME`; `runflow::<extension>::`
  is reserved for the bundled extensions (e.g. `runflow::flow::`).
- **Dry run:** when `runflow::dry_run` is true, run nothing. Print what would
  run with `runflow::dry "run: ..."` and return 0. Report problems that may
  be fixed by then (e.g. a file not yet created) with
  `runflow::dry "warning: ..."`.
- **MPI:** to run under `@mpi`, define `runflow::command_NAME`. It takes the
  directive's arguments and stores the program's command line in
  `_RUNFLOW_ARGV` without running it, because MPI launchers start programs,
  not functions. Build `@NAME` on it, as in the SYNOPSIS.
- **Jobs:** `@submit @NAME` runs `runflow -n NP -c @NAME ...` on the compute
  node, so the module and its tools must be available there.

## HELPERS

| Helper | Purpose |
|---|---|
| `runflow::directive`, `runflow::directive_setting` | Registration (see above) |
| `runflow::directive_options NAME` | Options for every `@NAME`, into `_RUNFLOW_WORDS` |
| `runflow::split_options STRING [WHAT]` | Shell-style split into `_RUNFLOW_WORDS` |
| `runflow::error`, `runflow::warning`, `runflow::info`, `runflow::debug` | Messages on stderr (`debug` only with `RUNFLOW_DEBUG=true`) |
| `runflow::dry_run`, `runflow::dry MESSAGE` | Dry-run test and output |
| `runflow::quoted ARG...` | Arguments shell-quoted on one line |
| `runflow::use PATH...` | Load modules |

The `@flow` extension also provides the following helpers. Check with
`declare -F runflow::flow::python_info` before using them:

| Helper | Returns |
|---|---|
| `runflow::flow::resolve_version VERSION` | the Flow executable |
| `runflow::flow::python_info VERSION [EXECUTABLE]` | everything about the version's Python, in `_RUNFLOW_FLOW_*` variables (see its comment) |
| `runflow::flow::find VERSION` | the same, without output: `_RUNFLOW_FLOW_FOUND`, or `_RUNFLOW_FLOW_PROBLEM` |
| `runflow::flow::list_versions` | the available versions |
