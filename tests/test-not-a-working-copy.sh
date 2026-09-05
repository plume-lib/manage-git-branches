#!/bin/sh

# Tests that `git-push-to` and `git-pull-from` report a directory that is not a
# git working copy, rather than claiming that it is on a deleted branch.
#
# Usage:
#   tests/test-not-a-working-copy.sh
#
# The test creates its directories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(dirname -- "${TESTS_DIR}")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
WORK_DIR="$(CDPATH='' cd -- "${WORK_DIR}" && pwd -P)"
trap 'rm -rf "${WORK_DIR}"' EXIT INT TERM

# A committer identity, in case the user running the test has none.
GIT_AUTHOR_NAME="Test User"
GIT_AUTHOR_EMAIL="test@example.com"
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# The compilation step is irrelevant to this test.
MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1
export MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

REMOTE="${WORK_DIR}/myrepo.git"
MAIN_DIR="${WORK_DIR}/myrepo-branch-main"
FEATURE_DIR="${WORK_DIR}/myrepo-branch-feature"
NOT_A_CLONE="${WORK_DIR}/notaclone"
STDERR_FILE="${WORK_DIR}/stderr.txt"

## Creates a remote repository with a `main` and a `feature` branch, a clone of
## each branch, and a directory that is not a working copy.
create_directories() {
  git init -q --bare -b main "${REMOTE}"
  git init -q -b main "${WORK_DIR}/seed"
  echo "first line" > "${WORK_DIR}/seed/file.txt"
  git -C "${WORK_DIR}/seed" add file.txt
  git -C "${WORK_DIR}/seed" commit -q -m "Initial commit"
  git -C "${WORK_DIR}/seed" remote add origin "${REMOTE}"
  git -C "${WORK_DIR}/seed" push -q --set-upstream origin main
  git -C "${WORK_DIR}/seed" push -q origin main:feature
  rm -rf "${WORK_DIR}/seed"
  git clone -q "${REMOTE}" "${MAIN_DIR}"
  git clone -q -b feature "${REMOTE}" "${FEATURE_DIR}"
  # Merge rather than rebase, whatever the user's git configuration says.
  git -C "${MAIN_DIR}" config pull.rebase false
  git -C "${FEATURE_DIR}" config pull.rebase false
  mkdir "${NOT_A_CLONE}"
}

## Fails the test unless STDERR_FILE says that NOT_A_CLONE is not a working
## copy, and does not call it a deleted branch.
check_not_a_working_copy_reported() {
  if ! grep -q "not a git working copy: ${NOT_A_CLONE}" "${STDERR_FILE}"; then
    fail "$1 did not report that ${NOT_A_CLONE} is not a working copy; its stderr was:
$(cat "${STDERR_FILE}")"
  fi
  if grep -q 'deleted branch' "${STDERR_FILE}"; then
    fail "$1 called ${NOT_A_CLONE} a deleted branch; its stderr was:
$(cat "${STDERR_FILE}")"
  fi
}

create_directories

# The temporary directory must lie outside any git working copy, or else the
# test is meaningless.
if git -C "${NOT_A_CLONE}" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  fail "the temporary directory ${WORK_DIR} is within a git working copy"
fi

# `git-push-to` with a FROM_DIR that is not a working copy.
status=0
"${COMMANDS_DIR}/git-push-to" --nocompile "${NOT_A_CLONE}" "${FEATURE_DIR}" \
  > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -eq 0 ]; then
  fail "git-push-to succeeded with a FROM_DIR that is not a working copy"
fi
check_not_a_working_copy_reported "git-push-to (as FROM_DIR)"

# `git-push-to` with a TO_DIR that is not a working copy.
status=0
"${COMMANDS_DIR}/git-push-to" --nocompile "${MAIN_DIR}" "${NOT_A_CLONE}" \
  > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -eq 0 ]; then
  fail "git-push-to succeeded with a TO_DIR that is not a working copy"
fi
check_not_a_working_copy_reported "git-push-to (as TO_DIR)"

# `git-pull-from` with an argument that is not a working copy.
status=0
(cd "${MAIN_DIR}" && "${COMMANDS_DIR}/git-pull-from" "${NOT_A_CLONE}") \
  > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -eq 0 ]; then
  fail "git-pull-from succeeded with an argument that is not a working copy"
fi
check_not_a_working_copy_reported "git-pull-from (as OTHER-REPO-DIR)"

# `git-pull-from` run in a directory that is not a working copy.
status=0
(cd "${NOT_A_CLONE}" && "${COMMANDS_DIR}/git-pull-from" "${MAIN_DIR}") \
  > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -eq 0 ]; then
  fail "git-pull-from succeeded in a directory that is not a working copy"
fi
check_not_a_working_copy_reported "git-pull-from (as the current directory)"

# Two genuine working copies are not rejected.
status=0
"${COMMANDS_DIR}/git-push-to" --nocompile "${MAIN_DIR}" "${FEATURE_DIR}" \
  > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -ne 0 ]; then
  fail "git-push-to failed on two working copies; its stderr was:
$(cat "${STDERR_FILE}")"
fi

echo "${SCRIPT_NAME}: PASS"
