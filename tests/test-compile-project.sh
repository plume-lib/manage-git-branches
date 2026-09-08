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
  # Use printf, not echo, so that backslashes in the message are not expanded.
  printf 'FAIL: %s\n' "$*" >&2
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

# Do not let a repository above ${tmpdir} (say, if TMPDIR is within a working
# copy) affect the top-level directory that `compile-project` discovers.
GIT_CEILING_DIRECTORIES="${tmpdir}"
export GIT_CEILING_DIRECTORIES

# Checks that `compile-project <directory>` exits with status 1 and complains
# on stderr that <directory> is not a directory.
expect_not_a_directory() {
  expect_stderr="$("${COMPILE_PROJECT}" "$1" 2>&1 > /dev/null)"
  expect_status=$?
  if [ "${expect_status}" != 1 ]; then
    fail "exit status ${expect_status}, not 1, for $1"
  fi
  case "${expect_stderr}" in
    *"not a directory: $1"*) ;;
    *) fail "expected \"not a directory: $1\" on stderr, got: ${expect_stderr}" ;;
  esac
}

# A directory that does not exist is an error.
expect_not_a_directory "${tmpdir}/does-not-exist"

# A file that is not a directory is an error.
notadirectory="${tmpdir}/regular-file"
touch "${notadirectory}"
expect_not_a_directory "${notadirectory}"

# The error message reports the path as given, without expanding backslash
# sequences in it.
expect_not_a_directory "${tmpdir}/backslash\\tname"

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

# A directory within a repository compiles the top level of the repository.
repo="${tmpdir}/repo"
mkdir -p "${repo}/sub/dir"
printf 'all:\n\t@touch built.txt\n' > "${repo}/Makefile"
git -c init.defaultBranch=main init -q "${repo}"
if ! "${COMPILE_PROJECT}" "${repo}/sub/dir" > /dev/null; then
  fail "nonzero exit status for directory ${repo}/sub/dir"
fi
if [ ! -f "${repo}/built.txt" ]; then
  fail "did not build the top level of the repository ${repo}"
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
