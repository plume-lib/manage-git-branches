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

. "${TESTS_DIR}/lib-git-test-env.sh"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${WORK_DIR}"' EXIT
trap 'rm -rf "${WORK_DIR}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${WORK_DIR}"; trap - TERM; kill -s TERM "$$"' TERM

sanitize_git_env "${WORK_DIR}"
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

# `remote.pushDefault` is a default for every clone, commonly set once in
# ~/.gitconfig to name a fork, so it can name a remote that this clone does not
# have.  Using that name would make the query fail, which would silently
# disable this check.
PUSHDEFAULT_DIR="${WORK_DIR}/pushdefault"
git clone -q "${REMOTE}" "${PUSHDEFAULT_DIR}"
git -C "${PUSHDEFAULT_DIR}" branch --unset-upstream
git -C "${PUSHDEFAULT_DIR}" config remote.pushDefault fork
if output="$(cd "${PUSHDEFAULT_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature1 2>&1)"; then
  fail "git-new-branch created a branch that already exists in the remote: ${output}"
fi
case "${output}" in
  *"branch feature1 already exists"*) ;;
  *) fail "git-new-branch did not ask a remote that the clone has: ${output}" ;;
esac
if [ -e "${WORK_DIR}/pushdefault-branch-feature1" ]; then
  fail "git-new-branch created a directory for a branch that already exists"
fi

# The branch's own remote says where the branch would be pushed, even in a
# clone that has several remotes and none named "origin".  Consulting only
# clone-wide configuration asked no remote at all in such a clone, so the check
# silently passed.
MULTIPLE_DIR="${WORK_DIR}/multipleremotes"
git clone -q "${REMOTE}" "${MULTIPLE_DIR}"
git -C "${MULTIPLE_DIR}" remote rename origin upstream
git -C "${MULTIPLE_DIR}" remote add elsewhere "${REMOTE}"
if output="$(cd "${MULTIPLE_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature1 2>&1)"; then
  fail "git-new-branch created a branch that already exists in the remote: ${output}"
fi
case "${output}" in
  *"branch feature1 already exists"*) ;;
  *) fail "git-new-branch did not ask the branch's own remote: ${output}" ;;
esac
if [ -e "${WORK_DIR}/multipleremotes-branch-feature1" ]; then
  fail "git-new-branch created a directory for a branch that already exists"
fi

# Only the remote that the branch would be pushed to matters.  In a fork
# workflow, the clone also tracks "upstream", whose branches the user cannot
# push to and whose names are therefore not in use for the new branch:
# refusing on account of one of those would refuse a name that
# `git checkout -b` accepts and that no push would collide with.
FORK_REMOTE="${WORK_DIR}/myfork.git"
git init -q --bare -b main "${FORK_REMOTE}"
FORK_DIR="${WORK_DIR}/fork"
git clone -q "${REMOTE}" "${FORK_DIR}"
# `git remote rename` moves `branch.main.remote` along with the remote, so the
# clone tracks the upstream repository and pushes to the fork.
git -C "${FORK_DIR}" remote rename origin upstream
git -C "${FORK_DIR}" remote add origin "${FORK_REMOTE}"
git -C "${FORK_DIR}" config branch.main.pushRemote origin
git -C "${FORK_DIR}" push -q origin main
if ! git -C "${FORK_DIR}" rev-parse --verify --quiet refs/remotes/upstream/feature1 > /dev/null; then
  fail "the test's fork clone does not track upstream/feature1"
fi
if ! output="$(cd "${FORK_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature1 2>&1)"; then
  fail "git-new-branch refused a name that only the upstream remote uses: ${output}"
fi
branch="$(git -C "${WORK_DIR}/fork-branch-feature1" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature1" ]; then
  fail "${WORK_DIR}/fork-branch-feature1 is on branch ${branch}, not feature1"
fi

# `git-push-to` recommends a remote that the clone has, for the same reason.
ADVICE_DIR="${WORK_DIR}/advice"
git clone -q "${REMOTE}" "${ADVICE_DIR}"
git -C "${ADVICE_DIR}" branch --unset-upstream
git -C "${ADVICE_DIR}" config remote.pushDefault fork
if output="$("${COMMANDS_DIR}/git-push-to" "${ADVICE_DIR}" "${MAIN_DIR}" 2>&1)"; then
  fail "git-push-to succeeded on a working copy with no upstream branch"
fi
case "${output}" in
  *fork*) fail "git-push-to recommended a remote that the clone does not have: ${output}" ;;
esac
case "${output}" in
  *"git push --set-upstream 'origin' 'main'"*) ;;
  *) fail "git-push-to did not recommend a remote that the clone has: ${output}" ;;
esac

# `git-push-to` and `is-deleted-branch` must agree about which remote a branch
# would be pushed to, so `git-push-to` also prefers the branch's own remote to
# the clone-wide `remote.pushDefault`.
git -C "${ADVICE_DIR}" remote add fork "${REMOTE}"
git -C "${ADVICE_DIR}" config branch.main.remote origin
if output="$("${COMMANDS_DIR}/git-push-to" "${ADVICE_DIR}" "${MAIN_DIR}" 2>&1)"; then
  fail "git-push-to succeeded on a working copy with no upstream branch"
fi
case "${output}" in
  *"git push --set-upstream 'origin' 'main'"*) ;;
  *) fail "git-push-to did not prefer the branch's own remote to remote.pushDefault: ${output}" ;;
esac

# `git-new-branch` pushes the new branch to the remote that it asked about the
# branch, which is the remote that `git push` would use for the current
# branch.  Pushing to "origin" instead, as this script once did, pushed to a
# repository that the collision check had not asked about:  a branch that
# exists there rejects the push after the whole working copy has been copied,
# which is the cost that the check exists to avoid.
FORK="${WORK_DIR}/fork.git"
git init -q --bare -b main "${FORK}"
PUSHREMOTE_DIR="${WORK_DIR}/pushremote"
git clone -q "${REMOTE}" "${PUSHREMOTE_DIR}"
git -C "${PUSHREMOTE_DIR}" remote add fork "${FORK}"
git -C "${PUSHREMOTE_DIR}" config branch.main.pushRemote fork
if ! output="$(cd "${PUSHREMOTE_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature4 2>&1)"; then
  fail "git-new-branch failed in a clone whose push remote is not origin: ${output}"
fi
if ! git -C "${FORK}" rev-parse --verify --quiet refs/heads/feature4 > /dev/null; then
  fail "git-new-branch did not push feature4 to the branch's push remote: ${output}"
fi
if git -C "${REMOTE}" rev-parse --verify --quiet refs/heads/feature4 > /dev/null; then
  fail "git-new-branch pushed feature4 to origin rather than to the push remote"
fi
upstream="$(git -C "${WORK_DIR}/pushremote-branch-feature4" \
  rev-parse --symbolic-full-name '@{upstream}' 2> /dev/null || true)"
if [ "${upstream}" != 'refs/remotes/fork/feature4' ]; then
  fail "the new working copy's upstream is [${upstream}], not refs/remotes/fork/feature4"
fi

# In a clone whose sole remote has some other name, the new branch is pushed
# to that remote.  Pushing only to "origin" pushed nowhere at all in such a
# clone, so the new working copy had no upstream and `git-push-to` and
# `git-pull-from` could not use it.
ONLY_REMOTE_DIR="${WORK_DIR}/onlyremote"
git clone -q "${REMOTE}" "${ONLY_REMOTE_DIR}"
git -C "${ONLY_REMOTE_DIR}" remote rename origin elsewhere
if ! output="$(cd "${ONLY_REMOTE_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature5 2>&1)"; then
  fail "git-new-branch failed in a clone whose only remote is not origin: ${output}"
fi
if ! git -C "${REMOTE}" rev-parse --verify --quiet refs/heads/feature5 > /dev/null; then
  fail "git-new-branch did not push feature5 to the clone's only remote: ${output}"
fi
upstream="$(git -C "${WORK_DIR}/onlyremote-branch-feature5" \
  rev-parse --symbolic-full-name '@{upstream}' 2> /dev/null || true)"
if [ "${upstream}" != 'refs/remotes/elsewhere/feature5' ]; then
  fail "the new working copy's upstream is [${upstream}], not refs/remotes/elsewhere/feature5"
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
