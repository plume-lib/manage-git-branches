#!/bin/sh

# Tests that `git-new-branch` has only local effects: it does not push the new
# branch, and it creates the branch directory even when the remote cannot be
# contacted at all.
#
# Usage:
#   tests/test-new-branch-no-push.sh
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
OFFLINE_DIR="${WORK_DIR}/myrepo-branch-feature2"

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

# The remote's refs before the command, to compare to its refs afterward.
refs_before="$(git -C "${REMOTE}" for-each-ref)"

if ! output="$(cd "${MAIN_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature1 2>&1)"; then
  fail "git-new-branch failed: ${output}"
fi
if [ ! -d "${FEATURE_DIR}" ]; then
  fail "git-new-branch did not create ${FEATURE_DIR}: ${output}"
fi
if [ -e "${FEATURE_DIR}-TMP" ]; then
  fail "git-new-branch left behind ${FEATURE_DIR}-TMP"
fi

# The new branch was not pushed:  the remote is exactly as it was, and the new
# working copy has no upstream branch and no remote-tracking branch.
if [ "$(git -C "${REMOTE}" for-each-ref)" != "${refs_before}" ]; then
  fail "git-new-branch changed the refs of ${REMOTE}:
$(git -C "${REMOTE}" for-each-ref)"
fi
if git -C "${FEATURE_DIR}" rev-parse --symbolic-full-name '@{upstream}' > /dev/null 2>&1; then
  fail "git-new-branch gave feature1 an upstream branch"
fi
if git -C "${FEATURE_DIR}" show-ref --verify --quiet refs/remotes/origin/feature1; then
  fail "git-new-branch created a remote-tracking branch for feature1"
fi

# The new working copy is on the new branch, even though it has no upstream.
branch="$(git -C "${FEATURE_DIR}" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature1" ]; then
  fail "${FEATURE_DIR} is on branch ${branch}, not feature1"
fi

# A remote that cannot be contacted at all is not an error either, because
# nothing that `git-new-branch` must do requires the remote.  A nonexistent
# repository is the most portable way to make the remote unusable: making it
# read-only would depend on file permissions, and rejecting a fetch with a hook
# would not work under `core.hooksPath`.
git -C "${MAIN_DIR}" remote set-url origin "${WORK_DIR}/no-such-repository.git"
if ! output="$(cd "${MAIN_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature2 2>&1)"; then
  fail "git-new-branch failed when the remote could not be contacted: ${output}"
fi
if [ ! -d "${OFFLINE_DIR}" ]; then
  fail "git-new-branch did not create ${OFFLINE_DIR}: ${output}"
fi
if [ -e "${OFFLINE_DIR}-TMP" ]; then
  fail "git-new-branch left behind ${OFFLINE_DIR}-TMP"
fi
branch="$(git -C "${OFFLINE_DIR}" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature2" ]; then
  fail "${OFFLINE_DIR} is on branch ${branch}, not feature2"
fi

echo "${SCRIPT_NAME}: OK"
