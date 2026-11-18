# Writing a Directive

A directive is a bash function `@NAME` in a module file that registers it.
Once loaded, it works:
- inline (`flowrun -c @NAME`) and in scripts;
- inside `@submit` jobs;
- in `flowrun -h`;
- optionally under `@mpi`.

The bundled [lib/extensions/flow.sh](../lib/extensions/flow.sh) and
[lib/extensions/flowpy.sh](../lib/extensions/flowpy.sh) are complete examples:
options, a setting, `@mpi` support, and helpers shared between modules.

## SYNOPSIS

```bash
#!/usr/bin/env bash
# ~/.config/flowrun/directives/hello.sh
flowrun::directive hello "[-n] [NAME]" "Say hello" "echo options for every @hello"
flowrun::directive_setting hello-greeting HELLO_GREETING "Greeting for every @hello"
flowrun::directive_option "-n" - "No newline at the end"   # for @help and Tab completion
flowrun::directive_arguments none

flowrun::command_hello() {                     # optional: makes @mpi @hello possible
  local flags=()
  [[ "${1:-}" == -n ]] && { flags=(-n); shift; }
  flowrun::directive_options hello || return 1 # --hello-options
  _FLOWRUN_ARGV=(echo "${flags[@]}" "${_FLOWRUN_WORDS[@]}" "${HELLO_GREETING:-hello}" "${1:-world}")
}

@hello() {
  flowrun::command_hello "$@" || return 1
  if flowrun::dry_run; then
    flowrun::dry "run: $(flowrun::quoted "${_FLOWRUN_ARGV[@]}")"
    return 0
  fi
  "${_FLOWRUN_ARGV[@]}"
}
```

Try it:

```bash
flowrun --directives ./hello.sh -c @hello you
flowrun --directives ./hello.sh -c @help @hello
flowrun --directives ./hello.sh --hello-greeting Hi --hello-options "-e" -c @hello 'you\n'
flowrun --directives ./hello.sh --dry-run -c @mpi -n 4 @hello you
flowrun --directives ./hello.sh -s localq -c @wait @submit @hello job
```

## LOADING

Modules load at startup in this order. A later module replaces a directive of
the same name, except a core one: replacing `@submit`, `@wait`, `@cancel`,
`@mpi` or `@help` is an error and is undone.

1. `lib/directives/*.sh` (core);
2. `lib/extensions/*.sh` (bundled: `@flow`, `@flowpy`);
3. each entry of `FLOWRUN_DIRECTIVE_PATH`, a `:`-separated list of directories
   or files (default `${XDG_CONFIG_HOME:-~/.config}/flowrun/directives`);
4. `flowrun --directives PATH` or `flowrun::use PATH`. These are added to
   `FLOWRUN_DIRECTIVE_PATH`, so jobs load them too.

The current directory is never searched. A module that fails to load is
reported and skipped. `FLOWRUN_DEBUG=true` shows which module replaced which.

## REGISTRATION

**`flowrun::directive NAME USAGE SUMMARY [OPTIONS]`**
Registers `@NAME` for `flowrun -h` and `@help`. NAME must not be a scheduler's name.

With OPTIONS, which describes them, the directive accepts `--NAME-options`.
Read them with `flowrun::directive_options NAME`, which leaves the words in
`_FLOWRUN_WORDS`, and place them before the call's own options. They come from
`FLOWRUN_<NAME>_OPTIONS`: the configuration's site defaults plus
`--NAME-options`. For example, `my-tool` uses `FLOWRUN_MY_TOOL_OPTIONS`.

**`flowrun::directive_option "NAMES [VALUE]" KIND DESCRIPTION`**
Describes an option of the directive registered last, for `@help @NAME`
and Tab completion; the directive still parses its arguments
itself. NAMES are comma-separated spellings (`"-v, --flow-version VERSION"`); KIND
is how its value is completed: `version` (a Flow version), `deck`, `file`,
`job` (this run's job IDs), `scheduler`, `text` (not completed), or `-` for an
option without a value. A test checks that the bundled directives' options
appear in their man page section.

**`flowrun::directive_arguments KIND`**
What follows the options, for Tab completion: `deck`, `file`, `job`,
`command` (a program or a directive), `directive`, or `none`. Default: `file`.

**`flowrun::unknown_option NAME OPTION [HINT]`**
Reports an option `@NAME` does not take and returns 1. The message points to
`@help @NAME`.

**`flowrun::directive_setting OPTION VARIABLE DESCRIPTION [KIND]`**
Adds a setting `--OPTION VALUE` to the directive registered last; KIND as for
`flowrun::directive_option` (default `text`).
- `flowrun` and `flowrun::setup` accept it, and it sets and exports VARIABLE.
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
  `flowrun::error`.
- **Option strings:** split them with `flowrun::split_options STRING WHAT`,
  which honours quotes and expands nothing; it returns 1 on unbalanced
  quotes.
- **Output:** stdout carries data only; messages go to stderr.
- **Exit status:** return 0 on success, the program's own status, or 1 after
  an `flowrun::error`.
- **Names:** name helpers `NAME::...` and globals `NAME_...`. Define no
  `flowrun::` functions except `flowrun::command_NAME`; `flowrun::<extension>::`
  is reserved for the bundled extensions (e.g. `flowrun::flow::`).
- **Dry run:** when `flowrun::dry_run` is true, run nothing. Print what would
  run with `flowrun::dry "run: ..."` and return 0. Report problems that may
  be fixed by then (e.g. a file not yet created) with
  `flowrun::dry "warning: ..."`.
- **MPI:** to run under `@mpi`, define `flowrun::command_NAME`. It takes the
  directive's arguments and stores the program's command line in
  `_FLOWRUN_ARGV` without running it, because MPI launchers start programs,
  not functions. Build `@NAME` on it, as in the SYNOPSIS.
- **Jobs:** `@submit @NAME` runs `flowrun -n NP -c @NAME ...` on the compute
  node, so the module and its tools must be available there.

## HELPERS

| Helper | Purpose |
|---|---|
| `flowrun::directive`, `flowrun::directive_setting` | Registration (see above) |
| `flowrun::directive_options NAME` | Options for every `@NAME`, into `_FLOWRUN_WORDS` |
| `flowrun::split_options STRING [WHAT]` | Shell-style split into `_FLOWRUN_WORDS` |
| `flowrun::error`, `flowrun::warning`, `flowrun::info`, `flowrun::debug` | Messages on stderr (`debug` only with `FLOWRUN_DEBUG=true`) |
| `flowrun::dry_run`, `flowrun::dry MESSAGE` | Dry-run test and output |
| `flowrun::quoted ARG...` | Arguments shell-quoted on one line |
| `flowrun::use PATH...` | Load modules |

The `@flow` extension also provides the following helpers. Check with
`declare -F flowrun::flow::python_info` before using them:

| Helper | Returns |
|---|---|
| `flowrun::flow::resolve_version VERSION` | the Flow executable |
| `flowrun::flow::python_info VERSION [EXECUTABLE]` | everything about the version's Python, in `_FLOWRUN_FLOW_*` variables (see its comment) |
| `flowrun::flow::find VERSION` | the same, without output: `_FLOWRUN_FLOW_FOUND`, or `_FLOWRUN_FLOW_PROBLEM` |
| `flowrun::flow::list_versions` | the available versions |
