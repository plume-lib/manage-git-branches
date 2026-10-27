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

# A branch name that the main clone already uses is created in the branch
# directory instead.
git -C "${work}/proj" branch taken
if ! out="$(cd "${other}" && "${GIT_NEW_BRANCH}" --clean taken 2>&1)"; then
  fail "git-new-branch --clean taken failed: ${out}"
fi
if [ "$(host_of "${work}/proj-branch-taken")" != "${other}" ]; then
  fail "taken is registered in $(host_of "${work}/proj-branch-taken"), not in ${other}"
fi

# git-checkout-branch of a branch that the remote has.  It pulls in the
# directory that it is run in, not in the main clone.
echo "newer" > "${work}/seed/newer.txt"
git -C "${work}/seed" add newer.txt
git -C "${work}/seed" commit -q -m "Newer commit"
git -C "${work}/seed" push -q origin main
proj_head="$(git -C "${work}/proj" rev-parse HEAD)"
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

if [ "$(git -C "${work}/proj" rev-parse HEAD)" != "${proj_head}" ]; then
  fail "git-checkout-branch remote-only pulled in ${work}/proj"
fi

# git-checkout-branch of a local branch that the main clone has at another
# commit uses the branch directory's branch, and at the same commit uses the
# main clone's.
git -C "${other}" branch differs
git -C "${work}/proj" branch differs main
if ! out="$(cd "${other}" && "${GIT_CHECKOUT_BRANCH}" differs 2>&1)"; then
  fail "git-checkout-branch differs failed: ${out}"
fi
if [ "$(host_of "${work}/proj-branch-differs")" != "${other}" ]; then
  fail "differs is registered in $(host_of "${work}/proj-branch-differs"), not in ${other}"
fi
if [ "$(git -C "${work}/proj-branch-differs" rev-parse HEAD)" != "$(git -C "${other}" rev-parse differs)" ]; then
  fail "proj-branch-differs is not at the commit of ${other}'s branch differs"
fi
git -C "${other}" branch same "$(git -C "${work}/proj" rev-parse main)"
git -C "${work}/proj" branch same main
if ! out="$(cd "${other}" && "${GIT_CHECKOUT_BRANCH}" same 2>&1)"; then
  fail "git-checkout-branch same failed: ${out}"
fi
if [ "$(host_of "${work}/proj-branch-same")" != "${work}/proj" ]; then
  fail "same is registered in $(host_of "${work}/proj-branch-same"), not in ${work}/proj"
fi

# A local branch that the main clone has at the same commit, but with another
# upstream, uses the branch directory's branch, and so its upstream.
git -C "${other}" branch configured "$(git -C "${work}/proj" rev-parse main)"
git -C "${other}" config branch.configured.remote origin
git -C "${other}" config branch.configured.merge refs/heads/configured
git -C "${work}/proj" branch configured main
if ! out="$(cd "${other}" && "${GIT_CHECKOUT_BRANCH}" configured 2>&1)"; then
  fail "git-checkout-branch configured failed: ${out}"
fi
if [ "$(host_of "${work}/proj-branch-configured")" != "${other}" ]; then
  fail "configured is registered in $(host_of "${work}/proj-branch-configured"), not in ${other}"
fi
if [ "$(git -C "${work}/proj-branch-configured" config --get branch.configured.remote)" != 'origin' ]; then
  fail "proj-branch-configured has no upstream"
fi

# A local branch that the main clone has at the same commit and with the same
# upstream, but that the main clone pushes elsewhere, uses the branch
# directory's branch:  first because of `remote.pushDefault`, then because of
# a `pushurl`.
for pushed in pushdefault pushurl; do
  git -C "${other}" branch "${pushed}" "$(git -C "${work}/proj" rev-parse main)"
  git -C "${work}/proj" branch "${pushed}" main
  for repo in "${other}" "${work}/proj"; do
    git -C "${repo}" config "branch.${pushed}.remote" origin
    git -C "${repo}" config "branch.${pushed}.merge" "refs/heads/${pushed}"
  done
done
git -C "${work}/proj" remote add elsewhere "${work}/remote.git"
git -C "${work}/proj" remote set-url --push elsewhere "${work}/elsewhere.git"
git -C "${work}/proj" config remote.pushDefault elsewhere
if ! out="$(cd "${other}" && "${GIT_CHECKOUT_BRANCH}" pushdefault 2>&1)"; then
  fail "git-checkout-branch pushdefault failed: ${out}"
fi
git -C "${work}/proj" config --unset remote.pushDefault
git -C "${work}/proj" remote remove elsewhere
git -C "${work}/proj" remote set-url --push origin "${work}/elsewhere.git"
if ! out="$(cd "${other}" && "${GIT_CHECKOUT_BRANCH}" pushurl 2>&1)"; then
  fail "git-checkout-branch pushurl failed: ${out}"
fi
git -C "${work}/proj" config --unset remote.origin.pushurl
for pushed in pushdefault pushurl; do
  if [ "$(host_of "${work}/proj-branch-${pushed}")" != "${other}" ]; then
    fail "${pushed} is registered in $(host_of "${work}/proj-branch-${pushed}"), not in ${other}"
  fi
done

# A local branch that the main clone has at the same commit, but that a
# worktree of the main clone has checked out, uses the branch directory's
# branch.
git -C "${other}" branch main "$(git -C "${work}/proj" rev-parse main)"
git -C "${other}" config branch.main.remote origin
git -C "${other}" config branch.main.merge refs/heads/main
if ! out="$(cd "${other}" && "${GIT_CHECKOUT_BRANCH}" main 2>&1)"; then
  fail "git-checkout-branch main failed: ${out}"
fi
if [ "$(host_of "${work}/proj-branch-main")" != "${other}" ]; then
  fail "main is registered in $(host_of "${work}/proj-branch-main"), not in ${other}"
fi

# A local branch that a worktree of the branch directory has checked out is
# refused, as it is without a main clone, rather than checked out a second
# time in the main clone.
git -C "${other}" branch both "$(git -C "${work}/proj" rev-parse main)"
git -C "${work}/proj" branch both main
git -C "${other}" worktree add -q "${work}/elsewhere" both
if out="$(cd "${other}" && "${GIT_CHECKOUT_BRANCH}" both 2>&1)"; then
  fail "git-checkout-branch both succeeded, though ${work}/elsewhere has it checked out"
fi
[ ! -e "${work}/proj-branch-both" ] || fail "proj-branch-both was created"

# A remote that only the branch directory has fetched, which the main clone
# knows by another name.  The branch's upstream is the main clone's name for
# the remote.
git init -q --bare -b main "${work}/fork.git"
git -C "${work}/seed" push -q "${work}/fork.git" main:refs/heads/fork-only main:refs/heads/fork-taken
git -C "${other}" remote add fork "${work}/fork.git"
git -C "${other}" fetch -q fork
git -C "${work}/proj" remote add mine "${work}/fork.git"
if ! out="$(cd "${other}" && "${GIT_CHECKOUT_BRANCH}" fork-only 2>&1)"; then
  fail "git-checkout-branch fork-only failed: ${out}"
fi
if [ "$(host_of "${work}/proj-branch-fork-only")" != "${work}/proj" ]; then
  fail "fork-only is registered in $(host_of "${work}/proj-branch-fork-only"), not in ${work}/proj"
fi
if [ "$(git -C "${work}/proj" config --get branch.fork-only.remote)" != 'mine' ]; then
  fail "fork-only's upstream remote is [$(git -C "${work}/proj" config --get branch.fork-only.remote)], not mine"
fi
if [ "$(git -C "${work}/proj" config --get branch.fork-only.merge)" != 'refs/heads/fork-only' ]; then
  fail "fork-only's upstream branch is [$(git -C "${work}/proj" config --get branch.fork-only.merge)], not refs/heads/fork-only"
fi

# A remote that the main clone lacks.
git init -q --bare -b main "${work}/solo.git"
git -C "${work}/seed" push -q "${work}/solo.git" main:refs/heads/solo-only
git -C "${other}" remote add solo "${work}/solo.git"
git -C "${other}" fetch -q solo
if ! out="$(cd "${other}" && "${GIT_CHECKOUT_BRANCH}" solo-only 2>&1)"; then
  fail "git-checkout-branch solo-only failed: ${out}"
fi
if [ "$(host_of "${work}/proj-branch-solo-only")" != "${other}" ]; then
  fail "solo-only is registered in $(host_of "${work}/proj-branch-solo-only"), not in ${other}"
fi

# git-new-branch asks the remote that the main clone would push the new
# branch to.
git -C "${work}/proj" config remote.pushDefault mine
if out="$(cd "${other}" && "${GIT_NEW_BRANCH}" --clean fork-taken 2>&1)"; then
  fail "git-new-branch fork-taken succeeded, though ${work}/proj pushes to mine, which has it"
fi
case "${out}" in
  *"registering the new worktree"*) fail "git-new-branch fork-taken said that it registered a worktree: ${out}" ;;
esac
[ ! -e "${work}/proj-branch-fork-taken" ] || fail "proj-branch-fork-taken was created"
git -C "${work}/proj" config --unset remote.pushDefault

# A sparse main clone is not used.
git -C "${work}/proj" config core.sparseCheckout true
if ! out="$(cd "${other}" && "${GIT_NEW_BRANCH}" --clean sparse 2>&1)"; then
  fail "git-new-branch --clean sparse failed: ${out}"
fi
if [ "$(host_of "${work}/proj-branch-sparse")" != "${other}" ]; then
  fail "sparse is registered in $(host_of "${work}/proj-branch-sparse"), not in ${other}"
fi
git -C "${work}/proj" config --unset core.sparseCheckout

# A shallow branch directory, whose commit the main clone cannot fetch, falls
# back to registering the worktree in itself.  The branch directory's commit
# is the second of two new commits, so the main clone lacks the parent of the
# commit at the shallow boundary.  A local clone ignores --depth, so this one
# is made through a file: URL, and then given the URL that the main clone
# has.
for newest in newest1 newest2; do
  echo "${newest}" > "${work}/seed/${newest}.txt"
  git -C "${work}/seed" add "${newest}.txt"
  git -C "${work}/seed" commit -q -m "Commit ${newest}"
done
git -C "${work}/seed" push -q origin main:refs/heads/shallow
git clone -q --depth 1 -b shallow "file://${work}/remote.git" "${work}/proj-branch-shallow"
git -C "${work}/proj-branch-shallow" config remote.origin.url "${work}/remote.git"
if ! out="$(cd "${work}/proj-branch-shallow" && "${GIT_NEW_BRANCH}" --clean from-shallow 2>&1)"; then
  fail "git-new-branch --clean from-shallow failed: ${out}"
fi
if [ "$(host_of "${work}/proj-branch-from-shallow")" != "${work}/proj-branch-shallow" ]; then
  fail "from-shallow is registered in $(host_of "${work}/proj-branch-from-shallow"), not in ${work}/proj-branch-shallow"
fi

# Run in a linked worktree of the branch directory, the message names the
# branch directory that is freed.
git -C "${other}" worktree add -q -b linked "${work}/proj-branch-linked"
if ! out="$(cd "${work}/proj-branch-linked" && "${GIT_NEW_BRANCH}" --clean from-linked 2>&1)"; then
  fail "git-new-branch --clean from-linked failed: ${out}"
fi
case "${out}" in
  *"rather than in ${other}, so that ${other} can be removed independently"*) ;;
  *) fail "git-new-branch from-linked named the wrong directory: ${out}" ;;
esac

# A main clone of a different project is not used.
git init -q -b main "${work}/unrelated"
git clone -q -b other "${work}/remote.git" "${work}/unrelated-branch-other"
if ! out="$(cd "${work}/unrelated-branch-other" && "${GIT_NEW_BRANCH}" --clean new3 2>&1)"; then
  fail "git-new-branch --clean new3 failed: ${out}"
fi
if [ "$(host_of "${work}/unrelated-branch-new3")" != "${work}/unrelated-branch-other" ]; then
  fail "new3 is registered in $(host_of "${work}/unrelated-branch-new3"), not in ${work}/unrelated-branch-other"
fi

# A main clone whose remote's URL differs from the branch directory's only
# after a space is a clone of a different project.
mkdir "${work}/My Repos"
for spaced in a b; do
  git init -q --bare -b main "${work}/My Repos/${spaced}.git"
  git -C "${work}/seed" push -q "${work}/My Repos/${spaced}.git" main
done
git clone -q "${work}/My Repos/b.git" "${work}/spaced"
git clone -q "${work}/My Repos/a.git" "${work}/spaced-branch-main"
if ! out="$(cd "${work}/spaced-branch-main" && "${GIT_NEW_BRANCH}" --clean new5 2>&1)"; then
  fail "git-new-branch --clean new5 failed: ${out}"
fi
if [ "$(host_of "${work}/spaced-branch-new5")" != "${work}/spaced-branch-main" ]; then
  fail "new5 is registered in $(host_of "${work}/spaced-branch-new5"), not in ${work}/spaced-branch-main"
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
