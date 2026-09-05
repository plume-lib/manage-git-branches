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

# A directory that does not exist is an error.
nonexistent="${tmpdir}/does-not-exist"
if "${COMPILE_PROJECT}" "${nonexistent}" > /dev/null 2>&1; then
  fail "zero exit status for nonexistent directory ${nonexistent}"
fi

# A file that is not a directory is an error.
notadirectory="${tmpdir}/regular-file"
touch "${notadirectory}"
if "${COMPILE_PROJECT}" "${notadirectory}" > /dev/null 2>&1; then
  fail "zero exit status for non-directory ${notadirectory}"
fi

# A directory that contains a buildfile is still compiled.
project="${tmpdir}/project"
mkdir -p "${project}"
printf 'all:\n\t@touch built.txt\n' > "${project}/Makefile"
if ! "${COMPILE_PROJECT}" "${project}" > /dev/null; then
  fail "nonzero exit status for directory ${project}"
fi
if [ ! -f "${project}/built.txt" ]; then
  fail "did not build the project in ${project}"
fi

# A directory that contains no buildfile is not an error.
nobuildfile="${tmpdir}/no-buildfile"
mkdir -p "${nobuildfile}"
if ! "${COMPILE_PROJECT}" "${nobuildfile}" > /dev/null; then
  fail "nonzero exit status for directory without a buildfile ${nobuildfile}"
fi

if [ "${status}" = 0 ]; then
  echo "test-compile-project.sh: all tests passed"
fi
exit "${status}"
