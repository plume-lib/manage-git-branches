#!/bin/sh

# Tests for the `is-deleted-branch` script.
#
# Usage:
#   tests/test-is-deleted-branch.sh
#
# The exit status is 0 if all tests pass, 1 otherwise.
#
# These tests use a local repository as the remote, so they require no network
# access.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
IS_DELETED_BRANCH="${SCRIPT_DIR}/../is-deleted-branch"

status=0

fail() {
  echo "FAIL: $*" >&2
  status=1
}

GIT_AUTHOR_NAME="Test User"
GIT_AUTHOR_EMAIL="test@example.com"
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT INT TERM

# Create a repository to serve as the remote, with one commit on branch `main`.
origin="${tmpdir}/origin.git"
git init -q --bare --initial-branch=main "${origin}"
seed="${tmpdir}/seed"
git init -q --initial-branch=main "${seed}"
git -C "${seed}" remote add origin "${origin}"
echo "first" > "${seed}/file.txt"
git -C "${seed}" add file.txt
git -C "${seed}" commit -q -m "First commit"
git -C "${seed}" push -q origin main

# The clone under test, plus a commit in the remote that the clone lacks.
clone="${tmpdir}/work"
git clone -q "${origin}" "${clone}"
echo "second" > "${seed}/file.txt"
git -C "${seed}" commit -q -a -m "Second commit"
git -C "${seed}" push -q origin main

# A directory that is within a clone but is not the clone's top level is not
# itself a clone, so the status is 0 (true).  Furthermore, testing it must not
# run a git command in the enclosing clone.
subdir="${clone}/subdir"
mkdir "${subdir}"
head_before="$(git -C "${clone}" rev-parse HEAD)"
if ! "${IS_DELETED_BRANCH}" "${subdir}" > /dev/null 2>&1; then
  fail "nonzero exit status for the non-clone subdirectory ${subdir}"
fi
head_after="$(git -C "${clone}" rev-parse HEAD)"
if [ "${head_before}" != "${head_after}" ]; then
  fail "testing ${subdir} changed the enclosing clone ${clone} from ${head_before} to ${head_after}"
fi

# A clone whose branch exists in the remote yields status 1 (false).
if "${IS_DELETED_BRANCH}" "${clone}" > /dev/null 2>&1; then
  fail "zero exit status for the clone ${clone}, whose branch exists"
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
