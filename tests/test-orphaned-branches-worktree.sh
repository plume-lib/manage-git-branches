#!/bin/sh

# Tests that `git-orphaned-branches` recognizes a linked git worktree, whose
# `.git` is a file rather than a directory, as a clone.
#
# Usage:
#   tests/test-orphaned-branches-worktree.sh

set -e

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"
REPO_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $1" >&2
  exit 1
}

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT INT TERM

GIT_AUTHOR_NAME='manage-git-branches test'
GIT_AUTHOR_EMAIL='test@example.com'
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
# Ignore the invoking user's git configuration, which might set commit signing,
# a rebasing pull, or a hooks path.
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

remote="${workdir}/remote.git"
git init -q --bare -b main "${remote}"

scandir="${workdir}/scan"
mkdir "${scandir}"

# A conventional clone, on a branch that still exists in the remote.
maindir="${scandir}/myrepo-branch-main"
git clone -q "${remote}" "${maindir}"
git -C "${maindir}" config pull.rebase false
date > "${maindir}/initial.txt"
git -C "${maindir}" add initial.txt
git -C "${maindir}" commit -q -m "initial commit"
git -C "${maindir}" push -q -u origin main

# A linked worktree, on a branch that is deleted in the remote.  Within the
# worktree, `.git` is a file that points into ${maindir}/.git .
featdir="${scandir}/myrepo-branch-feat"
git -C "${maindir}" worktree add -q -b feat "${featdir}"
git -C "${featdir}" config pull.rebase false
git -C "${featdir}" push -q -u origin feat
git -C "${maindir}" push -q origin --delete feat

if [ -d "${featdir}/.git" ]; then
  fail "${featdir}/.git is a directory; the test does not exercise a linked worktree"
fi

actual="$(cd "${scandir}" && "${REPO_DIR}/git-orphaned-branches")"
expected="$(realpath "${featdir}")"

if [ "${actual}" != "${expected}" ]; then
  fail "git-orphaned-branches printed
${actual}
but expected
${expected}"
fi

echo "${SCRIPT_NAME}: OK"
