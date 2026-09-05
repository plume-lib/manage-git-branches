#!/bin/sh

# Tests that `git-push-to` and `git-pull-from` say that a failed merge left
# conflicts, rather than reporting only "problem pulling".
#
# Usage:
#   tests/test-merge-conflict-message.sh
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
STDERR_FILE="${WORK_DIR}/stderr.txt"

## Creates a remote repository with a `main` and a `feature` branch, and a
## clone of each branch.
create_repositories() {
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
}

## Commits a change to file.txt in each clone, and pushes each change to the
## clone's own branch, so that merging `main` into `feature` conflicts but
## pulling either branch from `origin` succeeds.
create_conflicting_commits() {
  echo "main line" > "${MAIN_DIR}/file.txt"
  git -C "${MAIN_DIR}" commit -q -a -m "Change on main"
  git -C "${MAIN_DIR}" push -q
  echo "feature line" > "${FEATURE_DIR}/file.txt"
  git -C "${FEATURE_DIR}" commit -q -a -m "Change on feature"
  git -C "${FEATURE_DIR}" push -q
}

## Fails the test unless STDERR_FILE says that the merge left conflicts, names
## the conflicted file, and says how to abandon the merge.
check_conflict_reported() {
  if ! grep -q 'left conflicts' "${STDERR_FILE}"; then
    fail "$1 did not report the conflicts left by the merge; its stderr was:
$(cat "${STDERR_FILE}")"
  fi
  if ! grep -q 'file.txt' "${STDERR_FILE}"; then
    fail "$1 did not name the conflicted file; its stderr was:
$(cat "${STDERR_FILE}")"
  fi
  if ! grep -q 'merge --abort' "${STDERR_FILE}"; then
    fail "$1 did not say how to abandon the merge; its stderr was:
$(cat "${STDERR_FILE}")"
  fi
}

create_repositories
create_conflicting_commits

# `git-push-to` merges MAIN_DIR into FEATURE_DIR, which conflicts.
status=0
"${COMMANDS_DIR}/git-push-to" --nocompile "${MAIN_DIR}" "${FEATURE_DIR}" \
  > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -eq 0 ]; then
  fail "git-push-to succeeded despite a conflicted merge"
fi
check_conflict_reported git-push-to
if [ -z "$(git -C "${FEATURE_DIR}" diff --name-only --diff-filter=U)" ]; then
  fail "the test did not produce a conflicted merge in ${FEATURE_DIR}"
fi

git -C "${FEATURE_DIR}" merge --abort

# `git-pull-from` merges MAIN_DIR into the current directory, which conflicts.
status=0
(cd "${FEATURE_DIR}" && "${COMMANDS_DIR}/git-pull-from" "${MAIN_DIR}") \
  > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -eq 0 ]; then
  fail "git-pull-from succeeded despite a conflicted merge"
fi
check_conflict_reported git-pull-from

git -C "${FEATURE_DIR}" merge --abort

# A pull that fails for a reason other than a conflict is not reported as a
# conflict.
git -C "${FEATURE_DIR}" branch --unset-upstream feature
status=0
"${COMMANDS_DIR}/git-push-to" --nocompile "${MAIN_DIR}" "${FEATURE_DIR}" \
  > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -eq 0 ]; then
  fail "git-push-to succeeded despite a failed pull"
fi
if grep -q 'left conflicts' "${STDERR_FILE}"; then
  fail "git-push-to reported conflicts for a pull that left none; its stderr was:
$(cat "${STDERR_FILE}")"
fi

echo "${SCRIPT_NAME}: PASS"
