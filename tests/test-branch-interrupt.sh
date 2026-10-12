#!/bin/sh

# Tests that `git-checkout-branch` and `git-new-branch` clean up when they are
# interrupted by a signal, so that a subsequent invocation is not blocked by a
# leftover:  no `-TMP` directory, and nothing of the worktree that they were
# creating -- no directory, no registration, and no branch.
#
# Usage:
#   tests/test-branch-interrupt
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(CDPATH='' cd -- "${TESTS_DIR}/.." && pwd -P)" || exit 1

. "${TESTS_DIR}/lib-git-test-env.sh"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${WORK_DIR}"' EXIT
trap 'rm -rf "${WORK_DIR}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${WORK_DIR}"; trap - TERM; kill -s TERM "$$"' TERM

sanitize_git_env "${WORK_DIR}"

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

REMOTE="${WORK_DIR}/myrepo.git"
MAIN_DIR="${WORK_DIR}/myrepo-branch-main"
FAKE_BIN="${WORK_DIR}/fakebin"
FAKE_GIT_BIN="${WORK_DIR}/fakegitbin"
SYSTEM_REALPATH="$(command -v realpath)"
export SYSTEM_REALPATH

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

  # Behave like macOS realpath, which rejects a nonexistent final component.
  cat > "${FAKE_BIN}/realpath" << 'INNER'
#!/bin/sh
target=""
for arg in "$@"; do target="${arg}"; done
if [ ! -e "${target}" ]; then exit 1; fi
exec "${SYSTEM_REALPATH}" "$@"
INNER
  chmod +x "${FAKE_BIN}/realpath"
}

## Creates a `git` command that stands in for a `git worktree add` that the
## user interrupts just after it finishes:  it runs the real git, and then, if
## the command was `git worktree add`, sends SIGINT to the script that invoked
## it.
create_interrupting_git() {
  mkdir -p "${FAKE_GIT_BIN}"
  real_git="$(command -v git)"
  cat > "${FAKE_GIT_BIN}/git" << INNER
#!/bin/sh
"${real_git}" "\$@"
git_status="\$?"
if [ "\$1" = worktree ] && [ "\$2" = add ]; then
  kill -s INT "\${PPID}"
fi
exit "\${git_status}"
INNER
  chmod +x "${FAKE_GIT_BIN}/git"
}

## Runs the given branch script on the given branch, in MAIN_DIR and with the
## given directory -- by default, the one that holds the interrupting `cp` --
## first on PATH.  Fails the test unless the script reports signal
## termination.
run_interrupted() {
  status=0
  (cd "${MAIN_DIR}" && PATH="${3:-${FAKE_BIN}}:${PATH}" "${COMMANDS_DIR}/$1" "$2") \
    > /dev/null 2>&1 || status="$?"
  # A shell reports a command killed by a signal with an exit status greater than 128.
  if [ "${status}" -le 128 ]; then
    fail "$1 exited with status ${status}, not greater than 128 (killed by a signal)"
  fi
}

## Fails unless an interrupted `git-new-branch` of the branch $1 left nothing
## behind:  no directory, no temporary directory, no worktree registration,
## and no branch.  $2 says when it was interrupted.
check_nothing_left() {
  if [ -e "${WORK_DIR}/myrepo-branch-$1-TMP" ]; then
    fail "git-new-branch interrupted $2 left myrepo-branch-$1-TMP behind"
  fi
  if [ -e "${WORK_DIR}/myrepo-branch-$1" ]; then
    fail "git-new-branch interrupted $2 left myrepo-branch-$1 behind"
  fi
  if git -C "${MAIN_DIR}" worktree list --porcelain | grep -q "myrepo-branch-$1"; then
    fail "git-new-branch interrupted $2 left a worktree registered"
  fi
  if [ -e "$(git -C "${MAIN_DIR}" rev-parse --path-format=absolute \
    --git-common-dir)/worktrees/myrepo-branch-$1" ]; then
    fail "git-new-branch interrupted $2 left an administrative directory"
  fi
  if git -C "${MAIN_DIR}" rev-parse --verify --quiet "refs/heads/$1" > /dev/null; then
    fail "git-new-branch interrupted $2 left the branch $1 behind"
  fi
  # A retry must succeed, rather than being blocked by a leftover.
  if ! (cd "${MAIN_DIR}" && "${COMMANDS_DIR}/git-new-branch" "$1" > /dev/null); then
    fail "git-new-branch failed after an invocation interrupted $2"
  fi
  if [ ! -d "${WORK_DIR}/myrepo-branch-$1" ]; then
    fail "git-new-branch did not create myrepo-branch-$1 after an invocation interrupted $2"
  fi
}

create_repositories
create_interrupting_cp
create_interrupting_git

# `git-new-branch`, interrupted while copying the working tree.
run_interrupted git-new-branch newfeature
check_nothing_left newfeature 'while copying the working tree'

# `git-new-branch`, interrupted just after the worktree was registered, in
# each mode that registers one.
run_interrupted git-new-branch registered "${FAKE_GIT_BIN}"
check_nothing_left registered 'after git worktree add'
status=0
(cd "${MAIN_DIR}" && PATH="${FAKE_GIT_BIN}:${PATH}" \
  "${COMMANDS_DIR}/git-new-branch" --clean cleanregistered) > /dev/null 2>&1 \
  || status="$?"
if [ "${status}" -le 128 ]; then
  fail "git-new-branch --clean exited with status ${status}, not greater than 128 (killed by a signal)"
fi
check_nothing_left cleanregistered 'after git worktree add --clean'

# `git-checkout-branch`, interrupted just after the worktree was registered.
# The branch was created from the remote-tracking branch, so it is removed
# along with the worktree.
CHECKOUT_DIR="${WORK_DIR}/myrepo-branch-feature1"
run_interrupted git-checkout-branch feature1 "${FAKE_GIT_BIN}"
if [ -e "${CHECKOUT_DIR}" ]; then
  fail "interrupted git-checkout-branch left ${CHECKOUT_DIR} behind"
fi
if [ -e "$(git -C "${MAIN_DIR}" rev-parse --path-format=absolute \
  --git-common-dir)/worktrees/myrepo-branch-feature1" ]; then
  fail "interrupted git-checkout-branch left an administrative directory"
fi
if git -C "${MAIN_DIR}" rev-parse --verify --quiet refs/heads/feature1 > /dev/null; then
  fail "interrupted git-checkout-branch left the branch feature1 behind"
fi
if ! (cd "${MAIN_DIR}" && "${COMMANDS_DIR}/git-checkout-branch" feature1 > /dev/null); then
  fail "git-checkout-branch failed after an interrupted invocation"
fi
if [ ! -d "${CHECKOUT_DIR}" ]; then
  fail "git-checkout-branch did not create ${CHECKOUT_DIR}"
fi

echo "${SCRIPT_NAME}: OK"
