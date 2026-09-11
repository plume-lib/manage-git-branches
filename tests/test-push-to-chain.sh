#!/bin/sh

# Tests that `git-push-to` asks a remote about a chain of directories no more
# often than it has to.
#
# Usage:
#   tests/test-push-to-chain.sh
#
# `git-push-to A B C` calls its two-directory helper on (A, B) and then on
# (B, C), so B is checked twice:  once as the TO_DIR of the first call and
# once as the FROM_DIR of the second.  Each check asks whether the branch
# still exists in its remote.  One question per remote URL answers all of
# them, and in this package's workflow every directory of the chain is a
# clone of one upstream.
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(dirname -- "${TESTS_DIR}")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${WORK_DIR}"' EXIT
trap 'rm -rf "${WORK_DIR}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${WORK_DIR}"; trap - TERM; kill -s TERM "$$"' TERM

# shellcheck source=lib-git-test-env.sh
. "${TESTS_DIR}/lib-git-test-env.sh"
sanitize_git_env "${WORK_DIR}"
# shellcheck source=common-functions.sh
. "${TESTS_DIR}/common-functions.sh"

# The test repository contains no build file, so skip compilation.
MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1
export MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

## Usage: make_clone REMOTE BRANCH DIRECTORY
## Clones BRANCH of REMOTE into DIRECTORY, ready to be a link of a chain.
make_clone() {
  git clone -q -b "$2" "$1" "$3"
  # `sanitize_git_env` leaves the global configuration empty, and git refuses
  # to pull divergent branches unless something says how to reconcile them.
  # This workflow merges them.
  git -C "$3" config pull.rebase false
}

## Usage: push_to_chain DIRECTORY...
## Runs `git-push-to` on the chain, with the counting `git` first on PATH, and
## sets ${queries} to the number of questions it asked a remote.
push_to_chain() {
  : > "${GIT_COMMAND_LOG}"
  PATH="${WORK_DIR}/fake-bin:${PATH}" "${COMMANDS_DIR}/git-push-to" "$@"
  queries="$(count_remote_queries)"
}

## Create a remote with "main" and three branches of it, and a clone of each.
REMOTE="${WORK_DIR}/myrepo.git"
git init -q --bare -b main "${REMOTE}"
git init -q -b main "${WORK_DIR}/seed"
echo "first line" > "${WORK_DIR}/seed/file.txt"
git -C "${WORK_DIR}/seed" add file.txt
git -C "${WORK_DIR}/seed" commit -q -m "Initial commit"
git -C "${WORK_DIR}/seed" remote add origin "${REMOTE}"
git -C "${WORK_DIR}/seed" push -q --set-upstream origin main
for branch in part1 part2 part3; do
  git -C "${WORK_DIR}/seed" push -q origin "main:refs/heads/${branch}"
done

MAIN_DIR="${WORK_DIR}/myrepo-branch-main"
make_clone "${REMOTE}" main "${MAIN_DIR}"
for branch in part1 part2 part3; do
  make_clone "${REMOTE}" "${branch}" "${WORK_DIR}/myrepo-branch-${branch}"
done

make_counting_git "${WORK_DIR}/fake-bin" "${WORK_DIR}/git-commands.log"

## A change to propagate along the chain.
echo "second line" >> "${MAIN_DIR}/file.txt"
git -C "${MAIN_DIR}" commit -q -a -m "Add a second line"
git -C "${MAIN_DIR}" push -q

# A chain of four clones of one upstream asks one question.  Checking each
# directory separately would ask six:  two for each of the three pairs.
push_to_chain "${MAIN_DIR}" "${WORK_DIR}/myrepo-branch-part1" \
  "${WORK_DIR}/myrepo-branch-part2" "${WORK_DIR}/myrepo-branch-part3"
if [ "${queries}" -ne 1 ]; then
  fail "a four-directory chain asked ${queries} question(s) of one remote, not 1"
fi

# The chain did its work:  the change reached the last directory, and each
# directory was pushed to its remote.
for branch in part1 part2 part3; do
  if ! grep -q "second line" "${WORK_DIR}/myrepo-branch-${branch}/file.txt"; then
    fail "the change did not reach myrepo-branch-${branch}"
  fi
  local_head="$(git -C "${WORK_DIR}/myrepo-branch-${branch}" rev-parse HEAD)"
  remote_head="$(git -C "${REMOTE}" rev-parse "refs/heads/${branch}")"
  if [ "${local_head}" != "${remote_head}" ]; then
    fail "git-push-to did not push ${branch}: ${local_head} != ${remote_head}"
  fi
done

## A chain whose middle directory has a different upstream asks each upstream
## once.  The middle directory is the TO_DIR of the first call and the
## FROM_DIR of the second, so a check per call would ask its remote twice.
SECOND_REMOTE="${WORK_DIR}/myrepo2.git"
git init -q --bare -b main "${SECOND_REMOTE}"
git -C "${WORK_DIR}/seed" remote add second "${SECOND_REMOTE}"
git -C "${WORK_DIR}/seed" push -q second main:refs/heads/mirror
MIRROR_DIR="${WORK_DIR}/myrepo2-branch-mirror"
make_clone "${SECOND_REMOTE}" mirror "${MIRROR_DIR}"

echo "third line" >> "${MAIN_DIR}/file.txt"
git -C "${MAIN_DIR}" commit -q -a -m "Add a third line"
git -C "${MAIN_DIR}" push -q

push_to_chain "${MAIN_DIR}" "${MIRROR_DIR}" "${WORK_DIR}/myrepo-branch-part1"
if [ "${queries}" -ne 2 ]; then
  fail "a chain over two remotes asked ${queries} question(s), not 2"
fi
if ! grep -q "third line" "${WORK_DIR}/myrepo-branch-part1/file.txt"; then
  fail "the change did not reach myrepo-branch-part1 through the other remote"
fi

echo "${SCRIPT_NAME}: OK"
