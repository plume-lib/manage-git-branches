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

# Usage: expect_outgoing DESCRIPTION EXPECTED [GIT-LOG-ARGS]
# Runs `git-outgoing --format=%s GIT-LOG-ARGS` in ${clone}, and checks that it
# succeeds and prints the subjects EXPECTED, one per line, in any order.
expect_outgoing() {
  description="$1"
  expected="$(printf '%s' "$2" | sort)"
  shift 2
  actual="$(cd "${clone}" && "${GIT_OUTGOING}" --format=%s "$@")"
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

# A path limit in the arguments does not show pushed commits.
expect_outgoing 'path limit, unpushed file' 'Feature commit 1' -- f.txt
expect_outgoing 'path limit, pushed file' '' -- a.txt

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

# A later upstream change to a file that the branch changed does not make the
# squash-merged branch outgoing.
commit_file "${upstream_work}" f.txt 'f2' 'Upstream change to f.txt'
git -C "${upstream_work}" push -q origin main
git -C "${clone}" fetch -q origin
expect_outgoing 'squash-merged branch, later upstream change' ''

# A branch started from the squash-merged branch shows only its own commits.
git -C "${clone}" branch -q stacked feature
git -C "${clone}" worktree add -q "${testdir}/myrepo-branch-stacked" stacked
commit_file "${testdir}/myrepo-branch-stacked" s.txt 's' 'Stacked commit'
expect_outgoing 'branch stacked on a squash-merged branch' 'Stacked commit'
git -C "${clone}" worktree remove --force "${testdir}/myrepo-branch-stacked"
git -C "${clone}" branch -q -D stacked

# A branch with no history in common with origin/HEAD is outgoing.
empty_tree="$(git -C "${clone}" mktree < /dev/null)"
orphan_commit="$(git -C "${clone}" commit-tree -m 'Orphan commit' "${empty_tree}")"
git -C "${clone}" branch -q orphan "${orphan_commit}"
expect_outgoing 'orphan branch' 'Orphan commit'
git -C "${clone}" branch -q -D orphan

# A branch whose changes conflict with origin/HEAD is outgoing.
git -C "${clone}" branch -q conflicting origin/main
git -C "${clone}" worktree add -q "${testdir}/myrepo-branch-conflicting" conflicting
commit_file "${testdir}/myrepo-branch-conflicting" a.txt 'conflict' 'Conflicting commit'
commit_file "${upstream_work}" a.txt 'a3' 'Upstream change to a.txt'
git -C "${upstream_work}" push -q origin main
git -C "${clone}" fetch -q origin
# The merge has conflicts, so its result has new objects, but the command
# does not write them to the repository.
objects_before="$(find "${clone}/.git/objects" -type f | wc -l)"
expect_outgoing 'conflicting branch' 'Conflicting commit'
objects_after="$(find "${clone}/.git/objects" -type f | wc -l)"
if [ "${objects_before}" -ne "${objects_after}" ]; then
  fail "conflicting branch: object count changed from ${objects_before} to ${objects_after}"
fi
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

# A remote whose name contains a slash is considered.
git -C "${clone}" remote add foo/bar "${upstream_remote}"
git -C "${clone}" fetch -q foo/bar
git -C "${clone}" remote set-head foo/bar main > /dev/null
expect_outgoing 'remote name with a slash' ''

# If `git merge-tree --write-tree` is not supported, as before git 2.38, the
# command fails rather than treating every branch as not merged.
fake_git_dir="${testdir}/fake-git"
mkdir "${fake_git_dir}"
real_git="$(command -v git)"
cat > "${fake_git_dir}/git" << EOF
#!/bin/sh
if [ "\$1" = merge-tree ]; then
  echo 'usage: git merge-tree' >&2
  exit 129
fi
exec "${real_git}" "\$@"
EOF
chmod +x "${fake_git_dir}/git"
if (cd "${clone}" && PATH="${fake_git_dir}:${PATH}" "${GIT_OUTGOING}") > /dev/null 2>&1; then
  fail 'git merge-tree unsupported: expected a failure status'
fi

# In a partial clone, a branch whose check needs file contents that have not
# been fetched is shown, and the command does not contact the remote.
git -C "${remote}" config uploadpack.allowFilter true
partial="${testdir}/myrepo-partial"
git clone -q --filter=blob:none "file://${remote}" "${partial}"
git -C "${partial}" checkout -q -b edit
commit_file "${partial}" a.txt 'edit' 'Partial clone commit'
commit_file "${upstream_work}" a.txt 'a4' 'Upstream change to a.txt again'
git -C "${upstream_work}" push -q origin main
git -C "${partial}" fetch -q origin
mv "${remote}" "${remote}.unreachable"
partial_output="$(cd "${partial}" && "${GIT_OUTGOING}" --format=%s 2> "${testdir}/partial-errors")"
partial_status="$?"
mv "${remote}.unreachable" "${remote}"
if [ "${partial_status}" -ne 0 ]; then
  fail "partial clone: exited with status ${partial_status}: $(cat "${testdir}/partial-errors")"
elif [ "${partial_output}" != 'Partial clone commit' ]; then
  fail "partial clone: printed [${partial_output}], expected [Partial clone commit]"
elif ! grep -q 'partial clone' "${testdir}/partial-errors"; then
  fail "partial clone: printed no warning"
fi

# Outside a git repository, the command fails.
if (cd "${testdir}" && "${GIT_OUTGOING}") > /dev/null 2>&1; then
  fail 'outside a repository: expected a failure status'
fi

if [ "${failures}" -ne 0 ]; then
  echo "${SCRIPT_NAME}: ${failures} test(s) failed" >&2
  exit 1
fi

echo "${SCRIPT_NAME}: OK"
