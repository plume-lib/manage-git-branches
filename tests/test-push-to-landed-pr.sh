#!/bin/sh

# Tests that `git-push-to` and `git-pull-upstream`, when they merge a branch
# that contains the squash commit of a pull request into a branch that
# merged an earlier version of that pull request, first merge the pull
# request's final version and then the squash commit, so that the merge has
# no conflicts; and that they do not when that would be wrong or useless.
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

## Usage: new_project NAME
## Creates the bare repository ${WORK_DIR}/NAME.git, which ${REMOTE} names,
## and a working copy of it, ${WORK_DIR}/NAME-seed, which ${SEED} names.  Its
## branch "main" has a commit with three files:  text.txt, whose 9 lines are
## "line 1" through "line 9", the binary file data.bin, and dependent.txt.
## ${SEED} is left on branch "main".
new_project() {
  PROJECT="$1"
  REMOTE="${WORK_DIR}/$1.git"
  SEED="${WORK_DIR}/$1-seed"
  git init -q --bare -b main "${REMOTE}"
  git init -q -b main "${SEED}"
  printf 'line %s\n' 1 2 3 4 5 6 7 8 9 > "${SEED}/text.txt"
  # A NUL byte makes git treat the file as binary.
  printf 'binary\000original\n' > "${SEED}/data.bin"
  echo "dependent's file" > "${SEED}/dependent.txt"
  git -C "${SEED}" add text.txt data.bin dependent.txt
  git -C "${SEED}" commit -q -m "Initial commit"
  git -C "${SEED}" remote add origin "${REMOTE}"
  git -C "${SEED}" push -q --set-upstream origin main
}

## Usage: set_line N TEXT
## Replaces line N of text.txt in ${SEED} by TEXT, and stages the file.
set_line() {
  sed -e "$1s/.*/$2/" "${SEED}/text.txt" > "${SEED}/text.txt.new"
  mv "${SEED}/text.txt.new" "${SEED}/text.txt"
  git -C "${SEED}" add text.txt
}

## Usage: set_binary TEXT
## Writes TEXT into data.bin in ${SEED}, and stages the file.
set_binary() {
  printf 'binary\000%s\n' "$1" > "${SEED}/data.bin"
  git -C "${SEED}" add data.bin
}

## Usage: land BRANCH N
## Squash-merges BRANCH of ${SEED} into "main" as pull request #N, as GitHub
## does, and pushes "main" and the ref "refs/pull/N/head", which GitHub
## provides, for the final head of BRANCH.  Sets ${squash} to the squash
## commit and ${final_head} to the head of BRANCH.  ${SEED} is left on
## branch "main".
land() {
  final_head="$(git -C "${SEED}" rev-parse "$1")"
  git -C "${SEED}" checkout -q main
  git -C "${SEED}" merge -q --squash "$1" > /dev/null 2>&1
  git -C "${SEED}" commit -q -m "Land $1 (#$2)"
  squash="$(git -C "${SEED}" rev-parse HEAD)"
  git -C "${SEED}" push -q origin main "$1:refs/pull/$2/head"
}

## Usage: push_main_into BRANCH
## Clones "main" and BRANCH of ${REMOTE}, and runs `git-push-to --no-llm` to
## merge "main" into BRANCH, writing its standard error to ${WORK_DIR}/stderr
## and setting ${TO} to BRANCH's working copy directory.  Returns the status
## of `git-push-to`.
push_main_into() {
  make_clone "${REMOTE}" main "${PROJECT}-branch-main"
  make_clone "${REMOTE}" "$1" "${PROJECT}-branch-$1"
  TO="${WORK_DIR}/${PROJECT}-branch-$1"
  "${COMMANDS_DIR}/git-push-to" --no-llm \
    "${WORK_DIR}/${PROJECT}-branch-main" "${TO}" > /dev/null 2> "${WORK_DIR}/stderr"
}

## Usage: expect_no_pr_merge DESCRIPTION DIRECTORY
## Fails unless the last command made no merge of ${final_head} in the
## working copy directory DIRECTORY, and printed nothing about a pull
## request's final version.  DESCRIPTION names the case; used for
## diagnostics.
expect_no_pr_merge() {
  if grep -q "final version of pull request" "${WORK_DIR}/stderr"; then
    fail "$1: merged a pull request's final version: $(cat "${WORK_DIR}/stderr")"
  fi
  if git -C "$2" merge-base --is-ancestor "${final_head}" HEAD; then
    fail "$1: merged the pull request's final head"
  fi
}

## Usage: make_basic_project NAME
## Creates a project NAME (see `new_project`) in which pull request #7, from
## branch "feature", changes text.txt and data.bin.  Branch "dependent"
## merges an early version of "feature" and makes a change of its own.  Then
## "feature" changes both files again, and the pull request lands on "main"
## as a squash commit, which is followed by a later change on "main".
make_basic_project() {
  new_project "$1"
  git -C "${SEED}" checkout -q -b feature
  set_line 1 'text early'
  set_binary 'early'
  git -C "${SEED}" commit -q -m "Early version of the feature"
  git -C "${SEED}" checkout -q -b dependent main
  git -C "${SEED}" merge -q --no-edit feature
  echo "dependent's change" >> "${SEED}/dependent.txt"
  git -C "${SEED}" commit -q -a -m "Dependent change"
  git -C "${SEED}" push -q origin dependent
  git -C "${SEED}" checkout -q feature
  set_line 1 'text final'
  set_binary 'final'
  git -C "${SEED}" commit -q -m "Final version of the feature"
}

## Usage: add_later_change
## Adds a commit to "main" of ${SEED}, which creates later.txt, and pushes it.
add_later_change() {
  echo "later change" > "${SEED}/later.txt"
  git -C "${SEED}" add later.txt
  git -C "${SEED}" commit -q -m "A later change on main"
  git -C "${SEED}" push -q origin main
}

### `git-push-to` merges the final version of the pull request, then the
### squash commit, and then "main", without conflicts.  The merges are made
### with `git merge`, so the commit-msg hook runs, and their messages do not
### write "#7", which would add an event to the pull request's timeline.

make_basic_project basic
land feature 7
add_later_change
## Without the merges of the pull request's final version, merging "main"
## into "dependent" conflicts in both files.
conflicts="$(git -C "${SEED}" merge-tree --write-tree --name-only --no-messages dependent main | sed -e '1d' || true)"
if [ "$(printf '%s\n' "${conflicts}" | sort | tr '\n' ' ')" != "data.bin text.txt " ]; then
  fail "the test's merge does not conflict as expected: [${conflicts}]"
fi
# A fork of the project, for `git-pull-upstream`, below.
git clone -q --bare "${REMOTE}" "${WORK_DIR}/basic-fork.git"

make_clone "${REMOTE}" main basic-branch-main
make_clone "${REMOTE}" dependent basic-branch-dependent
DEPENDENT="${WORK_DIR}/basic-branch-dependent"
# shellcheck disable=SC2016 # "$1" is expanded by the hook.
printf '#!/bin/sh\necho "Hook-Ran: yes" >> "$1"\n' > "${DEPENDENT}/.git/hooks/commit-msg"
chmod +x "${DEPENDENT}/.git/hooks/commit-msg"
if ! "${COMMANDS_DIR}/git-push-to" --no-llm \
  "${WORK_DIR}/basic-branch-main" "${DEPENDENT}" 2> "${WORK_DIR}/stderr"; then
  fail "git-push-to failed: $(cat "${WORK_DIR}/stderr")"
fi
if ! grep -q "merged the final version of pull request #7 " "${WORK_DIR}/stderr"; then
  fail "no diagnostic about pull request #7: $(cat "${WORK_DIR}/stderr")"
fi
for commit in "${final_head}" "${squash}"; do
  if ! git -C "${DEPENDENT}" merge-base --is-ancestor "${commit}" HEAD; then
    fail "git-push-to did not merge ${commit}"
  fi
done
for merge in "HEAD^1^1" "HEAD^1"; do
  message="$(git -C "${DEPENDENT}" log -1 --format=%B "${merge}")"
  case "${message}" in
    *'#7'*) fail "the message of a merge writes \"#7\": ${message}" ;;
  esac
  case "${message}" in
    *'Hook-Ran: yes'*) ;;
    *) fail "the commit-msg hook did not run for a merge: ${message}" ;;
  esac
done
if [ "$(git -C "${DEPENDENT}" rev-parse HEAD)" != "$(git -C "${DEPENDENT}" rev-parse '@{upstream}')" ]; then
  fail "git-push-to did not push"
fi
if [ "$(sed -n -e 1p "${DEPENDENT}/text.txt")" != "text final" ]; then
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

### `git-pull-upstream` does the same when it merges the upstream
### repository's default branch.

FORK="${WORK_DIR}/basic-fork"
make_clone "${WORK_DIR}/basic-fork.git" dependent basic-fork
git -C "${FORK}" remote add upstream "${REMOTE}"
if ! (cd "${FORK}" && "${COMMANDS_DIR}/git-pull-upstream" --no-llm) > /dev/null 2> "${WORK_DIR}/stderr"; then
  fail "git-pull-upstream failed: $(cat "${WORK_DIR}/stderr")"
fi
if ! grep -q "merged the final version of pull request #7 " "${WORK_DIR}/stderr"; then
  fail "git-pull-upstream: no diagnostic about pull request #7: $(cat "${WORK_DIR}/stderr")"
fi
if ! git -C "${FORK}" merge-base --is-ancestor "${final_head}" HEAD; then
  fail "git-pull-upstream did not merge the pull request's final head"
fi
if [ "$(git -C "${FORK}" rev-parse HEAD)" != "$(git -C "${WORK_DIR}/basic-fork.git" rev-parse dependent)" ]; then
  fail "git-pull-upstream did not push"
fi

### A branch that never merged the pull request's branch, and whose merge of
### "main" conflicts with the pull request's changes, gets an ordinary merge
### of "main", with no merge of the pull request's final version.

git -C "${SEED}" checkout -q -b unrelated "${squash}~1"
set_line 1 'unrelated change'
git -C "${SEED}" commit -q -m "Unrelated change"
git -C "${SEED}" push -q origin unrelated
make_clone "${REMOTE}" unrelated basic-branch-unrelated
"${COMMANDS_DIR}/git-push-to" --no-llm --no-pull-first \
  "${WORK_DIR}/basic-branch-main" "${WORK_DIR}/basic-branch-unrelated" > /dev/null 2> "${WORK_DIR}/stderr" || true
expect_no_pr_merge "unrelated branch" "${WORK_DIR}/basic-branch-unrelated"

### When no landed pull request changes a conflicted file, nothing asks the
### pull requests' repository about them.

git -C "${SEED}" checkout -q -b other-later "${squash}~1"
echo "another later change" > "${SEED}/later.txt"
git -C "${SEED}" add later.txt
git -C "${SEED}" commit -q -m "Another later change"
git -C "${SEED}" push -q origin other-later
make_clone "${REMOTE}" other-later basic-branch-other-later
GIT_TRACE="${WORK_DIR}/trace" "${COMMANDS_DIR}/git-push-to" --no-llm --no-pull-first \
  "${WORK_DIR}/basic-branch-main" "${WORK_DIR}/basic-branch-other-later" > /dev/null 2> "${WORK_DIR}/stderr" || true
if grep -q 'refs/pull/' "${WORK_DIR}/trace"; then
  fail "git-push-to asked about pull requests that change no conflicted file: $(grep 'refs/pull/' "${WORK_DIR}/trace")"
fi

### When the merge of "main" cannot start, the merges of the pull request's
### final version are undone too.

make_basic_project nostart
land feature 7
add_later_change
make_clone "${REMOTE}" main nostart-branch-main
make_clone "${REMOTE}" dependent nostart-branch-dependent
TO="${WORK_DIR}/nostart-branch-dependent"
before="$(git -C "${TO}" rev-parse HEAD)"
# An untracked file that the merge of "main" would overwrite.
echo "in the way" > "${TO}/later.txt"
if "${COMMANDS_DIR}/git-push-to" --no-llm \
  "${WORK_DIR}/nostart-branch-main" "${TO}" > /dev/null 2> "${WORK_DIR}/stderr"; then
  fail "merge that cannot start: git-push-to succeeded"
fi
if [ "$(git -C "${TO}" rev-parse HEAD)" != "${before}" ]; then
  fail "merge that cannot start: the branch was left at $(git -C "${TO}" log --oneline -1), not at ${before}"
fi

### A ref "refs/pull/7/head" whose head is not the one that the squash commit
### landed, as in a fork whose own pull request #7 is a different one, is
### not merged.

make_basic_project wronghead
land feature 7
git -C "${SEED}" checkout -q -b other-pr feature
echo "another pull request" > "${SEED}/other-pr.txt"
git -C "${SEED}" add other-pr.txt
git -C "${SEED}" commit -q -m "Another pull request"
git -C "${SEED}" push -q -f origin other-pr:refs/pull/7/head
final_head="$(git -C "${SEED}" rev-parse other-pr)"
push_main_into dependent || true
expect_no_pr_merge "wrong head" "${TO}"

### A final version that would undo another pull request's changes that the
### branch merged, because the pull request's branch merged that pull
### request's branch and later reverted the merge, is not merged.

new_project revert
git -C "${SEED}" checkout -q -b other main
echo "other's change" > "${SEED}/other.txt"
git -C "${SEED}" add other.txt
git -C "${SEED}" commit -q -m "Another pull request's change"
git -C "${SEED}" checkout -q -b feature main
set_line 1 'text early'
set_binary 'early'
git -C "${SEED}" commit -q -m "Early version of the feature"
git -C "${SEED}" checkout -q -b dependent feature
git -C "${SEED}" merge -q --no-edit other
git -C "${SEED}" push -q origin dependent
git -C "${SEED}" checkout -q feature
git -C "${SEED}" merge -q --no-edit other
git -C "${SEED}" revert --no-edit -m 1 HEAD > /dev/null
set_line 1 'text final'
set_binary 'final'
git -C "${SEED}" commit -q -m "Final version of the feature"
land feature 7
push_main_into dependent || true
expect_no_pr_merge "reverting final version" "${TO}"

### A final version whose merge conflicts with the branch is not merged.

make_basic_project conflicting
git -C "${SEED}" checkout -q dependent
set_line 1 "dependent's text"
git -C "${SEED}" commit -q -m "Change the feature's text"
git -C "${SEED}" push -q origin dependent
land feature 7
push_main_into dependent || true
expect_no_pr_merge "conflicting final version" "${TO}"

### A final version that leaves the merge of "main" as many conflicts as it
### has without it is not merged.  The pull request's later change is in a
### file that the branch did not change, and the conflict is with a later
### change on "main".

new_project useless
git -C "${SEED}" checkout -q -b feature
set_line 1 'text early'
git -C "${SEED}" commit -q -m "Early version of the feature"
git -C "${SEED}" checkout -q -b dependent feature
set_line 9 "dependent's line"
git -C "${SEED}" commit -q -m "Dependent change"
git -C "${SEED}" push -q origin dependent
git -C "${SEED}" checkout -q feature
set_binary 'final'
git -C "${SEED}" commit -q -m "Final version of the feature"
land feature 7
set_line 9 "main's line"
git -C "${SEED}" commit -q -m "Main's change"
git -C "${SEED}" push -q origin main
push_main_into dependent || true
expect_no_pr_merge "useless final version" "${TO}"

### Two pull requests whose earlier versions the branch merged, and that
### change different lines of the same file, are both merged, although
### neither alone resolves the conflicted file.  Pull request #5 changes line
### 1 and pull request #6 changes line 9.

## Usage: pr_line PR
## Prints the line of text.txt that pull request #PR changes.
pr_line() {
  if [ "$1" -eq 5 ]; then echo 1; else echo 9; fi
}

new_project two
for pr in 5 6; do
  git -C "${SEED}" checkout -q -b "feature${pr}" main
  set_line "$(pr_line "${pr}")" "text ${pr} early"
  git -C "${SEED}" commit -q -m "Early version of pull request ${pr}"
done
git -C "${SEED}" checkout -q -b dependent main
git -C "${SEED}" merge -q --no-ff --no-edit feature5
git -C "${SEED}" merge -q --no-edit feature6 > /dev/null
git -C "${SEED}" push -q origin dependent
for pr in 5 6; do
  git -C "${SEED}" checkout -q "feature${pr}"
  set_line "$(pr_line "${pr}")" "text ${pr} final"
  git -C "${SEED}" commit -q -m "Final version of pull request ${pr}"
done
land feature5 5
heads="${final_head}"
land feature6 6
heads="${heads} ${final_head}"
push_main_into dependent || fail "two pull requests: git-push-to failed: $(cat "${WORK_DIR}/stderr")"
for head in ${heads}; do
  if ! git -C "${TO}" merge-base --is-ancestor "${head}" HEAD; then
    fail "two pull requests: did not merge ${head}: $(cat "${WORK_DIR}/stderr")"
  fi
done
if [ "$(sed -n -e '1p;9p' "${TO}/text.txt" | tr '\n' ' ')" != "text 5 final text 6 final " ]; then
  fail "two pull requests: wrong text file: $(cat "${TO}/text.txt")"
fi

echo "${SCRIPT_NAME}: all tests passed"
