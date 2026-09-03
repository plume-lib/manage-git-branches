#!/bin/sh

# Tests for the `compile-project` script.
#
# Usage:
#   tests/test-compile-project.sh
#
# The exit status is 0 if all tests pass, 1 otherwise.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMPILE_PROJECT="${SCRIPT_DIR}/../compile-project"

status=0

fail() {
  echo "FAIL: $*" >&2
  status=1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT INT TERM

# Creates a git clone at $1, containing a Makefile whose default target creates
# the file "built.txt", and an empty subdirectory "src".
make_repo() {
  repo="$1"
  mkdir -p "${repo}/src"
  printf 'all:\n\t@touch built.txt\n' > "${repo}/Makefile"
  git init -q "${repo}"
}

# The project is built when the top-level directory is given explicitly.
repo="${tmpdir}/toplevel-argument"
make_repo "${repo}"
if ! "${COMPILE_PROJECT}" "${repo}" > /dev/null; then
  fail "nonzero exit status for top-level directory ${repo}"
fi
if [ ! -f "${repo}/built.txt" ]; then
  fail "did not build the project in ${repo}"
fi

# The project is built when a subdirectory of it is given as an argument.
repo="${tmpdir}/subdirectory-argument"
make_repo "${repo}"
if ! "${COMPILE_PROJECT}" "${repo}/src" > /dev/null; then
  fail "nonzero exit status for subdirectory ${repo}/src"
fi
if [ ! -f "${repo}/built.txt" ]; then
  fail "did not build the project containing ${repo}/src"
fi

# The project is built when a subdirectory of it is the current directory.
repo="${tmpdir}/subdirectory-current"
make_repo "${repo}"
if ! (cd "${repo}/src" && "${COMPILE_PROJECT}" > /dev/null); then
  fail "nonzero exit status when run in ${repo}/src"
fi
if [ ! -f "${repo}/built.txt" ]; then
  fail "did not build the project when run in ${repo}/src"
fi

# A directory that is not in a clone is used as the top level, as before.
plain="${tmpdir}/plain"
mkdir -p "${plain}"
printf 'all:\n\t@touch built.txt\n' > "${plain}/Makefile"
if ! "${COMPILE_PROJECT}" "${plain}" > /dev/null; then
  fail "nonzero exit status for non-clone directory ${plain}"
fi
if [ ! -f "${plain}/built.txt" ]; then
  fail "did not build the project in non-clone directory ${plain}"
fi

if [ "${status}" = 0 ]; then
  echo "test-compile-project.sh: all tests passed"
fi
exit "${status}"
