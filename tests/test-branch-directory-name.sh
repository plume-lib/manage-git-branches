#!/bin/sh

# Tests that `git-new-branch` derives the branch directory name from the branch
# name literally, rather than letting a shell's `echo` interpret the branch name
# as an option or as backslash escapes.
#
# Usage:
#   tests/test-branch-directory-name.sh

set -e

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"
REPO_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"

fail() {
  printf '%s: FAILURE: %s\n' "${SCRIPT_NAME}" "$1" >&2
  exit 1
}

# Runs `git-new-branch ${branchname}` under ${shell}, in a repository where the
# directory that ${branchname} should map to already exists.  `git-new-branch`
# refuses to overwrite an existing directory, and its error message contains the
# directory name it computed, which is what this test checks.
#
# Arguments: the branch name, and the directory suffix it should map to.
check_branch_directory() {
  branchname="$1"
  expected="${workdir}/repo-branch-$2"
  mkdir -- "${expected}"
  if output="$(cd "${workdir}/repo" && "${shell}" "${REPO_DIR}/git-new-branch" "${branchname}" 2>&1)"; then
    fail "${shell} git-new-branch '${branchname}' unexpectedly succeeded: ${output}"
  fi
  case "${output}" in
    *"ERROR: directory exists: ${expected}") ;;
    *) fail "${shell} git-new-branch '${branchname}' did not use directory ${expected}: ${output}" ;;
  esac
  rmdir -- "${expected}"
}

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT INT TERM
workdir="$(CDPATH='' cd -- "${workdir}" && pwd -P)"

GIT_AUTHOR_NAME='manage-git-branches test'
GIT_AUTHOR_EMAIL='test@example.com'
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

remote="${workdir}/remote.git"
git init -q --bare -b main "${remote}"
git clone -q "${remote}" "${workdir}/repo" 2> /dev/null
date > "${workdir}/repo/change.txt"
git -C "${workdir}/repo" add change.txt
git -C "${workdir}/repo" commit -q -m "initial commit"
git -C "${workdir}/repo" push -q -u origin main

# `git-new-branch` is a `#!/bin/sh` script, so run it under every POSIX shell
# that is installed; `echo` differs among them.
for shellname in sh dash bash ksh; do
  shell="$(command -v "${shellname}")" || continue
  # A branch name that every shell's `echo` treats as an option rather than as
  # data.  (A branch name containing a backslash would likewise be mangled by
  # some shells' `echo`, but git's refname rules exclude backslashes.)
  check_branch_directory '-n' '-n'
  # A branch name containing a slash, which becomes a dash.
  check_branch_directory 'feature/one' 'feature-one'
done

echo "${SCRIPT_NAME}: OK"
