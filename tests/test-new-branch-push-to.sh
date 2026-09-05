#!/bin/sh

# Tests that a working copy created by `git-new-branch` can be used by
# `git-push-to`, which is the workflow that the README describes.
#
# Usage:
#   tests/test-new-branch-push-to.sh
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
# The test repository contains no build file, so skip compilation.
MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1
export MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

REMOTE="${WORK_DIR}/myrepo.git"
MAIN_DIR="${WORK_DIR}/myrepo-branch-main"
FEATURE_DIR="${WORK_DIR}/myrepo-branch-feature1"

## Creates a remote repository with one commit, and a clone of it in MAIN_DIR.
create_repositories() {
  git init -q --bare -b main "${REMOTE}"
  git init -q -b main "${WORK_DIR}/seed"
  echo "first line" > "${WORK_DIR}/seed/file.txt"
  git -C "${WORK_DIR}/seed" add file.txt
  git -C "${WORK_DIR}/seed" commit -q -m "Initial commit"
  git -C "${WORK_DIR}/seed" remote add origin "${REMOTE}"
  git -C "${WORK_DIR}/seed" push -q --set-upstream origin main
  rm -rf "${WORK_DIR}/seed"
  git clone -q "${REMOTE}" "${MAIN_DIR}"
}

create_repositories

if ! (cd "${MAIN_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature1); then
  fail "git-new-branch failed"
fi
if [ ! -d "${FEATURE_DIR}" ]; then
  fail "git-new-branch did not create ${FEATURE_DIR}"
fi

# Commit a change in the main branch, to be propagated to the new branch.
echo "second line" >> "${MAIN_DIR}/file.txt"
git -C "${MAIN_DIR}" commit -q -a -m "Add a second line"
git -C "${MAIN_DIR}" push -q

if ! "${COMMANDS_DIR}/git-push-to" "${MAIN_DIR}" "${FEATURE_DIR}"; then
  fail "git-push-to failed on a working copy created by git-new-branch"
fi

if ! grep -q "second line" "${FEATURE_DIR}/file.txt"; then
  fail "git-push-to did not merge the change into ${FEATURE_DIR}"
fi

# `git-push-to` pushes TO_DIR to its remote.
local_head="$(git -C "${FEATURE_DIR}" rev-parse HEAD)"
remote_head="$(git -C "${REMOTE}" rev-parse refs/heads/feature1)"
if [ "${local_head}" != "${remote_head}" ]; then
  fail "git-push-to did not push feature1 to the remote: ${local_head} != ${remote_head}"
fi

# A working copy with no upstream branch gets an explanation, not git's
# "There is no tracking information for the current branch".
git -C "${FEATURE_DIR}" branch --unset-upstream
if output="$("${COMMANDS_DIR}/git-push-to" "${MAIN_DIR}" "${FEATURE_DIR}" 2>&1)"; then
  fail "git-push-to succeeded on a working copy with no upstream branch"
fi
case "${output}" in
  *"has no upstream branch"*) ;;
  *) fail "git-push-to did not explain the missing upstream branch: ${output}" ;;
esac

echo "${SCRIPT_NAME}: PASS"
