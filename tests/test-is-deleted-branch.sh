#!/bin/sh

# Tests for the `is-deleted-branch` script.
#
# Usage:
#   tests/test-is-deleted-branch.sh
#
# The exit status is 0 if all tests pass, 1 otherwise.
#
# These tests use local repositories as remotes, so they require no network
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

# Create a repository to serve as the remote, with branches `main` and `feat`.
origin="${tmpdir}/origin.git"
git init -q --bare --initial-branch=main "${origin}"
seed="${tmpdir}/seed"
git init -q --initial-branch=main "${seed}"
git -C "${seed}" remote add origin "${origin}"
echo "first" > "${seed}/file.txt"
git -C "${seed}" add file.txt
git -C "${seed}" commit -q -m "First commit"
git -C "${seed}" push -q origin main
git -C "${seed}" branch feat
git -C "${seed}" push -q origin feat
git -C "${seed}" branch feat2
git -C "${seed}" push -q origin feat2

# A clone whose branch exists in the remote yields status 1 (false).
existing="${tmpdir}/existing"
git clone -q -b feat "${origin}" "${existing}"
"${IS_DELETED_BRANCH}" "${existing}" > /dev/null 2>&1
result="$?"
if [ "${result}" != 1 ]; then
  fail "status ${result} rather than 1 for ${existing}, whose branch exists"
fi

# A clone whose branch was deleted in the remote yields status 0 (true).
deleted="${tmpdir}/deleted"
git clone -q -b feat "${origin}" "${deleted}"
git -C "${seed}" push -q origin --delete feat
"${IS_DELETED_BRANCH}" "${deleted}" > /dev/null 2>&1
result="$?"
if [ "${result}" != 0 ]; then
  fail "status ${result} rather than 0 for ${deleted}, whose branch was deleted"
fi

# A clone with an unfinished conflicted merge still yields status 0 (true) when
# its branch was deleted in the remote.  The state of the clone must not be
# confused with the state of the branch in the remote.
conflicted="${tmpdir}/conflicted"
git clone -q -b feat2 "${origin}" "${conflicted}"
git -C "${conflicted}" checkout -q -b other
echo "other" > "${conflicted}/file.txt"
git -C "${conflicted}" commit -q -a -m "Change on other"
git -C "${conflicted}" checkout -q feat2
echo "feat2" > "${conflicted}/file.txt"
git -C "${conflicted}" commit -q -a -m "Change on feat2"
git -C "${conflicted}" merge -q other > /dev/null 2>&1
if [ ! -f "${conflicted}/.git/MERGE_HEAD" ]; then
  fail "test setup: no merge is in progress in ${conflicted}"
fi
git -C "${seed}" push -q origin --delete feat2
"${IS_DELETED_BRANCH}" "${conflicted}" > /dev/null 2>&1
result="$?"
if [ "${result}" != 0 ]; then
  fail "status ${result} rather than 0 for ${conflicted}, whose branch was deleted"
fi

# A clone whose remote cannot be read yields status 2, not an answer, and it
# says why.  A failure to reach the remote is not evidence that the branch
# exists.
unreachable="${tmpdir}/unreachable"
git clone -q "${origin}" "${unreachable}"
git -C "${unreachable}" remote set-url origin "${tmpdir}/no-such-repository.git"
stderr_file="${tmpdir}/unreachable-stderr.txt"
"${IS_DELETED_BRANCH}" "${unreachable}" > /dev/null 2> "${stderr_file}"
result="$?"
if [ "${result}" != 2 ]; then
  fail "status ${result} rather than 2 for ${unreachable}, whose remote is unreachable"
fi
if [ ! -s "${stderr_file}" ]; then
  fail "no message on standard error for ${unreachable}, whose remote is unreachable"
fi

# A branch that was never pushed is new rather than deleted, so the status is 1
# (false), with no complaint on standard error.
neverpushed="${tmpdir}/neverpushed"
git clone -q "${origin}" "${neverpushed}"
git -C "${neverpushed}" checkout -q -b brandnew
stderr_file="${tmpdir}/neverpushed-stderr.txt"
"${IS_DELETED_BRANCH}" "${neverpushed}" > /dev/null 2> "${stderr_file}"
result="$?"
if [ "${result}" != 1 ]; then
  fail "status ${result} rather than 1 for ${neverpushed}, whose branch was never pushed"
fi
if [ -s "${stderr_file}" ]; then
  fail "message on standard error for ${neverpushed}: $(cat "${stderr_file}")"
fi

# A detached HEAD is not on a branch, so the status is 1 (false).
detached="${tmpdir}/detached"
git clone -q "${origin}" "${detached}"
git -C "${detached}" checkout -q --detach HEAD
"${IS_DELETED_BRANCH}" "${detached}" > /dev/null 2>&1
result="$?"
if [ "${result}" != 1 ]; then
  fail "status ${result} rather than 1 for ${detached}, which has a detached HEAD"
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
