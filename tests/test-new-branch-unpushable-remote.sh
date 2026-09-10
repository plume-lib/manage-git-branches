#!/bin/sh

# Tests that `git-new-branch` still creates the branch directory when the new
# branch cannot be pushed to "origin" -- for example, because the remote is
# read-only or unreachable.  Such a push failure is a warning, not an error.
#
# Usage:
#   tests/test-new-branch-unpushable-remote.sh
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(dirname -- "${TESTS_DIR}")"

. "${TESTS_DIR}/lib-git-test-env.sh"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${WORK_DIR}"' EXIT
trap 'rm -rf "${WORK_DIR}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${WORK_DIR}"; trap - TERM; kill -s TERM "$$"' TERM

sanitize_git_env "${WORK_DIR}"

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

# Make "origin" unpushable.  A nonexistent repository is the most portable way
# to do that: making the remote read-only would depend on file permissions, and
# rejecting the push with a hook would not work under `core.hooksPath`.
git -C "${MAIN_DIR}" remote set-url origin "${WORK_DIR}/no-such-repository.git"

if ! output="$(cd "${MAIN_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature1 2>&1)"; then
  fail "git-new-branch failed when the branch could not be pushed: ${output}"
fi
if [ ! -d "${FEATURE_DIR}" ]; then
  fail "git-new-branch did not create ${FEATURE_DIR}: ${output}"
fi
if [ -e "${FEATURE_DIR}-TMP" ]; then
  fail "git-new-branch left behind ${FEATURE_DIR}-TMP"
fi

# The user is told that the branch has no upstream, and how to give it one.
case "${output}" in
  *"WARNING"*"no upstream branch"*) ;;
  *) fail "git-new-branch did not warn about the failed push: ${output}" ;;
esac
case "${output}" in
  *"git push --set-upstream origin 'feature1'"*) ;;
  *) fail "git-new-branch did not say how to set the upstream: ${output}" ;;
esac

# The new working copy is on the new branch, even though it has no upstream.
branch="$(git -C "${FEATURE_DIR}" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature1" ]; then
  fail "${FEATURE_DIR} is on branch ${branch}, not feature1"
fi
if git -C "${FEATURE_DIR}" rev-parse --symbolic-full-name '@{upstream}' > /dev/null 2>&1; then
  fail "${FEATURE_DIR} has an upstream, but the push should have failed"
fi

echo "${SCRIPT_NAME}: OK"
