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

# Creates, in the given directory, a Makefile whose "all" target writes
# "built" and whose "clean" target writes "cleaned", to a file named "log".
make_project() {
  mkdir -p "$1"
  {
    printf 'all:\n\t@echo built >> log\n'
    printf 'clean:\n\t@echo cleaned >> log\n'
  } > "$1/Makefile"
}

# Without --clean, the project is compiled but not cleaned.
noclean="${tmpdir}/noclean"
make_project "${noclean}"
if ! "${COMPILE_PROJECT}" "${noclean}" > /dev/null; then
  fail "nonzero exit status in ${noclean}"
fi
if [ "$(cat "${noclean}/log")" != "built" ]; then
  fail "without --clean, expected only \"built\" but got: $(cat "${noclean}/log")"
fi

# With --clean, the project is cleaned and then compiled.
withclean="${tmpdir}/withclean"
make_project "${withclean}"
if ! "${COMPILE_PROJECT}" --clean "${withclean}" > /dev/null; then
  fail "nonzero exit status in ${withclean}"
fi
if [ "$(cat "${withclean}/log")" != "cleaned
built" ]; then
  fail "with --clean, expected \"cleaned\" then \"built\" but got: $(cat "${withclean}/log")"
fi

# CLEAN in the environment does not clean the project.
inherited="${tmpdir}/inherited"
make_project "${inherited}"
if ! CLEAN=anything "${COMPILE_PROJECT}" "${inherited}" > /dev/null; then
  fail "nonzero exit status in ${inherited}"
fi
if [ "$(cat "${inherited}/log")" != "built" ]; then
  fail "with CLEAN in the environment, expected only \"built\" but got: $(cat "${inherited}/log")"
fi

if [ "${status}" = 0 ]; then
  echo "test-compile-project.sh: all tests passed"
fi
exit "${status}"
