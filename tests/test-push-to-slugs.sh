#!/bin/sh

# Tests that `git-push-to` accepts slugs of the form ORG:BRANCH, and that it
# pushes along one chain for each project that has directories for them.
#
# Usage:
#   tests/test-push-to-slugs.sh
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(CDPATH='' cd -- "${TESTS_DIR}/.." && pwd -P)" || exit 1

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${WORK_DIR}"' EXIT
trap 'rm -rf "${WORK_DIR}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${WORK_DIR}"; trap - TERM; kill -s TERM "$$"' TERM

# shellcheck source=lib-git-test-env.sh
. "${TESTS_DIR}/lib-git-test-env.sh"
sanitize_git_env "${WORK_DIR}"

# The test repositories contain no build file, so skip compilation.
MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1
export MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

## Usage: make_remote PROJECT BRANCH...
## Creates a bare remote for PROJECT whose branches all start at "main".
make_remote() {
  make_remote_project="$1"
  shift
  git init -q --bare -b main "${WORK_DIR}/${make_remote_project}.git"
  git init -q -b main "${WORK_DIR}/seed-${make_remote_project}"
  echo "first line" > "${WORK_DIR}/seed-${make_remote_project}/file.txt"
  git -C "${WORK_DIR}/seed-${make_remote_project}" add file.txt
  git -C "${WORK_DIR}/seed-${make_remote_project}" commit -q -m "Initial commit"
  git -C "${WORK_DIR}/seed-${make_remote_project}" push -q \
    "${WORK_DIR}/${make_remote_project}.git" main
  for make_remote_branch; do
    git -C "${WORK_DIR}/seed-${make_remote_project}" push -q \
      "${WORK_DIR}/${make_remote_project}.git" "main:refs/heads/${make_remote_branch}"
  done
}

## Usage: make_clone PROJECT BRANCH DIRECTORY
## Clones BRANCH of PROJECT's remote into DIRECTORY, under ${WORK_DIR}/work.
make_clone() {
  git clone -q -b "$2" "${WORK_DIR}/$1.git" "${WORK_DIR}/work/$3"
  # `sanitize_git_env` leaves the global configuration empty, and git refuses
  # to pull divergent branches unless something says how to reconcile them.
  git -C "${WORK_DIR}/work/$3" config pull.rebase false
}

## Usage: add_line PROJECT LINE
## Commits LINE to "main" of PROJECT's remote.
add_line() {
  echo "$2" >> "${WORK_DIR}/seed-$1/file.txt"
  git -C "${WORK_DIR}/seed-$1" commit -q -a -m "Add $2"
  git -C "${WORK_DIR}/seed-$1" push -q "${WORK_DIR}/$1.git" main
}

mkdir "${WORK_DIR}/work"

# Project "proj" has the upstream's main branch and two branches of a fork,
# one of whose names contains a slash.  The fork's main branch is checked out
# in a directory without "-branch-".
make_remote proj part1 feature/part2
make_clone proj main proj-fork-upstream-branch-main
make_clone proj main proj-fork-me
make_clone proj part1 proj-fork-me-branch-part1
make_clone proj feature/part2 proj-fork-me-branch-feature-part2

# Project "other" has only the fork's branches, not the upstream's.
make_remote other part1 feature/part2
make_clone other part1 other-fork-me-branch-part1
make_clone other feature/part2 other-fork-me-branch-feature-part2

# Project "lonely" has only one of the directories, so it is skipped.
make_remote lonely part1
make_clone lonely part1 lonely-fork-me-branch-part1

add_line proj "proj line"
# The change to "other" is on part1, the start of that project's chain.
echo "other line" >> "${WORK_DIR}/seed-other/file.txt"
git -C "${WORK_DIR}/seed-other" commit -q -a -m "Add other line"
git -C "${WORK_DIR}/seed-other" push -q "${WORK_DIR}/other.git" main:refs/heads/part1

if ! (cd "${WORK_DIR}/work" \
  && "${COMMANDS_DIR}/git-push-to" upstream:main me:part1 me:feature/part2); then
  fail "git-push-to failed on slugs"
fi

check_contains() {
  if ! grep -q "$2" "${WORK_DIR}/work/$1/file.txt"; then
    fail "$1 does not contain \"$2\""
  fi
  if [ "$(git -C "${WORK_DIR}/work/$1" rev-parse HEAD)" \
    != "$(git -C "${WORK_DIR}/work/$1" rev-parse '@{upstream}')" ]; then
    fail "$1 was not pushed"
  fi
}
check_contains proj-fork-me-branch-part1 "proj line"
check_contains proj-fork-me-branch-feature-part2 "proj line"
check_contains other-fork-me-branch-feature-part2 "other line"
# me:main was not among the slugs.
if grep -q "proj line" "${WORK_DIR}/work/proj-fork-me/file.txt"; then
  fail "proj-fork-me was changed, but it was not named"
fi

# A directory without "-branch-" stands for the branch it has checked out.
add_line proj "second proj line"
git -C "${WORK_DIR}/work/proj-fork-upstream-branch-main" pull -q
if ! (cd "${WORK_DIR}/work" && "${COMMANDS_DIR}/git-push-to" upstream:main me:main); then
  fail "git-push-to failed on me:main"
fi
check_contains proj-fork-me "second proj line"

# A slug that names no directory is an error, and nothing is pushed.
add_line proj "third proj line"
if (cd "${WORK_DIR}/work" \
  && "${COMMANDS_DIR}/git-push-to" upstream:main me:part1 me:no-such-branch) 2> /dev/null; then
  fail "git-push-to succeeded on a slug that names no directory"
fi
if grep -q "third proj line" "${WORK_DIR}/work/proj-fork-me-branch-part1/file.txt"; then
  fail "git-push-to pushed despite a slug that names no directory"
fi

# Slugs and directories cannot be mixed.
if (cd "${WORK_DIR}/work" \
  && "${COMMANDS_DIR}/git-push-to" upstream:main proj-fork-me-branch-part1) 2> /dev/null; then
  fail "git-push-to succeeded on a mixture of slugs and directories"
fi

echo "${SCRIPT_NAME}: OK"
