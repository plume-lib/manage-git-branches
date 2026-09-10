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
FORK="${WORK_DIR}/fork.git"
MAIN_DIR="${WORK_DIR}/myrepo-branch-main"
FEATURE_DIR="${WORK_DIR}/myrepo-branch-feature1"
OFFLINE_DIR="${WORK_DIR}/myrepo-branch-feature2"

## Creates a remote repository with one commit, and a clone of it in MAIN_DIR.
create_repositories() {
  git init -q --bare -b main "${REMOTE}"
  git init -q --bare -b main "${FORK}"
  git init -q -b main "${WORK_DIR}/seed"
  echo "first line" > "${WORK_DIR}/seed/file.txt"
  git -C "${WORK_DIR}/seed" add file.txt
  git -C "${WORK_DIR}/seed" commit -q -m "Initial commit"
  git -C "${WORK_DIR}/seed" remote add origin "${REMOTE}"
  git -C "${WORK_DIR}/seed" push -q --set-upstream origin main
  rm -rf "${WORK_DIR}/seed"
  git clone -q "${REMOTE}" "${MAIN_DIR}"
}

## Usage: check_not_pushed BRANCH
## Fails if BRANCH exists in either repository that this clone could push to.
check_not_pushed() {
  if git -C "${REMOTE}" rev-parse --verify --quiet "refs/heads/$1" > /dev/null; then
    fail "git-new-branch pushed $1 to ${REMOTE}"
  fi
  if git -C "${FORK}" rev-parse --verify --quiet "refs/heads/$1" > /dev/null; then
    fail "git-new-branch pushed $1 to ${FORK}"
  fi
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

# The branch exists only in the new working copy.
check_not_pushed feature1
if git -C "${FEATURE_DIR}" rev-parse --symbolic-full-name '@{upstream}' \
  > /dev/null 2>&1; then
  fail "${FEATURE_DIR} has an upstream, but nothing should have been pushed"
fi
if git -C "${FEATURE_DIR}" rev-parse --verify --quiet \
  refs/remotes/origin/feature1 > /dev/null; then
  fail "${FEATURE_DIR} has a remote-tracking ref for a branch that was not pushed"
fi

# Not pushing is the normal case, not a failure, so it is not reported.
case "${output}" in
  *WARNING* | *ERROR*) fail "git-new-branch complained about not pushing: ${output}" ;;
esac

# Configuration that names a remote to push to does not make this script push.
# Pushing to that remote would create the branch in a repository that the user
# shares with others, before any commit on the branch justifies it.
PUSHREMOTE_DIR="${WORK_DIR}/pushremote"
git clone -q "${REMOTE}" "${PUSHREMOTE_DIR}"
git -C "${PUSHREMOTE_DIR}" remote add fork "${FORK}"
git -C "${PUSHREMOTE_DIR}" config branch.main.pushRemote fork
if ! output="$(cd "${PUSHREMOTE_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature2 2>&1)"; then
  fail "git-new-branch failed in a clone whose push remote is not origin: ${output}"
fi
if [ ! -d "${WORK_DIR}/pushremote-branch-feature2" ]; then
  fail "git-new-branch did not create ${WORK_DIR}/pushremote-branch-feature2: ${output}"
fi
check_not_pushed feature2
if git -C "${WORK_DIR}/pushremote-branch-feature2" \
  rev-parse --symbolic-full-name '@{upstream}' > /dev/null 2>&1; then
  fail "the new working copy has an upstream, but nothing should have been pushed"
fi

# A remote that cannot be contacted at all is not an error either, because
# nothing that `git-new-branch` must do requires the remote.  A nonexistent
# repository is the most portable way to make the remote unusable: making it
# read-only would depend on file permissions.
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
