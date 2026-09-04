#!/bin/sh

# Tests that `git-pull-from` accepts the `--nocompile` argument, just as
# `git-push-to` does.
#
# Usage:
#   tests/test-git-pull-from.sh
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"
REPO_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $1" >&2
  exit 1
}

# Creates a clone of ${remote} at the given directory, configured for merging.
make_clone() {
  git clone -q "${remote}" "$1"
  git -C "$1" config pull.rebase false
}

workdir="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT INT TERM

GIT_AUTHOR_NAME='manage-git-branches test'
GIT_AUTHOR_EMAIL='test@example.com'
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

remote="${workdir}/remote.git"
git init -q --bare -b main "${remote}"

# The Makefile that `compile-project` would run.  Its recipe creates a marker
# file, so the test can detect whether `compile-project` ran.
make_clone "${workdir}/from"
printf 'all:\n\ttouch compile-project-ran\n' > "${workdir}/from/Makefile"
git -C "${workdir}/from" add Makefile
git -C "${workdir}/from" commit -q -m "initial commit"
git -C "${workdir}/from" push -q -u origin main

make_clone "${workdir}/to"

date > "${workdir}/from/change.txt"
git -C "${workdir}/from" add change.txt
git -C "${workdir}/from" commit -q -m "a change"
git -C "${workdir}/from" push -q

if ! (cd "${workdir}/to" && "${REPO_DIR}/git-pull-from" --nocompile "${workdir}/from"); then
  fail "git-pull-from --nocompile failed"
fi
if [ ! -f "${workdir}/to/change.txt" ]; then
  fail "git-pull-from --nocompile did not merge the change"
fi
if [ -f "${workdir}/to/compile-project-ran" ]; then
  fail "git-pull-from --nocompile ran compile-project"
fi
if [ "$(git -C "${remote}" rev-parse main)" != "$(git -C "${workdir}/to" rev-parse HEAD)" ]; then
  fail "git-pull-from --nocompile did not push"
fi

echo "${SCRIPT_NAME}: OK"
