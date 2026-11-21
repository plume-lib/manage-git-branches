#!/bin/sh

# Tests that `git-push-to` and `git-pull-upstream` reformat a branch before
# pushing it, and commit the reformatting.
#
# Usage:
#   tests/test-push-to-reformat.sh
#
# The project's Makefile has a "reformat" rule, which `compile-project
# --format` runs, that upper-cases every file `*.txt`, and an "all" rule,
# which `compile-project` runs, that fails if the file "broken" exists.  The
# branch "main" is formatted, as an upstream branch whose continuous
# integration checks the formatting is; unformatted text comes from the
# branch "feature".
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.

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
# shellcheck source=common-test-functions.sh
. "${TESTS_DIR}/common-test-functions.sh"

unset MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT
unset MANAGE_GIT_BRANCHES_SKIP_FORMAT_PROJECT
unset MAKE_FLAGS
unset MAKELEVEL
unset MAKEFLAGS
unset MFLAGS

failures=0

fail() {
  echo "${SCRIPT_NAME}: FAIL: $*" >&2
  failures=$((failures + 1))
}

## Usage: make_clone REMOTE BRANCH DIRECTORY
## Clones BRANCH of REMOTE into DIRECTORY.
make_clone() {
  git clone -q -b "$2" "$1" "$3"
  # `sanitize_git_env` leaves `pull.rebase` unset, and git refuses
  # to pull divergent branches unless something says how to reconcile them.
  # This workflow merges them.
  git -C "$3" config pull.rebase false
}

## Usage: push_to ARGUMENT...
## Runs `git-push-to` with the ARGUMENTs and without an AI agent, with its
## standard error in ${WORK_DIR}/errors.  Returns its exit status.
push_to() {
  "${COMMANDS_DIR}/git-push-to" --no-llm "$@" > /dev/null 2> "${WORK_DIR}/errors"
}

## Usage: add_main_line LINE
## Appends LINE, which is formatted, to file.txt on main, and pushes main.
add_main_line() {
  printf '%s\n' "$1" >> "${MAIN_DIR}/file.txt"
  git -C "${MAIN_DIR}" commit -q -a -m "Add $1"
  git -C "${MAIN_DIR}" push -q
}

## Usage: add_feature_line DIRECTORY LINE
## Appends LINE, which need not be formatted, to feature.txt in the working
## tree DIRECTORY, and commits it without pushing it.
add_feature_line() {
  printf '%s\n' "$2" >> "$1/feature.txt"
  git -C "$1" add feature.txt
  git -C "$1" commit -q -m "Add $2"
}

## Usage: pushed_head [BRANCH]
## Prints the commit that the remote's branch BRANCH, by default "feature",
## names.
pushed_head() {
  git -C "${REMOTE}" rev-parse "refs/heads/${1:-feature}"
}

## Usage: last_subject DIRECTORY
## Prints the subject of the last commit in the working tree DIRECTORY.
last_subject() {
  git -C "$1" log -1 --format=%s
}

## Create a remote with "main" and "feature", and a clone of each.
REMOTE="${WORK_DIR}/myrepo.git"
git init -q --bare -b main "${REMOTE}"
SEED="${WORK_DIR}/seed"
git init -q -b main "${SEED}"
# shellcheck disable=SC2016 # Make, not this shell, expands the variables.
FORMAT_RULE='reformat:\n\t@for f in *.txt; do tr a-z A-Z < "$$f" > "$$f.tmp" && mv "$$f.tmp" "$$f"; done'
# shellcheck disable=SC2059 # The format contains the rule's escapes.
printf "all:\n\t@test ! -e broken\n${FORMAT_RULE}\n" > "${SEED}/Makefile"
printf '%s\n' broken '*.tmp' > "${SEED}/.gitignore"
echo "FIRST LINE" > "${SEED}/file.txt"
git -C "${SEED}" add Makefile .gitignore file.txt
git -C "${SEED}" commit -q -m "Initial commit"
git -C "${SEED}" remote add origin "${REMOTE}"
git -C "${SEED}" push -q --set-upstream origin main
git -C "${SEED}" push -q origin main:refs/heads/feature
git -C "${SEED}" push -q origin main:refs/heads/upstream-feature

MAIN_DIR="${WORK_DIR}/myrepo-branch-main"
FEATURE_DIR="${WORK_DIR}/myrepo-branch-feature"
make_clone "${REMOTE}" main "${MAIN_DIR}"
make_clone "${REMOTE}" feature "${FEATURE_DIR}"

MERGE_SUBJECT="Merge branch 'main' into feature"

## A branch with unformatted text is reformatted after the merge, and the
## reformatting is committed and pushed.
add_feature_line "${FEATURE_DIR}" "feature line"
add_main_line "SECOND LINE"
if ! push_to "${MAIN_DIR}" "${FEATURE_DIR}"; then
  fail "reformat: git-push-to failed: $(cat "${WORK_DIR}/errors")"
else
  if [ "$(last_subject "${FEATURE_DIR}")" != "Reformat" ]; then
    fail "reformat: the last commit is not \"Reformat\": $(git -C "${FEATURE_DIR}" log --oneline -3)"
  elif [ "$(git -C "${FEATURE_DIR}" log -1 --format=%s HEAD^)" != "${MERGE_SUBJECT}" ]; then
    fail "reformat: the reformatting's parent is not the merge: $(git -C "${FEATURE_DIR}" log --oneline -3)"
  fi
  if [ "$(git -C "${FEATURE_DIR}" show HEAD:feature.txt)" != "FEATURE LINE" ]; then
    fail "reformat: wrong committed feature.txt: $(git -C "${FEATURE_DIR}" show HEAD:feature.txt)"
  fi
  if [ -n "$(git -C "${FEATURE_DIR}" status --porcelain)" ]; then
    fail "reformat: the working tree is not clean: $(git -C "${FEATURE_DIR}" status --porcelain)"
  fi
  if [ "$(pushed_head)" != "$(git -C "${FEATURE_DIR}" rev-parse HEAD)" ]; then
    fail "reformat: the reformatting was not pushed"
  fi
fi

## A merge that is already formatted gets no reformatting commit.
add_main_line "THIRD LINE"
if ! push_to "${MAIN_DIR}" "${FEATURE_DIR}"; then
  fail "formatted: git-push-to failed: $(cat "${WORK_DIR}/errors")"
elif [ "$(last_subject "${FEATURE_DIR}")" != "${MERGE_SUBJECT}" ]; then
  fail "formatted: the last commit is not the merge: $(git -C "${FEATURE_DIR}" log --oneline -3)"
fi

## --noformat skips the reformatting.
add_feature_line "${FEATURE_DIR}" "noformat line"
add_main_line "FOURTH LINE"
if ! push_to --noformat "${MAIN_DIR}" "${FEATURE_DIR}"; then
  fail "--noformat: git-push-to failed: $(cat "${WORK_DIR}/errors")"
elif [ "$(last_subject "${FEATURE_DIR}")" != "${MERGE_SUBJECT}" ]; then
  fail "--noformat: the last commit is not the merge: $(git -C "${FEATURE_DIR}" log --oneline -3)"
elif ! grep -q -x "noformat line" "${FEATURE_DIR}/feature.txt"; then
  fail "--noformat: feature.txt was reformatted: $(cat "${FEATURE_DIR}/feature.txt")"
fi

## MANAGE_GIT_BRANCHES_SKIP_FORMAT_PROJECT skips the reformatting.
add_feature_line "${FEATURE_DIR}" "skip line"
add_main_line "FIFTH LINE"
# The subshell confines the variable to this call:  an assignment that
# prefixes a call of a shell function, as `push_to` is, stays set after the
# call in Bash 3.2, which is /bin/sh on macOS.
if ! (MANAGE_GIT_BRANCHES_SKIP_FORMAT_PROJECT=1 \
  && export MANAGE_GIT_BRANCHES_SKIP_FORMAT_PROJECT \
  && push_to "${MAIN_DIR}" "${FEATURE_DIR}"); then
  fail "MANAGE_GIT_BRANCHES_SKIP_FORMAT_PROJECT: git-push-to failed: $(cat "${WORK_DIR}/errors")"
elif [ "$(last_subject "${FEATURE_DIR}")" != "${MERGE_SUBJECT}" ]; then
  fail "MANAGE_GIT_BRANCHES_SKIP_FORMAT_PROJECT: the last commit is not the merge: $(git -C "${FEATURE_DIR}" log --oneline -3)"
elif ! grep -q -x "skip line" "${FEATURE_DIR}/feature.txt"; then
  fail "MANAGE_GIT_BRANCHES_SKIP_FORMAT_PROJECT: feature.txt was reformatted: $(cat "${FEATURE_DIR}/feature.txt")"
fi

## The next push reformats what the skipped reformattings left, even though
## it merges nothing new.
if ! push_to "${MAIN_DIR}" "${FEATURE_DIR}"; then
  fail "catch-up: git-push-to failed: $(cat "${WORK_DIR}/errors")"
elif [ "$(last_subject "${FEATURE_DIR}")" != "Reformat" ]; then
  fail "catch-up: the last commit is not \"Reformat\": $(git -C "${FEATURE_DIR}" log --oneline -3)"
elif grep -q '[a-z]' "${FEATURE_DIR}/feature.txt"; then
  fail "catch-up: feature.txt was not reformatted: $(cat "${FEATURE_DIR}/feature.txt")"
elif [ "$(pushed_head)" != "$(git -C "${FEATURE_DIR}" rev-parse HEAD)" ]; then
  fail "catch-up: the reformatting was not pushed"
fi

## If the reformatted project does not build, the reformatting is not
## committed, the tracked files are restored, and nothing is pushed.  This
## branch's formatter also creates the file `broken`, as if the reformatting
## broke the build.
# shellcheck disable=SC2059 # The format contains the rule's escapes.
printf "all:\n\t@test ! -e broken\n${FORMAT_RULE}; touch broken\n" > "${FEATURE_DIR}/Makefile"
git -C "${FEATURE_DIR}" commit -q -a -m "Break the build when reformatting"
add_feature_line "${FEATURE_DIR}" "broken line"
add_main_line "SIXTH LINE"
before="$(pushed_head)"
if push_to "${MAIN_DIR}" "${FEATURE_DIR}"; then
  fail "broken by reformatting: git-push-to succeeded"
else
  case "$(cat "${WORK_DIR}/errors")" in
    *"unable to build in ${FEATURE_DIR} after reformatting it"*"while reformatting"*) ;;
    *) fail "broken by reformatting: wrong diagnostic: $(cat "${WORK_DIR}/errors")" ;;
  esac
  if [ "$(last_subject "${FEATURE_DIR}")" != "${MERGE_SUBJECT}" ]; then
    fail "broken by reformatting: the last commit is not the merge: $(git -C "${FEATURE_DIR}" log --oneline -3)"
  fi
  if [ -n "$(git -C "${FEATURE_DIR}" status --porcelain --untracked-files=no)" ]; then
    fail "broken by reformatting: the tracked files were not restored: $(git -C "${FEATURE_DIR}" status --porcelain)"
  fi
  if [ "$(pushed_head)" != "${before}" ]; then
    fail "broken by reformatting: the branch was pushed"
  fi
fi
rm -f "${FEATURE_DIR}/broken"

## A formatter that fails stops the push, and the tracked files that it
## changed are restored.
printf 'all:\n\t@:\nreformat:\n\t@echo changed > feature.txt; exit 3\n' > "${FEATURE_DIR}/Makefile"
git -C "${FEATURE_DIR}" commit -q -a -m "Fail to reformat"
add_main_line "SEVENTH LINE"
before="$(pushed_head)"
if push_to "${MAIN_DIR}" "${FEATURE_DIR}"; then
  fail "failing formatter: git-push-to succeeded"
else
  case "$(cat "${WORK_DIR}/errors")" in
    *"unable to reformat ${FEATURE_DIR}"*"while reformatting"*) ;;
    *) fail "failing formatter: wrong diagnostic: $(cat "${WORK_DIR}/errors")" ;;
  esac
  if [ "$(pushed_head)" != "${before}" ]; then
    fail "failing formatter: the branch was pushed"
  fi
  if [ -n "$(git -C "${FEATURE_DIR}" status --porcelain --untracked-files=no)" ]; then
    fail "failing formatter: the tracked files were not restored: $(git -C "${FEATURE_DIR}" status --porcelain)"
  fi
fi

## The "Reformat" commit omits a change that the build makes to a tracked
## file.  This branch's build rewrites generated.dat, which the formatter does
## not change, once feature.txt is formatted.
# shellcheck disable=SC2059 # The format contains the rule's escapes.
printf "all:\n\t@if ! grep -q '[a-z]' feature.txt; then echo built > generated.dat; fi\n${FORMAT_RULE}\n" \
  > "${FEATURE_DIR}/Makefile"
echo original > "${FEATURE_DIR}/generated.dat"
git -C "${FEATURE_DIR}" add Makefile generated.dat
git -C "${FEATURE_DIR}" commit -q -m "Generate a file when formatted"
add_feature_line "${FEATURE_DIR}" "generated line"
add_main_line "EIGHTH LINE"
if ! push_to "${MAIN_DIR}" "${FEATURE_DIR}"; then
  fail "build changes: git-push-to failed: $(cat "${WORK_DIR}/errors")"
elif [ "$(last_subject "${FEATURE_DIR}")" != "Reformat" ]; then
  fail "build changes: the last commit is not \"Reformat\": $(git -C "${FEATURE_DIR}" log --oneline -3)"
elif [ "$(git -C "${FEATURE_DIR}" show HEAD:generated.dat)" != "original" ]; then
  fail "build changes: the reformatting commit includes the build's change: $(git -C "${FEATURE_DIR}" show --stat HEAD)"
elif [ "$(git -C "${FEATURE_DIR}" show HEAD:feature.txt | grep -c '[a-z]')" -ne 0 ]; then
  fail "build changes: feature.txt was not reformatted: $(git -C "${FEATURE_DIR}" show HEAD:feature.txt)"
fi
git -C "${FEATURE_DIR}" checkout -q -- .

## `git-pull-upstream` reformats too.
UPSTREAM_DIR="${WORK_DIR}/myrepo-branch-upstream-feature"
make_clone "${REMOTE}" upstream-feature "${UPSTREAM_DIR}"
add_feature_line "${UPSTREAM_DIR}" "upstream line"
add_main_line "NINTH LINE"
if ! (cd "${UPSTREAM_DIR}" && "${COMMANDS_DIR}/git-pull-upstream" --no-llm) \
  > /dev/null 2> "${WORK_DIR}/errors"; then
  fail "git-pull-upstream: failed: $(cat "${WORK_DIR}/errors")"
elif [ "$(last_subject "${UPSTREAM_DIR}")" != "Reformat" ]; then
  fail "git-pull-upstream: the last commit is not \"Reformat\": $(git -C "${UPSTREAM_DIR}" log --oneline -3)"
elif grep -q '[a-z]' "${UPSTREAM_DIR}/feature.txt"; then
  fail "git-pull-upstream: feature.txt was not reformatted: $(cat "${UPSTREAM_DIR}/feature.txt")"
elif [ "$(pushed_head upstream-feature)" != "$(git -C "${UPSTREAM_DIR}" rev-parse HEAD)" ]; then
  fail "git-pull-upstream: the reformatting was not pushed"
fi

if [ "${failures}" -ne 0 ]; then
  echo "${SCRIPT_NAME}: ${failures} failure(s)" >&2
  exit 1
fi
echo "${SCRIPT_NAME}: OK"
