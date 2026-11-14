#!/bin/sh

# Tests that `git-push-to` leaves TO_DIR unchanged, without pulling it, when
# the merge is to be built and TO_DIR has uncommitted changes, as when someone
# is editing it; and that with "--nocompile" it merges into such a TO_DIR.
#
# Usage:
#   tests/test-push-to-uncommitted.sh
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

# The merge is built:  the test repository contains no build file, so the
# build, by `compile-project`, does nothing and succeeds.
MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=''
export MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT
unset ERR_IF_NO_BUILDFILE

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

## Usage: commit_to_remote BRANCH FILE LINE
## Appends LINE to FILE on BRANCH of ${REMOTE}, without updating any working
## copy directory, as when another clone pushes.
commit_to_remote() {
  git -C "${WORK_DIR}/seed" checkout -q "$1"
  echo "$3" >> "${WORK_DIR}/seed/$2"
  git -C "${WORK_DIR}/seed" commit -q -a -m "Add $3 to $2"
  git -C "${WORK_DIR}/seed" push -q origin "$1"
}

## Create a remote with "main" and "feature", each checked out in a directory.
REMOTE="${WORK_DIR}/proj.git"
git init -q --bare -b main "${REMOTE}"
git init -q -b main "${WORK_DIR}/seed"
echo "first line" > "${WORK_DIR}/seed/main.txt"
echo "first line" > "${WORK_DIR}/seed/feature.txt"
echo "first line" > "${WORK_DIR}/seed/edited.txt"
git -C "${WORK_DIR}/seed" add main.txt feature.txt edited.txt
git -C "${WORK_DIR}/seed" commit -q -m "Initial commit"
git -C "${WORK_DIR}/seed" remote add origin "${REMOTE}"
git -C "${WORK_DIR}/seed" push -q --set-upstream origin main
git -C "${WORK_DIR}/seed" push -q --set-upstream origin main:feature
git -C "${WORK_DIR}/seed" branch -q --set-upstream-to=origin/main main
git -C "${WORK_DIR}/seed" fetch -q
git -C "${WORK_DIR}/seed" branch -q --track feature origin/feature
MAIN="${WORK_DIR}/proj-branch-main"
FEATURE="${WORK_DIR}/proj-branch-feature"
for dir in "${MAIN}" "${FEATURE}"; do
  git clone -q -b "$(basename -- "${dir}" | sed 's/^proj-branch-//')" "${REMOTE}" "${dir}"
  # `sanitize_git_env` leaves `pull.rebase` unset, and git refuses
  # to pull divergent branches unless something says how to reconcile them.
  git -C "${dir}" config pull.rebase false
done

## Both remote branches advance, so the pull of FEATURE would fast-forward it.
## Meanwhile, someone is editing FEATURE:  it has an uncommitted change to a
## file that the pull would not touch.
commit_to_remote main main.txt "second line"
main_commit="$(git -C "${WORK_DIR}/seed" rev-parse main)"
commit_to_remote feature feature.txt "second line"
feature_commit="$(git -C "${WORK_DIR}/seed" rev-parse feature)"
feature_before="$(git -C "${FEATURE}" rev-parse HEAD)"
echo "an uncommitted line" >> "${FEATURE}/edited.txt"
status_before="$(git -C "${FEATURE}" status --porcelain)"

if "${COMMANDS_DIR}/git-push-to" --no-llm --summary "${WORK_DIR}/summary" \
  "${MAIN}" "${FEATURE}" 2> "${WORK_DIR}/stderr"; then
  fail "git-push-to merged into a directory with uncommitted changes: $(cat "${WORK_DIR}/stderr")"
fi
if [ "$(git -C "${FEATURE}" rev-parse HEAD)" != "${feature_before}" ]; then
  fail "git-push-to changed the branch of a directory with uncommitted changes"
fi
if [ "$(git -C "${FEATURE}" status --porcelain)" != "${status_before}" ]; then
  fail "git-push-to changed the uncommitted changes: [$(git -C "${FEATURE}" status --porcelain)], expected [${status_before}]"
fi
if ! grep -q "the working tree of ${FEATURE} has uncommitted changes" "${WORK_DIR}/stderr"; then
  fail "wrong diagnostic for uncommitted changes: $(cat "${WORK_DIR}/stderr")"
fi
if ! grep -q "while checking ${FEATURE} for uncommitted changes" "${WORK_DIR}/summary"; then
  fail "wrong summary for uncommitted changes: $(cat "${WORK_DIR}/summary")"
fi

## With "--nocompile", the merge is not built, so the uncommitted change does
## not stop it, and remains.
if ! "${COMMANDS_DIR}/git-push-to" --no-llm --nocompile "${MAIN}" "${FEATURE}" \
  2> "${WORK_DIR}/stderr"; then
  fail "git-push-to --nocompile failed: $(cat "${WORK_DIR}/stderr")"
fi
for commit in "${main_commit}" "${feature_commit}"; do
  if ! git -C "${FEATURE}" merge-base --is-ancestor "${commit}" HEAD; then
    fail "git-push-to --nocompile did not merge ${commit}"
  fi
done
if [ "$(git -C "${FEATURE}" status --porcelain)" != "${status_before}" ]; then
  fail "git-push-to --nocompile changed the uncommitted changes: [$(git -C "${FEATURE}" status --porcelain)], expected [${status_before}]"
fi

echo "${SCRIPT_NAME}: OK"
