#!/bin/sh

# Tests that `git-new-branch` and `git-checkout-branch`, run in a branch
# directory that is a clone of its own (REPONAME-branch-OTHER/), register the
# new worktree in the project's main clone, REPONAME/, when that is a clone of
# the same project.
#
# Usage:
#   tests/test-main-clone.sh
#
# The status code is 0 if all the tests pass, and nonzero otherwise.

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
GIT_NEW_BRANCH="${TESTS_DIR}/../git-new-branch"
GIT_CHECKOUT_BRANCH="${TESTS_DIR}/../git-checkout-branch"

. "${TESTS_DIR}/lib-git-test-env.sh"

status=0

fail() {
  echo "${SCRIPT_NAME}: FAILED: $*" >&2
  status=1
}

if ! work="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")" || [ -z "${work}" ]; then
  echo "${SCRIPT_NAME}: cannot create a temporary directory" >&2
  exit 1
fi
trap 'rm -rf "${work}"' EXIT
trap 'rm -rf "${work}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${work}"; trap - TERM; kill -s TERM "$$"' TERM
work="$(CDPATH='' cd -- "${work}" && pwd -P)"

sanitize_git_env "${work}"

# Prints the main working tree of the repository that working tree $1 belongs
# to.
host_of() {
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"
  (CDPATH='' cd -- "${common%/.git}" && pwd -P)
}

# A remote with branches "main" and "other", the main clone "proj", and the
# branch directory "proj-branch-other", which is a clone of its own.
git init -q --bare -b main "${work}/remote.git"
git clone -q "${work}/remote.git" "${work}/seed" 2> /dev/null
echo "hello" > "${work}/seed/file.txt"
git -C "${work}/seed" add file.txt
git -C "${work}/seed" commit -q -m "Initial commit"
git -C "${work}/seed" push -q origin main main:refs/heads/other main:refs/heads/remote-only
git clone -q "${work}/remote.git" "${work}/proj"
git clone -q -b other "${work}/remote.git" "${work}/proj-branch-other"
other="${work}/proj-branch-other"

# A commit that only the branch directory has, and a staged file whose blob
# only the branch directory has.
echo "committed" > "${other}/committed.txt"
git -C "${other}" add committed.txt
git -C "${other}" commit -q -m "Local commit"
echo "staged" > "${other}/staged.txt"
git -C "${other}" add staged.txt

# git-new-branch, default mode.
if ! out="$(cd "${other}" && "${GIT_NEW_BRANCH}" new1 2>&1)"; then
  fail "git-new-branch new1 failed: ${out}"
fi
new1="${work}/proj-branch-new1"
if [ "$(host_of "${new1}")" != "${work}/proj" ]; then
  fail "new1 is registered in $(host_of "${new1}"), not in ${work}/proj"
fi
if [ "$(git -C "${new1}" rev-parse HEAD)" != "$(git -C "${other}" rev-parse HEAD)" ]; then
  fail "new1 is not at the commit of ${other}"
fi
if [ "$(git -C "${new1}" status --porcelain)" != "A  staged.txt" ]; then
  fail "new1's status is [$(git -C "${new1}" status --porcelain)], expected the staged file"
fi
if [ "$(git -C "${work}/proj" config --get branch.new1.createdForBranchDirectory)" != 'true' ]; then
  fail "branch new1 in ${work}/proj is not marked createdForBranchDirectory"
fi
case "${out}" in
  *"registering the new worktree in ${work}/proj"*) ;;
  *) fail "git-new-branch new1 did not say where it registered the worktree: ${out}" ;;
esac

# git-new-branch --clean.
if ! out="$(cd "${other}" && "${GIT_NEW_BRANCH}" --clean new2 2>&1)"; then
  fail "git-new-branch --clean new2 failed: ${out}"
fi
new2="${work}/proj-branch-new2"
if [ "$(host_of "${new2}")" != "${work}/proj" ]; then
  fail "new2 is registered in $(host_of "${new2}"), not in ${work}/proj"
fi
if [ -n "$(git -C "${new2}" status --porcelain)" ]; then
  fail "new2 is not clean: $(git -C "${new2}" status --porcelain)"
fi

# A branch name that the main clone already uses is refused.
git -C "${work}/proj" branch taken
if out="$(cd "${other}" && "${GIT_NEW_BRANCH}" --clean taken 2>&1)"; then
  fail "git-new-branch taken succeeded, though ${work}/proj has a branch taken"
fi
[ ! -e "${work}/proj-branch-taken" ] || fail "proj-branch-taken was created"

# git-checkout-branch of a branch that the remote has.
if ! out="$(cd "${other}" && "${GIT_CHECKOUT_BRANCH}" remote-only 2>&1)"; then
  fail "git-checkout-branch remote-only failed: ${out}"
fi
if [ "$(host_of "${work}/proj-branch-remote-only")" != "${work}/proj" ]; then
  fail "remote-only is registered in $(host_of "${work}/proj-branch-remote-only"), not in ${work}/proj"
fi

# git-checkout-branch of a branch that only the branch directory has.
git -C "${other}" branch local-only
if ! out="$(cd "${other}" && "${GIT_CHECKOUT_BRANCH}" local-only 2>&1)"; then
  fail "git-checkout-branch local-only failed: ${out}"
fi
if [ "$(host_of "${work}/proj-branch-local-only")" != "${other}" ]; then
  fail "local-only is registered in $(host_of "${work}/proj-branch-local-only"), not in ${other}"
fi

# A main clone of a different project is not used.
git init -q -b main "${work}/unrelated"
git clone -q -b other "${work}/remote.git" "${work}/unrelated-branch-other"
if ! out="$(cd "${work}/unrelated-branch-other" && "${GIT_NEW_BRANCH}" --clean new3 2>&1)"; then
  fail "git-new-branch --clean new3 failed: ${out}"
fi
if [ "$(host_of "${work}/unrelated-branch-new3")" != "${work}/unrelated-branch-other" ]; then
  fail "new3 is registered in $(host_of "${work}/unrelated-branch-new3"), not in ${work}/unrelated-branch-other"
fi

# A main clone that is a symbolic link to a branch directory is not used.
git clone -q "${work}/remote.git" "${work}/linked-branch-main"
ln -s linked-branch-main "${work}/linked"
git clone -q -b other "${work}/remote.git" "${work}/linked-branch-other"
if ! out="$(cd "${work}/linked-branch-other" && "${GIT_NEW_BRANCH}" --clean new4 2>&1)"; then
  fail "git-new-branch --clean new4 failed: ${out}"
fi
if [ "$(host_of "${work}/linked-branch-new4")" != "${work}/linked-branch-other" ]; then
  fail "new4 is registered in $(host_of "${work}/linked-branch-new4"), not in ${work}/linked-branch-other"
fi

if [ "${status}" = 0 ]; then
  echo "${SCRIPT_NAME}: OK"
fi
exit "${status}"
