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
# shellcheck source=common-functions.sh
. "${SCRIPT_DIR}/common-functions.sh"

failures=0

# Prints a message and records a test failure.
fail() {
  echo "${SCRIPT_NAME}: FAIL: $1" >&2
  failures=$((failures + 1))
}

# Usage: expect_outgoing DESCRIPTION EXPECTED [GIT-LOG-ARGS]
# Runs `git-outgoing --format=%s GIT-LOG-ARGS` in ${clone}, and checks that it
# succeeds, prints the subjects EXPECTED, one per line, in any order, and
# prints nothing to standard error.
expect_outgoing() {
  description="$1"
  expected="$(printf '%s' "$2" | sort)"
  shift 2
  actual="$(cd "${clone}" && "${GIT_OUTGOING}" --format=%s "$@" 2> "${testdir}/errors")"
  status="$?"
  actual="$(printf '%s' "${actual}" | sort)"
  if [ "${status}" -ne 0 ]; then
    fail "${description}: exited with status ${status}: $(cat "${testdir}/errors")"
  elif [ "${actual}" != "${expected}" ]; then
    fail "${description}: printed [${actual}], expected [${expected}]"
  elif [ -s "${testdir}/errors" ]; then
    fail "${description}: printed to standard error: $(cat "${testdir}/errors")"
  fi
}

# Usage: commit_file DIRECTORY FILE CONTENT SUBJECT
# Writes CONTENT to FILE in the working tree DIRECTORY, and commits it.
commit_file() {
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -- "$2"
  git -C "$1" commit -q -m "$4"
}

# Usage: squash_merge BRANCH
# Pushes BRANCH from ${clone}, squash-merges it into main in ${upstream_work},
# deletes it from the remote, and fetches into ${clone}.
squash_merge() {
  git -C "${clone}" push -q origin "$1"
  git -C "${upstream_work}" pull -q origin main
  git -C "${upstream_work}" fetch -q origin "$1"
  git -C "${upstream_work}" merge -q --squash FETCH_HEAD > /dev/null
  git -C "${upstream_work}" commit -q -m "Squash-merged $1"
  git -C "${upstream_work}" push -q origin main
  git -C "${upstream_work}" push -q origin --delete "$1"
  git -C "${clone}" fetch -q --prune origin
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
squash_merge feature
if [ -z "$(git -C "${clone}" log --format=%s --branches --not --remotes)" ]; then
  fail 'test setup: git log --branches --not --remotes should show the squash-merged commits'
fi
expect_outgoing 'squash-merged branch' ''
# Naming the omitted branch does not show its commits.
expect_outgoing 'squash-merged branch, named as a revision' '' refs/heads/feature

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

# With no outgoing branch, a revision in the arguments is still shown, and an
# invalid argument is still reported.
loose_commit="$(git -C "${clone}" commit-tree -m 'Loose commit' "$(git -C "${clone}" mktree < /dev/null)")"
expect_outgoing 'no outgoing branch, revision argument' 'Loose commit' "${loose_commit}"
if (cd "${clone}" && "${GIT_OUTGOING}" --no-such-option) > /dev/null 2>&1; then
  fail 'no outgoing branch, invalid argument: expected a failure status'
fi

# A squash-merged branch that changes only a file with a non-ASCII name is not
# outgoing, even after a later upstream change to that file.
git -C "${clone}" branch -q unicode origin/main
git -C "${clone}" worktree add -q "${testdir}/myrepo-branch-unicode" unicode
commit_file "${testdir}/myrepo-branch-unicode" 'résumé.txt' 'r' 'Non-ASCII file name commit'
squash_merge unicode
commit_file "${upstream_work}" 'résumé.txt' 'r2' 'Upstream change to résumé.txt'
git -C "${upstream_work}" push -q origin main
git -C "${clone}" fetch -q origin
expect_outgoing 'squash-merged branch, non-ASCII file name' ''
git -C "${clone}" worktree remove --force "${testdir}/myrepo-branch-unicode"
git -C "${clone}" branch -q -D unicode

# A squash commit on the second parent of a merge is found, even though the
# merge's result for the branch's files equals its first parent's.
git -C "${clone}" branch -q sidesquash origin/main
git -C "${clone}" worktree add -q "${testdir}/myrepo-branch-sidesquash" sidesquash
commit_file "${testdir}/myrepo-branch-sidesquash" s2.txt 's2' 'Side squash commit'
git -C "${clone}" push -q origin sidesquash
git -C "${upstream_work}" pull -q origin main
git -C "${upstream_work}" checkout -q -b side
git -C "${upstream_work}" fetch -q origin sidesquash
git -C "${upstream_work}" merge -q --squash FETCH_HEAD > /dev/null
git -C "${upstream_work}" commit -q -m 'Squash-merged sidesquash on a side branch'
git -C "${upstream_work}" checkout -q main
printf '%s\n' 's2' > "${upstream_work}/s2.txt"
printf '%s\n' 'o' > "${upstream_work}/other.txt"
git -C "${upstream_work}" add s2.txt other.txt
git -C "${upstream_work}" commit -q -m 'Same change to s2.txt, and a change to other.txt'
git -C "${upstream_work}" merge -q --no-edit side
git -C "${upstream_work}" branch -q -D side
commit_file "${upstream_work}" s2.txt 's2b' 'Upstream change to s2.txt'
git -C "${upstream_work}" push -q origin main
git -C "${upstream_work}" push -q origin --delete sidesquash
git -C "${clone}" fetch -q --prune origin
expect_outgoing 'squash commit on the second parent of a merge' ''
git -C "${clone}" worktree remove --force "${testdir}/myrepo-branch-sidesquash"
git -C "${clone}" branch -q -D sidesquash

# A branch started from the squash-merged branch shows only its own commits.
git -C "${clone}" branch -q stacked feature
git -C "${clone}" worktree add -q "${testdir}/myrepo-branch-stacked" stacked
commit_file "${testdir}/myrepo-branch-stacked" s.txt 's' 'Stacked commit'
expect_outgoing 'branch stacked on a squash-merged branch' 'Stacked commit'
git -C "${clone}" worktree remove --force "${testdir}/myrepo-branch-stacked"
git -C "${clone}" branch -q -D stacked

# A squash-merged branch is not outgoing when the command runs from a
# subdirectory, even with `diff.relative=true`, and even though the branch
# also changes a file outside that subdirectory.
git -C "${clone}" branch -q subdir origin/main
git -C "${clone}" worktree add -q "${testdir}/myrepo-branch-subdir" subdir
mkdir "${testdir}/myrepo-branch-subdir/sub"
printf '%s\n' 'x' > "${testdir}/myrepo-branch-subdir/sub/x.txt"
printf '%s\n' 't' > "${testdir}/myrepo-branch-subdir/top.txt"
git -C "${testdir}/myrepo-branch-subdir" add sub/x.txt top.txt
git -C "${testdir}/myrepo-branch-subdir" commit -q -m 'Subdirectory commit'
squash_merge subdir
commit_file "${upstream_work}" sub/x.txt 'x2' 'Upstream change to sub/x.txt'
git -C "${upstream_work}" push -q origin main
git -C "${clone}" fetch -q origin
mkdir -p "${clone}/sub"
saved_clone="${clone}"
clone="${saved_clone}/sub"
expect_outgoing 'squash-merged branch, run from a subdirectory' ''
git -C "${saved_clone}" config diff.relative true
expect_outgoing 'squash-merged branch, run from a subdirectory, diff.relative' ''
git -C "${saved_clone}" config --unset diff.relative
clone="${saved_clone}"
git -C "${clone}" worktree remove --force "${testdir}/myrepo-branch-subdir"
git -C "${clone}" branch -q -D subdir

# A commit with an old committer date in origin/HEAD does not hide a squash
# commit behind it.
git -C "${clone}" branch -q skew origin/main
git -C "${clone}" worktree add -q "${testdir}/myrepo-branch-skew" skew
commit_file "${testdir}/myrepo-branch-skew" k.txt 'k' 'Skew commit'
squash_merge skew
commit_file "${upstream_work}" k.txt 'k2' 'Upstream change to k.txt'
(
  GIT_COMMITTER_DATE='2000-01-01T00:00:00Z'
  export GIT_COMMITTER_DATE
  commit_file "${upstream_work}" old.txt 'old' 'Commit with an old date'
)
if [ "$(git -C "${upstream_work}" log -1 --format=%cI)" != '2000-01-01T00:00:00Z' ]; then
  fail 'test setup: the commit should have an old committer date'
fi
git -C "${upstream_work}" push -q origin main
git -C "${clone}" fetch -q origin
expect_outgoing 'squash-merged branch, later commit with an old date' ''
git -C "${clone}" worktree remove --force "${testdir}/myrepo-branch-skew"
git -C "${clone}" branch -q -D skew

# A squash-merged branch whose last commit is amended, with a later committer
# date but the same author date, is not outgoing, even after a later upstream
# change to the branch's file.
git -C "${clone}" branch -q amended origin/main
git -C "${clone}" worktree add -q "${testdir}/myrepo-branch-amended" amended
(
  GIT_AUTHOR_DATE="$(($(date +%s) - 5 * 24 * 60 * 60)) +0000"
  GIT_COMMITTER_DATE="${GIT_AUTHOR_DATE}"
  export GIT_AUTHOR_DATE GIT_COMMITTER_DATE
  commit_file "${testdir}/myrepo-branch-amended" m.txt 'm' 'Amended commit'
)
(
  GIT_COMMITTER_DATE="$(($(date +%s) - 4 * 24 * 60 * 60)) +0000"
  export GIT_COMMITTER_DATE
  squash_merge amended
)
commit_file "${upstream_work}" m.txt 'm2' 'Upstream change to m.txt'
git -C "${upstream_work}" push -q origin main
git -C "${clone}" fetch -q origin
git -C "${testdir}/myrepo-branch-amended" commit -q --amend --no-edit
expect_outgoing 'squash-merged branch, amended afterward' ''
git -C "${clone}" worktree remove --force "${testdir}/myrepo-branch-amended"
git -C "${clone}" branch -q -D amended

# A squash-merged branch is not outgoing when it has two merge bases with
# origin/HEAD and the squash commit descends from only one of them.  The
# branch merges upstream's commit m1, and upstream squash-merges the branch on
# top of the branch's first commit b1, so b1 and m1 are both merge bases.
git -C "${clone}" branch -q crisscross origin/main
crisscross="${testdir}/myrepo-branch-crisscross"
git -C "${clone}" worktree add -q "${crisscross}" crisscross
commit_file "${crisscross}" x.txt 'x' 'Crisscross commit b1'
git -C "${clone}" push -q origin crisscross
commit_file "${upstream_work}" y.txt 'y' 'Crisscross upstream commit m1'
git -C "${upstream_work}" push -q origin main
git -C "${clone}" fetch -q origin
git -C "${crisscross}" merge -q --no-edit origin/main
commit_file "${crisscross}" x.txt 'x2' 'Crisscross commit b2'
git -C "${clone}" push -q origin crisscross
git -C "${upstream_work}" pull -q origin main
git -C "${upstream_work}" fetch -q origin crisscross
crisscross_b1="$(git -C "${upstream_work}" rev-parse FETCH_HEAD~1^1)"
git -C "${upstream_work}" checkout -q -b squashed "${crisscross_b1}"
git -C "${upstream_work}" merge -q --squash FETCH_HEAD > /dev/null
git -C "${upstream_work}" commit -q -m 'Squash-merged crisscross on b1'
git -C "${upstream_work}" checkout -q main
git -C "${upstream_work}" merge -q --no-edit squashed
git -C "${upstream_work}" branch -q -D squashed
commit_file "${upstream_work}" x.txt 'x3' 'Upstream change to x.txt'
git -C "${upstream_work}" push -q origin main
git -C "${upstream_work}" push -q origin --delete crisscross
git -C "${clone}" fetch -q --prune origin
if [ "$(git -C "${clone}" merge-base --all origin/main crisscross | wc -l)" -ne 2 ]; then
  fail 'test setup: crisscross should have two merge bases with origin/main'
fi
expect_outgoing 'squash-merged branch, two merge bases' ''
git -C "${clone}" worktree remove --force "${testdir}/myrepo-branch-crisscross"
git -C "${clone}" branch -q -D crisscross

# A squash-merged branch that changes only one file is not outgoing, even with
# `log.follow=true`.
git -C "${clone}" branch -q follow origin/main
git -C "${clone}" worktree add -q "${testdir}/myrepo-branch-follow" follow
commit_file "${testdir}/myrepo-branch-follow" w.txt 'w' 'Follow commit'
squash_merge follow
commit_file "${upstream_work}" w.txt 'w2' 'Upstream change to w.txt'
git -C "${upstream_work}" push -q origin main
git -C "${clone}" fetch -q origin
git -C "${clone}" config log.follow true
expect_outgoing 'squash-merged branch, log.follow' ''
git -C "${clone}" config --unset log.follow
git -C "${clone}" worktree remove --force "${testdir}/myrepo-branch-follow"
git -C "${clone}" branch -q -D follow

# A commit in origin/HEAD that changes only the branch's files, but that comes
# from a history unrelated to the branch, does not make the command fail.
git -C "${clone}" branch -q readme origin/main
git -C "${clone}" worktree add -q "${testdir}/myrepo-branch-readme" readme
commit_file "${testdir}/myrepo-branch-readme" README.md 'readme' 'Readme commit'
git -C "${upstream_work}" checkout -q --orphan unrelated
git -C "${upstream_work}" rm -q -r -f .
commit_file "${upstream_work}" u.txt 'u' 'Unrelated root commit'
commit_file "${upstream_work}" README.md 'other readme' 'Unrelated readme commit'
git -C "${upstream_work}" checkout -q main
git -C "${upstream_work}" merge -q --no-edit --allow-unrelated-histories unrelated
git -C "${upstream_work}" branch -q -D unrelated
git -C "${upstream_work}" push -q origin main
git -C "${clone}" fetch -q origin
expect_outgoing 'branch, with an unrelated history in origin/HEAD' 'Readme commit'
git -C "${clone}" worktree remove --force "${testdir}/myrepo-branch-readme"
git -C "${clone}" branch -q -D readme

# A squash-merged branch is not outgoing in a repository whose path contains
# a colon, which is the separator in GIT_ALTERNATE_OBJECT_DIRECTORIES.
saved_clone="${clone}"
clone="${testdir}/my:repo"
git clone -q "${remote}" "${clone}"
git -C "${clone}" checkout -q -b colon
commit_file "${clone}" c.txt 'c' 'Colon commit'
expect_outgoing 'unpushed branch, path with a colon' 'Colon commit'
squash_merge colon
commit_file "${upstream_work}" c.txt 'c2' 'Upstream change to c.txt'
git -C "${upstream_work}" push -q origin main
git -C "${clone}" fetch -q origin
expect_outgoing 'squash-merged branch, path with a colon' ''
clone="${saved_clone}"
git -C "${clone}" fetch -q origin

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

# A git older than 2.38, which lacks `git merge-tree --write-tree`, is rejected.
older_git_dir="${testdir}/older-git"
make_fake_git "${older_git_dir}" version 0 'git version 2.37.0'
if (cd "${clone}" && PATH="${older_git_dir}:${PATH}" "${GIT_OUTGOING}") > /dev/null 2> "${testdir}/older-git-errors"; then
  fail 'git 2.37: expected a failure status'
fi
if ! grep -q 'requires git 2.38 or later' "${testdir}/older-git-errors"; then
  fail 'git 2.37: expected a version error message'
fi

# A git older than 2.44, which lacks `GIT_NO_LAZY_FETCH`, suffices outside a
# partial clone.  A relative DIRECTORY for make_fake_git works after a `cd`.
old_git_dir="old-git"
(cd "${testdir}" && make_fake_git "${old_git_dir}" version 0 'git version 2.43.0')
old_git_output="$(cd "${clone}" && PATH="${testdir}/${old_git_dir}:${PATH}" "${GIT_OUTGOING}" --format=%s 2> "${testdir}/old-git-errors")"
old_git_status="$?"
if [ "${old_git_status}" -ne 0 ]; then
  fail "git 2.43: exited with status ${old_git_status}: $(cat "${testdir}/old-git-errors")"
elif [ "${old_git_output}" != "$(cd "${clone}" && "${GIT_OUTGOING}" --format=%s)" ]; then
  fail "git 2.43: printed [${old_git_output}]"
fi

# A git failure that is not due to a partial clone is reported, even when a
# remote is configured, but not as a promisor remote.
corrupt_git_dir="${testdir}/corrupt-git"
make_fake_git "${corrupt_git_dir}" merge-tree 128 'fatal: simulated corruption'
git -C "${clone}" config remote.origin.promisor false
if (cd "${clone}" && PATH="${corrupt_git_dir}:${PATH}" "${GIT_OUTGOING}") > /dev/null 2> "${testdir}/corrupt-errors"; then
  fail 'git failure, not a partial clone: expected a failure status'
fi
if ! grep -q 'simulated corruption' "${testdir}/corrupt-errors"; then
  fail 'git failure, not a partial clone: expected the git error message'
fi
git -C "${clone}" config --unset remote.origin.promisor

# In a partial clone, a branch whose check needs file contents or directories
# that have not been fetched is shown, with a warning that includes git's
# error, and the command does not contact the remote.
git -C "${remote}" config uploadpack.allowFilter true
for filter in blob:none tree:0; do
  partial="${testdir}/myrepo-partial-${filter%%:*}"
  git clone -q --filter="${filter}" "file://${remote}" "${partial}"
  git -C "${partial}" checkout -q -b edit
  commit_file "${partial}" a.txt 'edit' 'Partial clone commit'
  commit_file "${upstream_work}" a.txt "a-${filter}" "Upstream change to a.txt for ${filter}"
  git -C "${upstream_work}" push -q origin main
  git -C "${partial}" fetch -q origin
  mv "${remote}" "${remote}.unreachable"
  partial_output="$(cd "${partial}" && "${GIT_OUTGOING}" --format=%s 2> "${testdir}/partial-errors")"
  partial_status="$?"
  if [ "${partial_status}" -ne 0 ]; then
    fail "partial clone ${filter}: exited with status ${partial_status}: $(cat "${testdir}/partial-errors")"
  elif [ "${partial_output}" != 'Partial clone commit' ]; then
    fail "partial clone ${filter}: printed [${partial_output}], expected [Partial clone commit]"
  elif ! grep -q 'partial clone' "${testdir}/partial-errors"; then
    fail "partial clone ${filter}: printed no warning"
  elif ! grep -q 'fatal:' "${testdir}/partial-errors"; then
    fail "partial clone ${filter}: printed no git error"
  fi
  # A git failure that names no missing object is reported.
  if (cd "${partial}" && PATH="${corrupt_git_dir}:${PATH}" "${GIT_OUTGOING}") > /dev/null 2> "${testdir}/corrupt-errors"; then
    fail "partial clone ${filter}, git failure: expected a failure status"
  elif ! grep -q 'simulated corruption' "${testdir}/corrupt-errors"; then
    fail "partial clone ${filter}, git failure: expected the git error message"
  fi
  # git 2.43 is rejected in a partial clone.
  if (cd "${partial}" && PATH="${testdir}/${old_git_dir}:${PATH}" "${GIT_OUTGOING}") > /dev/null 2> "${testdir}/old-git-errors"; then
    fail "partial clone ${filter}, git 2.43: expected a failure status"
  elif ! grep -q 'requires git 2.44 or later in a partial clone' "${testdir}/old-git-errors"; then
    fail "partial clone ${filter}, git 2.43: expected a version error message"
  fi
  mv "${remote}.unreachable" "${remote}"
  # GIT-LOG-ARGS that need file contents that have not been fetched make the
  # command fail rather than fetch them, even though the remote is reachable.
  # The commit's parent is the upstream change, whose file contents have not
  # been fetched.
  on_upstream="$(git -C "${partial}" commit-tree -p origin/main -m 'On upstream' "edit^{tree}")"
  git -C "${partial}" branch -q on-upstream "${on_upstream}"
  if (cd "${partial}" && "${GIT_OUTGOING}" --stat) > /dev/null 2>&1; then
    fail "partial clone ${filter}, --stat: expected a failure status"
  fi
done

# Outside a git repository, the command fails.
if (cd "${testdir}" && "${GIT_OUTGOING}") > /dev/null 2>&1; then
  fail 'outside a repository: expected a failure status'
fi

if [ "${failures}" -ne 0 ]; then
  echo "${SCRIPT_NAME}: ${failures} test(s) failed" >&2
  exit 1
fi

echo "${SCRIPT_NAME}: OK"
