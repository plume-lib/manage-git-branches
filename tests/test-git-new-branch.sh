#!/bin/sh

# Tests for the `git-new-branch` script.
#
# Usage:
#   tests/test-git-new-branch.sh
#
# The exit status is 0 if all tests pass, 1 otherwise.
#
# These tests exercise only cases that require no network access.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
GIT_NEW_BRANCH="${SCRIPT_DIR}/../git-new-branch"

status=0

fail() {
  echo "FAIL: $*" >&2
  status=1
}

tmpdir="$(mktemp -d)"
trap 'chmod -R u+rwx "${tmpdir}" 2> /dev/null; rm -rf "${tmpdir}"' EXIT INT TERM

# Creates, in "$1", a repository that has no remote, with a branch "localonly"
# in addition to the initial branch.
make_repo() {
  mkdir -p "$1" || return 1
  (
    cd "$1" || exit 1
    git init -q -b main .
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "hello" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"
    git branch localonly
  )
}

repo="${tmpdir}/myrepo-branch-main"
make_repo "${repo}" || exit 1

# A branch name that is already in use locally is an error, reported by
# `git-new-branch` itself rather than as a raw `git checkout` failure.
if out="$(cd "${repo}" && "${GIT_NEW_BRANCH}" localonly 2>&1)"; then
  fail "zero exit status for the existing local branch localonly"
fi
case "${out}" in
  *"git-new-branch: ERROR: branch localonly already exists"*) ;;
  *) fail "unexpected message for the existing local branch localonly: ${out}" ;;
esac
for leftover in "${tmpdir}/myrepo-branch-localonly" "${tmpdir}/myrepo-branch-localonly-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "directory was created for the existing local branch localonly: ${leftover}"
  fi
done

# The local name collision is detected before the working copy is copied.  The
# copy is made unable to succeed, by making a subdirectory unreadable; if
# `git-new-branch` attempts the copy, it reports the copy failure instead.
# Only an unprivileged user is stopped by the permissions.
if [ "$(id -u)" != 0 ]; then
  unreadable_repo="${tmpdir}/unreadable-branch-main"
  make_repo "${unreadable_repo}" || exit 1
  mkdir "${unreadable_repo}/subdir"
  chmod 000 "${unreadable_repo}/subdir"
  if out="$(cd "${unreadable_repo}" && "${GIT_NEW_BRANCH}" localonly 2>&1)"; then
    fail "zero exit status for the existing local branch localonly"
  fi
  case "${out}" in
    *"git-new-branch: ERROR: branch localonly already exists"*) ;;
    *) fail "the working copy was copied before the local branch localonly was detected: ${out}" ;;
  esac
  chmod 700 "${unreadable_repo}/subdir"
fi

# A branch name that is not in use creates the branch and its directory.
if ! out="$(cd "${repo}" && "${GIT_NEW_BRANCH}" brandnew 2>&1)"; then
  fail "nonzero exit status for the new branch brandnew: ${out}"
fi
newdir="${tmpdir}/myrepo-branch-brandnew"
if [ ! -d "${newdir}" ]; then
  fail "directory was not created: ${newdir}"
else
  checkedout="$(git -C "${newdir}" rev-parse --abbrev-ref HEAD)"
  if [ "${checkedout}" != "brandnew" ]; then
    fail "checked out ${checkedout} rather than brandnew in ${newdir}"
  fi
fi
if [ -e "${newdir}-TMP" ]; then
  fail "temporary directory was left behind: ${newdir}-TMP"
fi

# A branch name that is in use on the remote is an error.
clone="${tmpdir}/myclone-branch-main"
git clone -q "${repo}" "${clone}"
if out="$(cd "${clone}" && "${GIT_NEW_BRANCH}" localonly 2>&1)"; then
  fail "zero exit status for the branch localonly that exists on the remote"
fi
case "${out}" in
  *"already exists"*) ;;
  *) fail "unexpected message for the branch localonly that exists on the remote: ${out}" ;;
esac
if [ -e "${tmpdir}/myclone-branch-localonly" ]; then
  fail "directory was created for the branch localonly that exists on the remote"
fi

# The wrong number of arguments is an error.
if (cd "${repo}" && "${GIT_NEW_BRANCH}" > /dev/null 2>&1); then
  fail "zero exit status when given no argument"
fi
if (cd "${repo}" && "${GIT_NEW_BRANCH}" a b > /dev/null 2>&1); then
  fail "zero exit status when given two arguments"
fi

if [ "${status}" = 0 ]; then
  echo "test-git-new-branch.sh: all tests passed"
fi
exit "${status}"
