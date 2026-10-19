#!/usr/bin/env bash
# CI: install what the tests need, then run them as an ordinary user.
#
#   run-tests.sh            set up, then run (Linux: as root in a container;
#                           macOS: with Homebrew)
#   run-tests.sh --run      run only (the user, the tools already set up)
#
# Environment:
#   CI_FLOW=debian|ppa   also install OPM Flow from packages (Debian's, or the
#                        OPM project's Ubuntu PPA), download the decks, and
#                        run the real-Flow tests
#   CI_STRESS=1          also run the localq stress test
#
# Tests never run as root: root may write every file (the configuration
# permission tests would mean nothing), and mpirun refuses root. Failed tests
# keep their sandbox in ci-sandboxes/ (KEEP_FAILED), for the workflow to upload.
#
# The setup part runs on macOS's /bin/bash 3.2: no bash 4 features before
# --run.

set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
script="$root/.github/ci/run-tests.sh"

# Where Open MPI's mpirun is, on systems that keep it out of PATH
mpi_path() {
  local dir
  for dir in /usr/lib64/openmpi/bin /usr/lib64/mpi/gcc/openmpi4/bin; do
    [[ -x "$dir/mpirun" ]] && { echo "$dir"; return; }
  done
}

install_linux() {
  local flow_packages="libopm-simulators-bin python3-opm-common python3-opm-simulators python3-numpy"
  if command -v apt-get > /dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q --no-install-recommends bash coreutils util-linux procps perl \
      python3 openmpi-bin man-db groff-base git curl ca-certificates gawk binutils file
    case "${CI_FLOW:-}" in
      debian) apt-get install -y -q --no-install-recommends $flow_packages ;;
      ppa)
        apt-get install -y -q --no-install-recommends software-properties-common gpg-agent
        add-apt-repository -y ppa:opm/ppa
        apt-get update -q
        apt-get install -y -q --no-install-recommends $flow_packages
        ;;
    esac
  elif command -v dnf > /dev/null; then
    # --allowerasing: some images ship coreutils-single instead of coreutils
    dnf install -y -q --allowerasing bash coreutils util-linux procps-ng perl python3 \
      openmpi man-db groff-base git-core gawk findutils diffutils binutils file shadow-utils
  elif command -v zypper > /dev/null; then
    zypper -n -q install bash coreutils util-linux procps perl python3 openmpi4 man groff \
      git-core gawk findutils diffutils binutils file shadow
  else
    echo "run-tests.sh: no known package manager" >&2
    exit 1
  fi
}

# Linux, as root: the packages, then a user owning the checkout (the host's
# runner user, mounted into the container), who runs the tests
setup_linux() {
  local uid user=ci path
  install_linux
  uid=$(stat -c %u "$root")
  (( uid != 0 )) || uid=1000
  getent passwd "$uid" > /dev/null || useradd -m -u "$uid" "$user"
  user=$(getent passwd "$uid" | cut -d: -f1)
  path=$(mpi_path)
  path="${path:+$path:}$PATH"
  exec runuser -u "$user" -- env HOME="$(getent passwd "$uid" | cut -d: -f6)" PATH="$path" \
    CI_FLOW="${CI_FLOW:-}" CI_STRESS="${CI_STRESS:-}" bash "$script" --run
}

# macOS: Homebrew's bash, flock and GNU coreutils (the tests use timeout,
# date +%N and stat -c), and Open MPI
setup_macos() {
  local prefix
  brew install -q bash flock coreutils open-mpi
  prefix=$(brew --prefix)
  export PATH="$prefix/opt/coreutils/libexec/gnubin:$prefix/bin:$PATH"
  exec "$prefix/bin/bash" "$script" --run
}

# The two decks of the examples, from an opm-common release (as in
# examples/README.md)
download_decks() {
  local deck
  mkdir -p "$1"
  for deck in SPE1CASE2 SPE9_CP_PACKED; do
    curl -fsSL --retry 3 -o "$1/$deck.DATA" \
      "https://raw.githubusercontent.com/OPM/opm-common/release/2026.04/final/tests/$deck.DATA"
  done
}

run() {
  cd "$root"
  echo "bash $BASH_VERSION on $(uname -sm)$( [[ -r /etc/os-release ]] && . /etc/os-release && echo ", $PRETTY_NAME")"
  if [[ -n "${CI_FLOW:-}" ]]; then
    TEST_FLOW=$(command -v flow) || { echo "run-tests.sh: no flow after installing OPM" >&2; exit 1; }
    export TEST_FLOW TEST_DECKS="$HOME/decks"
    download_decks "$TEST_DECKS"
    echo "Flow: $TEST_FLOW ($("$TEST_FLOW" --version 2>&1 | head -n 1))"
  fi
  export KEEP_FAILED=1 TMPDIR="$root/ci-sandboxes"
  mkdir -p "$TMPDIR"

  local rc=0
  tests/run_tests.sh || rc=1
  if [[ -n "${CI_STRESS:-}" ]]; then
    tests/stress_localq.sh || rc=1
  fi
  return "$rc"
}

if [[ "${1:-}" == --run ]]; then
  run
elif [[ "$(uname -s)" == Darwin ]]; then
  setup_macos
elif [[ "$(id -u)" == 0 ]]; then
  setup_linux
else
  # A Linux runner: install with sudo, test as this user
  sudo env CI_FLOW="${CI_FLOW:-}" bash -c "$(declare -f install_linux); install_linux"
  path=$(mpi_path)
  PATH="${path:+$path:}$PATH" run
fi
