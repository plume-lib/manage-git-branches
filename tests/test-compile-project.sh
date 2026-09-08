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

# Do not let the invoking environment change what the script under test does.
# The flag variables could keep `compile-project` from creating the marker file
# that the tests look for, and ERR_IF_NO_BUILDFILE would make it fail in the
# directory that has no buildfile.
unset MAKE_FLAGS
unset GRADLE_ASSEMBLE_FLAGS
unset MVN_COMPILE_FLAGS
unset ERR_IF_NO_BUILDFILE

if ! tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")" || [ -z "${tmpdir}" ]; then
  echo "$0: cannot create a temporary directory" >&2
  exit 1
fi
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${tmpdir}"' EXIT
trap 'rm -rf "${tmpdir}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${tmpdir}"; trap - TERM; kill -s TERM "$$"' TERM

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
