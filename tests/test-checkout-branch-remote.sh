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

# shellcheck source=lib-git-test-env.sh
. "${TESTS_DIR}/lib-git-test-env.sh"
# shellcheck source=common-functions.sh
. "${TESTS_DIR}/common-functions.sh"

sanitize_git_env "${WORK_DIR}"

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

# A branch that the remote has but that this clone never fetched has no ref
# here, and `git checkout` consults only the refs that the clone holds.  The
# branch is therefore fetched, rather than only queried:  a successful query
# would leave the checkout to fail with git's "pathspec did not match".
UNFETCHED_DIR="${WORK_DIR}/unfetched"
git clone -q "${REMOTE}" "${UNFETCHED_DIR}"
# Restrict the fetch refspec before deleting the remote-tracking branch, so
# that the `git pull` in `git-checkout-branch` does not recreate it.
git -C "${UNFETCHED_DIR}" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git -C "${UNFETCHED_DIR}" update-ref -d refs/remotes/origin/feature1
if ! output="$(cd "${UNFETCHED_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 2>&1)"; then
  fail "git-checkout-branch failed on a branch that this clone has not fetched: ${output}"
fi
branch="$(git -C "${WORK_DIR}/unfetched-branch-feature1" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature1" ]; then
  fail "${WORK_DIR}/unfetched-branch-feature1 is on branch ${branch}, not feature1"
fi
expected_commit="$(git -C "${REMOTE}" rev-parse refs/heads/feature1)"
actual_commit="$(git -C "${WORK_DIR}/unfetched-branch-feature1" rev-parse HEAD)"
if [ "${actual_commit}" != "${expected_commit}" ]; then
  fail "${WORK_DIR}/unfetched-branch-feature1 is at ${actual_commit}, not at the remote's feature1 (${expected_commit})"
fi
# The new working copy gets an upstream even though this clone's fetch refspec
# does not cover the branch, so git set none up:  `git-push-to` and
# `git-pull-from` require one.
upstream_remote="$(git -C "${WORK_DIR}/unfetched-branch-feature1" config --get branch.feature1.remote)"
upstream_merge="$(git -C "${WORK_DIR}/unfetched-branch-feature1" config --get branch.feature1.merge)"
if [ "${upstream_remote}" != "origin" ] \
  || [ "${upstream_merge}" != "refs/heads/feature1" ]; then
  fail "${WORK_DIR}/unfetched-branch-feature1 has upstream [${upstream_remote}] [${upstream_merge}], not origin refs/heads/feature1"
fi

# The branch's configured remote can be a pathname rather than the name of a
# remote, which is what `git push --set-upstream ../other.git BRANCH` records.
# Such a remote has no remote-tracking namespace, so the fetch records the
# branch only in FETCH_HEAD, and the branch is created from that.
git clone -q --bare "${REMOTE}" "${WORK_DIR}/mainonly.git"
git -C "${WORK_DIR}/mainonly.git" update-ref -d refs/heads/feature1
PATHREMOTE_DIR="${WORK_DIR}/pathremote"
git clone -q "${WORK_DIR}/mainonly.git" "${PATHREMOTE_DIR}"
# The pathname is relative to the clone, which is where git resolves it.
git -C "${PATHREMOTE_DIR}" config branch.main.remote '../myrepo.git'
if ! output="$(cd "${PATHREMOTE_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 2>&1)"; then
  fail "git-checkout-branch failed on a branch of a remote named by a pathname: ${output}"
fi
branch="$(git -C "${WORK_DIR}/pathremote-branch-feature1" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature1" ]; then
  fail "${WORK_DIR}/pathremote-branch-feature1 is on branch ${branch}, not feature1"
fi
expected_commit="$(git -C "${REMOTE}" rev-parse refs/heads/feature1)"
actual_commit="$(git -C "${WORK_DIR}/pathremote-branch-feature1" rev-parse HEAD)"
if [ "${actual_commit}" != "${expected_commit}" ]; then
  fail "${WORK_DIR}/pathremote-branch-feature1 is at ${actual_commit}, not at the remote's feature1 (${expected_commit})"
fi
# The upstream is the pathname, which is what `git push --set-upstream` would
# have recorded.  Git records none for a branch created from FETCH_HEAD.
upstream_remote="$(git -C "${WORK_DIR}/pathremote-branch-feature1" config --get branch.feature1.remote)"
if [ "${upstream_remote}" != "../myrepo.git" ]; then
  fail "${WORK_DIR}/pathremote-branch-feature1 has upstream remote [${upstream_remote}], not ../myrepo.git"
fi

# A clone can hold a remote-tracking branch that its refspecs do not cover, if
# someone fetched the branch once with an explicit refspec.  `git checkout
# feature1` does not find such a ref -- it searches the remotes' refspecs, not
# the refs -- so the branch has to be created from the ref by name.  Git
# records an upstream only for a branch that the clone fetches, so it sets
# none here, and `git-checkout-branch` configures one itself.
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
upstream_remote="$(git -C "${WORK_DIR}/oneoff-branch-feature1" config --get branch.feature1.remote)"
upstream_merge="$(git -C "${WORK_DIR}/oneoff-branch-feature1" config --get branch.feature1.merge)"
if [ "${upstream_remote}" != "origin" ] \
  || [ "${upstream_merge}" != "refs/heads/feature1" ]; then
  fail "${WORK_DIR}/oneoff-branch-feature1 has upstream [${upstream_remote}] [${upstream_merge}], not origin refs/heads/feature1"
fi

# Several remotes have a branch of this name, and one of them is the remote
# that this clone fetches the current branch from, so that one is chosen.
# `git checkout feature1` fails on such a name -- "matched multiple remote
# tracking branches" -- so the choice is made here rather than left to it.
MULTI_DIR="${WORK_DIR}/multiremote"
SECOND_REMOTE="${WORK_DIR}/second.git"
git clone -q --bare "${REMOTE}" "${SECOND_REMOTE}"
git clone -q "${REMOTE}" "${MULTI_DIR}"
git -C "${MULTI_DIR}" remote add second "${SECOND_REMOTE}"
git -C "${MULTI_DIR}" fetch -q second
if ! output="$(cd "${MULTI_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 2>&1)"; then
  fail "git-checkout-branch failed when the fetch remote is one of several that have the branch: ${output}"
fi
if ! upstream="$(git -C "${WORK_DIR}/multiremote-branch-feature1" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2> /dev/null)"; then
  upstream=''
fi
if [ "${upstream}" != "origin/feature1" ]; then
  fail "${WORK_DIR}/multiremote-branch-feature1 tracks [${upstream}], not the origin/feature1 of the fetch remote"
fi
rm -rf "${WORK_DIR}/multiremote-branch-feature1"

# `checkout.defaultRemote` outranks the fetch remote, as it does for git's own
# search, and the branch is created from that remote's branch.
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

# When none of the remotes that have the branch is the fetch remote and
# `checkout.defaultRemote` names none of them either, which one to check out
# is ambiguous.  Saying so before the copy both explains the problem and saves
# the user a full copy of the repository.
AMBIGUOUS_DIR="${WORK_DIR}/ambiguous"
THIRD_REMOTE="${WORK_DIR}/third.git"
git clone -q --bare "${REMOTE}" "${THIRD_REMOTE}"
git clone -q "${REMOTE}" "${AMBIGUOUS_DIR}"
# Narrow the fetch refspec of the fetch remote and drop its remote-tracking
# branch, so that only the two other remotes have one for feature1.
git -C "${AMBIGUOUS_DIR}" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git -C "${AMBIGUOUS_DIR}" update-ref -d refs/remotes/origin/feature1
git -C "${AMBIGUOUS_DIR}" remote add second "${SECOND_REMOTE}"
git -C "${AMBIGUOUS_DIR}" remote add third "${THIRD_REMOTE}"
git -C "${AMBIGUOUS_DIR}" fetch -q second
git -C "${AMBIGUOUS_DIR}" fetch -q third
if output="$(cd "${AMBIGUOUS_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 2>&1)"; then
  fail "git-checkout-branch checked out a branch that several remotes have: ${output}"
fi
case "${output}" in
  *"branch feature1 exists on several remotes of this clone"*) ;;
  *) fail "git-checkout-branch did not say that several remotes have the branch: ${output}" ;;
esac
case "${output}" in
  *"checkout.defaultRemote"*) ;;
  *) fail "git-checkout-branch did not say how to choose a remote: ${output}" ;;
esac
for leftover in "${WORK_DIR}/ambiguous-branch-feature1" "${WORK_DIR}/ambiguous-branch-feature1-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "git-checkout-branch copied the working copy before refusing: ${leftover}"
  fi
done

# The remote has the branch, but the fetch of it into this clone fails, which
# is not the same as the branch not existing:  the branch is there, and the
# user's next step is to fix whatever stopped the fetch rather than to look
# for another name.  Here a ref named "origin/feature1/blocker" occupies the
# name that the fetch would write, and git refuses to have both a ref and a
# directory of refs at one name.
BLOCKED_DIR="${WORK_DIR}/blockedfetch"
git clone -q "${REMOTE}" "${BLOCKED_DIR}"
# Narrow the fetch refspec before deleting the remote-tracking branch, so that
# neither the `git pull` in `git-checkout-branch` nor its fetch of the branch
# recreates it, and the branch is looked for on the remote.
git -C "${BLOCKED_DIR}" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git -C "${BLOCKED_DIR}" update-ref -d refs/remotes/origin/feature1
git -C "${BLOCKED_DIR}" update-ref refs/remotes/origin/feature1/blocker \
  "$(git -C "${BLOCKED_DIR}" rev-parse refs/remotes/origin/main)"
if output="$(cd "${BLOCKED_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 2>&1)"; then
  fail "git-checkout-branch succeeded although the branch could not be fetched: ${output}"
fi
case "${output}" in
  *"could not be fetched"*) ;;
  *) fail "git-checkout-branch did not say that the branch could not be fetched: ${output}" ;;
esac
# The failed fetch is reported before the copy, so it costs the user no copy
# of the repository.
for leftover in "${WORK_DIR}/blockedfetch-branch-feature1" "${WORK_DIR}/blockedfetch-branch-feature1-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "git-checkout-branch copied the working copy although the fetch failed: ${leftover}"
  fi
done

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
# The query's own output follows that message, because "could not be asked"
# alone does not say what went wrong, and the reason is what the user acts on.
reason="$(printf '%s\n' "${output}" \
  | sed -n '/ERROR: branch nosuchbranch/,$p' | sed '1d')"
if [ -z "${reason}" ]; then
  fail "git-checkout-branch did not report why the remote could not be asked: ${output}"
fi
if [ ! -s "${SSH_ARGUMENTS}" ]; then
  fail 'git-checkout-branch did not contact the remote over SSH'
elif ! grep -q -- '-o BatchMode=yes' "${SSH_ARGUMENTS}"; then
  fail "SSH invocation did not include \"-o BatchMode=yes\": [$(cat "${SSH_ARGUMENTS}")]"
fi

echo "${SCRIPT_NAME}: OK"
