#!/bin/sh

# Tests `git-pull-upstream`.
#
# Usage:
#   tests/test-git-pull-upstream.sh
#
# The status code is 0 if all tests pass and 1 otherwise.
#
# The tests use local "remote" repositories, so they do not access the network.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"
COMMANDS_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)" || exit 1
GIT_PULL_UPSTREAM="${COMMANDS_DIR}/git-pull-upstream"

. "${SCRIPT_DIR}/lib-git-test-env.sh"
# shellcheck source=common-test-functions.sh
. "${SCRIPT_DIR}/common-test-functions.sh"

failures=0

# Prints a message and records a test failure.
fail() {
  echo "${SCRIPT_NAME}: FAIL: $1" >&2
  failures=$((failures + 1))
}

# Usage: pull_upstream DIRECTORY [ARGS]
# Runs `git-pull-upstream ARGS` in DIRECTORY, writing its standard error to
# ${testdir}/errors.
pull_upstream() {
  (cd "$1" && shift && "${GIT_PULL_UPSTREAM}" "$@") > /dev/null 2> "${testdir}/errors"
}

# Usage: pushed_head
# Prints the commit that branch "feature" has in the fork's remote repository.
pushed_head() {
  git -C "${fork_remote}" rev-parse refs/heads/feature
}

testdir="$(mktemp -d)"
trap 'rm -rf "${testdir}"' EXIT
trap 'rm -rf "${testdir}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${testdir}"; trap - TERM; kill -s TERM "$$"' TERM

sanitize_git_env "${testdir}"

# The canonical repository, whose default branch is not named "main", and a
# fork of it, with a branch "feature" that has an upstream branch.  The
# Makefile builds successfully unless the file "broken" exists.
canonical="${testdir}/canonical.git"
git init -q --bare -b trunk "${canonical}"
canonical_work="${testdir}/canonical-work"
git clone -q "${canonical}" "${canonical_work}" 2> /dev/null
printf 'all:\n\ttest ! -e broken\n' > "${canonical_work}/Makefile"
git -C "${canonical_work}" add Makefile
commit_file "${canonical_work}" a.txt 'a1'
git -C "${canonical_work}" push -q origin trunk
fork_remote="${testdir}/fork.git"
git clone -q --bare "${canonical}" "${fork_remote}"

fork="${testdir}/fork"
git clone -q "${fork_remote}" "${fork}"
git -C "${fork}" remote add upstream "${canonical}"
git -C "${fork}" switch -q -c feature
mkdir "${fork}/subdir"
commit_file "${fork}" subdir/b.txt 'b1'
git -C "${fork}" push -q -u origin feature

# The fork's branch already contains the default branch of `upstream`.
before="$(git -C "${fork}" rev-parse HEAD)"
if ! pull_upstream "${fork}"; then
  fail "up to date: failed: $(cat "${testdir}/errors")"
elif [ "$(git -C "${fork}" rev-parse HEAD)" != "${before}" ]; then
  fail "up to date: changed HEAD"
fi

# A new commit in `upstream` is merged and pushed, even when this command is
# run in a subdirectory.
commit_file "${canonical_work}" a.txt 'a2'
git -C "${canonical_work}" push -q origin trunk
if ! pull_upstream "${fork}/subdir"; then
  fail "merge: failed: $(cat "${testdir}/errors")"
else
  subject="$(git -C "${fork}" log -1 --format=%s)"
  if [ "${subject}" != "Merge remote-tracking branch 'upstream/trunk' into feature" ]; then
    fail "merge: wrong merge message: ${subject}"
  fi
  if [ "$(cat "${fork}/a.txt")" != 'a2' ]; then
    fail "merge: did not merge a.txt"
  fi
  if [ "$(pushed_head)" != "$(git -C "${fork}" rev-parse HEAD)" ]; then
    fail "merge: did not push"
  fi
fi

# The current branch is pulled from its own upstream branch first.
other="${testdir}/other"
git clone -q -b feature "${fork_remote}" "${other}"
commit_file "${other}" c.txt 'c1'
git -C "${other}" push -q origin feature
commit_file "${canonical_work}" a.txt 'a3'
git -C "${canonical_work}" push -q origin trunk
if ! pull_upstream "${fork}"; then
  fail "pull first: failed: $(cat "${testdir}/errors")"
elif [ ! -e "${fork}/c.txt" ] || [ "$(cat "${fork}/a.txt")" != 'a3' ]; then
  fail "pull first: did not pull and merge"
fi

# A merge that does not build is not pushed, unless `--nocompile` is given.
pushed_before="$(pushed_head)"
commit_file "${canonical_work}" broken 'x'
git -C "${canonical_work}" push -q origin trunk
if pull_upstream "${fork}"; then
  fail "build failure: succeeded"
elif [ "$(pushed_head)" != "${pushed_before}" ]; then
  fail "build failure: pushed"
fi

# The merge that was not pushed survives the pull of a new commit on the
# branch, even when `pull.rebase` is set, and the pull's own merge does not
# stop at an editor.  `GIT_MERGE_AUTOEDIT` makes git start the editor even
# though no terminal is attached, and the editor `false` makes the merge fail.
unpushed_merge="$(git -C "${fork}" rev-parse HEAD)"
git -C "${other}" pull -q --no-rebase
commit_file "${other}" c.txt 'c2'
git -C "${other}" push -q origin feature
git -C "${fork}" config pull.rebase true
if ! GIT_MERGE_AUTOEDIT=yes GIT_EDITOR=false pull_upstream "${fork}" --nocompile; then
  fail "--nocompile: failed: $(cat "${testdir}/errors")"
elif [ "$(pushed_head)" != "$(git -C "${fork}" rev-parse HEAD)" ]; then
  fail "--nocompile: did not push"
elif ! git -C "${fork}" merge-base --is-ancestor "${unpushed_merge}" HEAD; then
  fail "--nocompile: lost the merge that was not pushed"
elif [ "$(cat "${fork}/c.txt")" != 'c2' ]; then
  fail "--nocompile: did not pull c.txt"
fi
git -C "${fork}" config --unset pull.rebase

# A conflicting merge fails and is not pushed.
commit_file "${fork}" a.txt 'fork'
git -C "${fork}" push -q
pushed_before="$(pushed_head)"
commit_file "${canonical_work}" a.txt 'canonical'
git -C "${canonical_work}" push -q origin trunk
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "conflict: succeeded"
elif [ "$(pushed_head)" != "${pushed_before}" ]; then
  fail "conflict: pushed"
fi
git -C "${fork}" merge --abort

# Without an `upstream` remote, `origin` is the upstream repository.
git -C "${fork}" remote remove upstream
if ! MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "origin: failed: $(cat "${testdir}/errors")"
fi

# An extra argument is rejected.
if pull_upstream "${fork}" extra; then
  fail "extra argument: succeeded"
fi

if [ "${failures}" -ne 0 ]; then
  echo "${SCRIPT_NAME}: ${failures} failure(s)" >&2
  exit 1
fi
