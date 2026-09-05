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

status=0

fail() {
  echo "FAIL: $*" >&2
  status=1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT INT TERM

# Create a repository that has no remote, with a branch "localonly" in
# addition to the initial branch.
repo="${tmpdir}/myrepo-branch-main"
mkdir -p "${repo}"
(
  cd "${repo}" || exit 1
  git init -q -b main .
  git config user.email "test@example.com"
  git config user.name "Test User"
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
