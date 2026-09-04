#!/bin/sh

# Tests that the debug output of `git-orphaned-branches` names the command that
# actually failed: `git ls-remote` when the remote is unreachable, and
# `git config --get remote.origin.url` when the clone has no origin.
#
# Usage:
#   tests/test-orphaned-branches-debug-message.sh

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
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

## A clone whose origin URL exists but is unreachable.

unreachable="${workdir}/myrepo-branch-unreachable"
git init -q -b main "${unreachable}"
git -C "${unreachable}" remote add origin "${workdir}/no-such-remote.git"

output="$(cd "${workdir}" && DEBUG=1 "${REPO_DIR}/git-orphaned-branches" 2>&1)"

case "${output}" in
  *"ls-remote"*) ;;
  *) fail "debug output for an unreachable remote does not mention ls-remote: ${output}" ;;
esac
case "${output}" in
  *"config --get"*)
    fail "debug output for an unreachable remote blames config --get: ${output}"
    ;;
esac

## A clone with no origin at all.

git -C "${unreachable}" remote remove origin

output="$(cd "${workdir}" && DEBUG=1 "${REPO_DIR}/git-orphaned-branches" 2>&1)"

case "${output}" in
  *"config --get"*) ;;
  *) fail "debug output for a clone with no origin does not mention config --get: ${output}" ;;
esac

echo "${SCRIPT_NAME}: OK"
