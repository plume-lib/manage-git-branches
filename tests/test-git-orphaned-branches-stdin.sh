#!/bin/sh

# Tests that `git-orphaned-branches` processes every candidate directory even
# when the `is-deleted-branch` child process reads from standard input.
#
# The loop in `git-orphaned-branches` used to take its input from standard
# input, so a child process that read standard input consumed directory names
# that the loop had not yet read, and those directories were silently skipped.

set -e

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"

testdir="$(mktemp -d "${TMPDIR:-/tmp}/test-git-orphaned-branches.XXXXXX")"
trap 'rm -rf "${testdir}"' EXIT INT TERM

# Do not let the tester's git configuration affect the test.
GIT_CONFIG_GLOBAL="${testdir}/gitconfig"
GIT_CONFIG_SYSTEM=/dev/null
GIT_AUTHOR_NAME="Test"
GIT_AUTHOR_EMAIL="test@example.com"
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
: > "${GIT_CONFIG_GLOBAL}"

# `git-orphaned-branches` runs the `is-deleted-branch` that sits beside it, so
# run a copy of `git-orphaned-branches` beside a stub `is-deleted-branch` that
# reads all of its standard input, as a real `git pull` may do.
bindir="${testdir}/bin"
mkdir "${bindir}"
cp "${REPO_DIR}/git-orphaned-branches" "${bindir}/git-orphaned-branches"
cat > "${bindir}/is-deleted-branch" << 'STUB'
#!/bin/sh
cat > /dev/null
exit 0
STUB
chmod +x "${bindir}/is-deleted-branch"

# Create a remote repository and three working copies of it.
workdir="${testdir}/work"
mkdir "${workdir}"
git init -q --bare "${workdir}/origin.git"
git clone -q "${workdir}/origin.git" "${testdir}/seed" 2> /dev/null
: > "${testdir}/seed/file.txt"
git -C "${testdir}/seed" add file.txt
git -C "${testdir}/seed" commit -q -m "Initial commit"
git -C "${testdir}/seed" push -q origin HEAD
for i in 1 2 3; do
  git clone -q "${workdir}/origin.git" "${workdir}/myrepo-branch-${i}"
done

# Redirect standard input from /dev/null, so that the stub reads end-of-file
# unless the loop hands it the list of directories.
actual="$(cd "${workdir}" && "${bindir}/git-orphaned-branches" < /dev/null | sort)"
expected="$(for i in 1 2 3; do realpath "${workdir}/myrepo-branch-${i}"; done | sort)"

if [ "${actual}" != "${expected}" ]; then
  echo "FAIL: git-orphaned-branches skipped directories." >&2
  echo "Expected:" >&2
  echo "${expected}" >&2
  echo "Actual:" >&2
  echo "${actual}" >&2
  exit 1
fi

echo "PASS: $(basename -- "$0")"
