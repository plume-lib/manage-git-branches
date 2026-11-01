#!/bin/sh

# Tests that `git-push-to` commits a merge whose conflicts `git rerere`
# resolved, after checking the resolution; that it refuses a resolution that
# changed text outside the conflict regions; and that it stops, with the
# merge in progress, at conflicts that rerere did not resolve.
#
# Usage:
#   tests/test-push-to-rerere.sh
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

# The test repository contains no build file, so skip compilation.
MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1
export MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

## Usage: setup_case NAME
## Creates a remote under ${WORK_DIR}/NAME with branches "main" and
## "feature", whose changes to file.txt conflict, and a clone of each.  Sets
## ${main_dir} and ${feature_dir} to the clones, ${remote} to the remote, and
## ${feature_head} to the head of "feature".
setup_case() {
  case_dir="${WORK_DIR}/$1"
  mkdir "${case_dir}"
  remote="${case_dir}/myrepo.git"
  git init -q --bare -b main "${remote}"
  git init -q -b main "${case_dir}/seed"
  printf '%s\n' one two three four five six seven eight nine > "${case_dir}/seed/file.txt"
  git -C "${case_dir}/seed" add file.txt
  git -C "${case_dir}/seed" commit -q -m "Initial commit"
  git -C "${case_dir}/seed" remote add origin "${remote}"
  git -C "${case_dir}/seed" push -q --set-upstream origin main
  git -C "${case_dir}/seed" push -q origin main:refs/heads/feature

  main_dir="${case_dir}/myrepo-branch-main"
  feature_dir="${case_dir}/myrepo-branch-feature"
  git clone -q -b main "${remote}" "${main_dir}"
  git clone -q -b feature "${remote}" "${feature_dir}"
  git -C "${main_dir}" config pull.rebase false
  git -C "${feature_dir}" config pull.rebase false

  printf '%s\n' ONE two three four five six SEVEN-main eight nine > "${main_dir}/file.txt"
  git -C "${main_dir}" commit -q -a -m "Change main"
  git -C "${main_dir}" push -q
  printf '%s\n' one two three four five six SEVEN-feature eight nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Change feature"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
}

## Usage: record_resolution AUTO-UPDATE [SED-SCRIPT]
## Turns on `git rerere` in ${feature_dir}, with `rerere.autoUpdate` set to
## AUTO-UPDATE, and records a resolution of the merge of main that keeps both
## sides, edited by SED-SCRIPT if it is given.  Then undoes the merge.
record_resolution() {
  git -C "${feature_dir}" config rerere.enabled true
  git -C "${feature_dir}" config rerere.autoUpdate "$1"
  git -C "${feature_dir}" fetch -q
  if git -C "${feature_dir}" merge -q --no-edit origin/main > /dev/null 2>&1; then
    fail "the merge has no conflicts"
  fi
  sed -e '/^<<<<<<< /d' -e '/^||||||| /,/^=======$/d' -e '/^=======$/d' -e '/^>>>>>>> /d' \
    -e "${2:-}" "${feature_dir}/file.txt" > "${feature_dir}/file.txt.new"
  mv "${feature_dir}/file.txt.new" "${feature_dir}/file.txt"
  git -C "${feature_dir}" add file.txt
  git -C "${feature_dir}" commit -q --no-edit 2> /dev/null
  git -C "${feature_dir}" reset -q --hard "${feature_head}"
}

## Usage: push_to
## Runs `git-push-to ${main_dir} ${feature_dir}`.  Sets ${push_status} to its
## exit status and ${push_output} to its output.
push_to() {
  if push_output="$("${COMMANDS_DIR}/git-push-to" "${main_dir}" "${feature_dir}" 2>&1)"; then
    push_status=0
  else
    push_status=$?
  fi
}

## Usage: check_not_resolved DESCRIPTION
## Checks that git-push-to failed, pushed nothing, committed nothing, and left
## the merge in progress.
check_not_resolved() {
  if [ "${push_status}" -eq 0 ]; then
    fail "$1: git-push-to succeeded"
  fi
  if [ "$(git -C "${remote}" rev-parse refs/heads/feature)" != "${feature_head}" ]; then
    fail "$1: pushed to feature"
  fi
  if [ "$(git -C "${feature_dir}" rev-parse HEAD)" != "${feature_head}" ]; then
    fail "$1: HEAD changed"
  fi
  if ! git -C "${feature_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
    fail "$1: the merge is not in progress"
  fi
}

## A conflict that rerere did not resolve stops git-push-to, and its markers
## are in the diff3 style.
setup_case unresolved
push_to
check_not_resolved "unresolved conflict"
case "${push_output}" in
  *"conflicted: file.txt"*) ;;
  *) fail "unresolved conflict: wrong diagnostic: ${push_output}" ;;
esac
if ! grep -q '^||||||| ' "${feature_dir}/file.txt"; then
  fail "unresolved conflict: the merge did not use the diff3 conflict style"
fi

## A resolution that rerere recorded is checked and committed, whether or not
## rerere stages the files that it resolves.
expected="$(printf '%s\n' ONE two three four five six SEVEN-feature SEVEN-main eight nine)"
for auto_update in false true; do
  setup_case "rerere-${auto_update}"
  record_resolution "${auto_update}"
  push_to
  if [ "${push_status}" -ne 0 ]; then
    fail "rerere (autoUpdate ${auto_update}): git-push-to failed: ${push_output}"
  fi
  remote_head="$(git -C "${remote}" rev-parse refs/heads/feature)"
  if [ "${remote_head}" != "$(git -C "${feature_dir}" rev-parse HEAD)" ]; then
    fail "rerere (autoUpdate ${auto_update}): the merge was not pushed"
  fi
  if [ "$(git -C "${remote}" rev-parse "${remote_head}^1")" != "${feature_head}" ] \
    || [ "$(git -C "${remote}" rev-parse "${remote_head}^2")" != "$(git -C "${main_dir}" rev-parse HEAD)" ]; then
    fail "rerere (autoUpdate ${auto_update}): the pushed commit is not the merge of main into feature"
  fi
  if [ "$(git -C "${remote}" show "${remote_head}:file.txt")" != "${expected}" ]; then
    fail "rerere (autoUpdate ${auto_update}): wrong merge result: $(git -C "${remote}" show "${remote_head}:file.txt")"
  fi
  message="$(git -C "${remote}" log -1 --format=%B "${remote_head}")"
  if [ "${message}" != "Merge branch 'main' into feature" ]; then
    fail "rerere (autoUpdate ${auto_update}): wrong merge message: ${message}"
  fi
done

## A recorded resolution that also changed a line that merged cleanly is
## refused.
setup_case rerere-clean
record_resolution false 's/^three$/THREE/'
push_to
check_not_resolved "resolution that changed a clean line"
case "${push_output}" in
  *"file.txt: the text before the first conflict region changed"*) ;;
  *) fail "resolution that changed a clean line: wrong diagnostic: ${push_output}" ;;
esac

echo "${SCRIPT_NAME}: all tests passed"
