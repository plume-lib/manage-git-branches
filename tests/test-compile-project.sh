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
# "built" to a file named "log" and whose "clean" target writes "cleaned"
# to that file and then exits with the status given as the second argument.
make_project() {
  mkdir -p "$1"
  {
    printf 'all:\n\t@echo built >> log\n'
    printf 'clean:\n\t@echo cleaned >> log\n\t@exit %s\n' "$2"
  } > "$1/Makefile"
}

# With --clean and a clean that succeeds, the project is cleaned and then compiled.
cleanok="${tmpdir}/cleanok"
make_project "${cleanok}" 0
if ! "${COMPILE_PROJECT}" --clean "${cleanok}" > /dev/null; then
  fail "nonzero exit status in ${cleanok}"
fi
if [ "$(cat "${cleanok}/log")" != "cleaned
built" ]; then
  fail "with a successful clean, expected \"cleaned\" then \"built\" but got: $(cat "${cleanok}/log")"
fi

# With --clean and a clean that fails, the project is not compiled and the
# exit status is failure.
cleanfails="${tmpdir}/cleanfails"
make_project "${cleanfails}" 3
if "${COMPILE_PROJECT}" --clean "${cleanfails}" > /dev/null 2>&1; then
  fail "zero exit status despite a failing clean in ${cleanfails}"
fi
if [ "$(cat "${cleanfails}/log")" != "cleaned" ]; then
  fail "with a failing clean, expected only \"cleaned\" but got: $(cat "${cleanfails}/log")"
fi

if [ "${status}" = 0 ]; then
  echo "test-compile-project.sh: all tests passed"
fi
exit "${status}"
