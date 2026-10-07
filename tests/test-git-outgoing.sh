#!/bin/sh

# Tests `git-outgoing`.
#
# Usage:
#   tests/test-git-outgoing.sh
#
# The status code is 0 if all tests pass and 1 otherwise.
#
# The tests use local "remote" repositories, so they do not access the network.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"
COMMANDS_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)" || exit 1
GIT_OUTGOING="${COMMANDS_DIR}/git-outgoing"

. "${SCRIPT_DIR}/lib-git-test-env.sh"

failures=0

# Prints a message and records a test failure.
fail() {
  echo "${SCRIPT_NAME}: FAIL: $1" >&2
  failures=$((failures + 1))
}

# Usage: expect_outgoing DESCRIPTION EXPECTED
# Runs `git-outgoing --format=%s` in ${clone}, and checks that it succeeds and
# prints the subjects EXPECTED, one per line, in any order.
expect_outgoing() {
  description="$1"
  expected="$(printf '%s' "$2" | sort)"
  actual="$(cd "${clone}" && "${GIT_OUTGOING}" --format=%s)"
  status="$?"
  actual="$(printf '%s' "${actual}" | sort)"
  if [ "${status}" -ne 0 ]; then
    fail "${description}: exited with status ${status}"
  elif [ "${actual}" != "${expected}" ]; then
    fail "${description}: printed [${actual}], expected [${expected}]"
  fi
}

# Usage: commit_file DIRECTORY FILE CONTENT SUBJECT
# Writes CONTENT to FILE in the working tree DIRECTORY, and commits it.
commit_file() {
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -- "$2"
  git -C "$1" commit -q -m "$4"
}

testdir="$(mktemp -d)"
trap 'rm -rf "${testdir}"' EXIT
trap 'rm -rf "${testdir}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${testdir}"; trap - TERM; kill -s TERM "$$"' TERM

sanitize_git_env "${testdir}"

# The remote "origin" and a working tree that plays the role of its other
# users, who push to it directly.
remote="${testdir}/myrepo-remote.git"
git init -q --bare -b main "${remote}"
upstream_work="${testdir}/upstream-work"
git clone -q "${remote}" "${upstream_work}" 2> /dev/null
commit_file "${upstream_work}" a.txt 'a' 'Initial commit'
git -C "${upstream_work}" push -q origin main

clone="${testdir}/myrepo"
git clone -q "${remote}" "${clone}"

expect_outgoing 'fresh clone' ''

# A commit that is pushed is not outgoing.
git -C "${clone}" branch -q pushed main
commit_file "${clone}" a.txt 'a2' 'Pushed commit'
git -C "${clone}" push -q origin main
expect_outgoing 'pushed commit' ''

# A branch with unpushed commits is outgoing.  `--format` is passed to `git log`.
git -C "${clone}" branch -q feature main
git -C "${clone}" worktree add -q "${testdir}/myrepo-branch-feature" feature
feature="${testdir}/myrepo-branch-feature"
commit_file "${feature}" f.txt 'f' 'Feature commit 1'
commit_file "${feature}" g.txt 'g' 'Feature commit 2'
expect_outgoing 'unpushed branch' 'Feature commit 1
Feature commit 2'

# The branch is pushed, squash-merged into main by someone else, and then
# deleted from the remote.  Its commits are no longer on any remote branch,
# but its changes are in origin/HEAD, so it is not outgoing.
git -C "${feature}" push -q origin feature
git -C "${upstream_work}" pull -q origin main
git -C "${upstream_work}" fetch -q origin feature
git -C "${upstream_work}" merge -q --squash FETCH_HEAD > /dev/null
git -C "${upstream_work}" commit -q -m 'Squash-merged feature'
git -C "${upstream_work}" push -q origin main
git -C "${upstream_work}" push -q origin --delete feature
git -C "${clone}" fetch -q --prune origin
if [ -z "$(git -C "${clone}" log --format=%s --branches --not --remotes)" ]; then
  fail 'test setup: git log --branches --not --remotes should show the squash-merged commits'
fi
expect_outgoing 'squash-merged branch' ''

# A commit after the squash-merge makes the branch outgoing again.  All of its
# commits are shown, because none of them is on a remote branch.
commit_file "${feature}" h.txt 'h' 'Feature commit 3'
expect_outgoing 'squash-merged branch with a later commit' 'Feature commit 1
Feature commit 2
Feature commit 3'
git -C "${feature}" reset -q --hard HEAD^

# A branch whose changes conflict with origin/HEAD is outgoing.
git -C "${clone}" branch -q conflicting origin/main
git -C "${clone}" worktree add -q "${testdir}/myrepo-branch-conflicting" conflicting
commit_file "${testdir}/myrepo-branch-conflicting" a.txt 'conflict' 'Conflicting commit'
commit_file "${upstream_work}" a.txt 'a3' 'Upstream change to a.txt'
git -C "${upstream_work}" push -q origin main
git -C "${clone}" fetch -q origin
expect_outgoing 'conflicting branch' 'Conflicting commit'
git -C "${clone}" worktree remove --force "${testdir}/myrepo-branch-conflicting"
git -C "${clone}" branch -q -D conflicting

# A remote with no REMOTE/HEAD is not considered, so a branch whose changes
# are only in such a remote's default branch is outgoing.
git -C "${clone}" remote set-head origin --delete
expect_outgoing 'no origin/HEAD' 'Feature commit 1
Feature commit 2'

# A second remote, "upstream", whose default branch contains the changes,
# suffices for the branch not to be outgoing, even though "origin" does not.
upstream_remote="${testdir}/upstream-remote.git"
git clone -q --bare "${remote}" "${upstream_remote}"
git -C "${clone}" remote add upstream "${upstream_remote}"
git -C "${clone}" fetch -q upstream
git -C "${clone}" remote set-head upstream main > /dev/null
expect_outgoing 'changes in second remote' ''

# A file named like a branch does not make the branch name ambiguous.
git -C "${clone}" remote set-head upstream --delete
: > "${clone}/feature"
expect_outgoing 'file named like a branch' 'Feature commit 1
Feature commit 2'

# Outside a git repository, the command fails.
if (cd "${testdir}" && "${GIT_OUTGOING}") > /dev/null 2>&1; then
  fail 'outside a repository: expected a failure status'
fi

if [ "${failures}" -ne 0 ]; then
  echo "${SCRIPT_NAME}: ${failures} test(s) failed" >&2
  exit 1
fi

echo "${SCRIPT_NAME}: OK"
