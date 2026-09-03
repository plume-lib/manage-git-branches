#!/bin/sh

# Tests that `git-checkout-branch` and `git-new-branch` report a failure of the
# `git pull` that they run in the current working copy, rather than ignoring it.
#
# Usage:
#   tests/test-branch-pull-failure.sh
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(dirname -- "${TESTS_DIR}")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT INT TERM

# A committer identity, in case the user running the test has none.
GIT_AUTHOR_NAME="Test User"
GIT_AUTHOR_EMAIL="test@example.com"
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

REMOTE="${WORK_DIR}/myrepo.git"
MAIN_DIR="${WORK_DIR}/myrepo-branch-main"
STDERR_FILE="${WORK_DIR}/stderr.txt"

## Creates a remote repository with a `main`, a `feature1`, and a `feature2`
## branch, and a clone of it in MAIN_DIR.
create_repositories() {
  git init -q --bare -b main "${REMOTE}"
  git init -q -b main "${WORK_DIR}/seed"
  echo "first line" > "${WORK_DIR}/seed/file.txt"
  git -C "${WORK_DIR}/seed" add file.txt
  git -C "${WORK_DIR}/seed" commit -q -m "Initial commit"
  git -C "${WORK_DIR}/seed" remote add origin "${REMOTE}"
  git -C "${WORK_DIR}/seed" push -q --set-upstream origin main
  git -C "${WORK_DIR}/seed" push -q origin main:feature1
  git -C "${WORK_DIR}/seed" push -q origin main:feature2
  rm -rf "${WORK_DIR}/seed"
  git clone -q "${REMOTE}" "${MAIN_DIR}"
}

## Makes `git pull` in MAIN_DIR fail with a merge conflict, by committing a
## change to file.txt in MAIN_DIR and a different change to file.txt on the
## remote's `main` branch.
create_conflict() {
  git clone -q "${REMOTE}" "${WORK_DIR}/other"
  echo "remote line" > "${WORK_DIR}/other/file.txt"
  git -C "${WORK_DIR}/other" commit -q -a -m "Remote change"
  git -C "${WORK_DIR}/other" push -q origin main
  rm -rf "${WORK_DIR}/other"
  echo "local line" > "${MAIN_DIR}/file.txt"
  git -C "${MAIN_DIR}" commit -q -a -m "Local change"
}

## Runs the given branch script on the given branch, in MAIN_DIR, with stderr
## in STDERR_FILE.  Sets `status` to the script's exit status.
run_script() {
  status=0
  (cd "${MAIN_DIR}" && "${COMMANDS_DIR}/$1" "$2") \
    > /dev/null 2> "${STDERR_FILE}" || status="$?"
}

## Fails the test unless STDERR_FILE mentions the failed pull.
check_pull_reported() {
  if ! grep -q 'git pull. failed' "${STDERR_FILE}"; then
    fail "$1 did not report the failed pull; its stderr was:
$(cat "${STDERR_FILE}")"
  fi
}

## Fails the test unless STDERR_FILE says that the failed pull left conflicts.
check_conflict_reported() {
  if ! grep -q 'left conflicts' "${STDERR_FILE}"; then
    fail "$1 did not report the conflicts left by the pull; its stderr was:
$(cat "${STDERR_FILE}")"
  fi
}

create_repositories

# A pull that fails because the current branch has no upstream.  The script
# reports the failure, then does its work.
git -C "${MAIN_DIR}" branch --unset-upstream main

run_script git-checkout-branch feature1
if [ "${status}" -ne 0 ]; then
  fail "git-checkout-branch exited with status ${status}:
$(cat "${STDERR_FILE}")"
fi
check_pull_reported git-checkout-branch
if [ ! -d "${WORK_DIR}/myrepo-branch-feature1" ]; then
  fail "git-checkout-branch did not create ${WORK_DIR}/myrepo-branch-feature1"
fi

run_script git-new-branch newfeature
if [ "${status}" -ne 0 ]; then
  fail "git-new-branch exited with status ${status}:
$(cat "${STDERR_FILE}")"
fi
check_pull_reported git-new-branch
if [ ! -d "${WORK_DIR}/myrepo-branch-newfeature" ]; then
  fail "git-new-branch did not create ${WORK_DIR}/myrepo-branch-newfeature"
fi

# A pull that fails with a merge conflict.  The script reports the failure and
# does nothing, rather than copying a conflicted working copy.
git -C "${MAIN_DIR}" branch --set-upstream-to=origin/main main > /dev/null
create_conflict

run_script git-new-branch conflicted
if [ "${status}" -eq 0 ]; then
  fail "git-new-branch succeeded despite a conflicted pull"
fi
check_pull_reported git-new-branch
check_conflict_reported git-new-branch
if [ -e "${WORK_DIR}/myrepo-branch-conflicted" ]; then
  fail "git-new-branch created ${WORK_DIR}/myrepo-branch-conflicted after a conflicted pull"
fi

git -C "${MAIN_DIR}" merge --abort

run_script git-checkout-branch feature2
if [ "${status}" -eq 0 ]; then
  fail "git-checkout-branch succeeded despite a conflicted pull"
fi
check_pull_reported git-checkout-branch
check_conflict_reported git-checkout-branch
if [ -e "${WORK_DIR}/myrepo-branch-feature2" ]; then
  fail "git-checkout-branch created ${WORK_DIR}/myrepo-branch-feature2 after a conflicted pull"
fi

echo "${SCRIPT_NAME}: PASS"
