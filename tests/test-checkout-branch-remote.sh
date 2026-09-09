#!/bin/sh

# Tests which remote `git-checkout-branch` asks whether a branch exists, and
# that it asks without ever prompting.  Asking only the remote named "origin",
# as it once did, reported that the branch does not exist in a clone whose
# sole remote has some other name, so the command was unusable there.
#
# Usage:
#   tests/test-checkout-branch-remote.sh
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

## Creates a remote repository with a `main` and a `feature1` branch.
create_repositories() {
  git init -q --bare -b main "${REMOTE}"
  git init -q -b main "${WORK_DIR}/seed"
  echo "first line" > "${WORK_DIR}/seed/file.txt"
  git -C "${WORK_DIR}/seed" add file.txt
  git -C "${WORK_DIR}/seed" commit -q -m "Initial commit"
  git -C "${WORK_DIR}/seed" remote add origin "${REMOTE}"
  git -C "${WORK_DIR}/seed" push -q --set-upstream origin main
  git -C "${WORK_DIR}/seed" checkout -q -b feature1
  git -C "${WORK_DIR}/seed" push -q origin feature1
  rm -rf "${WORK_DIR}/seed"
}

create_repositories

# The clone's only remote is not named "origin", so a command that asks only
# "origin" asks no remote at all.
OTHER_NAME_DIR="${WORK_DIR}/othername"
git clone -q "${REMOTE}" "${OTHER_NAME_DIR}"
git -C "${OTHER_NAME_DIR}" remote rename origin elsewhere
if ! output="$(cd "${OTHER_NAME_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 2>&1)"; then
  fail "git-checkout-branch failed in a clone whose remote is not named origin: ${output}"
fi
branch="$(git -C "${WORK_DIR}/othername-branch-feature1" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature1" ]; then
  fail "${WORK_DIR}/othername-branch-feature1 is on branch ${branch}, not feature1"
fi
# The branch was created from the remote-tracking branch of the clone's only
# remote, so it tracks that remote's branch.
if ! upstream="$(git -C "${WORK_DIR}/othername-branch-feature1" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2> /dev/null)"; then
  upstream=''
fi
if [ "${upstream}" != "elsewhere/feature1" ]; then
  fail "${WORK_DIR}/othername-branch-feature1 tracks [${upstream}], not elsewhere/feature1"
fi

# A branch that neither the remote nor the clone has does not exist.
if output="$(cd "${OTHER_NAME_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" nosuchbranch 2>&1)"; then
  fail "git-checkout-branch checked out a branch that does not exist: ${output}"
fi
case "${output}" in
  *"branch nosuchbranch does not exist"*) ;;
  *) fail "git-checkout-branch did not say that the branch does not exist: ${output}" ;;
esac
if [ -e "${WORK_DIR}/othername-branch-nosuchbranch" ]; then
  fail "git-checkout-branch created a directory for a branch that does not exist"
fi

# A branch that exists only in this clone was never pushed, so the remote does
# not have it -- and yet `git checkout` can check it out.
LOCAL_DIR="${WORK_DIR}/localonly"
git clone -q "${REMOTE}" "${LOCAL_DIR}"
git -C "${LOCAL_DIR}" branch neverpushed
if ! output="$(cd "${LOCAL_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" neverpushed 2>&1)"; then
  fail "git-checkout-branch failed on a branch that only this clone has: ${output}"
fi
branch="$(git -C "${WORK_DIR}/localonly-branch-neverpushed" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "neverpushed" ]; then
  fail "${WORK_DIR}/localonly-branch-neverpushed is on branch ${branch}, not neverpushed"
fi

# A clone with no remote determines no remote to ask, so the message says so
# rather than asserting that the branch does not exist.
NO_REMOTE_DIR="${WORK_DIR}/noremote"
git clone -q "${REMOTE}" "${NO_REMOTE_DIR}"
git -C "${NO_REMOTE_DIR}" remote remove origin
if output="$(cd "${NO_REMOTE_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" nosuchbranch 2>&1)"; then
  fail "git-checkout-branch checked out a branch that does not exist: ${output}"
fi
case "${output}" in
  *"determines no remote to ask about it"*) ;;
  *) fail "git-checkout-branch claimed to know that the branch does not exist: ${output}" ;;
esac

# A branch that the remote has but that this clone never fetched cannot be
# checked out:  `git checkout` consults only the refs that the clone holds.
# Refusing before the copy, with advice to fetch, beats copying the whole
# repository and then failing with git's "pathspec did not match" message.
UNFETCHED_DIR="${WORK_DIR}/unfetched"
git clone -q "${REMOTE}" "${UNFETCHED_DIR}"
# Restrict the fetch refspec before deleting the remote-tracking branch, so
# that the `git pull` in `git-checkout-branch` does not recreate it.
git -C "${UNFETCHED_DIR}" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git -C "${UNFETCHED_DIR}" update-ref -d refs/remotes/origin/feature1
if output="$(cd "${UNFETCHED_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 2>&1)"; then
  fail "git-checkout-branch checked out a branch that this clone has not fetched: ${output}"
fi
case "${output}" in
  *"exists on remote origin, but this clone has not fetched it"*) ;;
  *) fail "git-checkout-branch did not say that the branch was never fetched: ${output}" ;;
esac
case "${output}" in
  *"git fetch origin"*) ;;
  *) fail "git-checkout-branch did not say to fetch the branch: ${output}" ;;
esac
for leftover in "${WORK_DIR}/unfetched-branch-feature1" "${WORK_DIR}/unfetched-branch-feature1-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "git-checkout-branch copied the working copy before refusing: ${leftover}"
  fi
done
# This clone's fetch refspec covers only `main`, so plain `git fetch origin`
# would not bring the branch in and the user would arrive right back here.  The
# advice has to name a refspec that fetches the branch.
case "${output}" in
  *"does not cover feature1"*) ;;
  *) fail "git-checkout-branch did not say that this clone does not fetch the branch: ${output}" ;;
esac
case "${output}" in
  *"git remote set-branches --add origin feature1"*) ;;
  *) fail "git-checkout-branch did not say how to make this clone fetch the branch: ${output}" ;;
esac
# Following the advice works:  the branch can then be checked out, and it
# tracks the remote's branch.
git -C "${UNFETCHED_DIR}" remote set-branches --add origin feature1
git -C "${UNFETCHED_DIR}" fetch -q origin
if ! output="$(cd "${UNFETCHED_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 2>&1)"; then
  fail "git-checkout-branch failed after the commands that it advised: ${output}"
fi
branch="$(git -C "${WORK_DIR}/unfetched-branch-feature1" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature1" ]; then
  fail "${WORK_DIR}/unfetched-branch-feature1 is on branch ${branch}, not feature1"
fi
if ! upstream="$(git -C "${WORK_DIR}/unfetched-branch-feature1" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2> /dev/null)"; then
  upstream=''
fi
if [ "${upstream}" != "origin/feature1" ]; then
  fail "${WORK_DIR}/unfetched-branch-feature1 tracks [${upstream}], not origin/feature1"
fi

# A clone can hold a remote-tracking branch that its refspecs do not cover, if
# someone fetched the branch once with an explicit refspec.  `git checkout
# feature1` does not find such a ref -- it searches the remotes' refspecs, not
# the refs -- so the branch has to be created from the ref by name.  Git
# records an upstream only for a branch that the clone fetches, so the branch
# gets none, and the command says so rather than leaving the user to discover
# it at the next `git push`.
ONEOFF_DIR="${WORK_DIR}/oneoff"
git clone -q "${REMOTE}" "${ONEOFF_DIR}"
git -C "${ONEOFF_DIR}" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git -C "${ONEOFF_DIR}" update-ref -d refs/remotes/origin/feature1
git -C "${ONEOFF_DIR}" fetch -q origin 'feature1:refs/remotes/origin/feature1'
if ! output="$(cd "${ONEOFF_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 2>&1)"; then
  fail "git-checkout-branch failed on a ref that this clone holds but does not fetch: ${output}"
fi
branch="$(git -C "${WORK_DIR}/oneoff-branch-feature1" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature1" ]; then
  fail "${WORK_DIR}/oneoff-branch-feature1 is on branch ${branch}, not feature1"
fi
expected_commit="$(git -C "${ONEOFF_DIR}" rev-parse refs/remotes/origin/feature1)"
actual_commit="$(git -C "${WORK_DIR}/oneoff-branch-feature1" rev-parse HEAD)"
if [ "${actual_commit}" != "${expected_commit}" ]; then
  fail "${WORK_DIR}/oneoff-branch-feature1 is at ${actual_commit}, not at origin/feature1 (${expected_commit})"
fi
case "${output}" in
  *"has no upstream"*) ;;
  *) fail "git-checkout-branch did not say that the branch has no upstream: ${output}" ;;
esac

# Several remotes with a branch of this name do not say which one to check out.
# `git checkout feature1` fails on such a name -- "matched multiple remote
# tracking branches" -- so refusing here, before the copy, both explains the
# problem and saves the user a full copy of the repository.
MULTI_DIR="${WORK_DIR}/multiremote"
SECOND_REMOTE="${WORK_DIR}/second.git"
git clone -q --bare "${REMOTE}" "${SECOND_REMOTE}"
git clone -q "${REMOTE}" "${MULTI_DIR}"
git -C "${MULTI_DIR}" remote add second "${SECOND_REMOTE}"
git -C "${MULTI_DIR}" fetch -q second
if output="$(cd "${MULTI_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 2>&1)"; then
  fail "git-checkout-branch checked out a branch that several remotes have: ${output}"
fi
case "${output}" in
  *"2 remotes of this clone have a branch feature1"*) ;;
  *) fail "git-checkout-branch did not say that several remotes have the branch: ${output}" ;;
esac
case "${output}" in
  *"checkout.defaultRemote"*) ;;
  *) fail "git-checkout-branch did not say how to choose a remote: ${output}" ;;
esac
for leftover in "${WORK_DIR}/multiremote-branch-feature1" "${WORK_DIR}/multiremote-branch-feature1-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "git-checkout-branch copied the working copy before refusing: ${leftover}"
  fi
done

# `checkout.defaultRemote` chooses among them, as it does for `git checkout`
# itself, and the branch is created from that remote's branch.
git -C "${MULTI_DIR}" config checkout.defaultRemote second
if ! output="$(cd "${MULTI_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 2>&1)"; then
  fail "git-checkout-branch failed when checkout.defaultRemote chose a remote: ${output}"
fi
branch="$(git -C "${WORK_DIR}/multiremote-branch-feature1" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature1" ]; then
  fail "${WORK_DIR}/multiremote-branch-feature1 is on branch ${branch}, not feature1"
fi
if ! upstream="$(git -C "${WORK_DIR}/multiremote-branch-feature1" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2> /dev/null)"; then
  upstream=''
fi
if [ "${upstream}" != "second/feature1" ]; then
  fail "${WORK_DIR}/multiremote-branch-feature1 tracks [${upstream}], not second/feature1"
fi

# The tests that need no network access come first, so a branch that this clone
# holds is checked out without asking any remote about it.  A fake `ssh` counts
# the connections:  the `git pull` above makes one, and a query about the
# branch would make another.  A branch whose remote cannot be reached is still
# checked out, from the remote-tracking branch that this clone holds.
SSH_DIR="${WORK_DIR}/sshclone"
git clone -q "${REMOTE}" "${SSH_DIR}"
SSH_ARGUMENTS="${WORK_DIR}/ssh-arguments"
use_fake_ssh "${SSH_DIR}" "${SSH_ARGUMENTS}"

if ! output="$(cd "${SSH_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 2>&1)"; then
  fail "git-checkout-branch failed when the remote could not be reached over SSH: ${output}"
fi
branch="$(git -C "${WORK_DIR}/sshclone-branch-feature1" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature1" ]; then
  fail "${WORK_DIR}/sshclone-branch-feature1 is on branch ${branch}, not feature1"
fi
connections="$(grep -c '.' "${SSH_ARGUMENTS}" || true)"
if [ "${connections}" -ne 1 ]; then
  fail "git-checkout-branch made ${connections} SSH connections for a branch that this clone holds: [$(cat "${SSH_ARGUMENTS}")]"
fi

# `git-checkout-branch` asks the remote -- about a branch that this clone does
# not hold, which is the case that needs an answer -- without ever prompting.
# A prompt would block forever:  this script discards the query's output, and
# it may run from another script or from a CI job.  `GIT_TERMINAL_PROMPT=0`
# does not suppress the prompts that SSH itself issues, such as the one for an
# unknown host key, so the SSH command must also be given the option that
# disables those.
: > "${SSH_ARGUMENTS}"
if output="$(cd "${SSH_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" nosuchbranch 2>&1)"; then
  fail "git-checkout-branch checked out a branch that does not exist: ${output}"
fi
case "${output}" in
  *"could not be asked about it"*) ;;
  *) fail "git-checkout-branch claimed to know that the branch does not exist: ${output}" ;;
esac
if [ ! -s "${SSH_ARGUMENTS}" ]; then
  fail 'git-checkout-branch did not contact the remote over SSH'
elif ! grep -q -- '-o BatchMode=yes' "${SSH_ARGUMENTS}"; then
  fail "SSH invocation did not include \"-o BatchMode=yes\": [$(cat "${SSH_ARGUMENTS}")]"
fi

echo "${SCRIPT_NAME}: OK"
