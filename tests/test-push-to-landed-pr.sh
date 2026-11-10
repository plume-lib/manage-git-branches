#!/bin/sh

# Tests that `git-push-to`, when it merges a branch that contains the squash
# commit of a pull request into a branch that merged an earlier version of
# that pull request, first merges the pull request's final version and then
# the squash commit, so that the merge has no conflicts.
#
# Usage:
#   tests/test-push-to-landed-pr.sh
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
# The physical path, because git-push-to's diagnostics name physical paths,
# and on macOS the temporary directory is reached through a symbolic link.
WORK_DIR="$(CDPATH='' cd -- "${WORK_DIR}" && pwd -P)" || exit 1

# shellcheck source=lib-git-test-env.sh
. "${TESTS_DIR}/lib-git-test-env.sh"
sanitize_git_env "${WORK_DIR}"

# The test repository contains no build file, so skip compilation.
MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1
export MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

## Usage: make_clone REMOTE BRANCH DIRECTORY
## Clones BRANCH of REMOTE into ${WORK_DIR}/DIRECTORY.
make_clone() {
  git clone -q -b "$2" "$1" "${WORK_DIR}/$3"
  # `sanitize_git_env` leaves `pull.rebase` unset, and git refuses
  # to pull divergent branches unless something says how to reconcile them.
  git -C "${WORK_DIR}/$3" config pull.rebase false
}

## Usage: write_versions VERSION
## Writes VERSION into the text file and into the binary file of the seed
## repository, and stages both.
write_versions() {
  printf 'text %s\n' "$1" > "${WORK_DIR}/seed/text.txt"
  # A NUL byte makes git treat the file as binary.
  printf 'binary\000%s\n' "$1" > "${WORK_DIR}/seed/data.bin"
  git -C "${WORK_DIR}/seed" add text.txt data.bin
}

## Create a remote whose "main" has a text file and a binary file.  Pull
## request #7, from branch "feature", changes both files.  Branch "dependent"
## merges an early version of "feature" and makes a change of its own.  Then
## "feature" changes both files again, and the pull request lands on "main"
## as a squash commit.  The remote has the ref "refs/pull/7/head", as GitHub
## does, for the final head of the pull request's branch.
REMOTE="${WORK_DIR}/proj.git"
git init -q --bare -b main "${REMOTE}"
git init -q -b main "${WORK_DIR}/seed"
write_versions 'original'
echo "dependent's file" > "${WORK_DIR}/seed/dependent.txt"
git -C "${WORK_DIR}/seed" add dependent.txt
git -C "${WORK_DIR}/seed" commit -q -m "Initial commit"
git -C "${WORK_DIR}/seed" remote add origin "${REMOTE}"
git -C "${WORK_DIR}/seed" push -q --set-upstream origin main

git -C "${WORK_DIR}/seed" checkout -q -b feature
write_versions 'early'
git -C "${WORK_DIR}/seed" commit -q -m "Early version of the feature"
git -C "${WORK_DIR}/seed" checkout -q -b dependent main
git -C "${WORK_DIR}/seed" merge -q --no-edit feature
echo "dependent's change" >> "${WORK_DIR}/seed/dependent.txt"
git -C "${WORK_DIR}/seed" commit -q -a -m "Dependent change"
git -C "${WORK_DIR}/seed" push -q origin dependent

git -C "${WORK_DIR}/seed" checkout -q feature
write_versions 'final'
git -C "${WORK_DIR}/seed" commit -q -m "Final version of the feature"
git -C "${WORK_DIR}/seed" push -q origin feature:refs/pull/7/head
final_head="$(git -C "${WORK_DIR}/seed" rev-parse HEAD)"

git -C "${WORK_DIR}/seed" checkout -q main
git -C "${WORK_DIR}/seed" merge -q --squash feature > /dev/null
git -C "${WORK_DIR}/seed" commit -q -m "Add the feature (#7)"
squash="$(git -C "${WORK_DIR}/seed" rev-parse HEAD)"
echo "later change" > "${WORK_DIR}/seed/later.txt"
git -C "${WORK_DIR}/seed" add later.txt
git -C "${WORK_DIR}/seed" commit -q -m "A later change on main"
git -C "${WORK_DIR}/seed" push -q origin main

make_clone "${REMOTE}" main proj-branch-main
make_clone "${REMOTE}" dependent proj-branch-dependent
DEPENDENT="${WORK_DIR}/proj-branch-dependent"

## Without the merges of the pull request's final version, merging "main"
## into "dependent" conflicts in both files.
conflicts="$(git -C "${DEPENDENT}" merge-tree --write-tree --name-only --no-messages HEAD origin/main | sed -e '1d' || true)"
if [ "$(printf '%s\n' "${conflicts}" | sort | tr '\n' ' ')" != "data.bin text.txt " ]; then
  fail "the test's merge does not conflict as expected: [${conflicts}]"
fi

## `git-push-to` merges the final version of the pull request, then the
## squash commit, and then "main", without conflicts.
if ! "${COMMANDS_DIR}/git-push-to" --no-llm \
  "${WORK_DIR}/proj-branch-main" "${DEPENDENT}" 2> "${WORK_DIR}/stderr"; then
  fail "git-push-to failed: $(cat "${WORK_DIR}/stderr")"
fi
if ! grep -q "merging the final version of pull request #7 " "${WORK_DIR}/stderr"; then
  fail "no diagnostic about pull request #7: $(cat "${WORK_DIR}/stderr")"
fi
for commit in "${final_head}" "${squash}"; do
  if ! git -C "${DEPENDENT}" merge-base --is-ancestor "${commit}" HEAD; then
    fail "git-push-to did not merge ${commit}"
  fi
done
if [ "$(git -C "${DEPENDENT}" rev-parse HEAD)" != "$(git -C "${DEPENDENT}" rev-parse '@{upstream}')" ]; then
  fail "git-push-to did not push"
fi
if [ "$(cat "${DEPENDENT}/text.txt")" != "text final" ]; then
  fail "wrong text file: $(cat "${DEPENDENT}/text.txt")"
fi
if ! git -C "${DEPENDENT}" diff --quiet "${final_head}" HEAD -- data.bin; then
  fail "the binary file is not the pull request's final version"
fi
if [ "$(cat "${DEPENDENT}/dependent.txt")" != "dependent's file
dependent's change" ]; then
  fail "wrong dependent file: $(cat "${DEPENDENT}/dependent.txt")"
fi
if [ "$(cat "${DEPENDENT}/later.txt")" != "later change" ]; then
  fail "git-push-to did not merge the later change on main"
fi
if [ -n "$(git -C "${DEPENDENT}" status --porcelain --untracked-files=no)" ]; then
  fail "git-push-to left changes in the working tree"
fi

## A branch that never merged the pull request's branch, and whose merge of
## "main" conflicts with the pull request's changes, gets an ordinary merge of
## "main", with no merge of the pull request's final version.
git -C "${WORK_DIR}/seed" checkout -q -b unrelated "${squash}~1"
echo "unrelated change" > "${WORK_DIR}/seed/text.txt"
git -C "${WORK_DIR}/seed" commit -q -a -m "Unrelated change"
git -C "${WORK_DIR}/seed" push -q origin unrelated
make_clone "${REMOTE}" unrelated proj-branch-unrelated
"${COMMANDS_DIR}/git-push-to" --no-llm --no-pull-first \
  "${WORK_DIR}/proj-branch-main" "${WORK_DIR}/proj-branch-unrelated" > /dev/null 2> "${WORK_DIR}/stderr" || true
if grep -q "pull request #7" "${WORK_DIR}/stderr"; then
  fail "git-push-to merged pull request #7 into a branch that never merged it: $(cat "${WORK_DIR}/stderr")"
fi
if git -C "${WORK_DIR}/proj-branch-unrelated" merge-base --is-ancestor "${final_head}" HEAD; then
  fail "git-push-to merged the pull request's final head into a branch that never merged it"
fi

echo "${SCRIPT_NAME}: all tests passed"
