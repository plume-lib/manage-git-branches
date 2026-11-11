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

## Usage: push_to [OPTION...]
## Runs `git-push-to --no-llm OPTION... ${main_dir} ${feature_dir}`.  Sets
## ${push_status} to its exit status and ${push_output} to its output.
push_to() {
  if push_output="$("${COMMANDS_DIR}/git-push-to" --no-llm "$@" "${main_dir}" "${feature_dir}" 2>&1)"; then
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

## The lines of a hook that, like a formatter's, rejects a commit after
## lowercasing file.txt, and accepts a commit whose file.txt is lowercase.
lowercase_hook="tr 'A-Z' 'a-z' < file.txt > hook.tmp
if cmp -s file.txt hook.tmp; then rm hook.tmp; exit 0; fi
mv hook.tmp file.txt
exit 1"

## Usage: check_no_retry DESCRIPTION
## Checks that git-push-to did not commit again after a hook rejected a
## commit.
check_no_retry() {
  case "${push_output}" in
    *": committing again"*) fail "$1: committed again: ${push_output}" ;;
  esac
}

## Usage: hook_runs
## Prints the number of times that a hook that begins with ${count_hook_run}
## ran in ${feature_dir}.
# shellcheck disable=SC2016 # The hook expands the command substitution.
count_hook_run='echo ran >> "$(git rev-parse --git-path hook-runs)"'
hook_runs() {
  hook_runs_file="$(git -C "${feature_dir}" rev-parse --path-format=absolute --git-path hook-runs)"
  if [ -e "${hook_runs_file}" ]; then
    wc -l < "${hook_runs_file}" | tr -d ' '
  else
    echo 0
  fi
}

## A pre-commit hook that rejects the merge commit after reformatting the
## merged file does not stop git-push-to, which commits the file as the hook
## left it.  The commit runs the commit-msg hook.
setup_case hook-reformats
record_resolution false
install_git_hook "${feature_dir}" pre-commit "${lowercase_hook}"
# shellcheck disable=SC2016 # The hook expands $1.
install_git_hook "${feature_dir}" commit-msg 'echo "Checked: yes" >> "$1"'
push_to
check_resolved "a hook that reformats the merged file" "$(printf '%s\n' "Merge branch 'main' into feature" "Checked: yes")" \
  one two three four five six same seven-feature seven-main same2 eight nine
case "${push_output}" in
  *"the pre-commit hook changed file.txt"*) ;;
  *) fail "a hook that reformats the merged file: no diagnostic about the hook: ${push_output}" ;;
esac

## Usage: check_other_notice DESCRIPTION RESULT
## Checks that the summary file ${summary} has a line that says that the
## pre-commit hook changed other.txt and asks for a review of the hook's
## changes, which RESULT, such as "are staged, but not committed".
## DESCRIPTION names the test case; used for diagnostics.
check_other_notice() {
  if ! grep -q -x -F -- "in ${feature_dir}: the pre-commit hook changed other.txt, which the commit does not otherwise change; review the hook's changes, which $2" "${summary}"; then
    fail "$1: no summary line about other.txt: $(cat "${summary}")"
  fi
}

## A hook that, like one that formats the whole project, rejects the commit
## after reformatting a file that the merge does not change, does not stop
## git-push-to, which commits that file too, as the hook left it, and lists
## it for review.  The hook runs only twice.
setup_case hook-changes-other
record_resolution false
install_git_hook "${feature_dir}" pre-commit "${count_hook_run}
tr 'a-z' 'A-Z' < other.txt > hook.tmp
if cmp -s other.txt hook.tmp; then rm hook.tmp; exit 0; fi
mv hook.tmp other.txt
exit 1"
summary="${case_dir}/summary.txt"
push_to --summary "${summary}"
check_resolved "a hook that reformats another file" "Merge branch 'main' into feature"
if [ "$(git -C "${remote}" show refs/heads/feature:other.txt)" != OTHER ]; then
  fail "a hook that reformats another file: the merge lacks the hook's change: $(git -C "${remote}" show refs/heads/feature:other.txt)"
fi
check_other_notice "a hook that reformats another file" \
  "commit $(git -C "${feature_dir}" rev-parse --short HEAD) includes"
if [ "$(hook_runs)" -ne 2 ]; then
  fail "a hook that reformats another file: the hook ran $(hook_runs) times"
fi

## A hook that rejects every commit, changing a file that the merge does not
## change each time, stops git-push-to, with its first change to that file
## staged and its second not staged, and lists that file for review.
setup_case hook-changes-other-fails
record_resolution false
install_git_hook "${feature_dir}" pre-commit 'echo hooked >> other.txt' 'exit 1'
summary="${case_dir}/summary.txt"
push_to --summary "${summary}"
check_not_resolved "a hook that always fails after changing another file" "cannot commit the merge"
check_no_retry "a hook that always fails after changing another file"
if [ "$(git -C "${feature_dir}" show :other.txt)" != "$(printf '%s\n' other hooked)" ]; then
  fail "a hook that always fails after changing another file: the hook's change is not staged: $(git -C "${feature_dir}" show :other.txt)"
fi
case "${push_output}" in
  *"the pre-commit hook, run again, failed or changed a file; the changes that the pre-commit hook made when it rejected the commit are staged; the working tree has later changes, which are not staged"*) ;;
  *) fail "a hook that always fails after changing another file: no diagnostic about the staged changes: ${push_output}" ;;
esac
check_other_notice "a hook that always fails after changing another file" \
  "are staged, but not committed; the working tree has later changes, which are not staged"

## A hook that rejects the commit after reformatting a file that the merge
## does not change and creating a file stops git-push-to, which lists the
## file that the hook reformatted for review.
setup_case hook-changes-other-creates-file
record_resolution false
install_git_hook "${feature_dir}" pre-commit 'echo generated > generated.txt' 'echo hooked >> other.txt' 'exit 1'
summary="${case_dir}/summary.txt"
push_to --summary "${summary}"
check_not_resolved "a hook that changes another file and creates a file" \
  "the pre-commit hook created or deleted an untracked file"
check_no_retry "a hook that changes another file and creates a file"
check_other_notice "a hook that changes another file and creates a file" "are not committed"

## A hook that rejects the commit after changing a file that the merge does
## not change, and that changes it again when it runs again, although it
## then accepts the commit, stops git-push-to.
setup_case hook-changes-other-again
record_resolution false
# shellcheck disable=SC2016 # The hook expands ${marker}.
install_git_hook "${feature_dir}" pre-commit 'echo hooked >> other.txt' \
  'marker="$(git rev-parse --git-path hook-ran)"' \
  'if [ -e "${marker}" ]; then exit 0; fi' \
  ': > "${marker}"' \
  'exit 1'
push_to
check_not_resolved "a hook that changes another file again" "cannot commit the merge"
check_no_retry "a hook that changes another file again"

## A hook that rejects the commit after reformatting the merged file, and
## that changes it again when it runs again, although it then accepts the
## commit, stops git-push-to.
setup_case hook-changes-again
record_resolution false
# shellcheck disable=SC2016 # The hook expands ${marker}.
install_git_hook "${feature_dir}" pre-commit 'echo hooked >> file.txt' \
  'marker="$(git rev-parse --git-path hook-ran)"' \
  'if [ -e "${marker}" ]; then exit 0; fi' \
  ': > "${marker}"' \
  'exit 1'
push_to
check_not_resolved "a hook that changes the merged file again" "cannot commit the merge"
check_no_retry "a hook that changes the merged file again"

## A hook that rejects the commit after reformatting the merged file, and
## that stages a change when it runs again, although it then accepts the
## commit, stops git-push-to.
setup_case hook-stages-again
record_resolution false
# shellcheck disable=SC2016 # The hook expands ${marker}.
install_git_hook "${feature_dir}" pre-commit \
  'marker="$(git rev-parse --git-path hook-ran)"' \
  'if [ -e "${marker}" ]; then echo again >> file.txt; git add file.txt; exit 0; fi' \
  ': > "${marker}"' \
  'echo hooked >> file.txt' \
  'exit 1'
push_to
check_not_resolved "a hook that stages a change when it runs again" "cannot commit the merge"
check_no_retry "a hook that stages a change when it runs again"

## A hook that rejects the commit after reformatting the merged file and
## creating a file stops git-push-to.
setup_case hook-creates-file
record_resolution false
install_git_hook "${feature_dir}" pre-commit 'echo generated > generated.txt' "${lowercase_hook}"
push_to
check_not_resolved "a hook that creates a file" "cannot commit the merge"
check_no_retry "a hook that creates a file"

## A hook that rejects every commit, changing the merged file each time, stops
## git-push-to after one more commit.
setup_case hook-always-fails
record_resolution false
install_git_hook "${feature_dir}" pre-commit 'echo hooked >> file.txt' 'exit 1'
push_to
check_not_resolved "a hook that always fails" "cannot commit the merge"
if [ "$(grep -c -x hooked "${feature_dir}/file.txt")" -ne 2 ]; then
  fail "a hook that always fails: the hook did not run exactly twice"
fi

## Usage: setup_clean_case NAME
## As `setup_case`, but feature changes other.txt rather than file.txt, so
## that the merge of main into feature has no conflicts.
setup_clean_case() {
  setup_case "$1"
  git -C "${feature_dir}" reset -q --hard HEAD~1
  printf '%s\n' other-feature > "${feature_dir}/other.txt"
  git -C "${feature_dir}" commit -q -a -m "Change other.txt on feature"
  git -C "${feature_dir}" push -q --force
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
}

## A pre-merge-commit hook that rejects the commit of a merge without
## conflicts after reformatting the merged file does not stop git-push-to,
## which runs the hook again and commits the file as the hook left it.
setup_clean_case pre-merge-commit-reformats
install_git_hook "${feature_dir}" pre-merge-commit "${lowercase_hook}"
install_git_hook "${feature_dir}" pre-commit "${lowercase_hook}"
push_to
check_resolved "a pre-merge-commit hook that reformats the merged file" \
  "Merge branch 'main' into feature" \
  one two three four five six same seven-main same2 eight nine
case "${push_output}" in
  *"the pre-merge-commit hook changed file.txt"*) ;;
  *) fail "a pre-merge-commit hook that reformats the merged file: no diagnostic about the hook: ${push_output}" ;;
esac

## A pre-merge-commit hook that rejects the files as it left them stops
## git-push-to.
setup_clean_case pre-merge-commit-always-fails
install_git_hook "${feature_dir}" pre-merge-commit 'echo hooked >> file.txt' 'exit 1'
push_to
check_not_resolved "a pre-merge-commit hook that always fails" "cannot commit the merge"
case "${push_output}" in
  *"the pre-merge-commit hook, run again, failed or changed a file"*) ;;
  *) fail "a pre-merge-commit hook that always fails: the hook did not run again: ${push_output}" ;;
esac

## A pre-merge-commit hook that rejects the commit of the merge that a pull
## makes, after reformatting the merged file, does not stop the pull, which
## commits the file as the hook left it.  Feature has a commit that is not
## pushed, and the remote's feature changes file.txt.  The later merge of
## main then has conflicts, which stop git-push-to.
setup_case pre-merge-commit-pull
remote_feature="$(git -C "${feature_dir}" rev-parse HEAD)"
git -C "${feature_dir}" reset -q --hard HEAD~1
printf '%s\n' other-feature > "${feature_dir}/other.txt"
git -C "${feature_dir}" commit -q -a -m "Change other.txt on feature"
local_feature="$(git -C "${feature_dir}" rev-parse HEAD)"
install_git_hook "${feature_dir}" pre-merge-commit "${lowercase_hook}"
push_to
if [ "$(git -C "${feature_dir}" rev-parse HEAD^1)" != "${local_feature}" ] \
  || [ "$(git -C "${feature_dir}" rev-parse HEAD^2)" != "${remote_feature}" ]; then
  fail "a pre-merge-commit hook in a pull: the merge of the pull was not committed: ${push_output}"
fi
message="$(git -C "${feature_dir}" log -1 --format=%B HEAD)"
if [ "${message}" != "Merge remote-tracking branch 'origin/feature' into feature" ]; then
  fail "a pre-merge-commit hook in a pull: wrong message for the merge of the pull: ${message}"
fi
if [ "$(git -C "${feature_dir}" show HEAD:file.txt)" != "$(printf '%s\n' one two three four five six same seven-feature same2 eight nine)" ]; then
  fail "a pre-merge-commit hook in a pull: wrong file.txt: $(git -C "${feature_dir}" show HEAD:file.txt)"
fi

echo "${SCRIPT_NAME}: all tests passed"
