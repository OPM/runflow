#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# @flow - run OPM Flow, and the runflow::flow:: helpers that find a Flow
# version and its Python (bundled extension; a later directory in
# RUNFLOW_DIRECTIVE_PATH may replace it). @flowpy is in flowpy.sh.
#
# Settings: RUNFLOW_FLOW_BIN_PATHS, RUNFLOW_FLOW_VERSION,
# RUNFLOW_FLOW_PYTHONPATH, RUNFLOW_FLOW_PYTHON_MAP (see etc/defaults/runflow.conf)

runflow::directive flow "[-v VERSION] [FLOW_ARGUMENTS...]  |  -l [VERSION]  |  -w [VERSION]" \
  "Run Flow as one process, its arguments as for flow (-l: list versions, -w: the executable); with MPI: @mpi @flow" \
  "Flow options for every @flow, before the call's arguments"
runflow::directive_setting flow-version RUNFLOW_FLOW_VERSION \
  "Flow version for every @flow and @flowpy without -v (default: $RUNFLOW_FLOW_VERSION)" version
runflow::directive_option "-v, --flow-version VERSION" version \
  "Flow version: a path, a name in RUNFLOW_FLOW_VERSIONS, an executable in RUNFLOW_FLOW_BIN_PATHS, or a unique OPM version"
runflow::directive_option "-l, --list [VERSION]" version \
  "List the Flow versions with their build and Python (* the default); -l VERSION: everything about one"
runflow::directive_option "-w, --which [VERSION]" version \
  "Print the executable of a version (default: the default one), e.g. ldd \"\$(@flow -w)\""
runflow::directive_option "--" - \
  "End of @flow's options: the rest goes to Flow"
runflow::directive_arguments deck

# --- Finding Flow ----------------------------------------------------------

# Directories searched for Flow versions, one per line: RUNFLOW_FLOW_BIN_PATHS,
# where the entry PATH stands for the directories of $PATH at this moment (in
# a job: after RUNFLOW_JOB_SETUP, e.g. module loads). Relative entries (such
# as "" or "." in PATH) are skipped, so a deck directory never provides Flow.
runflow::flow::search_dirs() {
  local entry dir dirs seen=":"

  for entry in "${RUNFLOW_FLOW_BIN_PATHS[@]}"; do
    if [[ "$entry" == PATH ]]; then
      IFS=: read -ra dirs <<< "$PATH"
    else
      dirs=("$entry")
    fi
    for dir in "${dirs[@]}"; do
      [[ "$dir" == /* ]] || continue
      [[ "$dir" == / ]] || dir=${dir%/}
      [[ "$seen" == *":$dir:"* ]] && continue
      seen+="$dir:"
      echo "$dir"
    done
  done
}

# The OPM version of a Flow executable (e.g. 2025.04), from its --version
# ("flow 2025.04"), or "unknown" for OPM simulators without --version; returns
# 1 for other programs named flow (e.g. the JavaScript type checker).
runflow::flow::opm_version() {
  local exe="$1" output runner=()

  command -v timeout > /dev/null && runner=(timeout 30)
  output=$("${runner[@]}" "$exe" --version < /dev/null 2>&1)
  if [[ "$output" =~ (^|$'\n')flow[^[:space:]]*[[:space:]]+([0-9]{4}\.[0-9]{2}[^[:space:]]*) ]]; then
    echo "${BASH_REMATCH[2]}"
  elif [[ "$output" == *"[OPTIONS] [DECK_FILENAME]"* ]]; then
    # OPM simulators without --version (e.g. flow_comp, flowexp_*) answer
    # with the usage line of OPM's parameter system
    echo unknown
  else
    return 1
  fi
}

# The executable of one RUNFLOW_FLOW_VERSIONS item 'NAME=PATH' (PATH an
# executable or the directory holding flow, ~/ for HOME)
runflow::flow::entry_path() {
  local path=${1#*=}
  [[ "$path" != "~/"* ]] || path="$HOME/${path#"~/"}"
  [[ ! -d "$path" ]] || path="${path%/}/flow"
  echo "$path"
}

# A named version's executable, or nothing. The LAST item of a name wins, as
# a later configuration file wins: RUNFLOW_FLOW_VERSIONS+=('NAME=PATH') in a
# user's file redefines a site's NAME.
runflow::flow::named_path() {
  local i entry
  for (( i = ${#RUNFLOW_FLOW_VERSIONS[@]} - 1; i >= 0; i-- )); do
    entry=${RUNFLOW_FLOW_VERSIONS[i]}
    [[ "${entry%%=*}" == "$1" && "$entry" == *=* ]] || continue
    runflow::flow::entry_path "$entry"
    return 0
  done
  return 1
}

# Accept CANDIDATE if it is an executable OPM Flow: _RUNFLOW_FLOW_FOUND (its
# absolute path) and _RUNFLOW_FLOW_FOUND_VERSION (its OPM version); else
# _RUNFLOW_FLOW_PROBLEM is NOT_FOUND or NOT_OPM.
runflow::flow::accept() {
  local candidate="$1" not_found="$2" not_opm="$3"
  if [[ ! -f "$candidate" || ! -x "$candidate" ]]; then
    _RUNFLOW_FLOW_PROBLEM=$not_found
    return 1
  fi
  if ! _RUNFLOW_FLOW_FOUND_VERSION=$(runflow::flow::opm_version "$candidate"); then
    _RUNFLOW_FLOW_PROBLEM=$not_opm
    return 1
  fi
  [[ "$candidate" == */* ]] || candidate="./$candidate"
  _RUNFLOW_FLOW_FOUND="$(cd "${candidate%/*}" && pwd)/${candidate##*/}"
}

# Find the executable of Flow version SPEC, in this shell and without output:
# on success _RUNFLOW_FLOW_FOUND and _RUNFLOW_FLOW_FOUND_VERSION (see
# runflow::flow::accept), else _RUNFLOW_FLOW_PROBLEM. The first that applies:
#   1. a path (containing "/");
#   2. a name in RUNFLOW_FLOW_VERSIONS;
#   3. an executable flow<VERSION> or <VERSION> in the search directories
#      (the first OPM Flow found wins; other programs named flow are skipped);
#   4. an OPM version (e.g. 2025.04) reported by exactly one of the named
#      versions and the executables named flow in the search directories;
#      several: a problem listing them.
runflow::flow::find() {
  local spec="$1" dir candidate rejected=() matches=() seen=() known
  _RUNFLOW_FLOW_FOUND="" _RUNFLOW_FLOW_FOUND_VERSION="" _RUNFLOW_FLOW_PROBLEM=""

  if [[ "$spec" == */* ]]; then
    runflow::flow::accept "$spec" "Flow executable not found: $spec" \
      "Not OPM Flow: $spec (its --version names no OPM Flow version)"
    return
  fi
  if candidate=$(runflow::flow::named_path "$spec"); then
    runflow::flow::accept "$candidate" "Flow version $spec (RUNFLOW_FLOW_VERSIONS): executable not found: $candidate" \
      "Flow version $spec (RUNFLOW_FLOW_VERSIONS): not OPM Flow: $candidate"
    return
  fi

  while IFS= read -r dir; do
    for candidate in "$dir/flow$spec" "$dir/$spec"; do
      [[ -f "$candidate" && -x "$candidate" ]] || continue
      runflow::flow::accept "$candidate" "" "" && return 0
      rejected+=("$candidate")
    done
  done < <(runflow::flow::search_dirs)

  # By OPM version: never a guess among several builds
  if [[ "$spec" =~ ^[0-9]{4}\.[0-9]{2} ]]; then
    while IFS= read -r candidate; do
      [[ -f "$candidate" && -x "$candidate" ]] || continue
      for known in "${seen[@]}"; do
        [[ "$candidate" -ef "$known" ]] && continue 2
      done
      seen+=("$candidate")
      [[ "$(runflow::flow::opm_version "$candidate")" == "$spec" ]] && matches+=("$candidate")
    done < <(
      for candidate in "${RUNFLOW_FLOW_VERSIONS[@]}"; do
        runflow::flow::named_path "${candidate%%=*}"
      done
      runflow::flow::search_dirs | sed 's|$|/flow|'
    )
    if [[ ${#matches[@]} -eq 1 ]]; then
      runflow::flow::accept "${matches[0]}" "" ""
      return
    elif [[ ${#matches[@]} -gt 1 ]]; then
      _RUNFLOW_FLOW_PROBLEM="Flow version $spec is ambiguous: ${#matches[@]} builds report it; name one in RUNFLOW_FLOW_VERSIONS or give its path:"
      for candidate in "${matches[@]}"; do
        runflow::flow::build_info "$candidate"
        _RUNFLOW_FLOW_PROBLEM+=$'\n'"        $candidate ($(runflow::flow::build_summary))"
      done
      return 1
    fi
  fi

  _RUNFLOW_FLOW_PROBLEM="Flow version not found: $spec (searched RUNFLOW_FLOW_VERSIONS, then RUNFLOW_FLOW_BIN_PATHS: ${RUNFLOW_FLOW_BIN_PATHS[*]})${rejected[*]:+; not OPM Flow: ${rejected[*]}}"
  return 1
}

# Print the executable of Flow version SPEC (see runflow::flow::find), or an
# error
runflow::flow::resolve_version() {
  runflow::flow::find "$1" || { runflow::error "$_RUNFLOW_FLOW_PROBLEM"; return 1; }
  echo "$_RUNFLOW_FLOW_FOUND"
}

# --- Build information ----------------------------------------------------------

# What identifies a Flow build, into these variables ("" if unknown):
#   _RUNFLOW_FLOW_INFO_VERSION   OPM version, e.g. 2025.04 or 2027.04-pre
#   _RUNFLOW_FLOW_INFO_HASH      git hash; "*" marks local changes
#   _RUNFLOW_FLOW_INFO_BUILT     build time, YYYY-MM-DD HH:MM:SS
#   _RUNFLOW_FLOW_INFO_TYPE      build type, e.g. Release or Debug
#   _RUNFLOW_FLOW_INFO_MPI       MPI library, if Flow reports it
#   _RUNFLOW_FLOW_INFO_FROM      build-info (flow --build-info), probe, version
# Flow with --build-info reports them itself. Otherwise, once --version shows
# it is OPM Flow, it is probed: run on a one-line deck in a temporary
# directory, Flow writes the header of its log (version, hash, build time)
# before rejecting the deck. The build type then comes from a bin/<CONFIG>
# directory, the build tree's CMakeCache.txt, or the hash "debug" of OPM's
# Debug builds. Returns 1 if EXECUTABLE is not OPM Flow.
runflow::flow::build_info() {
  local exe="$1" output line key value runner=() tmp dir cache
  _RUNFLOW_FLOW_INFO_VERSION="" _RUNFLOW_FLOW_INFO_HASH="" _RUNFLOW_FLOW_INFO_BUILT=""
  _RUNFLOW_FLOW_INFO_TYPE="" _RUNFLOW_FLOW_INFO_MPI="" _RUNFLOW_FLOW_INFO_FROM=""
  command -v timeout > /dev/null && runner=(timeout 30)

  output=$("${runner[@]}" "$exe" --build-info < /dev/null 2> /dev/null)
  if [[ "$output" == version=* || "$output" == *$'\n'version=* ]]; then
    while IFS='=' read -r key value; do
      case "$key" in
        version) _RUNFLOW_FLOW_INFO_VERSION=$value ;;
        hash) _RUNFLOW_FLOW_INFO_HASH=$value ;;
        build_time) _RUNFLOW_FLOW_INFO_BUILT=$value ;;
        build_type) _RUNFLOW_FLOW_INFO_TYPE=$value ;;
        mpi) _RUNFLOW_FLOW_INFO_MPI=$value ;;
      esac
    done <<< "$output"
    _RUNFLOW_FLOW_INFO_FROM=build-info
  else
    _RUNFLOW_FLOW_INFO_VERSION=$(runflow::flow::opm_version "$exe") || return 1
    _RUNFLOW_FLOW_INFO_FROM=version
  fi
  if [[ "$_RUNFLOW_FLOW_INFO_FROM" == version ]] &&
     tmp=$(mktemp -d "${TMPDIR:-/tmp}/runflow-probe.XXXXXX" 2> /dev/null); then
    printf 'RUNSPEC\n' > "$tmp/PROBE.DATA"
    ( cd "$tmp" && "${runner[@]}" "$exe" --output-dir="$tmp" PROBE.DATA < /dev/null > /dev/null 2>&1 )
    line=$(grep -h -m 1 '^Flow Version *= ' "$tmp/PROBE.PRT" "$tmp/PROBE.DBG" 2> /dev/null | head -n 1)
    if [[ "$line" =~ =\ +([^ ]+)\ +\((.*)\) ]]; then
      _RUNFLOW_FLOW_INFO_VERSION=${BASH_REMATCH[1]}
      _RUNFLOW_FLOW_INFO_HASH=${BASH_REMATCH[2]}
      line=$(grep -h -m 1 '^Build time *= ' "$tmp/PROBE.PRT" "$tmp/PROBE.DBG" 2> /dev/null | head -n 1)
      _RUNFLOW_FLOW_INFO_BUILT=${line#*=  }
      _RUNFLOW_FLOW_INFO_FROM=probe
    fi
    rm -rf -- "$tmp"
  fi

  # "2026-10-16 at 01:11:27 hrs" -> "2026-10-16 01:11:27"
  value=${_RUNFLOW_FLOW_INFO_BUILT% hrs}
  _RUNFLOW_FLOW_INFO_BUILT=${value/ at / }

  if [[ -z "$_RUNFLOW_FLOW_INFO_TYPE" ]]; then
    dir=${exe%/*}
    case "${dir##*/}" in
      Debug|Release|RelWithDebInfo|MinSizeRel) _RUNFLOW_FLOW_INFO_TYPE=${dir##*/} ;;
      *)
        cache=$(runflow::flow::cmake_cache "$dir")
        [[ -z "$cache" ]] || _RUNFLOW_FLOW_INFO_TYPE=$(sed -n 's/^CMAKE_BUILD_TYPE:[A-Z]*=//p' "$cache" | head -n 1)
        ;;
    esac
    [[ -n "$_RUNFLOW_FLOW_INFO_TYPE" || "$_RUNFLOW_FLOW_INFO_HASH" != debug ]] || _RUNFLOW_FLOW_INFO_TYPE=Debug
  fi
}

# The MPI library (if Flow did not report it) and the build ID (unique per
# binary) of executable EXE, for the details of a version:
# _RUNFLOW_FLOW_INFO_MPI, _RUNFLOW_FLOW_INFO_BUILD_ID
runflow::flow::build_details() {
  local exe="$1" output
  _RUNFLOW_FLOW_INFO_BUILD_ID=""
  if [[ -z "$_RUNFLOW_FLOW_INFO_MPI" ]] && command -v ldd > /dev/null; then
    output=$(ldd "$exe" 2> /dev/null)
    case "$output" in
      *libmpi.so.40*|*openmpi*) _RUNFLOW_FLOW_INFO_MPI="Open MPI" ;;
      *intel*libmpi*|*libmpi*intel*) _RUNFLOW_FLOW_INFO_MPI="Intel MPI" ;;
      *libmpich*|*libmpi.so.12*) _RUNFLOW_FLOW_INFO_MPI="MPICH" ;;
      *libmpi*) _RUNFLOW_FLOW_INFO_MPI="MPI" ;;
    esac
  fi

  if command -v readelf > /dev/null; then
    _RUNFLOW_FLOW_INFO_BUILD_ID=$(readelf -n "$exe" 2> /dev/null | sed -n 's/^ *Build ID: *//p' | head -n 1)
  elif command -v file > /dev/null; then
    output=$(file -b "$exe" 2> /dev/null)
    [[ "$output" =~ BuildID\[[a-z0-9]+\]=([0-9a-f]+) ]] && _RUNFLOW_FLOW_INFO_BUILD_ID=${BASH_REMATCH[1]}
  fi
  if [[ -z "$_RUNFLOW_FLOW_INFO_BUILD_ID" ]] && command -v otool > /dev/null; then
    _RUNFLOW_FLOW_INFO_BUILD_ID=$(otool -l "$exe" 2> /dev/null | awk '$1 == "uuid" { print $2; exit }')
  fi
  return 0
}

# One line about the build of the last runflow::flow::build_info, e.g.
# "2027.04-pre (c375a47c1*), Release, built 2026-10-16 01:11:27"
runflow::flow::build_summary() {
  local summary=$_RUNFLOW_FLOW_INFO_VERSION
  [[ -z "$_RUNFLOW_FLOW_INFO_HASH" ]] || summary+=" ($_RUNFLOW_FLOW_INFO_HASH)"
  [[ -z "$_RUNFLOW_FLOW_INFO_TYPE" ]] || summary+=", $_RUNFLOW_FLOW_INFO_TYPE"
  [[ -z "$_RUNFLOW_FLOW_INFO_BUILT" ]] || summary+=", built $_RUNFLOW_FLOW_INFO_BUILT"
  echo "$summary"
}

# --- Python of a Flow version -------------------------------------------------
#
# A Flow version may use Python in two ways: embedded (PYACTION; Flow is linked
# against libpython) and through its opm bindings (opm.io, opm.simulators: a
# Python extension module built for one Python version). Both must match:
# @flow sets PYTHONPATH to the bindings when Flow embeds Python, and @flowpy
# runs the Python the bindings were built for.

# Configured Python version of a Flow version (RUNFLOW_FLOW_PYTHON_MAP), or
# nothing
runflow::flow::python_map() {
  local version="$1" pattern i

  # The last matching item wins, as for RUNFLOW_FLOW_VERSIONS: += in a later
  # configuration file adds or overrides
  for (( i = ${#RUNFLOW_FLOW_PYTHON_MAP[@]} - 1; i >= 0; i-- )); do
    pattern=${RUNFLOW_FLOW_PYTHON_MAP[i]}
    # shellcheck disable=SC2053  # pattern match on purpose
    if [[ "$version" == ${pattern%:*} ]]; then
      echo "${pattern##*:}"
      return 0
    fi
  done
}

# The libpython in "ldd" (Linux) or "otool -L" (macOS) output on stdin, as
# "VERSION PATH" (PATH empty if not resolved), or nothing
runflow::flow::parse_libpython() {
  local line word words

  while IFS= read -r line; do
    [[ "$line" =~ libpython(3\.[0-9]+[a-z]*)|Python\.framework/Versions/(3\.[0-9]+[a-z]*)/ ]] || continue
    read -ra words <<< "$line"
    for word in "${words[@]}"; do
      if [[ "$word" == /* ]]; then
        echo "${BASH_REMATCH[1]:-${BASH_REMATCH[2]}} $word"
        return 0
      fi
    done
    echo "${BASH_REMATCH[1]:-${BASH_REMATCH[2]}}"
    return 0
  done
}

# The libpython a Flow executable is linked against (see
# runflow::flow::parse_libpython). ldd includes libraries loaded through other
# libraries (e.g. libopmcommon.so); otool -L lists the executable's own only.
runflow::flow::libpython() {
  local exe="$1"

  if command -v ldd > /dev/null; then
    ldd "$exe" 2> /dev/null | runflow::flow::parse_libpython
  elif command -v otool > /dev/null; then
    otool -L "$exe" 2> /dev/null | runflow::flow::parse_libpython
  fi
}

# The compiled module of opm bindings in DIR (a directory containing opm/) and
# the Python it was built for, from its name, as "VERSION MODULE":
# opmcommon_python.cpython-313-...so: 3.13; cpython-313t (free-threaded):
# 3.13t; cpython-313d (debug): 3.13d. VERSION is "-" for an untagged module.
# Prints nothing if there is no compiled module.
runflow::flow::bindings_python() {
  local dir="$1" module tag

  for module in "$dir/opm/opmcommon_python.cpython-"*.so "$dir/opm/opmcommon_python"*.so; do
    [[ -f "$module" ]] || continue
    tag=${module##*/}
    if [[ "$tag" =~ \.cpython-([0-9])([0-9]+)([a-z]*)- ]]; then
      echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}${BASH_REMATCH[3]} $module"
    else
      echo "- $module"   # untagged (e.g. .so or .abi3.so): any Python 3
    fi
    return 0
  done
}

# Can INTERPRETER import extension MODULE? Python imports only modules whose
# suffix (.cpython-313-x86_64-linux-gnu.so, .abi3.so, .so) is one of its own
# importlib.machinery.EXTENSION_SUFFIXES.
runflow::flow::module_loadable() {
  local interpreter="$1" module="${2##*/}" suffix
  module=".${module#*.}"
  while IFS= read -r suffix; do
    [[ "$suffix" == "$module" ]] && return 0
  done < <("$interpreter" -c 'import importlib.machinery as m; print("\n".join(m.EXTENSION_SUFFIXES))' 2> /dev/null)
  return 1
}

# Bindings of an installed Flow: <prefix>/lib{,64}/python3.X/{site,dist}-packages
# next to <prefix>/bin/flow, preferring Python version PYTHON if given.
# Prints the directory.
runflow::flow::installed_bindings() {
  local prefix="$1" python="${2:-}" dir found=""

  for dir in "$prefix"/lib/python3*/{site,dist}-packages "$prefix"/lib64/python3*/{site,dist}-packages; do
    [[ -d "$dir/opm" ]] || continue
    if [[ -z "$python" || "$dir" == */python$python/* ]]; then
      echo "$dir"
      return 0
    fi
    found=${found:-$dir}
  done
  [[ -z "$found" ]] || echo "$found"
}

# The CMakeCache.txt of the build tree holding DIR (DIR or up to three
# directories above), or nothing
runflow::flow::cmake_cache() {
  local dir="$1" level
  for level in 1 2 3 4; do
    if [[ -f "$dir/CMakeCache.txt" ]]; then
      echo "$dir/CMakeCache.txt"
      return 0
    fi
    dir=$(dirname "$dir")
  done
}

# Bindings of a Flow in a CMake build tree: the CMakeCache.txt above the
# executable names the opm-common build (opm-common_DIR), whose python/ holds
# opm.io; the build's own python/ holds opm.simulators. Multi-config builds
# (e.g. Ninja Multi-Config) have one python/<CONFIG>/ per configuration: the
# one of the executable's directory (bin/Debug/flow: Debug). Prints them as a
# PYTHONPATH (opm-common first).
runflow::flow::build_tree_bindings() {
  local dir="$1" config cache="" common="" entries=() entry python

  config=$(basename "$dir")
  cache=$(runflow::flow::cmake_cache "$dir")
  [[ -n "$cache" ]] || return 0
  dir=$(dirname "$cache")

  common=$(sed -n 's/^opm-common_DIR:[A-Z]*=//p' "$cache" | head -n 1)
  if [[ -z "$common" ]] && grep -q '^CMAKE_PROJECT_NAME:STATIC=opm-common$' "$cache"; then
    common="$dir"
  fi

  for entry in "$common" "$dir"; do
    [[ -n "$entry" ]] || continue
    if [[ -d "$entry/python/$config/opm" ]]; then
      python="$entry/python/$config"
    elif [[ -d "$entry/python/opm" ]]; then
      python="$entry/python"
    else
      continue
    fi
    [[ " ${entries[*]} " == *" $python "* ]] || entries+=("$python")
  done
  (IFS=:; echo "${entries[*]}")
}

# Python interpreter for Python version PYTHON: the one installed with the
# libpython Flow is linked against (LIBPYTHON, e.g. /opt/python/3.11/lib/...
# -> /opt/python/3.11/bin/python3.11), else python3.X in PATH, else python3 if
# it is that version. Never a different version. Prints nothing if none.
runflow::flow::find_interpreter() {
  local python="$1" libpython="${2:-}" candidate in_path

  in_path=$(command -v "python$python")
  if [[ -n "$libpython" ]]; then
    candidate="$(dirname "$libpython")"
    candidate="${candidate%/lib*}/bin/python$python"
    # The same file in PATH (e.g. /bin and /usr/bin) is shown as in PATH
    if [[ -x "$candidate" && ! "$candidate" -ef "$in_path" ]]; then
      echo "$candidate"
      return 0
    fi
  fi
  if [[ -n "$in_path" ]]; then
    echo "$in_path"
    return 0
  fi
  if candidate=$(command -v python3) &&
     [[ "$("$candidate" -c 'import sys; print("%d.%d%s" % (sys.version_info[0], sys.version_info[1], sys.abiflags))' 2> /dev/null)" == "$python" ]]; then
    echo "$candidate"
  fi
}

# Everything about the Python of a Flow version, into these variables:
#   _RUNFLOW_FLOW_EXE          the executable ("" if not found)
#   _RUNFLOW_FLOW_LIBPYTHON    "VERSION PATH" of the embedded Python, or ""
#   _RUNFLOW_FLOW_PYTHON       Python version, e.g. 3.13 or 3.13t, or ""
#   _RUNFLOW_FLOW_PYTHON_FROM  where it came from: map, bindings, libpython
#   _RUNFLOW_FLOW_BINDINGS     PYTHONPATH entries of the opm bindings, or ""
#   _RUNFLOW_FLOW_MODULE       the bindings' compiled module, or ""
#   _RUNFLOW_FLOW_MODULE_PYTHON  the Python it was built for, or "" (untagged)
#   _RUNFLOW_FLOW_INTERPRETER  the Python interpreter, or ""
# The configuration wins over detection: RUNFLOW_FLOW_PYTHON_MAP for the
# version, a template in RUNFLOW_FLOW_PYTHONPATH for the bindings.
# Usage: runflow::flow::python_info VERSION EXECUTABLE (empty: not found)
runflow::flow::python_info() {
  local version="$1" exe="${2:-}" setting="${RUNFLOW_FLOW_PYTHONPATH:-}" bindings="" from="" module="" python prefix

  _RUNFLOW_FLOW_EXE="$exe"
  _RUNFLOW_FLOW_LIBPYTHON=""
  [[ -z "$exe" ]] || _RUNFLOW_FLOW_LIBPYTHON=$(runflow::flow::libpython "$exe")

  python=$(runflow::flow::python_map "$version")
  [[ -z "$python" ]] || from=map

  if [[ "$setting" == auto && -n "$exe" ]]; then
    prefix="$(cd "$(dirname "$exe")" && pwd)"
    if [[ "$prefix" == */bin ]]; then
      # Several Pythons' bindings: the configured one, else the embedded one
      bindings=$(runflow::flow::installed_bindings "${prefix%/bin}" "${python:-${_RUNFLOW_FLOW_LIBPYTHON%% *}}")
    fi
    [[ -n "$bindings" ]] || bindings=$(runflow::flow::build_tree_bindings "$prefix")
    # Only bindings with their compiled module count (a build tree may hold
    # empty package directories for a configuration built without Python)
    [[ -z "$bindings" ]] || module=$(runflow::flow::bindings_python "${bindings%%:*}")
    if [[ -z "$module" ]]; then
      bindings=""
    elif [[ -z "$python" && "${module%% *}" != - ]]; then
      python=${module%% *}
      from=bindings
    fi
  elif [[ "$setting" != auto && -n "$setting" ]]; then
    bindings=$setting
  fi

  if [[ -z "$python" && -n "$_RUNFLOW_FLOW_LIBPYTHON" ]]; then
    python=${_RUNFLOW_FLOW_LIBPYTHON%% *}
    from=libpython
  fi

  # Template: {version}, {python}, {prefix} (the directory above Flow's bin/)
  if [[ -n "$bindings" && "$setting" != auto ]]; then
    prefix="$(dirname "$(dirname "${exe:-/bin/flow}")")"
    bindings=${bindings//\{version\}/$version}
    bindings=${bindings//\{python\}/${python:-3}}
    bindings=${bindings//\{prefix\}/$prefix}
    module=$(runflow::flow::bindings_python "${bindings%%:*}")
  fi

  _RUNFLOW_FLOW_PYTHON="$python"
  _RUNFLOW_FLOW_PYTHON_FROM="$from"
  _RUNFLOW_FLOW_BINDINGS="$bindings"
  _RUNFLOW_FLOW_MODULE="${module#* }"
  _RUNFLOW_FLOW_MODULE_PYTHON="${module%% *}"
  [[ "$_RUNFLOW_FLOW_MODULE_PYTHON" != - ]] || _RUNFLOW_FLOW_MODULE_PYTHON=""
  _RUNFLOW_FLOW_INTERPRETER=""
  if [[ -n "$python" ]]; then
    local libpython_path=""
    [[ "$_RUNFLOW_FLOW_LIBPYTHON" == "$python "* ]] && libpython_path=${_RUNFLOW_FLOW_LIBPYTHON#* }
    _RUNFLOW_FLOW_INTERPRETER=$(runflow::flow::find_interpreter "$python" "$libpython_path")
  elif [[ "$setting" != auto ]]; then
    # Nothing known and no detection: the default python3
    _RUNFLOW_FLOW_INTERPRETER=$(command -v python3)
  fi
}

# Does the Python Flow embeds differ from the one its bindings were built for
# (from the last runflow::flow::python_info)? Then PYACTION cannot import
# them. Without a tagged module, the version in use is compared instead.
runflow::flow::embedded_mismatch() {
  local embedded=${_RUNFLOW_FLOW_LIBPYTHON%% *}
  [[ -n "$embedded" ]] || return 1
  [[ "$embedded" != "${_RUNFLOW_FLOW_MODULE_PYTHON:-${_RUNFLOW_FLOW_PYTHON:-$embedded}}" ]]
}

# One line about the Python of the last runflow::flow::python_info
runflow::flow::python_summary() {
  local summary

  if [[ -z "$_RUNFLOW_FLOW_PYTHON" && -z "$_RUNFLOW_FLOW_BINDINGS" ]]; then
    echo "no python"
    return
  fi
  summary="python ${_RUNFLOW_FLOW_PYTHON:-?}"
  [[ -z "$_RUNFLOW_FLOW_PYTHON_FROM" ]] || summary+=" (from $_RUNFLOW_FLOW_PYTHON_FROM)"
  if runflow::flow::embedded_mismatch; then
    summary+=", embedded ${_RUNFLOW_FLOW_LIBPYTHON%% *} (mismatch)"
  elif [[ -n "$_RUNFLOW_FLOW_LIBPYTHON" ]]; then
    summary+=", embedded"
  else
    summary+=", not embedded"
  fi
  summary+=", opm bindings: ${_RUNFLOW_FLOW_BINDINGS:-not found}"
  echo "$summary"
}

# The Python of the last runflow::flow::python_info, short: "3.13 embedded",
# "3.13" (bindings only), "?" (bindings, version unknown), "-" (none); a
# mismatch names the bindings' version. Never empty (a column of a table).
runflow::flow::python_short() {
  local short
  if [[ -z "$_RUNFLOW_FLOW_PYTHON" && -z "$_RUNFLOW_FLOW_BINDINGS" ]]; then
    echo -
    return
  fi
  short=${_RUNFLOW_FLOW_LIBPYTHON%% *}
  short=${short:-${_RUNFLOW_FLOW_PYTHON:-?}}
  [[ -z "$_RUNFLOW_FLOW_LIBPYTHON" ]] || short+=" embedded"
  if runflow::flow::embedded_mismatch; then
    short+=" (bindings ${_RUNFLOW_FLOW_MODULE_PYTHON:-$_RUNFLOW_FLOW_PYTHON})"
  elif [[ -n "$_RUNFLOW_FLOW_LIBPYTHON" && -z "$_RUNFLOW_FLOW_BINDINGS" ]]; then
    short+=" (no bindings)"
  fi
  echo "$short"
}

# List the Flow versions: the named ones (RUNFLOW_FLOW_VERSIONS), then the
# executables flow* of each search directory, one line each with the OPM
# version, hash, build type, build time and Python. A name found again in a
# later directory is shadowed: the first one is used. The executables are
# examined in parallel, a batch of one per CPU at a time.
# With VERSION: everything about that version (runflow::flow::version_details).
runflow::flow::list_versions() {
  if [[ $# -gt 0 ]]; then
    runflow::flow::version_details "$1"
    return
  fi

  local dir exe entry i batch result fields=() rows=() groups=() names=() exes=() found=false
  local -A first=()

  local -A last=()   # name -> index of its last item, the one used
  for i in "${!RUNFLOW_FLOW_VERSIONS[@]}"; do
    entry=${RUNFLOW_FLOW_VERSIONS[i]}
    [[ "$entry" == *=* ]] || continue
    groups+=("Named versions (RUNFLOW_FLOW_VERSIONS)")
    names+=("${entry%%=*}")
    exes+=("$(runflow::flow::entry_path "$entry")")
    last[${entry%%=*}]=$(( ${#exes[@]} - 1 ))
  done
  while IFS= read -r dir; do
    for exe in "$dir"/flow*; do
      [[ -f "$exe" && -x "$exe" ]] || continue
      groups+=("$dir")
      names+=("${exe##*/}")
      exes+=("$exe")
    done
  done < <(runflow::flow::search_dirs)

  # One "INDEX<TAB>RESULT" line per executable: "-" for programs that are not
  # OPM Flow, else VERSION, HASH, TYPE, BUILT and PYTHON separated by tabs
  local results=()
  batch=$(getconf _NPROCESSORS_ONLN 2> /dev/null) || batch=4
  while IFS=$'\t' read -r i result; do
    results[i]=$result
  done < <(
    for i in "${!exes[@]}"; do
      (
        exe=${exes[i]}
        # A name's earlier items are not used: not probed
        [[ "${groups[i]}" == /* || "${last[${names[i]}]}" == "$i" ]] || exit
        [[ -f "$exe" && -x "$exe" ]] || { printf '%s\t!\n' "$i"; exit; }
        if runflow::flow::build_info "$exe"; then
          runflow::flow::python_info "${names[i]}" "$exe"
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$_RUNFLOW_FLOW_INFO_VERSION" "${_RUNFLOW_FLOW_INFO_HASH:--}" \
            "${_RUNFLOW_FLOW_INFO_TYPE:--}" "${_RUNFLOW_FLOW_INFO_BUILT:--}" "$(runflow::flow::python_short)"
        else
          printf '%s\t-\n' "$i"
        fi
      ) &
      (( (i + 1) % batch )) || wait
    done
    wait
  )

  # Rows: GROUP, NAME, then the fields or a note; the last item of a name in
  # RUNFLOW_FLOW_VERSIONS, and the first OPM Flow of each name in the search
  # directories, are used. "*" before the name marks the
  # default version (RUNFLOW_FLOW_VERSION).
  local default="" marked=false
  runflow::flow::find "$RUNFLOW_FLOW_VERSION" && default=$_RUNFLOW_FLOW_FOUND
  for i in "${!exes[@]}"; do
    result=${results[i]:--}
    if [[ "${groups[i]}" != /* && "${last[${names[i]}]}" != "$i" ]]; then
      result="redefined by a later item (or configuration file): ${exes[i]}"
    elif [[ "$result" == '!' ]]; then
      result="executable not found: ${exes[i]}"
    elif [[ "$result" == - ]]; then
      result="not OPM Flow, ignored"
    elif [[ "${groups[i]}" == /* && -n "${first[${names[i]}]:-}" ]]; then
      result="shadowed by ${first[${names[i]}]}"

    else
      found=true
      [[ "${groups[i]}" != /* ]] || first[${names[i]}]=${exes[i]}
      [[ "${groups[i]}" == /* ]] || result+=$'\t'"${exes[i]}"
      if ! $marked && [[ -n "$default" && "${exes[i]}" -ef "$default" ]]; then
        names[i]="*${names[i]}"
        marked=true
      fi
    fi
    rows+=("${groups[i]}"$'\t'"${names[i]}"$'\t'"$result")
  done

  if ! $found; then
    runflow::error "No OPM Flow found (RUNFLOW_FLOW_VERSIONS, then RUNFLOW_FLOW_BIN_PATHS: ${RUNFLOW_FLOW_BIN_PATHS[*]})"
    return 1
  fi
  runflow::flow::print_table "${rows[@]}"
  ! $marked || echo "* the default (RUNFLOW_FLOW_VERSION=$RUNFLOW_FLOW_VERSION)"
}

# Print the rows of runflow::flow::list_versions under their group headings,
# the columns aligned; a row with a note instead of fields keeps the note
runflow::flow::print_table() {
  local row group current="" widths=(4 7 4 4 5 6) cols i line mark
  for row in "$@"; do
    IFS=$'\t' read -ra cols <<< "${row#*$'\t'}"
    [[ ${#cols[@]} -ge 6 ]] || cols=("${cols[0]}")
    cols[0]=${cols[0]#\*}
    for i in "${!cols[@]}"; do
      (( i < 6 && ${#cols[i]} > widths[i] )) && widths[i]=${#cols[i]}
    done
  done

  printf '   %-*s  %-*s  %-*s  %-*s  %-*s  %s\n' "${widths[0]}" NAME "${widths[1]}" VERSION \
    "${widths[2]}" HASH "${widths[3]}" TYPE "${widths[4]}" BUILT PYTHON
  for row in "$@"; do
    group=${row%%$'\t'*}
    [[ "$group" == "$current" ]] || { current=$group; echo "$group"; }
    IFS=$'\t' read -ra cols <<< "${row#*$'\t'}"
    mark=" "
    [[ "${cols[0]}" != \** ]] || { mark="*"; cols[0]=${cols[0]#\*}; }
    if [[ ${#cols[@]} -lt 6 ]]; then
      printf '   %-*s  %s\n' "${widths[0]}" "${cols[0]}" "${cols[*]:1}"
      continue
    fi
    line=$(printf ' %s %-*s  %-*s  %-*s  %-*s  %-*s  %s' "$mark" "${widths[0]}" "${cols[0]}" "${widths[1]}" "${cols[1]}" \
      "${widths[2]}" "${cols[2]}" "${widths[3]}" "${cols[3]}" "${widths[4]}" "${cols[4]}" "${cols[5]}")
    [[ ${#cols[@]} -lt 7 ]] || line=$(printf '%-*s  %s' $(( ${#line} - ${#cols[5]} + widths[5] )) "$line" "${cols[6]}")
    echo "$line"
  done
}

# Everything about Flow version VERSION: executable, build, MPI, Python
runflow::flow::version_details() {
  local version="$1" exe
  exe=$(runflow::flow::resolve_version "$version") || return 1
  runflow::flow::build_info "$exe" || return 1
  runflow::flow::build_details "$exe"
  runflow::flow::python_info "$version" "$exe"
  printf 'Flow %s\n' "$version"
  printf '  %-12s %s\n' \
    Executable "$exe" \
    "OPM version" "$_RUNFLOW_FLOW_INFO_VERSION" \
    "Git hash" "${_RUNFLOW_FLOW_INFO_HASH:--}${_RUNFLOW_FLOW_INFO_HASH:+$( [[ "$_RUNFLOW_FLOW_INFO_HASH" == *\* ]] && echo ' (built with local changes)')}" \
    "Build type" "${_RUNFLOW_FLOW_INFO_TYPE:--}" \
    Built "${_RUNFLOW_FLOW_INFO_BUILT:--}" \
    MPI "${_RUNFLOW_FLOW_INFO_MPI:--}" \
    "Build ID" "${_RUNFLOW_FLOW_INFO_BUILD_ID:--}" \
    Python "$(runflow::flow::python_summary)" \
    Interpreter "${_RUNFLOW_FLOW_INTERPRETER:--}" \
    Source "$(case "$_RUNFLOW_FLOW_INFO_FROM" in
                build-info) echo "flow --build-info" ;;
                probe) echo "Flow's log header (this Flow has no --build-info)" ;;
                *) echo "flow --version only" ;;
              esac)"
}

# --- @flow ------------------------------------------------------------------

# Build the command line of @flow into _RUNFLOW_ARGV, without running it.
# Shared by @flow and @mpi (MPI launchers start programs, not shell functions).
runflow::command_flow() {
  local version argument arguments=()
  _RUNFLOW_ARGV=()

  # @flow's own options (Flow uses none of them); everything else is Flow's
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--flow-version) runflow::has_value @flow "$@" || return 1; version="$2"; shift 2 ;;
      -n|--np)
        runflow::error "@flow: no -n option; to run Flow with MPI: @mpi -n ${2:-N} @flow ..."
        return 1
        ;;
      -l|--list|-w|--which) runflow::error "@flow: $1 works on its own: @flow $1 [VERSION]"; return 1 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  # Decks (arguments naming a .DATA file) are made absolute: jobs and MPI
  # ranks may start elsewhere
  for argument in "$@"; do
    if [[ "$argument" != -* && "${argument^^}" == *.DATA ]]; then
      if [[ -f "$argument" ]]; then
        argument="$(cd "$(dirname "$argument")" && pwd)/$(basename "$argument")"
      else
        runflow::dry_run || { runflow::error "Input deck not found: $argument"; return 1; }
        runflow::dry "warning: input deck not found (yet?): $argument"
      fi
    fi
    arguments+=("$argument")
  done
  set -- "${arguments[@]}"

  version=${version:-$RUNFLOW_FLOW_VERSION}

  # The executable, and for the record (the terminal, or the job's log)
  # which Flow runs; @flow -l VERSION shows the build in detail
  local flow_exe resolved_exe="" environment=()
  if runflow::flow::find "$version"; then
    flow_exe=$_RUNFLOW_FLOW_FOUND resolved_exe=$_RUNFLOW_FLOW_FOUND
    if runflow::dry_run; then
      runflow::dry "flow $version: $flow_exe (OPM $_RUNFLOW_FLOW_FOUND_VERSION)"
    else
      runflow::info "@flow: flow $version: $flow_exe (OPM $_RUNFLOW_FLOW_FOUND_VERSION)"
    fi
  else
    runflow::dry_run || { runflow::error "$_RUNFLOW_FLOW_PROBLEM"; return 1; }
    runflow::dry "warning: $_RUNFLOW_FLOW_PROBLEM"
    flow_exe="UNRESOLVED_FLOW_$version"
  fi

  # PYTHONPATH (set on the command via env, not exported here): a configured
  # template always; detected bindings when Flow embeds Python (PYACTION)
  runflow::flow::python_info "$version" "$resolved_exe"
  if [[ -n "$_RUNFLOW_FLOW_BINDINGS" ]] &&
     [[ "$RUNFLOW_FLOW_PYTHONPATH" != auto || -n "$_RUNFLOW_FLOW_LIBPYTHON" ]]; then
    environment=(env "PYTHONPATH=$_RUNFLOW_FLOW_BINDINGS${PYTHONPATH:+:$PYTHONPATH}")
    runflow::dry_run && runflow::dry "flow $version: $(runflow::flow::python_summary)"
    if runflow::flow::embedded_mismatch; then
      local mismatch="flow $version embeds Python ${_RUNFLOW_FLOW_LIBPYTHON%% *}, but its opm bindings are for Python ${_RUNFLOW_FLOW_MODULE_PYTHON:-$_RUNFLOW_FLOW_PYTHON} (PYACTION will fail; see RUNFLOW_FLOW_PYTHONPATH, RUNFLOW_FLOW_PYTHON_MAP)"
      if runflow::dry_run; then
        runflow::dry "warning: $mismatch"
      else
        runflow::warning "@flow: $mismatch"
      fi
    fi
  elif [[ -n "$_RUNFLOW_FLOW_LIBPYTHON" ]]; then
    runflow::dry_run && runflow::dry "warning: flow $version embeds Python, but its opm bindings were not found (PYACTION will fail; see RUNFLOW_FLOW_PYTHONPATH)"
  fi

  # Options for every @flow (configuration, --flow-options), then the call's
  runflow::directive_options flow || return 1
  local options=("${_RUNFLOW_WORDS[@]}")

  runflow::debug "@flow: version=$version, executable=$flow_exe, $(runflow::flow::python_summary)"
  _RUNFLOW_ARGV=("${environment[@]}" "$flow_exe" "${options[@]}" "$@")
}

# Run OPM Flow as a single process, with its arguments as for flow itself
# (@flow --version, @flow --help, @flow CASE.DATA); @flow -l lists the
# versions, @flow -w prints an executable. runflow's help: @help @flow.
#   @mpi [-n NP] @flow ...        Flow with MPI
#   @submit [opts] @mpi @flow ... queued (@wait @submit ... waits for it)
@flow() {
  case "${1:-}" in
    -l|--list)
      runflow::flow::list_versions "${@:2}"
      return
      ;;
    -w|--which)
      runflow::flow::resolve_version "${2:-$RUNFLOW_FLOW_VERSION}"
      return
      ;;
  esac

  runflow::command_flow "$@" || return 1

  if runflow::dry_run; then
    runflow::dry "run: $(runflow::quoted "${_RUNFLOW_ARGV[@]}")"
    return 0
  fi

  "${_RUNFLOW_ARGV[@]}"
}
