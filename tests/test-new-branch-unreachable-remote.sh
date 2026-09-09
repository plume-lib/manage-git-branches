#!/bin/sh

# Tests that `git-new-branch` still creates the branch directory when the
# remote is unreachable -- for example, because it is offline or has been
# moved.  `git-new-branch` contacts the remote to bring the working copy up to
# date and to ask whether the branch already exists; it reports being unable to
# do the former, but neither failure is an error.
#
# Usage:
#   tests/test-new-branch-unreachable-remote.sh
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

# shellcheck source=common-functions.sh
. "${TESTS_DIR}/common-functions.sh"

isolate_git_configuration "${WORK_DIR}"

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

REMOTE="${WORK_DIR}/myrepo.git"
MAIN_DIR="${WORK_DIR}/myrepo-branch-main"
FEATURE_DIR="${WORK_DIR}/myrepo-branch-feature1"

## Creates a remote repository with one commit, and a clone of it in MAIN_DIR.
create_repositories() {
  git init -q --bare -b main "${REMOTE}"
  git init -q -b main "${WORK_DIR}/seed"
  echo "first line" > "${WORK_DIR}/seed/file.txt"
  git -C "${WORK_DIR}/seed" add file.txt
  git -C "${WORK_DIR}/seed" commit -q -m "Initial commit"
  git -C "${WORK_DIR}/seed" remote add origin "${REMOTE}"
  git -C "${WORK_DIR}/seed" push -q --set-upstream origin main
  rm -rf "${WORK_DIR}/seed"
  git clone -q "${REMOTE}" "${MAIN_DIR}"
}

create_repositories

# Make "origin" unreachable.  A nonexistent repository is the most portable way
# to do that: making the remote read-only would depend on file permissions, and
# rejecting a connection with a hook would not work under `core.hooksPath`.
git -C "${MAIN_DIR}" remote set-url origin "${WORK_DIR}/no-such-repository.git"

if ! output="$(cd "${MAIN_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature1 2>&1)"; then
  fail "git-new-branch failed when the remote could not be contacted: ${output}"
fi
if [ ! -d "${FEATURE_DIR}" ]; then
  fail "git-new-branch did not create ${FEATURE_DIR}: ${output}"
fi
if [ -e "${FEATURE_DIR}-TMP" ]; then
  fail "git-new-branch left behind ${FEATURE_DIR}-TMP"
fi

# The `git pull` that brings this working copy up to date fails when the remote
# is unreachable, and that failure is reported, because the new branch is based
# on a possibly stale commit; see `tests/test-branch-pull-failure.sh`.
case "${output}" in
  *"\`git pull\` failed"*) ;;
  *) fail "git-new-branch did not report the failed pull: ${output}" ;;
esac
# Being unable to reach the remote is not the user's problem to solve here, so
# the command continues rather than treating it as an error.
case "${output}" in
  *ERROR*) fail "git-new-branch treated the unreachable remote as an error: ${output}" ;;
esac
case "${output}" in
  *"continuing, using the current commit"*) ;;
  *) fail "git-new-branch did not say that it continued anyway: ${output}" ;;
esac

# The new working copy is on the new branch, and has no upstream, because
# `git-new-branch` does not push.
branch="$(git -C "${FEATURE_DIR}" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature1" ]; then
  fail "${FEATURE_DIR} is on branch ${branch}, not feature1"
fi
if git -C "${FEATURE_DIR}" rev-parse --symbolic-full-name '@{upstream}' > /dev/null 2>&1; then
  fail "${FEATURE_DIR} has an upstream, but git-new-branch does not push"
fi

# `git-new-branch` asks the remote without ever prompting.  A prompt would
# block forever:  this script discards the query's standard error, and it may
# run from another script or from a CI job.  `GIT_TERMINAL_PROMPT=0` does not
# suppress the prompts that SSH itself issues, such as the one for an unknown
# host key, so the SSH command must also be given the option that disables
# those.
SSH_DIR="${WORK_DIR}/myrepo-branch-ssh"
git clone -q "${REMOTE}" "${SSH_DIR}"
SSH_ARGUMENTS="${WORK_DIR}/ssh-arguments"
use_fake_ssh "${SSH_DIR}" "${SSH_ARGUMENTS}"

if ! output="$(cd "${SSH_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature2 2>&1)"; then
  fail "git-new-branch failed when the remote could not be reached over SSH: ${output}"
fi
if [ ! -d "${WORK_DIR}/myrepo-branch-feature2" ]; then
  fail "git-new-branch did not create ${WORK_DIR}/myrepo-branch-feature2: ${output}"
fi
if [ ! -s "${SSH_ARGUMENTS}" ]; then
  fail 'git-new-branch did not contact the remote over SSH'
elif ! grep -q -- '-o BatchMode=yes' "${SSH_ARGUMENTS}"; then
  fail "SSH invocation did not include \"-o BatchMode=yes\": [$(cat "${SSH_ARGUMENTS}")]"
fi

# Every test that needs no network access comes first, so a collision with an
# existing directory is reported without asking any remote about the branch.
# Waiting for a query -- possibly for as long as a connection attempt takes to
# time out -- before reporting a purely local failure would be pure delay.  The
# fake `ssh` counts the connections:  the `git pull` above makes one, and a
# query about the branch would make another.
: > "${SSH_ARGUMENTS}"
if output="$(cd "${SSH_DIR}" && "${COMMANDS_DIR}/git-new-branch" feature2 2>&1)"; then
  fail "git-new-branch created a branch whose directory exists: ${output}"
fi
case "${output}" in
  *"directory exists: ${WORK_DIR}/myrepo-branch-feature2"*) ;;
  *) fail "git-new-branch did not say that the directory exists: ${output}" ;;
esac
connections="$(grep -c '.' "${SSH_ARGUMENTS}" || true)"
if [ "${connections}" -ne 1 ]; then
  fail "git-new-branch made ${connections} SSH connections before reporting that the directory exists: [$(cat "${SSH_ARGUMENTS}")]"
fi

echo "${SCRIPT_NAME}: OK"
