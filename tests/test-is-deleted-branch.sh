#!/bin/sh

# Tests for the `is-deleted-branch` script.
#
# Usage:
#   tests/test-is-deleted-branch.sh
#
# The exit status is 0 if all tests pass, 1 otherwise.
#
# These tests exercise only cases that require no network access.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
IS_DELETED_BRANCH="${SCRIPT_DIR}/../is-deleted-branch"

status=0

fail() {
  echo "FAIL: $*" >&2
  status=1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT INT TERM

# A directory that does not exist is not a clone, so the status is 0 (true).
nonexistent="${tmpdir}/nonexistent"
if ! "${IS_DELETED_BRANCH}" "${nonexistent}" > /dev/null 2>&1; then
  fail "nonzero exit status for the nonexistent directory ${nonexistent}"
fi

# A path that exists but is not a directory is not a clone either.
plainfile="${tmpdir}/plainfile"
: > "${plainfile}"
if ! "${IS_DELETED_BRANCH}" "${plainfile}" > /dev/null 2>&1; then
  fail "nonzero exit status for the plain file ${plainfile}"
fi

# An existing directory that is not a clone yields status 0 (true).
notaclone="${tmpdir}/notaclone"
mkdir "${notaclone}"
if ! "${IS_DELETED_BRANCH}" "${notaclone}" > /dev/null 2>&1; then
  fail "nonzero exit status for the non-clone directory ${notaclone}"
fi

# The wrong number of arguments is an error.
if "${IS_DELETED_BRANCH}" > /dev/null 2>&1; then
  fail "zero exit status when given no argument"
fi
if "${IS_DELETED_BRANCH}" "${notaclone}" "${notaclone}" > /dev/null 2>&1; then
  fail "zero exit status when given two arguments"
fi

if [ "${status}" = 0 ]; then
  echo "test-is-deleted-branch.sh: all tests passed"
fi
exit "${status}"
