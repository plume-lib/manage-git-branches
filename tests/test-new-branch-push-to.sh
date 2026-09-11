#!/bin/sh

# Tests that a working copy created by `git-new-branch`, once its branch has
# been given an upstream, can be used by `git-push-to`, which is the workflow
# that the README describes.
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
# Test the configuration that defines an upstream, as `git-push-to` does, not
# `@{upstream}`, which also fails when only the cached remote-tracking ref is
# absent -- which it always is here, since `git-new-branch` pushes nothing.
if [ -n "$(git -C "${FEATURE_DIR}" config --get branch.feature1.remote)" ] \
  && [ -n "$(git -C "${FEATURE_DIR}" config --get-all branch.feature1.merge)" ]; then
  fail "git-new-branch gave feature1 an upstream, but it does not push"
fi

# `git-push-to` needs an upstream branch, and `git-new-branch` does not create
# one, because it has only local effects.  Report its absence here, where the
# cause is clear, rather than as a `git-push-to` failure below.
if output="$("${COMMANDS_DIR}/git-push-to" "${MAIN_DIR}" "${FEATURE_DIR}" 2>&1)"; then
  fail "git-push-to succeeded on a new branch that has no upstream branch"
fi
case "${output}" in
  *"has no upstream branch"*) ;;
  *) fail "git-push-to did not explain the missing upstream branch: ${output}" ;;
esac

# `git-new-branch` pushes nothing, so the new branch has no upstream branch
# until the user creates one, as the README says to do.  `git-push-to` and
# `git-pull-from` need one.
if ! git -C "${FEATURE_DIR}" push -q --set-upstream origin feature1; then
  fail "cannot give the new branch an upstream"
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

# The merge commit that `git-push-to` creates names the branch that it merged
# and names FROM_DIR by a relative pathname.  `git pull PATH` alone leaves
# `fmt-merge-msg` nothing to name, because `git fetch` writes no branch name
# into FETCH_HEAD for a pathname with no refspec; and an absolute pathname
# would embed this machine's directory layout in shared history.
#
# Both branches get a commit of their own, so that the merge is a real merge
# rather than a fast-forward, which would create no merge commit at all.
# `sanitize_git_env` leaves the global configuration empty, and git refuses to
# pull divergent branches unless something says how to reconcile them.  Merge
# them, which is what this workflow does; a rebase would leave no merge commit
# to inspect.
git -C "${FEATURE_DIR}" config pull.rebase false
echo "feature line" > "${FEATURE_DIR}/feature.txt"
git -C "${FEATURE_DIR}" add feature.txt
git -C "${FEATURE_DIR}" commit -q -m "A commit on the feature branch"
echo "third line" >> "${MAIN_DIR}/file.txt"
git -C "${MAIN_DIR}" commit -q -a -m "Add a third line"
git -C "${MAIN_DIR}" push -q
if ! "${COMMANDS_DIR}/git-push-to" "${MAIN_DIR}" "${FEATURE_DIR}"; then
  fail "git-push-to failed when each branch had a commit of its own"
fi
merge_parents="$(git -C "${FEATURE_DIR}" rev-list --parents -n 1 HEAD | wc -w)"
if [ "${merge_parents}" -ne 3 ]; then
  fail "git-push-to did not create a merge commit"
fi
merge_subject="$(git -C "${FEATURE_DIR}" log -1 --format=%s)"
case "${merge_subject}" in
  *"branch 'main'"*) ;;
  *) fail "the merge commit does not name the branch: ${merge_subject}" ;;
esac
case "${merge_subject}" in
  *"../myrepo-branch-main"*) ;;
  *) fail "the merge commit does not name FROM_DIR relatively: ${merge_subject}" ;;
esac
case "${merge_subject}" in
  *"${WORK_DIR}"*)
    fail "the merge commit embeds an absolute pathname: ${merge_subject}"
    ;;
esac

# A tag whose name is the branch's name does not displace the branch.  `git
# fetch` resolves a bare `BRANCH` by trying `refs/tags/BRANCH` before
# `refs/heads/BRANCH`, so naming the branch bare merges the tag -- here, a
# commit that FROM_DIR has already left behind -- and reports success while
# merging none of the branch's own commits.
git -C "${MAIN_DIR}" tag main
echo "fourth line" >> "${MAIN_DIR}/file.txt"
git -C "${MAIN_DIR}" commit -q -a -m "Add a fourth line"
git -C "${MAIN_DIR}" push -q
if ! "${COMMANDS_DIR}/git-push-to" "${MAIN_DIR}" "${FEATURE_DIR}"; then
  fail "git-push-to failed when a tag and the branch have the same name"
fi
if ! grep -q "fourth line" "${FEATURE_DIR}/file.txt"; then
  fail "git-push-to merged the tag rather than the branch of ${MAIN_DIR}"
fi
merge_subject="$(git -C "${FEATURE_DIR}" log -1 --format=%s)"
case "${merge_subject}" in
  *"branch 'main'"*) ;;
  *) fail "the merge commit does not name the branch: ${merge_subject}" ;;
esac
# Leave the repository as the rest of this test found it.
git -C "${MAIN_DIR}" tag -d main > /dev/null

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

# In a clone whose sole remote has some other name, a branch name that no
# remote has is created, just as it is in a clone whose remote is "origin".
# (`tests/test-new-branch-no-push.sh` checks that no remote receives it.)
ONLY_REMOTE_DIR="${WORK_DIR}/onlyremote"
git clone -q "${REMOTE}" "${ONLY_REMOTE_DIR}"
git -C "${ONLY_REMOTE_DIR}" remote rename origin elsewhere
if ! output="$(cd "${ONLY_REMOTE_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature5 2>&1)"; then
  fail "git-new-branch failed in a clone whose only remote is not origin: ${output}"
fi
branch="$(git -C "${WORK_DIR}/onlyremote-branch-feature5" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature5" ]; then
  fail "${WORK_DIR}/onlyremote-branch-feature5 is on branch ${branch}, not feature5"
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
