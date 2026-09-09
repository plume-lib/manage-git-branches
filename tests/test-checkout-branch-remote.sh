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

# Make the test independent of the invoking user's git configuration.  A
# global setting such as `commit.gpgsign`, `pull.rebase`, `merge.ff`,
# `core.hooksPath`, or `commit.template` would otherwise change what the
# commands below do, or make them fail.
GIT_CONFIG_GLOBAL="${WORK_DIR}/gitconfig"
GIT_CONFIG_SYSTEM=/dev/null
# A committer identity, in case the user running the test has none.
GIT_AUTHOR_NAME="Test User"
GIT_AUTHOR_EMAIL="test@example.com"
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
: > "${GIT_CONFIG_GLOBAL}"

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

# `git-checkout-branch` asks the remote without ever prompting.  A prompt would
# block forever:  this script discards the query's output, and it may run from
# another script or from a CI job.  `GIT_TERMINAL_PROMPT=0` does not suppress
# the prompts that SSH itself issues, such as the one for an unknown host key,
# so the SSH command must also be given the option that disables those.  A
# branch whose remote cannot be reached is still checked out, from the
# remote-tracking branch that this clone holds.
SSH_DIR="${WORK_DIR}/sshclone"
git clone -q "${REMOTE}" "${SSH_DIR}"
SSH_ARGUMENTS="${WORK_DIR}/ssh-arguments"
FAKE_SSH="${WORK_DIR}/fake-ssh"
cat > "${FAKE_SSH}" << 'FAKE_SSH_END'
#!/bin/sh
printf '%s\n' "$*" >> "${SSH_ARGUMENTS_FILE}"
exit 1
FAKE_SSH_END
chmod +x "${FAKE_SSH}"
SSH_ARGUMENTS_FILE="${SSH_ARGUMENTS}"
export SSH_ARGUMENTS_FILE
git -C "${SSH_DIR}" config core.sshCommand "${FAKE_SSH}"
git -C "${SSH_DIR}" config ssh.variant ssh
git -C "${SSH_DIR}" remote set-url origin 'ssh://example.invalid/no-such-repo.git'
: > "${SSH_ARGUMENTS}"

if ! output="$(cd "${SSH_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 2>&1)"; then
  fail "git-checkout-branch failed when the remote could not be reached over SSH: ${output}"
fi
branch="$(git -C "${WORK_DIR}/sshclone-branch-feature1" rev-parse --abbrev-ref HEAD)"
if [ "${branch}" != "feature1" ]; then
  fail "${WORK_DIR}/sshclone-branch-feature1 is on branch ${branch}, not feature1"
fi
if [ ! -s "${SSH_ARGUMENTS}" ]; then
  fail 'git-checkout-branch did not contact the remote over SSH'
elif ! grep -q -- '-o BatchMode=yes' "${SSH_ARGUMENTS}"; then
  fail "SSH invocation did not include \"-o BatchMode=yes\": [$(cat "${SSH_ARGUMENTS}")]"
fi

echo "${SCRIPT_NAME}: OK"
