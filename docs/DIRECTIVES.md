# Writing a Directive

A directive is a bash function `@NAME` in a module file that registers it.
Once loaded, it works:
- inline (`opmexec -c @NAME`) and in scripts;
- inside `@submit` jobs;
- in `opmexec -h`;
- optionally under `@mpi`.

The bundled [lib/extensions/flow.sh](../lib/extensions/flow.sh) and
[lib/extensions/flowpy.sh](../lib/extensions/flowpy.sh) are complete examples:
options, a setting, `@mpi` support, and helpers shared between modules.

## SYNOPSIS

```bash
#!/usr/bin/env bash
# ~/.config/opmexec/directives/hello.sh
opmexec::directive hello "[-n] [NAME]" "Say hello" "echo options for every @hello"
opmexec::directive_setting hello-greeting HELLO_GREETING "Greeting for every @hello"
opmexec::directive_option "-n" - "No newline at the end"   # for @help and Tab completion
opmexec::directive_arguments none

opmexec::command_hello() {                     # optional: makes @mpi @hello possible
  local flags=()
  [[ "${1:-}" == -n ]] && { flags=(-n); shift; }
  opmexec::directive_options hello || return 1 # --hello-options
  _OPMEXEC_ARGV=(echo "${flags[@]}" "${_OPMEXEC_WORDS[@]}" "${HELLO_GREETING:-hello}" "${1:-world}")
}

@hello() {
  opmexec::command_hello "$@" || return 1
  if opmexec::dry_run; then
    opmexec::dry "run: $(opmexec::quoted "${_OPMEXEC_ARGV[@]}")"
    return 0
  fi
  "${_OPMEXEC_ARGV[@]}"
}
```

Try it:

```bash
opmexec --directives ./hello.sh -c @hello you
opmexec --directives ./hello.sh -c @help @hello
opmexec --directives ./hello.sh --hello-greeting Hi --hello-options "-e" -c @hello 'you\n'
opmexec --directives ./hello.sh --dry-run -c @mpi -n 4 @hello you
opmexec --directives ./hello.sh -s localq -c @wait @submit @hello job
```

## LOADING

Modules load at startup in this order. A later module replaces a directive of
the same name, except a core one: replacing `@submit`, `@wait`, `@cancel`,
`@mpi` or `@help` is an error and is undone.

1. `lib/directives/*.sh` (core);
2. `lib/extensions/*.sh` (bundled: `@flow`, `@flowpy`);
3. each entry of `OPMEXEC_DIRECTIVE_PATH`, a `:`-separated list of directories
   or files (default `${XDG_CONFIG_HOME:-~/.config}/opmexec/directives`);
4. `opmexec --directives PATH` or `opmexec::use PATH`. These are added to
   `OPMEXEC_DIRECTIVE_PATH`, so jobs load them too.

The current directory is never searched. A module that fails to load is
reported and skipped. `OPMEXEC_DEBUG=true` shows which module replaced which.

## REGISTRATION

**`opmexec::directive NAME USAGE SUMMARY [OPTIONS]`**
Registers `@NAME` for `opmexec -h` and `@help`. NAME must not be a scheduler's name.

With OPTIONS, which describes them, the directive accepts `--NAME-options`.
Read them with `opmexec::directive_options NAME`, which leaves the words in
`_OPMEXEC_WORDS`, and place them before the call's own options. They come from
`OPMEXEC_<NAME>_OPTIONS`: the configuration's site defaults plus
`--NAME-options`. For example, `my-tool` uses `OPMEXEC_MY_TOOL_OPTIONS`.

**`opmexec::directive_option "NAMES [VALUE]" KIND DESCRIPTION`**
Describes an option of the directive registered last, for `@help @NAME`
and Tab completion; the directive still parses its arguments
itself. NAMES are comma-separated spellings (`"-v, --flow-version VERSION"`); KIND
is how its value is completed: `version` (a Flow version), `deck`, `file`,
`job` (this run's job IDs), `scheduler`, `text` (not completed), or `-` for an
option without a value. A test checks that the bundled directives' options
appear in their man page section.

**`opmexec::directive_arguments KIND`**
What follows the options, for Tab completion: `deck`, `file`, `job`,
`command` (a program or a directive), `directive`, or `none`. Default: `file`.

**`opmexec::unknown_option NAME OPTION [HINT]`**
Reports an option `@NAME` does not take and returns 1. The message points to
`@help @NAME`.

**`opmexec::directive_setting OPTION VARIABLE DESCRIPTION [KIND]`**
Adds a setting `--OPTION VALUE` to the directive registered last; KIND as for
`opmexec::directive_option` (default `text`).
- `opmexec` and `opmexec::setup` accept it, and it sets and exports VARIABLE.
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
  `opmexec::error`.
- **Option strings:** split them with `opmexec::split_options STRING WHAT`,
  which honours quotes and expands nothing; it returns 1 on unbalanced
  quotes.
- **Output:** stdout carries data only; messages go to stderr.
- **Exit status:** return 0 on success, the program's own status, or 1 after
  an `opmexec::error`.
- **Names:** name helpers `NAME::...` and globals `NAME_...`. Define no
  `opmexec::` functions except `opmexec::command_NAME`; `opmexec::<extension>::`
  is reserved for the bundled extensions (e.g. `opmexec::flow::`).
- **Dry run:** when `opmexec::dry_run` is true, run nothing. Print what would
  run with `opmexec::dry "run: ..."` and return 0. Report problems that may
  be fixed by then (e.g. a file not yet created) with
  `opmexec::dry "warning: ..."`.
- **MPI:** to run under `@mpi`, define `opmexec::command_NAME`. It takes the
  directive's arguments and stores the program's command line in
  `_OPMEXEC_ARGV` without running it, because MPI launchers start programs,
  not functions. Build `@NAME` on it, as in the SYNOPSIS.
- **Jobs:** `@submit @NAME` runs `opmexec -n NP -c @NAME ...` on the compute
  node, so the module and its tools must be available there.

## HELPERS

| Helper | Purpose |
|---|---|
| `opmexec::directive`, `opmexec::directive_setting` | Registration (see above) |
| `opmexec::directive_options NAME` | Options for every `@NAME`, into `_OPMEXEC_WORDS` |
| `opmexec::split_options STRING [WHAT]` | Shell-style split into `_OPMEXEC_WORDS` |
| `opmexec::error`, `opmexec::warning`, `opmexec::info`, `opmexec::debug` | Messages on stderr (`debug` only with `OPMEXEC_DEBUG=true`) |
| `opmexec::dry_run`, `opmexec::dry MESSAGE` | Dry-run test and output |
| `opmexec::quoted ARG...` | Arguments shell-quoted on one line |
| `opmexec::use PATH...` | Load modules |

The `@flow` extension also provides the following helpers. Check with
`declare -F opmexec::flow::python_info` before using them:

| Helper | Returns |
|---|---|
| `opmexec::flow::resolve_version VERSION` | the Flow executable |
| `opmexec::flow::python_info VERSION [EXECUTABLE]` | everything about the version's Python, in `_OPMEXEC_FLOW_*` variables (see its comment) |
| `opmexec::flow::find VERSION` | the same, without output: `_OPMEXEC_FLOW_FOUND`, or `_OPMEXEC_FLOW_PROBLEM` |
| `opmexec::flow::list_versions` | the available versions |
