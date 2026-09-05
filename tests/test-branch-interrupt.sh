#!/bin/sh

# Tests that `git-checkout-branch` and `git-new-branch` remove their
# `-TMP` directory when they are interrupted by a signal, so that a
# subsequent invocation is not blocked by a leftover directory.
#
# Usage:
#   tests/test-branch-interrupt.sh
#
# The test creates its repositories under a temporary directory, which it
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

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

REMOTE="${WORK_DIR}/myrepo.git"
MAIN_DIR="${WORK_DIR}/myrepo-branch-main"
FAKE_BIN="${WORK_DIR}/fakebin"

## Creates a remote repository with a `main` and a `feature1` branch, and a
## clone of it in MAIN_DIR.
create_repositories() {
  git init -q --bare -b main "${REMOTE}"
  git init -q -b main "${WORK_DIR}/seed"
  echo "first line" > "${WORK_DIR}/seed/file.txt"
  git -C "${WORK_DIR}/seed" add file.txt
  git -C "${WORK_DIR}/seed" commit -q -m "Initial commit"
  git -C "${WORK_DIR}/seed" remote add origin "${REMOTE}"
  git -C "${WORK_DIR}/seed" push -q --set-upstream origin main
  git -C "${WORK_DIR}/seed" push -q origin main:feature1
  rm -rf "${WORK_DIR}/seed"
  git clone -q "${REMOTE}" "${MAIN_DIR}"
}

## Creates a `cp` command that stands in for a copy that the user interrupts:
## it creates part of the destination directory, then sends SIGINT to the
## script that invoked it.  The scripts run `\cp`, which suppresses alias
## expansion but still searches PATH, so putting this command first on PATH
## makes it the one that runs.
create_interrupting_cp() {
  mkdir -p "${FAKE_BIN}"
  cat > "${FAKE_BIN}/cp" << 'INNER'
#!/bin/sh
# Exit rather than sending the interrupt if the partial copy cannot be made,
# so that the test cannot pass without an interrupt actually occurring.
set -e
# The destination is the last argument.
dest=""
for arg in "$@"; do dest="${arg}"; done
mkdir -p "${dest}"
echo "partial copy" > "${dest}/partial-file"
kill -s INT "${PPID}"
INNER
  chmod +x "${FAKE_BIN}/cp"
}

## Runs the given branch script on the given branch, in MAIN_DIR and with the
## interrupting `cp` first on PATH.  Fails the test unless the script is killed
## by SIGINT.
run_interrupted() {
  status=0
  (cd "${MAIN_DIR}" && PATH="${FAKE_BIN}:${PATH}" "${COMMANDS_DIR}/$1" "$2") \
    > /dev/null 2>&1 || status="$?"
  # A shell reports a command killed by signal N as exit status 128+N.
  if [ "${status}" -ne 130 ]; then
    fail "$1 exited with status ${status}, not 130 (killed by SIGINT)"
  fi
}

create_repositories
create_interrupting_cp

# `git-new-branch`, interrupted while copying the working copy.
NEW_DIR="${WORK_DIR}/myrepo-branch-newfeature"
run_interrupted git-new-branch newfeature
if [ -e "${NEW_DIR}-TMP" ]; then
  fail "interrupted git-new-branch left ${NEW_DIR}-TMP behind"
fi
# A retry must succeed, rather than being blocked by a leftover directory.
if ! (cd "${MAIN_DIR}" && "${COMMANDS_DIR}/git-new-branch" newfeature > /dev/null); then
  fail "git-new-branch failed after an interrupted invocation"
fi
if [ ! -d "${NEW_DIR}" ]; then
  fail "git-new-branch did not create ${NEW_DIR}"
fi

# `git-checkout-branch`, interrupted while copying the working copy.
CHECKOUT_DIR="${WORK_DIR}/myrepo-branch-feature1"
run_interrupted git-checkout-branch feature1
if [ -e "${CHECKOUT_DIR}-TMP" ]; then
  fail "interrupted git-checkout-branch left ${CHECKOUT_DIR}-TMP behind"
fi
if ! (cd "${MAIN_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 > /dev/null); then
  fail "git-checkout-branch failed after an interrupted invocation"
fi
if [ ! -d "${CHECKOUT_DIR}" ]; then
  fail "git-checkout-branch did not create ${CHECKOUT_DIR}"
fi

echo "${SCRIPT_NAME}: PASS"
