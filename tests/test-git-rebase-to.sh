#!/bin/sh

# Tests that `git-rebase-to` pushes each branch into the next and then
# rebases each branch onto the previous one:  it eliminates merge commits,
# keeps the branches' own commits, leaves an already-linear branch alone,
# never changes a branch's content, and with "--squash" makes each branch a
# single commit.
#
# Usage:
#   tests/test-git-rebase-to.sh
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

## Usage: make_clone REMOTE BRANCH DIRECTORY
make_clone() {
  git clone -q -b "$2" "$1" "$3"
  git -C "$3" config pull.rebase false
}

## Usage: commit_file DIRECTORY FILE CONTENT MESSAGE
## Writes CONTENT to FILE in DIRECTORY, commits it, and pushes it.
commit_file() {
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -- "$2"
  git -C "$1" commit -q -m "$4"
  git -C "$1" push -q
}

## Usage: subjects DIRECTORY BASE_DIRECTORY
## Prints the subjects of the commits in DIRECTORY that are not in
## BASE_DIRECTORY, oldest first, separated by commas.
subjects() {
  git -C "$1" fetch -q "$2" HEAD
  git -C "$1" log --reverse --format=%s FETCH_HEAD..HEAD | tr '\n' ',' | sed -e 's/,$//'
}

## Usage: count_commits DIRECTORY BASE_DIRECTORY
## Prints the number of commits in DIRECTORY that are not in BASE_DIRECTORY.
count_commits() {
  git -C "$1" fetch -q "$2" HEAD
  git -C "$1" rev-list --count FETCH_HEAD..HEAD
}

## Usage: check_linear DIRECTORY BASE_DIRECTORY
## Checks that DIRECTORY's branch is BASE_DIRECTORY's branch followed by
## commits that are not merges, and that both have been pushed.
check_linear() {
  base_head="$(git -C "$2" rev-parse HEAD)"
  git -C "$1" fetch -q "$2" HEAD
  if [ "$(git -C "$1" rev-parse HEAD)" = "${base_head}" ]; then
    return 0
  fi
  if ! git -C "$1" merge-base --is-ancestor "${base_head}" HEAD; then
    fail "$1 does not contain $2"
  fi
  if [ -n "$(git -C "$1" rev-list --merges "${base_head}..HEAD")" ]; then
    fail "$1 has merge commits after $2"
  fi
  if [ "$(git -C "$1" rev-parse HEAD)" != "$(git -C "$1" rev-parse '@{upstream}')" ] \
    || [ "$(git -C "$1" rev-parse HEAD)" != "$(git -C "${REMOTE}" rev-parse "refs/heads/$(git -C "$1" symbolic-ref --short HEAD)")" ]; then
    fail "$1 was not pushed"
  fi
}

REMOTE="${WORK_DIR}/myrepo.git"
git init -q --bare -b main "${REMOTE}"
git init -q -b main "${WORK_DIR}/seed"
printf 'line 1\nline 2\nline 3\n' > "${WORK_DIR}/seed/file.txt"
echo "to be deleted" > "${WORK_DIR}/seed/doomed.txt"
git -C "${WORK_DIR}/seed" add file.txt doomed.txt
git -C "${WORK_DIR}/seed" commit -q -m "Initial commit"
git -C "${WORK_DIR}/seed" remote add origin "${REMOTE}"
git -C "${WORK_DIR}/seed" push -q --set-upstream origin main
for branch in part1 part2; do
  git -C "${WORK_DIR}/seed" push -q origin "main:refs/heads/${branch}"
done

MAIN="${WORK_DIR}/myrepo-branch-main"
PART1="${WORK_DIR}/myrepo-branch-part1"
PART2="${WORK_DIR}/myrepo-branch-part2"
make_clone "${REMOTE}" main "${MAIN}"
make_clone "${REMOTE}" part1 "${PART1}"
make_clone "${REMOTE}" part2 "${PART2}"

## A stack:  part2 builds on part1, which builds on main.  part2 was made
## from part1 by merging.
commit_file "${PART1}" part1.txt "part1 a" "part1 commit a"
commit_file "${PART1}" part1.txt "part1 b" "part1 commit b"
"${COMMANDS_DIR}/git-push-to" "${PART1}" "${PART2}"
commit_file "${PART2}" part2.txt "part2 a" "part2 commit a"
## main moves ahead.
commit_file "${MAIN}" main.txt "main a" "main commit a"

"${COMMANDS_DIR}/git-rebase-to" "${MAIN}" "${PART1}" "${PART2}"

check_linear "${PART1}" "${MAIN}"
check_linear "${PART2}" "${PART1}"
# Each branch's own commits are replayed once, and nothing else is.
part1_subjects="$(subjects "${PART1}" "${MAIN}")"
if [ "${part1_subjects}" != "part1 commit a,part1 commit b" ]; then
  fail "part1 has commits: ${part1_subjects}"
fi
part2_subjects="$(subjects "${PART2}" "${PART1}")"
if [ "${part2_subjects}" != "part2 commit a" ]; then
  fail "part2 has commits: ${part2_subjects}"
fi
if [ "$(cat "${PART2}/main.txt")" != "main a" ] \
  || [ "$(cat "${PART2}/part1.txt")" != "part1 b" ] \
  || [ "$(cat "${PART2}/part2.txt")" != "part2 a" ]; then
  fail "part2 lost content"
fi

## Running again changes nothing, because the branches are already linear.
part1_head="$(git -C "${PART1}" rev-parse HEAD)"
part2_head="$(git -C "${PART2}" rev-parse HEAD)"
"${COMMANDS_DIR}/git-rebase-to" "${MAIN}" "${PART1}" "${PART2}"
if [ "$(git -C "${PART1}" rev-parse HEAD)" != "${part1_head}" ] \
  || [ "$(git -C "${PART2}" rev-parse HEAD)" != "${part2_head}" ]; then
  fail "git-rebase-to rewrote branches that were already linear"
fi

## Conflicts that the user resolved in a merge commit, which the rebase drops:
## both main and part1 change a line, and main deletes a file that part1
## changes.  The rebase replays part1's commits, taking part1's side of every
## conflict, then restores the user's resolution.
sed -e 's/line 2/line 2 from part1/' "${PART1}/file.txt" > "${WORK_DIR}/tmp.txt"
mv "${WORK_DIR}/tmp.txt" "${PART1}/file.txt"
echo "changed by part1" > "${PART1}/doomed.txt"
git -C "${PART1}" commit -q -a -m "part1 commit c"
git -C "${PART1}" push -q
sed -e 's/line 2/line 2 from main/' "${MAIN}/file.txt" > "${WORK_DIR}/tmp.txt"
mv "${WORK_DIR}/tmp.txt" "${MAIN}/file.txt"
git -C "${MAIN}" rm -q doomed.txt
git -C "${MAIN}" commit -q -a -m "main commit b"
git -C "${MAIN}" push -q
if git -C "${PART1}" pull -q --no-rebase origin main > /dev/null 2>&1; then
  fail "expected a merge conflict"
fi
printf 'line 1\nline 2 from both\nline 3\n' > "${PART1}/file.txt"
git -C "${PART1}" add file.txt doomed.txt
git -C "${PART1}" commit -q --no-edit
git -C "${PART1}" push -q
resolved_tree="$(git -C "${PART1}" rev-parse 'HEAD^{tree}')"

"${COMMANDS_DIR}/git-rebase-to" "${MAIN}" "${PART1}" "${PART2}"

check_linear "${PART1}" "${MAIN}"
check_linear "${PART2}" "${PART1}"
if [ "$(git -C "${PART1}" rev-parse 'HEAD^{tree}')" != "${resolved_tree}" ]; then
  fail "the rebase changed the content of part1"
fi
if [ "$(sed -n 2p "${PART2}/file.txt")" != "line 2 from both" ] \
  || [ "$(cat "${PART2}/doomed.txt")" != "changed by part1" ]; then
  fail "the rebase lost the conflict resolution in part2"
fi
if [ "$(git -C "${PART1}" log -1 --format=%s)" != "Restore the content of part1 from before rebasing onto main" ]; then
  fail "expected a commit that restores part1's content, got: $(git -C "${PART1}" log -1 --format=%s)"
fi

## With "--squash", each branch becomes one commit, with the same content.
commit_file "${MAIN}" main.txt "main c" "main commit c"
part2_tree_before="$(git -C "${PART2}" rev-parse 'HEAD^{tree}')"
"${COMMANDS_DIR}/git-rebase-to" --squash "${MAIN}" "${PART1}" "${PART2}"
check_linear "${PART1}" "${MAIN}"
check_linear "${PART2}" "${PART1}"
if [ "$(count_commits "${PART1}" "${MAIN}")" -ne 1 ] \
  || [ "$(count_commits "${PART2}" "${PART1}")" -ne 1 ]; then
  fail "--squash did not make each branch a single commit"
fi
if ! git -C "${PART1}" log -1 --format=%B | grep -q "part1 commit a"; then
  fail "the squashed commit's message omits the branch's commit messages"
fi
if [ "$(cat "${PART2}/main.txt")" != "main c" ] \
  || [ "$(cat "${PART2}/part2.txt")" != "part2 a" ] \
  || [ "$(sed -n 2p "${PART2}/file.txt")" != "line 2 from both" ]; then
  fail "--squash changed the content of part2"
fi
# Apart from main's new change, part2's content is unchanged.
git -C "${PART2}" diff --quiet "${part2_tree_before}" HEAD -- . ':!main.txt' \
  || fail "--squash changed part2's files"

## Squashing again changes nothing.
part1_head="$(git -C "${PART1}" rev-parse HEAD)"
part2_head="$(git -C "${PART2}" rev-parse HEAD)"
"${COMMANDS_DIR}/git-rebase-to" --squash "${MAIN}" "${PART1}" "${PART2}"
if [ "$(git -C "${PART1}" rev-parse HEAD)" != "${part1_head}" ] \
  || [ "$(git -C "${PART2}" rev-parse HEAD)" != "${part2_head}" ]; then
  fail "git-rebase-to --squash rewrote branches that were already squashed"
fi

## Too few arguments.
if "${COMMANDS_DIR}/git-rebase-to" --squash "${MAIN}" 2> "${WORK_DIR}/err.txt"; then
  fail "git-rebase-to accepted a single directory"
fi
grep -q "^git-rebase-to: not enough arguments" "${WORK_DIR}/err.txt" \
  || fail "unexpected diagnostic: $(cat "${WORK_DIR}/err.txt")"

echo "${SCRIPT_NAME}: OK"
