#!/bin/sh

# Tests that `git-push-to` and `git-pull-from` reject a request to push a
# repository into itself, no matter how the two directories are spelled.
#
# Usage:
#   tests/test-same-directory.sh
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

# The repositories under test contain no buildfile, but skip compilation
# anyway, so that the test does not depend on `compile-project`.
MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1
export MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

REMOTE="${WORK_DIR}/myrepo.git"
CLONE="${WORK_DIR}/myrepo-branch-main"
OTHER_CLONE="${WORK_DIR}/myrepo-branch-other"

## Creates a remote repository and two clones of it.
create_repositories() {
  git init -q --bare -b main "${REMOTE}"
  git init -q -b main "${WORK_DIR}/seed"
  echo "first line" > "${WORK_DIR}/seed/file.txt"
  git -C "${WORK_DIR}/seed" add file.txt
  git -C "${WORK_DIR}/seed" commit -q -m "Initial commit"
  git -C "${WORK_DIR}/seed" remote add origin "${REMOTE}"
  git -C "${WORK_DIR}/seed" push -q --set-upstream origin main
  rm -rf "${WORK_DIR}/seed"
  git clone -q "${REMOTE}" "${CLONE}"
  git -C "${CLONE}" config pull.rebase false
  git clone -q "${REMOTE}" "${OTHER_CLONE}"
  git -C "${OTHER_CLONE}" config pull.rebase false
}

## Checks that `git-push-to` rejects the given arguments.  The first argument
## is a description of the case; the rest are passed to `git-push-to`.
check_push_to_rejects() {
  description="$1"
  shift
  if output="$("${COMMANDS_DIR}/git-push-to" "$@" 2>&1)"; then
    fail "git-push-to accepted ${description}"
  fi
  case "${output}" in
    *"same directory"*) ;;
    *) fail "git-push-to gave an unexpected message for ${description}: ${output}" ;;
  esac
}

create_repositories

## The same directory, spelled the same way.
check_push_to_rejects "identical arguments" "${CLONE}" "${CLONE}"

## The same directory, spelled with and without a trailing slash.
check_push_to_rejects "a trailing slash" "${CLONE}" "${CLONE}/"

## The same directory, spelled relatively and absolutely.
(
  cd "${WORK_DIR}"
  check_push_to_rejects "a relative and an absolute name" \
    "$(basename -- "${CLONE}")" "${CLONE}"
)

## The same directory, one of them reached through a symbolic link.
ln -s "${CLONE}" "${WORK_DIR}/link-to-clone"
check_push_to_rejects "a symbolic link" "${CLONE}" "${WORK_DIR}/link-to-clone"

## More than two directories, two adjacent ones being the same.
check_push_to_rejects "adjacent duplicates among three directories" \
  "${OTHER_CLONE}" "${CLONE}" "${CLONE}"

## `git-pull-from` pulling the current directory into itself.
if output="$(cd "${CLONE}" && "${COMMANDS_DIR}/git-pull-from" . 2>&1)"; then
  fail "git-pull-from accepted the current directory"
fi
case "${output}" in
  *"current directory"*) ;;
  *) fail "git-pull-from gave an unexpected message: ${output}" ;;
esac

## Two different directories are still accepted.
if ! "${COMMANDS_DIR}/git-push-to" "${OTHER_CLONE}" "${CLONE}"; then
  fail "git-push-to rejected two different directories"
fi

echo "${SCRIPT_NAME}: OK"
