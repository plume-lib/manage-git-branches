#!/bin/sh

# Tests for the `git-checkout-branch` script.
#
# Usage:
#   tests/test-git-checkout-branch.sh
#
# The exit status is 0 if all tests pass, 1 otherwise.
#
# These tests exercise only cases that require no network access.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
GIT_CHECKOUT_BRANCH="${SCRIPT_DIR}/../git-checkout-branch"

. "${SCRIPT_DIR}/lib-git-test-env.sh"

status=0

fail() {
  echo "FAIL: $*" >&2
  status=1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT INT TERM

sanitize_git_env "${tmpdir}"

# Create a repository that has no remote, with a branch "localonly" in
# addition to the initial branch.
repo="${tmpdir}/myrepo-branch-main"
mkdir -p "${repo}"
(
  cd "${repo}" || exit 1
  git init -q -b main .
  echo "hello" > file.txt
  git add file.txt
  git commit -q -m "Initial commit"
  git branch localonly
) || exit 1

# A branch that exists only locally can be checked out.
if ! out="$(cd "${repo}" && "${GIT_CHECKOUT_BRANCH}" localonly 2>&1)"; then
  fail "nonzero exit status for the local branch localonly: ${out}"
fi
localdir="${tmpdir}/myrepo-branch-localonly"
if [ ! -d "${localdir}" ]; then
  fail "directory was not created: ${localdir}"
else
  checkedout="$(git -C "${localdir}" rev-parse --abbrev-ref HEAD)"
  if [ "${checkedout}" != "localonly" ]; then
    fail "checked out ${checkedout} rather than localonly in ${localdir}"
  fi
fi

# A branch that does not exist is an error, and the message says so.
if out="$(cd "${repo}" && "${GIT_CHECKOUT_BRANCH}" nosuchbranch 2>&1)"; then
  fail "zero exit status for the nonexistent branch nosuchbranch"
fi
case "${out}" in
  *"does not exist"*) ;;
  *) fail "unexpected message for the nonexistent branch nosuchbranch: ${out}" ;;
esac
if [ -e "${tmpdir}/myrepo-branch-nosuchbranch" ]; then
  fail "directory was created for the nonexistent branch nosuchbranch"
fi

# A branch that exists only as a remote-tracking branch can be checked out.
clone="${tmpdir}/myclone-branch-main"
git clone -q "${repo}" "${clone}"
if ! out="$(cd "${clone}" && "${GIT_CHECKOUT_BRANCH}" localonly 2>&1)"; then
  fail "nonzero exit status for the remote-tracking branch localonly: ${out}"
fi
clonedir="${tmpdir}/myclone-branch-localonly"
if [ ! -d "${clonedir}" ]; then
  fail "directory was not created: ${clonedir}"
else
  checkedout="$(git -C "${clonedir}" rev-parse --abbrev-ref HEAD)"
  if [ "${checkedout}" != "localonly" ]; then
    fail "checked out ${checkedout} rather than localonly in ${clonedir}"
  fi
fi

# A clone whose sole remote is not named "origin" is asked about the branch.
othername="${tmpdir}/othername-branch-main"
git clone -q "${repo}" "${othername}"
git -C "${othername}" remote rename origin elsewhere
if ! out="$(cd "${othername}" && "${GIT_CHECKOUT_BRANCH}" localonly 2>&1)"; then
  fail "nonzero exit status for a branch of a remote not named origin: ${out}"
fi
otherdir="${tmpdir}/othername-branch-localonly"
if [ ! -d "${otherdir}" ]; then
  fail "directory was not created: ${otherdir}"
else
  checkedout="$(git -C "${otherdir}" rev-parse --abbrev-ref HEAD)"
  if [ "${checkedout}" != "localonly" ]; then
    fail "checked out ${checkedout} rather than localonly in ${otherdir}"
  fi
fi

# The diagnostic for a nonexistent branch names the remote that was asked,
# rather than "origin", which such a clone does not have.
if out="$(cd "${othername}" && "${GIT_CHECKOUT_BRANCH}" nosuchbranch 2>&1)"; then
  fail "zero exit status for the nonexistent branch nosuchbranch"
fi
case "${out}" in
  *"does not exist, locally or on remote elsewhere"*) ;;
  *) fail "the message does not name the remote that was asked: ${out}" ;;
esac

# A clone that pushes to a fork checks out a branch of the remote that it
# fetches from.  The push remote is the wrong one to ask about a branch:  a
# fork does not have the project's branches, so asking it would report that a
# branch that plainly exists does not exist.
forkclone="${tmpdir}/forkclone-branch-main"
git clone -q "${repo}" "${forkclone}"
git init -q --bare -b main "${tmpdir}/fork.git"
git -C "${forkclone}" remote add fork "${tmpdir}/fork.git"
git -C "${forkclone}" config branch.main.pushRemote fork
if ! out="$(cd "${forkclone}" && "${GIT_CHECKOUT_BRANCH}" localonly 2>&1)"; then
  fail "nonzero exit status for a branch of the fetch remote: ${out}"
fi
forkdir="${tmpdir}/forkclone-branch-localonly"
if [ ! -d "${forkdir}" ]; then
  fail "directory was not created: ${forkdir}"
else
  checkedout="$(git -C "${forkdir}" rev-parse --abbrev-ref HEAD)"
  if [ "${checkedout}" != "localonly" ]; then
    fail "checked out ${checkedout} rather than localonly in ${forkdir}"
  fi
fi

# The diagnostic for a nonexistent branch names the remote that was asked,
# which is the one the clone fetches from rather than the one it pushes to.
if out="$(cd "${forkclone}" && "${GIT_CHECKOUT_BRANCH}" nosuchbranch 2>&1)"; then
  fail "zero exit status for the nonexistent branch nosuchbranch"
fi
case "${out}" in
  *"does not exist, locally or on remote origin"*) ;;
  *) fail "the message does not name the remote that was asked: ${out}" ;;
esac

# A branch that only a remote other than the fetch remote has can be checked
# out, because `git checkout` creates the local branch from the
# remote-tracking branch of any remote.
git -C "${forkclone}" push -q fork "refs/remotes/origin/localonly:refs/heads/onlyfork"
git -C "${forkclone}" fetch -q fork
if ! out="$(cd "${forkclone}" && "${GIT_CHECKOUT_BRANCH}" onlyfork 2>&1)"; then
  fail "nonzero exit status for a branch of a remote other than the fetch remote: ${out}"
fi
onlyforkdir="${tmpdir}/forkclone-branch-onlyfork"
if [ ! -d "${onlyforkdir}" ]; then
  fail "directory was not created: ${onlyforkdir}"
else
  checkedout="$(git -C "${onlyforkdir}" rev-parse --abbrev-ref HEAD)"
  if [ "${checkedout}" != "onlyfork" ]; then
    fail "checked out ${checkedout} rather than onlyfork in ${onlyforkdir}"
  fi
fi

# `HEAD` is not a branch name, even though a clone has a symbolic ref
# `refs/remotes/origin/HEAD`.
if out="$(cd "${clone}" && "${GIT_CHECKOUT_BRANCH}" HEAD 2>&1)"; then
  fail "zero exit status for HEAD"
fi
case "${out}" in
  *"does not exist"*) ;;
  *) fail "unexpected message for HEAD: ${out}" ;;
esac
if [ -e "${tmpdir}/myclone-branch-HEAD" ]; then
  fail "directory was created for HEAD"
fi

# The query to `origin` disables SSH's own interactive prompts, as the README
# promises.  Without that, a prompt for an unknown host key or for the
# passphrase of a key blocks forever when this script runs from another script
# or from a CI job, where nobody sees the prompt and nobody can answer it.
# The fake `ssh` records the arguments of each invocation and then fails, so
# the query fails and the branch is reported as nonexistent; what this checks
# is the option that the query passed.  `sanitize_git_env` has already unset
# the variables that would otherwise select some other SSH command.
# shellcheck source=common-functions.sh
. "${SCRIPT_DIR}/common-functions.sh"
sshclone="${tmpdir}/sshclone-branch-main"
git clone -q "${repo}" "${sshclone}"
use_fake_ssh "${sshclone}" "${tmpdir}/ssh-arguments"
# A name that no local test can answer, so that the remote is asked:  the
# clone has no branch and no remote-tracking branch of that name.
if (cd "${sshclone}" && "${GIT_CHECKOUT_BRANCH}" onlyremote > /dev/null 2>&1); then
  fail "zero exit status for a branch that only an unreachable remote could have"
fi
if [ ! -s "${tmpdir}/ssh-arguments" ]; then
  fail "git-checkout-branch did not ask origin about the branch"
elif ! grep -q -- '-o BatchMode=yes' "${tmpdir}/ssh-arguments"; then
  fail "the query to origin did not disable SSH's prompts: $(cat "${tmpdir}/ssh-arguments")"
fi

# The wrong number of arguments is an error.
if (cd "${repo}" && "${GIT_CHECKOUT_BRANCH}" > /dev/null 2>&1); then
  fail "zero exit status when given no argument"
fi
if (cd "${repo}" && "${GIT_CHECKOUT_BRANCH}" a b > /dev/null 2>&1); then
  fail "zero exit status when given two arguments"
fi

if [ "${status}" = 0 ]; then
  echo "test-git-checkout-branch.sh: all tests passed"
fi
exit "${status}"
