#!/bin/sh

# Tests `git-diff-upstream`.
#
# Usage:
#   tests/test-git-diff-upstream.sh
#
# The status code is 0 if all tests pass and 1 otherwise.
#
# The tests use local "remote" repositories, so they do not access the network.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"
COMMANDS_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)" || exit 1
GIT_DIFF_UPSTREAM="${COMMANDS_DIR}/git-diff-upstream"

. "${SCRIPT_DIR}/lib-git-test-env.sh"
# shellcheck source=common-test-functions.sh
. "${SCRIPT_DIR}/common-test-functions.sh"

failures=0

# Prints a message and records a test failure.
fail() {
  echo "${SCRIPT_NAME}: FAIL: $1" >&2
  failures=$((failures + 1))
}

# Usage: expect_files DESCRIPTION EXPECTED [ARGS]
# Runs `git-diff-upstream ARGS` in ${fork}, and checks that it
# succeeds and prints the file names EXPECTED, one per line.
expect_files() {
  description="$1"
  expected="$2"
  shift 2
  actual="$(cd "${fork}" && "${GIT_DIFF_UPSTREAM}" "$@" 2> "${testdir}/errors")"
  status="$?"
  if [ "${status}" -ne 0 ]; then
    fail "${description}: exited with status ${status}: $(cat "${testdir}/errors")"
  elif [ "${actual}" != "${expected}" ]; then
    fail "${description}: printed [${actual}], expected [${expected}]"
  fi
}

testdir="$(mktemp -d)"
trap 'rm -rf "${testdir}"' EXIT
trap 'rm -rf "${testdir}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${testdir}"; trap - TERM; kill -s TERM "$$"' TERM

sanitize_git_env "${testdir}"

# The canonical repository, whose default branch is not named "main", and a
# fork of it.
canonical="${testdir}/canonical.git"
git init -q --bare -b trunk "${canonical}"
canonical_work="${testdir}/canonical-work"
git clone -q "${canonical}" "${canonical_work}" 2> /dev/null
commit_file "${canonical_work}" a.txt 'a1'
commit_file "${canonical_work}" b.txt 'b1'
git -C "${canonical_work}" push -q origin trunk
fork_remote="${testdir}/fork.git"
git clone -q --bare "${canonical}" "${fork_remote}"

fork="${testdir}/fork"
git clone -q "${fork_remote}" "${fork}"
git -C "${fork}" switch -q -c feature
commit_file "${fork}" a.txt 'a2'

# With no `upstream` remote, the diff is against `origin`.
expect_files 'origin only' 'a.txt' --name-only

# `git remote add` does not create `upstream/HEAD`.
git -C "${fork}" remote add upstream "${canonical}"
commit_file "${canonical_work}" b.txt 'b2'
git -C "${canonical_work}" push -q origin trunk

# `--no-fetch` does not see the new commit in `upstream`, but this command
# still creates `upstream/HEAD`, which requires `upstream/trunk` to exist.
git -C "${fork}" fetch -q upstream
commit_file "${canonical_work}" c.txt 'c1'
git -C "${canonical_work}" push -q origin trunk
expect_files '--no-fetch' 'a.txt
b.txt' --no-fetch --name-only

# Fetching sees the new commit.
expect_files 'fetch' 'a.txt
b.txt
c.txt' --name-only

printf 'b2\n' > "${fork}/b.txt"
expect_files 'working tree' 'a.txt
c.txt' --name-only

# GIT-DIFF-ARGS may name paths.
expect_files 'path' 'c.txt' --name-only -- c.txt

# After `upstream` renames its default branch and a fetch with `--prune`
# deletes the old one, `upstream/HEAD` names a branch that does not exist.
git -C "${canonical}" branch -m trunk main
git -C "${fork}" fetch -q --prune upstream
# `rev-parse` warns about the dangling `upstream/HEAD`.
if git -C "${fork}" rev-parse --verify --quiet upstream/HEAD > /dev/null 2>&1; then
  fail 'renamed default branch: upstream/HEAD still resolves, so this test checks nothing'
fi
expect_files 'renamed default branch' 'a.txt
c.txt' --no-fetch --name-only

# After `upstream` renames its default branch again, a fetch without `--prune`
# keeps the old remote-tracking branch, so `upstream/HEAD` still resolves, to
# a commit that lacks the renamed branch's new commits.
git -C "${canonical}" branch -m main stable
commit_file "${canonical_work}" d.txt 'd1'
git -C "${canonical_work}" push -q origin HEAD:stable
git -C "${fork}" config fetch.prune false
# Git 2.48 and later update `upstream/HEAD` during the fetch, so this command
# needs no `git remote set-head`, which would connect to the remote again.
make_counting_git "${testdir}/counting-git" "${testdir}/git-commands"
saved_path="${PATH}"
PATH="${testdir}/counting-git:${PATH}"
expect_files 'renamed default branch without --prune' 'a.txt
c.txt
d.txt' --name-only
PATH="${saved_path}"
git_minor="$(git version | sed -n 's/^git version 2\.\([0-9]*\).*/\1/p')"
if [ -n "${git_minor}" ] && [ "${git_minor}" -ge 48 ] \
  && grep -q '^remote set-head' "${testdir}/git-commands"; then
  fail 'renamed default branch without --prune: ran git remote set-head'
fi

if [ "${failures}" -ne 0 ]; then
  echo "${SCRIPT_NAME}: ${failures} failure(s)" >&2
  exit 1
fi
