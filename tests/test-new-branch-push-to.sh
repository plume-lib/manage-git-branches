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
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${WORK_DIR}"' EXIT
trap 'rm -rf "${WORK_DIR}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${WORK_DIR}"; trap - TERM; kill -s TERM "$$"' TERM

# Make the test independent of the invoking user's git configuration.  A
# global setting such as `commit.gpgsign`, `pull.rebase`, `merge.ff`,
# `core.hooksPath`, or `commit.template` would otherwise change what the
# commands below do, or make them fail.
GIT_CONFIG_GLOBAL="${WORK_DIR}/gitconfig"
GIT_CONFIG_SYSTEM=/dev/null
# A committer identity, in case the user running the test has none.
GIT_AUTHOR_NAME="Test User"
GIT_AUTHOR_EMAIL="test@example.com"
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
: > "${GIT_CONFIG_GLOBAL}"

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

# `git-new-branch` does not change any remote repository.
if git -C "${REMOTE}" rev-parse --verify --quiet refs/heads/feature1 > /dev/null; then
  fail "git-new-branch pushed feature1 to the remote"
fi
if git -C "${FEATURE_DIR}" rev-parse --symbolic-full-name '@{upstream}' > /dev/null 2>&1; then
  fail "git-new-branch gave feature1 an upstream, but it does not push"
fi

# `git-push-to` needs an upstream, so create one, as `git-new-branch` tells the
# user to do.
git -C "${FEATURE_DIR}" push -q --set-upstream origin feature1

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

# A configured upstream is valid even when its cached remote-tracking ref is
# absent.  `git pull` restores the ref from the remote.
git -C "${MAIN_DIR}" update-ref -d refs/remotes/origin/main
if ! "${COMMANDS_DIR}/git-push-to" "${MAIN_DIR}" "${FEATURE_DIR}"; then
  fail "git-push-to rejected a configured upstream whose cached ref was absent"
fi
if ! git -C "${MAIN_DIR}" show-ref --verify --quiet refs/remotes/origin/main; then
  fail "git pull did not restore the missing remote-tracking ref"
fi

# A configured upstream may name a tag rather than a cached remote-tracking branch.
git -C "${MAIN_DIR}" tag upstream-tag
git -C "${MAIN_DIR}" push -q origin refs/tags/upstream-tag
git -C "${MAIN_DIR}" config branch.main.merge refs/tags/upstream-tag
if ! "${COMMANDS_DIR}/git-push-to" "${MAIN_DIR}" "${FEATURE_DIR}"; then
  fail "git-push-to rejected a configured tag upstream"
fi
git -C "${MAIN_DIR}" config branch.main.merge refs/heads/main

# A working copy with no upstream branch gets an explanation, not git's
# "There is no tracking information for the current branch".
git -C "${FEATURE_DIR}" branch --unset-upstream
git -C "${FEATURE_DIR}" remote rename origin github
if output="$("${COMMANDS_DIR}/git-push-to" "${MAIN_DIR}" "${FEATURE_DIR}" 2>&1)"; then
  fail "git-push-to succeeded on a working copy with no upstream branch"
fi
case "${output}" in
  *"has no upstream branch"*) ;;
  *) fail "git-push-to did not explain the missing upstream branch: ${output}" ;;
esac
case "${output}" in
  *"git push --set-upstream 'github' 'feature1'"*) ;;
  *) fail "git-push-to did not recommend the configured remote: ${output}" ;;
esac

# When several remotes exist and none is named origin, no remote can be chosen
# for the user, so the advice names the remotes instead of a placeholder that
# would fail if the user pasted it.
git -C "${FEATURE_DIR}" remote add elsewhere "${REMOTE}"
if output="$("${COMMANDS_DIR}/git-push-to" "${MAIN_DIR}" "${FEATURE_DIR}" 2>&1)"; then
  fail "git-push-to succeeded on a working copy with no upstream branch"
fi
case "${output}" in
  *"several remotes and none is named origin"*) ;;
  *) fail "git-push-to did not explain that it could not choose a remote: ${output}" ;;
esac
case "${output}" in
  *"--set-upstream 'REMOTE'"*)
    fail "git-push-to recommended a command that names a placeholder remote: ${output}" ;;
esac
case "${output}" in
  *"  github"*) ;;
  *) fail "git-push-to did not list the remotes to choose from: ${output}" ;;
esac

# A working copy with no remote at all cannot be given an upstream by `git
# push` alone, so the advice says to add a remote first.
git -C "${FEATURE_DIR}" remote remove elsewhere
git -C "${FEATURE_DIR}" remote remove github
if output="$("${COMMANDS_DIR}/git-push-to" "${MAIN_DIR}" "${FEATURE_DIR}" 2>&1)"; then
  fail "git-push-to succeeded on a working copy with no remote"
fi
case "${output}" in
  *"has no remote"*) ;;
  *) fail "git-push-to did not explain that the clone has no remote: ${output}" ;;
esac
case "${output}" in
  *"--set-upstream 'REMOTE'"*)
    fail "git-push-to recommended a command that names a placeholder remote: ${output}" ;;
esac

# A subdirectory of a working copy is a git repository, so saying merely "not a
# git clone" would send the user looking for the wrong problem.
mkdir -p "${MAIN_DIR}/subdir"
if output="$("${COMMANDS_DIR}/git-push-to" "${MAIN_DIR}/subdir" "${FEATURE_DIR}" 2>&1)"; then
  fail "git-push-to succeeded on a subdirectory of a working copy"
fi
case "${output}" in
  *"not the top level of a git clone"*) ;;
  *) fail "git-push-to did not say that the directory is not a top level: ${output}" ;;
esac

# `git-new-branch` asks the remote whether the branch already exists, even when
# the clone's only remote is not named "origin".  Asking only a remote named
# "origin", as it once did, asked no remote at all in such a clone, so the
# check silently passed.
OTHER_NAME_DIR="${WORK_DIR}/othername"
git clone -q "${REMOTE}" "${OTHER_NAME_DIR}"
git -C "${OTHER_NAME_DIR}" remote rename origin elsewhere
if output="$(cd "${OTHER_NAME_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature1 2>&1)"; then
  fail "git-new-branch created a branch that already exists in the remote: ${output}"
fi
case "${output}" in
  *"branch feature1 already exists"*) ;;
  *) fail "git-new-branch did not say that the branch already exists: ${output}" ;;
esac
if [ -e "${WORK_DIR}/othername-branch-feature1" ]; then
  fail "git-new-branch created a directory for a branch that already exists"
fi

# A clone with no remote has no remote to ask, so the branch is created.
NO_REMOTE_DIR="${WORK_DIR}/noremote"
git clone -q "${REMOTE}" "${NO_REMOTE_DIR}"
git -C "${NO_REMOTE_DIR}" remote remove origin
if ! output="$(cd "${NO_REMOTE_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature3 2>&1)"; then
  fail "git-new-branch failed in a clone with no remote: ${output}"
fi
branch="$(git -C "${WORK_DIR}/noremote-branch-feature3" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature3" ]; then
  fail "${WORK_DIR}/noremote-branch-feature3 is on branch ${branch}, not feature3"
fi

echo "${SCRIPT_NAME}: OK"
