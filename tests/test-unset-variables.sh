#!/bin/sh

# Tests that every command enables `set -u`, that the commands nonetheless work
# when their optional environment variables are unset, and that the branch
# commands do not depend on `realpath`, which is unavailable on some systems.
#
# Usage:
#   tests/test-unset-variables.sh
#
# The test creates its directories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(dirname -- "${TESTS_DIR}")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT INT TERM

# A committer identity, in case the user running the test has none.
GIT_AUTHOR_NAME="Test User"
GIT_AUTHOR_EMAIL="test@example.com"
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# The point of this test: every optional variable that the commands read is
# unset, so `set -u` aborts any command that dereferences one without a default.
unset CLEAN GRADLE_ASSEMBLE_FLAGS MVN_COMPILE_FLAGS MAKE_FLAGS
unset ERR_IF_NO_BUILDFILE DEBUG MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT

COMMANDS="compile-project git-checkout-branch git-new-branch git-orphaned-branches git-pull-from git-push-to is-deleted-branch"

REMOTE="${WORK_DIR}/myrepo.git"
MAIN_DIR="${WORK_DIR}/myrepo-branch-main"
FEATURE_DIR="${WORK_DIR}/myrepo-branch-feature"
MAKE_DIR="${WORK_DIR}/makeproject"
FAKE_BIN="${WORK_DIR}/fakebin"
STDERR_FILE="${WORK_DIR}/stderr.txt"

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

## Creates a remote repository with a `main` and a `feature` branch, a clone of
## each branch, a Make project, and a directory holding a `realpath` that fails.
create_directories() {
  git init -q --bare -b main "${REMOTE}"
  git init -q -b main "${WORK_DIR}/seed"
  echo "first line" > "${WORK_DIR}/seed/file.txt"
  git -C "${WORK_DIR}/seed" add file.txt
  git -C "${WORK_DIR}/seed" commit -q -m "Initial commit"
  git -C "${WORK_DIR}/seed" remote add origin "${REMOTE}"
  git -C "${WORK_DIR}/seed" push -q --set-upstream origin main
  git -C "${WORK_DIR}/seed" push -q origin main:feature
  git -C "${WORK_DIR}/seed" push -q origin main:checkoutbranch
  rm -rf "${WORK_DIR}/seed"
  git clone -q "${REMOTE}" "${MAIN_DIR}"
  git clone -q -b feature "${REMOTE}" "${FEATURE_DIR}"
  # Merge rather than rebase, whatever the user's git configuration says.
  git -C "${MAIN_DIR}" config pull.rebase false
  git -C "${FEATURE_DIR}" config pull.rebase false

  mkdir "${MAKE_DIR}"
  printf 'all:\n\t@echo BUILD\n' > "${MAKE_DIR}/Makefile"

  mkdir "${FAKE_BIN}"
  printf '#!/bin/sh\nexit 1\n' > "${FAKE_BIN}/realpath"
  chmod +x "${FAKE_BIN}/realpath"
}

create_directories

## Part 1: every command enables `set -u`.
for command in ${COMMANDS}; do
  if ! grep -q '^set -u$' "${COMMANDS_DIR}/${command}"; then
    fail "${command} does not contain \"set -u\""
  fi
done

## Part 2: the commands work when their optional variables are unset.

# `compile-project` on a project that has a buildfile.
status=0
"${COMMANDS_DIR}/compile-project" "${MAKE_DIR}" > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -ne 0 ]; then
  fail "compile-project failed on ${MAKE_DIR}; its stderr was:
$(cat "${STDERR_FILE}")"
fi

# `compile-project --clean`, which reads CLEAN.
status=0
"${COMMANDS_DIR}/compile-project" --clean "${MAKE_DIR}" > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -ne 0 ]; then
  fail "compile-project --clean failed on ${MAKE_DIR}; its stderr was:
$(cat "${STDERR_FILE}")"
fi

# `compile-project` on a project that has no buildfile, which reads
# ERR_IF_NO_BUILDFILE.
status=0
"${COMMANDS_DIR}/compile-project" "${MAIN_DIR}" > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -ne 0 ]; then
  fail "compile-project failed on a project with no buildfile; its stderr was:
$(cat "${STDERR_FILE}")"
fi

# `git-orphaned-branches`, which reads DEBUG.
status=0
(cd "${WORK_DIR}" && "${COMMANDS_DIR}/git-orphaned-branches") \
  > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -ne 0 ]; then
  fail "git-orphaned-branches failed; its stderr was:
$(cat "${STDERR_FILE}")"
fi

# `is-deleted-branch`.
status=0
"${COMMANDS_DIR}/is-deleted-branch" "${MAIN_DIR}" > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -gt 1 ]; then
  fail "is-deleted-branch exited with status ${status}; its stderr was:
$(cat "${STDERR_FILE}")"
fi

# `git-push-to` and `git-pull-from`, which read
# MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT.  Neither directory has a buildfile,
# so the compilation step succeeds without doing anything.
status=0
PATH="${COMMANDS_DIR}:${PATH}" "${COMMANDS_DIR}/git-push-to" "${MAIN_DIR}" "${FEATURE_DIR}" \
  > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -ne 0 ]; then
  fail "git-push-to failed; its stderr was:
$(cat "${STDERR_FILE}")"
fi

status=0
(cd "${FEATURE_DIR}" && PATH="${COMMANDS_DIR}:${PATH}" "${COMMANDS_DIR}/git-pull-from" "${MAIN_DIR}") \
  > /dev/null 2> "${STDERR_FILE}" || status="$?"
if [ "${status}" -ne 0 ]; then
  fail "git-pull-from failed; its stderr was:
$(cat "${STDERR_FILE}")"
fi

## Part 3: a failing `realpath` does not affect the branch commands.  They
## canonicalize the existing parent directory with POSIX `pwd -P` instead.

## Runs command $1 on branch $2, with a `realpath` that fails.  Fails the test
## unless the command succeeds and creates the expected branch directory.
check_without_realpath() {
  status=0
  (cd "${MAIN_DIR}" && PATH="${FAKE_BIN}:${PATH}" "${COMMANDS_DIR}/$1" "$2") \
    > /dev/null 2> "${STDERR_FILE}" || status="$?"
  if [ "${status}" -ne 0 ]; then
    fail "$1 failed because realpath was unavailable; its stderr was:
$(cat "${STDERR_FILE}")"
  fi
  if [ ! -d "${WORK_DIR}/myrepo-branch-$2" ]; then
    fail "$1 did not create ${WORK_DIR}/myrepo-branch-$2"
  fi
}

# `newbranch` does not exist in the remote, and `checkoutbranch` does.
check_without_realpath git-new-branch newbranch
check_without_realpath git-checkout-branch checkoutbranch

echo "${SCRIPT_NAME}: PASS"
