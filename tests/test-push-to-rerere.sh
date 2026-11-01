#!/bin/sh

# Tests that `git-push-to` and `git-pull-upstream` commit a merge whose
# conflicts `git rerere` resolved, after checking the resolution, and that
# they stop, with the merge in progress, when they cannot accept the
# resolution:  at conflicts that rerere did not resolve, at a resolution that
# changed text outside the conflict regions, at a conflict other than a
# content conflict, at a file whose sides contain lines that look like
# conflict markers, and at a working tree with other changes.
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

## Usage: setup_case NAME [FILE]
## Creates a remote under ${WORK_DIR}/NAME with branches "main" and
## "feature", whose changes to FILE (default "file.txt") conflict, and a clone
## of each.  Both sides add the same lines around the lines that conflict, so
## the conflict region differs between the "merge" and "diff3" conflict
## styles.  The repository also contains sub/keep.txt and other.txt.  Sets
## ${cfile} to FILE, ${main_dir} and ${feature_dir} to the clones, ${remote}
## to the remote, and ${feature_head} to the head of "feature".
setup_case() {
  case_dir="${WORK_DIR}/$1"
  cfile="${2:-file.txt}"
  mkdir "${case_dir}"
  remote="${case_dir}/myrepo.git"
  git init -q --bare -b main "${remote}"
  git init -q -b main "${case_dir}/seed"
  printf '%s\n' one two three four five six seven eight nine > "${case_dir}/seed/${cfile}"
  mkdir "${case_dir}/seed/sub"
  printf '%s\n' keep > "${case_dir}/seed/sub/keep.txt"
  printf '%s\n' other > "${case_dir}/seed/other.txt"
  git -C "${case_dir}/seed" add -A
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

  printf '%s\n' ONE two three four five six SAME SEVEN-main SAME2 eight nine > "${main_dir}/${cfile}"
  git -C "${main_dir}" commit -q -a -m "Change main"
  git -C "${main_dir}" push -q
  printf '%s\n' one two three four five six SAME SEVEN-feature SAME2 eight nine > "${feature_dir}/${cfile}"
  git -C "${feature_dir}" commit -q -a -m "Change feature"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
}

## Usage: commit_feature MESSAGE
## Commits every change in ${feature_dir}, pushes it, and updates
## ${feature_head}.
commit_feature() {
  git -C "${feature_dir}" commit -q -a -m "$1"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
}

## The resolution that `record_resolution` records by default:  it keeps
## both sides.
default_resolution='ONE two three four five six SAME SEVEN-feature SEVEN-main SAME2 eight nine'

## Usage: record_resolution AUTO-UPDATE [LINE...]
## Turns on `git rerere` in ${feature_dir}, with `rerere.autoUpdate` set to
## AUTO-UPDATE, and records a resolution of the merge of main whose ${cfile}
## consists of the LINEs, or else of ${default_resolution}.  Then undoes the
## merge.
record_resolution() {
  git -C "${feature_dir}" config rerere.enabled true
  git -C "${feature_dir}" config rerere.autoUpdate "$1"
  shift
  if [ $# -eq 0 ]; then
    # shellcheck disable=SC2086 # Split the lines at spaces.
    set -- ${default_resolution}
  fi
  git -C "${feature_dir}" fetch -q
  if git -C "${feature_dir}" merge -q --no-edit origin/main > /dev/null 2>&1; then
    fail "the merge has no conflicts"
  fi
  printf '%s\n' "$@" > "${feature_dir}/${cfile}"
  git -C "${feature_dir}" add -- "${cfile}"
  git -C "${feature_dir}" commit -q --no-edit 2> /dev/null
  git -C "${feature_dir}" reset -q --hard "${feature_head}"
}

## Usage: push_to
## Runs `git-push-to --no-llm ${main_dir} ${feature_dir}`.  Sets
## ${push_status} to its exit status and ${push_output} to its output.
push_to() {
  if push_output="$("${COMMANDS_DIR}/git-push-to" --no-llm "${main_dir}" "${feature_dir}" 2>&1)"; then
    push_status=0
  else
    push_status=$?
  fi
}

## Usage: check_resolved DESCRIPTION MERGE-MESSAGE [LINE...]
## Checks that the command succeeded without reporting a problem merging, and
## pushed the merge of main into feature, with MERGE-MESSAGE as its message,
## and with ${cfile} consisting of the LINEs, or else of ${default_resolution}.
check_resolved() {
  check_description="$1"
  check_message="$2"
  shift 2
  if [ $# -eq 0 ]; then
    # shellcheck disable=SC2086 # Split the lines at spaces.
    set -- ${default_resolution}
  fi
  if [ "${push_status}" -ne 0 ]; then
    fail "${check_description}: the command failed: ${push_output}"
  fi
  case "${push_output}" in
    *"problem merging"*) fail "${check_description}: reported a problem: ${push_output}" ;;
  esac
  remote_head="$(git -C "${remote}" rev-parse refs/heads/feature)"
  if [ "${remote_head}" != "$(git -C "${feature_dir}" rev-parse HEAD)" ]; then
    fail "${check_description}: the merge was not pushed"
  fi
  if [ "$(git -C "${remote}" rev-parse "${remote_head}^1")" != "${feature_head}" ] \
    || [ "$(git -C "${remote}" rev-parse "${remote_head}^2")" != "$(git -C "${main_dir}" rev-parse HEAD)" ]; then
    fail "${check_description}: the pushed commit is not the merge of main into feature"
  fi
  if [ "$(git -C "${remote}" show "${remote_head}:${cfile}")" != "$(printf '%s\n' "$@")" ]; then
    fail "${check_description}: wrong merge result: $(git -C "${remote}" show "${remote_head}:${cfile}")"
  fi
  message="$(git -C "${remote}" log -1 --format=%B "${remote_head}")"
  if [ "${message}" != "${check_message}" ]; then
    fail "${check_description}: wrong merge message: ${message}"
  fi
}

## Usage: check_not_resolved DESCRIPTION DIAGNOSTIC
## Checks that git-push-to failed, pushed nothing, committed nothing, left
## the merge in progress, and printed DIAGNOSTIC.
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
  case "${push_output}" in
    *"$2"*) ;;
    *) fail "$1: wrong diagnostic: ${push_output}" ;;
  esac
}

## A conflict that rerere did not resolve stops git-push-to.
setup_case unresolved
push_to
check_not_resolved "unresolved conflict" "conflicted: file.txt"

## A resolution that rerere recorded is checked and committed, whether or not
## rerere stages the files that it resolves, and in the conflict style that
## the repository's configuration gives, under which rerere recorded the
## resolution.
for style in merge diff3; do
  for auto_update in false true; do
    setup_case "rerere-${style}-${auto_update}"
    git -C "${feature_dir}" config merge.conflictStyle "${style}"
    record_resolution "${auto_update}"
    push_to
    check_resolved "rerere (${style}, autoUpdate ${auto_update})" "Merge branch 'main' into feature"
  done
done

## A conflicted file whose name git would quote is handled.
setup_case unusual-name 'odd "name" \ here.txt'
record_resolution false
push_to
check_resolved "unusual file name" "Merge branch 'main' into feature"

## `git-pull-upstream` handles a resolution that rerere recorded, even when it
## runs in a subdirectory.
setup_case pull-upstream
record_resolution false
if push_output="$(cd "${feature_dir}/sub" && "${COMMANDS_DIR}/git-pull-upstream" 2>&1)"; then
  push_status=0
else
  push_status=$?
fi
check_resolved "git-pull-upstream in a subdirectory" "Merge remote-tracking branch 'origin/main' into feature"

## A recorded resolution that also changed a line that merged cleanly is
## refused.
setup_case rerere-clean
# shellcheck disable=SC2046 # Split the lines at spaces.
record_resolution false $(printf '%s\n' "${default_resolution}" | sed -e 's/three/THREE/')
push_to
check_not_resolved "resolution that changed a clean line" \
  "file.txt: the text before the first conflict region changed"

## A conflict other than a content conflict is refused, even beside a file
## whose conflicts rerere resolved.
setup_case modify-delete
record_resolution false
git -C "${main_dir}" rm -q other.txt
git -C "${main_dir}" commit -q -m "Delete other.txt"
git -C "${main_dir}" push -q
printf '%s\n' changed > "${feature_dir}/other.txt"
commit_feature "Change other.txt"
push_to
check_not_resolved "modify/delete conflict" \
  "other.txt has a conflict other than a content conflict"

## A file whose sides contain a line that looks like a conflict marker is
## refused, even if rerere resolved its conflicts.
setup_case marker-like
printf '%s\n' one two three four five six SAME SEVEN-feature SAME2 eight '>>>>>>> nine' \
  > "${feature_dir}/file.txt"
commit_feature "Add a line that looks like a conflict marker"
record_resolution false ONE two three four five six SAME SEVEN-feature SEVEN-main SAME2 eight '>>>>>>> nine'
push_to
check_not_resolved "a line that looks like a conflict marker" \
  "file.txt contains lines that look like conflict markers"

## The same holds when one side renamed the file, so that the other side
## has it under its old name.
setup_case marker-like-renamed
git -C "${main_dir}" mv file.txt moved.txt
git -C "${main_dir}" commit -q -m "Rename file.txt"
git -C "${main_dir}" push -q
printf '%s\n' one two three four five six SAME SEVEN-feature SAME2 eight '>>>>>>> nine' \
  > "${feature_dir}/file.txt"
commit_feature "Add a line that looks like a conflict marker"
cfile=moved.txt
record_resolution false ONE two three four five six SAME SEVEN-feature SEVEN-main SAME2 eight '>>>>>>> nine'
push_to
check_not_resolved "a line that looks like a conflict marker, in a renamed file" \
  "moved.txt contains lines that look like conflict markers"

## A line "=======" in the resolution is accepted if a side contains one,
## such as a Markdown heading's underline.  rerere cannot parse a conflict
## region that contains such a line unless the conflict markers are longer,
## as the attribute `conflict-marker-size` makes them.
setup_case separator
printf '%s\n' 'file.txt conflict-marker-size=10' > "${feature_dir}/.gitattributes"
git -C "${feature_dir}" add .gitattributes
printf '%s\n' one two three four five six SAME SEVEN-feature '=======' SAME2 eight nine \
  > "${feature_dir}/file.txt"
commit_feature "Underline a heading"
record_resolution false ONE two three four five six SAME SEVEN-feature '=======' SEVEN-main SAME2 eight nine
push_to
check_resolved "a line that looks like a separator" "Merge branch 'main' into feature" \
  ONE two three four five six SAME SEVEN-feature '=======' SEVEN-main SAME2 eight nine

## A change in the working tree other than the merge is refused.
setup_case other-change
record_resolution false
printf '%s\n' changed > "${feature_dir}/sub/keep.txt"
push_to
check_not_resolved "another change in the working tree" \
  "changed, but not conflicted: sub/keep.txt"

echo "${SCRIPT_NAME}: all tests passed"
