#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# The Python of a Flow version: detection, @flowpy, and @flow's PYTHONPATH

# Fake tools in front of PATH: ldd prints a fake Flow's "# LDD: " lines (its
# libraries); python3.X prints how it was called, and its extension suffixes
# when asked (for the import check)
use_fake_tools() {
  mkdir -p "$SANDBOX/fakebin"
  cat > "$SANDBOX/fakebin/ldd" << 'EOF'
#!/bin/sh
sed -n 's/^# LDD: /	/p' "$1"
EOF
  local version
  for version in 3.11 3.12 3.13t; do
    cat > "$SANDBOX/fakebin/python$version" << EOF
#!/bin/sh
case "\$2" in
  *EXTENSION_SUFFIXES*) printf '%s\n' .cpython-${version/./}-x86_64-linux-gnu.so .abi3.so .so; exit 0 ;;
esac
echo "PYTHON $version pythonpath=\$PYTHONPATH"
printf 'ARGV'; printf ' [%s]' "\$@"; echo
EOF
  done
  chmod +x "$SANDBOX/fakebin/"*
  export PATH="$SANDBOX/fakebin:$PATH"
}

# A fake Flow at PATH, linked against libpython VERSION if given, found in
# PREFIX/lib (default: a sandbox directory without an interpreter, never the
# system's: flowrun prefers PREFIX/bin/pythonVERSION, which e.g. Rocky Linux
# 10 has in /usr)
fake_flow() {
  local path="$1" libpython="${2:-}" prefix="${3:-$SANDBOX/no-python}"
  mkdir -p "$(dirname "$path")"
  cp "$SANDBOX/bin/flowtest" "$path"
  [[ -z "$libpython" ]] || echo "# LDD: libpython$libpython.so.1.0 => $prefix/lib/libpython$libpython.so.1.0 (0x1)" >> "$path"
}

# Fake opm bindings for Python VERSION in DIR (DIR/opm/opmcommon_python...)
fake_bindings() {
  local dir="$1" version="$2"
  mkdir -p "$dir/opm"
  touch "$dir/opm/opmcommon_python.cpython-${version/./}-x86_64-linux-gnu.so"
}

# Detection only: no configured map or template; Flow versions in bin/ and
# an installation in opt/: flowinst embeds Python 3.12, flowplain does not,
# both with bindings for 3.12
use_detection() {
  use_fake_tools
  fake_flow "$SANDBOX/opt/bin/flowinst" 3.12
  fake_flow "$SANDBOX/opt/bin/flowplain"
  fake_bindings "$SANDBOX/opt/lib/python3.12/site-packages" 3.12
  cat >> "$FLOWRUN_CONFIG" << EOF
FLOWRUN_FLOW_BIN_PATHS=("$SANDBOX/bin" "$SANDBOX/opt/bin")
FLOWRUN_FLOW_PYTHONPATH=auto
FLOWRUN_FLOW_PYTHON_MAP=()
EOF
}

# --- Detection ---

test_flowpy_finds_installed_bindings_and_interpreter() {
  use_detection
  run "$FLOWRUN" --dry-run -c @flowpy -v flowinst script.py
  assert_rc 0
  assert_contains "$OUT" "flow flowinst: $SANDBOX/fakebin/python3.12; python 3.12 (from bindings), embedded, opm bindings: $SANDBOX/opt/lib/python3.12/site-packages"
  assert_contains "$OUT" "run: env PYTHONPATH=$SANDBOX/opt/lib/python3.12/site-packages $SANDBOX/fakebin/python3.12 script.py"

  run "$FLOWRUN" -c @flowpy -v flowinst -c 'code' a "b c"
  assert_rc 0
  assert_contains "$OUT" "PYTHON 3.12 pythonpath=$SANDBOX/opt/lib/python3.12/site-packages"
  assert_contains "$OUT" "ARGV [-c] [code] [a] [b c]"
}

test_flowpy_records_interpreter_on_stderr() {
  use_detection
  local stdout
  stdout=$("$FLOWRUN" -c @flowpy -v flowinst -c 'code' 2> err.log)
  RC=$?
  assert_rc 0
  assert_file_contains err.log "[INFO] @flowpy: flow flowinst: $SANDBOX/fakebin/python3.12; python 3.12 (from bindings), embedded, opm bindings: $SANDBOX/opt/lib/python3.12/site-packages"
  assert_not_contains "$stdout" "[INFO]"
  assert_contains "$stdout" "ARGV [-c] [code]"
}

test_flow_with_embedded_python_gets_bindings() {
  use_detection
  run "$FLOWRUN" -c @flow -v flowinst A.DATA
  assert_rc 0
  assert_contains "$OUT" "pythonpath=$SANDBOX/opt/lib/python3.12/site-packages"
}

test_flow_without_python_keeps_environment() {
  use_detection
  run "$FLOWRUN" --dry-run -c @flow -v flowplain A.DATA
  assert_rc 0
  assert_contains "$OUT" "run: $SANDBOX/opt/bin/flowplain $PWD/A.DATA"

  # Its bindings still work with @flowpy
  run "$FLOWRUN" --dry-run -c @flowpy -v flowplain script.py
  assert_contains "$OUT" "python 3.12 (from bindings), not embedded"
  assert_contains "$OUT" "$SANDBOX/fakebin/python3.12 script.py"
}

test_flowpy_finds_build_tree_bindings() {
  # Multi-config build (e.g. Ninja Multi-Config): python/<CONFIG>/ per
  # configuration, the one of the executable's bin/<CONFIG>/
  use_detection
  local build="$SANDBOX/build"
  fake_flow "$build/opm-simulators/bin/Debug/flowdev" 3.11
  printf '%s\n' "CMAKE_PROJECT_NAME:STATIC=opm-simulators" "opm-common_DIR:UNINITIALIZED=$build/opm-common" \
    > "$build/opm-simulators/CMakeCache.txt"
  fake_bindings "$build/opm-common/python/Release" 3.12
  fake_bindings "$build/opm-common/python/Debug" 3.11
  mkdir -p "$build/opm-simulators/python/Release/opm" "$build/opm-simulators/python/Debug/opm"

  run "$FLOWRUN" --dry-run -c @flowpy -v "$build/opm-simulators/bin/Debug/flowdev" script.py
  assert_rc 0
  assert_contains "$OUT" "python 3.11 (from bindings), embedded"
  assert_contains "$OUT" "run: env PYTHONPATH=$build/opm-common/python/Debug:$build/opm-simulators/python/Debug $SANDBOX/fakebin/python3.11 script.py"
}

test_flowpy_finds_single_config_build_tree_bindings() {
  use_detection
  local build="$SANDBOX/build"
  fake_flow "$build/opm-simulators/bin/flowdev"
  printf '%s\n' "opm-common_DIR:PATH=$build/opm-common" > "$build/opm-simulators/CMakeCache.txt"
  fake_bindings "$build/opm-common/python" 3.12

  run "$FLOWRUN" --dry-run -c @flowpy -v "$build/opm-simulators/bin/flowdev" script.py
  assert_rc 0
  assert_contains "$OUT" "python 3.12 (from bindings), not embedded"
  assert_contains "$OUT" "run: env PYTHONPATH=$build/opm-common/python $SANDBOX/fakebin/python3.12 script.py"
}

test_build_tree_without_compiled_bindings_has_none() {
  # A configuration built without Python: empty package directories only
  use_detection
  local build="$SANDBOX/build"
  fake_flow "$build/opm-simulators/bin/Release/flowrel"
  printf '%s\n' "opm-common_DIR:UNINITIALIZED=$build/opm-common" > "$build/opm-simulators/CMakeCache.txt"
  mkdir -p "$build/opm-common/python/Release/opm" "$build/opm-simulators/python/Release/opm/simulators"

  run "$FLOWRUN" -c @flowpy -v "$build/opm-simulators/bin/Release/flowrel" script.py
  assert_rc 1
  assert_contains "$OUT" "@flowpy: no opm Python bindings found for flow $build/opm-simulators/bin/Release/flowrel;"
  run "$FLOWRUN" --dry-run -c @flow -v "$build/opm-simulators/bin/Release/flowrel" A.DATA
  assert_contains "$OUT" "run: $build/opm-simulators/bin/Release/flowrel $PWD/A.DATA"
}

test_free_threaded_bindings_need_free_threaded_python() {
  use_detection
  fake_flow "$SANDBOX/ft/bin/flowft"
  fake_bindings "$SANDBOX/ft/lib/python3.13t/site-packages" 3.13t
  printf '%s\n' "FLOWRUN_FLOW_BIN_PATHS+=(\"$SANDBOX/ft/bin\")" >> "$FLOWRUN_CONFIG"
  run "$FLOWRUN" --dry-run -c @flowpy -v flowft script.py
  assert_rc 0
  assert_contains "$OUT" "python 3.13t (from bindings)"
  assert_contains "$OUT" "$SANDBOX/fakebin/python3.13t script.py"
}

test_embedded_python_selects_among_installed_bindings() {
  use_detection
  fake_bindings "$SANDBOX/opt/lib/python3.11/site-packages" 3.11
  run "$FLOWRUN" --dry-run -c @flowpy -v flowinst script.py
  assert_contains "$OUT" "python 3.12 (from bindings), embedded, opm bindings: $SANDBOX/opt/lib/python3.12/site-packages"
}

test_untagged_bindings_use_libpython_version() {
  use_detection
  fake_flow "$SANDBOX/inst2/bin/flowplainso" 3.12
  mkdir -p "$SANDBOX/inst2/lib/python3.12/site-packages/opm"
  touch "$SANDBOX/inst2/lib/python3.12/site-packages/opm/opmcommon_python.so"
  run "$FLOWRUN" -c @flowpy -v "$SANDBOX/inst2/bin/flowplainso" script.py
  assert_rc 0
  assert_contains "$OUT" "PYTHON 3.12 pythonpath=$SANDBOX/inst2/lib/python3.12/site-packages"
}

test_flowpy_checks_interpreter_can_import_bindings() {
  # The map names 3.11, but the only bindings are for 3.12
  use_detection
  printf '%s\n' "FLOWRUN_FLOW_PYTHON_MAP=('flowplain:3.11')" >> "$FLOWRUN_CONFIG"
  run "$FLOWRUN" -c @flowpy -v flowplain script.py
  assert_rc 1
  assert_contains "$OUT" "@flowpy: $SANDBOX/fakebin/python3.11 cannot import the opm bindings of flow flowplain: opmcommon_python.cpython-312-x86_64-linux-gnu.so is for another Python"

  run "$FLOWRUN" --dry-run -c @flowpy -v flowplain script.py
  assert_rc 0
  assert_contains "$OUT" "warning: $SANDBOX/fakebin/python3.11 cannot import"
}

test_flow_warns_when_embedded_python_differs_from_bindings() {
  use_detection
  fake_bindings "$SANDBOX/opt/lib/python3.11/site-packages" 3.11
  printf '%s\n' "FLOWRUN_FLOW_PYTHON_MAP=('flowinst:3.11')" >> "$FLOWRUN_CONFIG"
  run "$FLOWRUN" -c @flow -v flowinst A.DATA
  assert_rc 0
  assert_contains "$OUT" "[WARNING] @flow: flow flowinst embeds Python 3.12, but its opm bindings are for Python 3.11 (PYACTION will fail"

  # Consistent: no warning
  run "$FLOWRUN" -c @flow -v flowplain A.DATA
  assert_not_contains "$OUT" "WARNING"
}

test_flow_python_falls_back_to_libpython() {
  use_detection
  fake_flow "$SANDBOX/bin/flowlinked" 3.11
  printf '%s\n' "FLOWRUN_FLOW_PYTHONPATH=''" >> "$FLOWRUN_CONFIG"
  run "$FLOWRUN" --dry-run -c @flowpy -v flowlinked script.py
  assert_rc 0
  assert_contains "$OUT" "python 3.11 (from libpython), embedded, opm bindings: not found"
  assert_contains "$OUT" "run: $SANDBOX/fakebin/python3.11 script.py"
}

test_interpreter_installed_with_libpython_wins_over_path() {
  # The Python installed with the libpython Flow embeds, not the first
  # python3.11 in PATH
  use_detection
  mkdir -p "$SANDBOX/py/bin"
  cp "$SANDBOX/fakebin/python3.11" "$SANDBOX/py/bin/python3.11"
  fake_flow "$SANDBOX/bin/flowlinked" 3.11 "$SANDBOX/py"
  printf '%s\n' "FLOWRUN_FLOW_PYTHONPATH=''" >> "$FLOWRUN_CONFIG"
  run "$FLOWRUN" --dry-run -c @flowpy -v flowlinked script.py
  assert_rc 0
  assert_contains "$OUT" "run: $SANDBOX/py/bin/python3.11 script.py"
}

test_flow_lists_python_of_versions() {
  use_detection
  run "$FLOWRUN" -c @flow -l
  assert_rc 0
  [[ "$OUT" =~ "  flowinst "\ +"2099.10  abc1234  Release  2099-01-02 03:04:05  3.12 embedded" ]] || fail "flowinst row"
  [[ "$OUT" =~ "  flowplain "\ +"2099.10  abc1234  Release  2099-01-02 03:04:05  3.12"($|$'\n') ]] || fail "flowplain row"
  [[ "$OUT" =~ " * flowtest "\ +"2099.10  abc1234  Release  2099-01-02 03:04:05  -" ]] || fail "flowtest row"

  # Everything about one version
  run "$FLOWRUN" -c @flow -l flowinst
  assert_contains "$OUT" "  Python       python 3.12 (from bindings), embedded, opm bindings: $SANDBOX/opt/lib/python3.12/site-packages"
}

test_parse_libpython_from_ldd_and_otool() {
  source "$ROOT/lib/flowrun.sh" 2> /dev/null
  assert_eq "$(flowrun::flow::parse_libpython <<< $'\tlibm.so.6 => /lib/libm.so.6 (0x1)\n\tlibpython3.13.so.1.0 => /lib/x86_64-linux-gnu/libpython3.13.so.1.0 (0x2)')" \
    "3.13 /lib/x86_64-linux-gnu/libpython3.13.so.1.0"
  assert_eq "$(flowrun::flow::parse_libpython <<< $'\tlibpython3.12.so.1.0 => not found')" "3.12"
  assert_eq "$(flowrun::flow::parse_libpython <<< $'\tlibpython3.13t.so.1.0 => /usr/lib/libpython3.13t.so.1.0 (0x1)')" \
    "3.13t /usr/lib/libpython3.13t.so.1.0"
  assert_eq "$(flowrun::flow::parse_libpython <<< $'flow:\n\t/opt/py/lib/libpython3.11.dylib (compatibility version 3.11.0)')" \
    "3.11 /opt/py/lib/libpython3.11.dylib"
  assert_eq "$(flowrun::flow::parse_libpython <<< $'\t/Library/Frameworks/Python.framework/Versions/3.12/Python (compat)')" \
    "3.12 /Library/Frameworks/Python.framework/Versions/3.12/Python"
  assert_eq "$(flowrun::flow::parse_libpython <<< $'\tlibc.so.6 => /lib/libc.so.6 (0x1)')" ""
}

# --- The configuration wins over detection ---

test_python_map_wins_over_detection() {
  use_detection
  fake_bindings "$SANDBOX/opt/lib/python3.11/site-packages" 3.11
  printf '%s\n' "FLOWRUN_FLOW_PYTHON_MAP=('flowinst:3.11')" >> "$FLOWRUN_CONFIG"
  run "$FLOWRUN" --dry-run -c @flowpy -v flowinst script.py
  assert_rc 0
  assert_contains "$OUT" "python 3.11 (from map), embedded 3.12 (mismatch), opm bindings: $SANDBOX/opt/lib/python3.11/site-packages"
  assert_contains "$OUT" "$SANDBOX/fakebin/python3.11 script.py"
}

test_pythonpath_template_wins_over_detection() {
  use_detection
  printf '%s\n' "FLOWRUN_FLOW_PYTHONPATH='{prefix}/py{python}/{version}'" >> "$FLOWRUN_CONFIG"
  run "$FLOWRUN" --dry-run -c @flowpy -v flowinst script.py
  assert_rc 0
  assert_contains "$OUT" "run: env PYTHONPATH=$SANDBOX/opt/py3.12/flowinst $SANDBOX/fakebin/python3.12 script.py"
}

# --- @flowpy errors ---

test_flowpy_without_bindings_fails() {
  use_detection
  run "$FLOWRUN" -c @flowpy -v flowtest script.py
  assert_rc 1
  assert_contains "$OUT" "@flowpy: no opm Python bindings found for flow flowtest ($SANDBOX/bin/flowtest)"
}

test_flowpy_never_uses_another_python() {
  use_detection
  printf '%s\n' "FLOWRUN_FLOW_PYTHON_MAP=('flowinst:3.99')" >> "$FLOWRUN_CONFIG"
  run "$FLOWRUN" -c @flowpy -v flowinst script.py
  assert_rc 1
  assert_contains "$OUT" "@flowpy: Python 3.99 not found (needed by flow flowinst)"
}

test_flowpy_unknown_version_fails() {
  use_detection
  run "$FLOWRUN" -c @flowpy -v nosuchflow script.py
  assert_rc 1
  assert_contains "$OUT" "@flowpy: Flow version not found: nosuchflow"
}

test_flowpy_needs_flow_helpers() {
  # @flow replaced by a module without the flowrun::flow:: helpers
  mkdir "$SANDBOX/directives"
  printf '%s\n' 'flowrun::directive flow "" "Other flow"' '@flow() { echo other; }' \
    'unset -f flowrun::flow::python_info' > "$SANDBOX/directives/flow.sh"
  export FLOWRUN_DIRECTIVE_PATH="$SANDBOX/directives"
  run "$FLOWRUN" -c @flowpy script.py
  assert_rc 1
  assert_contains "$OUT" "@flowpy: needs the flowrun::flow:: helpers of the @flow extension (flow.sh)"
}

test_flowpy_requires_script() {
  run "$FLOWRUN" -c @flowpy -v flowrc47
  assert_rc 1
  assert_contains "$OUT" "script, -c CODE or -m MODULE required"
}

# --- @flowpy with the test configuration (template and map) ---

test_flowpy_runs_with_version_pythonpath() {
  use_fake_tools
  run "$FLOWRUN" -c @flowpy -c 'code' a "b c"
  assert_rc 0
  assert_contains "$OUT" "PYTHON 3.11 pythonpath=$SANDBOX/lib/python3.11/site-packages/flowtest"
  assert_contains "$OUT" "ARGV [-c] [code] [a] [b c]"
}

test_flowpy_version_selects_interpreter() {
  use_fake_tools
  run "$FLOWRUN" --dry-run -c @flowpy -v flowrc47 script.py
  assert_rc 0
  assert_contains "$OUT" "run: env PYTHONPATH=$SANDBOX/lib/python3.12/site-packages/flowrc47 $SANDBOX/fakebin/python3.12 script.py"
}

test_flowpy_runs_script_in_job() {
  use_fake_tools
  run "$FLOWRUN" -c @wait @submit -o "$PWD/out.log" @flowpy hello.py hi
  assert_rc 0
  assert_file_contains out.log "PYTHON 3.11"
  assert_file_contains out.log "ARGV [hello.py] [hi]"
}

test_flowpy_under_mpi() {
  use_fake_tools
  run "$FLOWRUN" --dry-run -c @mpi -n 4 @flowpy script.py
  assert_rc 0
  assert_contains "$OUT" "run: mpirun -np 4 env PYTHONPATH=$SANDBOX/lib/python3.11/site-packages/flowtest $SANDBOX/fakebin/python3.11 script.py"
}
