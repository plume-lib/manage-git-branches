#!/bin/sh

# Tests that `git-push-to --no-pull-first` merges the commit that the first
# directory already has, without pulling it, and that a run of several chains
# of slugs that start with the same directory pulls it only once.
#
# Usage:
#   tests/test-push-to-no-pull-first.sh
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
# shellcheck source=common-test-functions.sh
. "${TESTS_DIR}/common-test-functions.sh"

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

## Usage: advance_main LINE
## Commits LINE to "main" of ${REMOTE}, without updating any working copy
## directory, as when upstream changes during a run.  Sets ${advanced} to the
## new commit.
advance_main() {
  echo "$1" >> "${WORK_DIR}/seed/file.txt"
  git -C "${WORK_DIR}/seed" commit -q -a -m "Add $1"
  git -C "${WORK_DIR}/seed" push -q origin main
  advanced="$(git -C "${WORK_DIR}/seed" rev-parse HEAD)"
}

## Usage: has_commit DIRECTORY COMMIT
## Returns 0 if the branch of DIRECTORY, both locally and in ${REMOTE},
## contains COMMIT.  Fails the test if the branch was not pushed.
has_commit() {
  has_commit_head="$(git -C "${WORK_DIR}/$1" rev-parse HEAD)"
  if [ "${has_commit_head}" != "$(git -C "${WORK_DIR}/$1" rev-parse '@{upstream}')" ]; then
    fail "$1 was not pushed"
  fi
  git -C "${WORK_DIR}/$1" merge-base --is-ancestor "$2" HEAD
}

## Create a remote with "main" and two branches of it, and a remote for
## another ORG's fork with a branch "part1".  The upstream's main is checked
## out in proj-fork-upstream-branch-main; the branch "part1" of each remote is
## checked out in a fork directory of its ORG; and "part2" is checked out in
## proj-branch-part2.
REMOTE="${WORK_DIR}/proj.git"
git init -q --bare -b main "${REMOTE}"
git init -q -b main "${WORK_DIR}/seed"
echo "first line" > "${WORK_DIR}/seed/file.txt"
git -C "${WORK_DIR}/seed" add file.txt
git -C "${WORK_DIR}/seed" commit -q -m "Initial commit"
git -C "${WORK_DIR}/seed" remote add origin "${REMOTE}"
git -C "${WORK_DIR}/seed" push -q --set-upstream origin main
for branch in part1 part2; do
  git -C "${WORK_DIR}/seed" push -q origin "main:refs/heads/${branch}"
done
YOU_REMOTE="${WORK_DIR}/you.git"
git init -q --bare -b main "${YOU_REMOTE}"
git -C "${WORK_DIR}/seed" push -q "${YOU_REMOTE}" main:refs/heads/part1
MAIN=proj-fork-upstream-branch-main
make_clone "${REMOTE}" main "${MAIN}"
make_clone "${REMOTE}" part1 proj-fork-me-branch-part1
make_clone "${YOU_REMOTE}" part1 proj-fork-you-branch-part1
make_clone "${REMOTE}" part2 proj-branch-part2

## The first pull gets the remote's main; with "--no-pull-first", a later
## commit of the remote's main is not merged.
advance_main "second line"
first="${advanced}"
if ! "${COMMANDS_DIR}/git-push-to" "${WORK_DIR}/${MAIN}" "${WORK_DIR}/proj-fork-me-branch-part1"; then
  fail "git-push-to failed"
fi
if ! has_commit proj-fork-me-branch-part1 "${first}"; then
  fail "git-push-to did not merge the remote's main"
fi
advance_main "third line"
# The first directory, which is not pulled, has AGENT-TODO.md, whose only
# entry is about a merge that is no longer in progress there.  The run
# deletes the file.
# The backquotes are Markdown, not command substitutions.
# shellcheck disable=SC2016
printf '%s\n' '# AI agent sessions to continue' '' \
  'A script of manage-git-branches, such as `git-push-to`, appends an entry' \
  'here when an AI agent fails, when the script rejects its work, or when' \
  "the script leaves a merge in progress.  An entry's command continues the" \
  "agent's session interactively.  Delete the entry once you have dealt with" \
  'it.' '' \
  '## Finish the merge in progress (git-push-to, 2026-11-09 08:23:59)' '' \
  "The merge of commit ${first} is in progress in ${WORK_DIR}/${MAIN}." \
  'Finish it (resolve its conflicts and commit it), or abort it with `git merge --abort`; then delete this entry.' \
  > "${WORK_DIR}/${MAIN}/AGENT-TODO.md"
if ! "${COMMANDS_DIR}/git-push-to" --no-pull-first \
  "${WORK_DIR}/${MAIN}" "${WORK_DIR}/proj-branch-part2"; then
  fail "git-push-to --no-pull-first failed"
fi
if [ -e "${WORK_DIR}/${MAIN}/AGENT-TODO.md" ]; then
  fail "git-push-to --no-pull-first did not delete AGENT-TODO.md in the first directory"
fi
if ! has_commit proj-branch-part2 "${first}"; then
  fail "git-push-to --no-pull-first did not merge the first directory's commit"
fi
if has_commit proj-branch-part2 "${advanced}"; then
  fail "git-push-to --no-pull-first pulled the first directory"
fi
if [ "$(git -C "${WORK_DIR}/${MAIN}" rev-parse HEAD)" != "${first}" ]; then
  fail "git-push-to --no-pull-first changed the first directory"
fi

## With "--no-pull-first", a merge in progress in the first directory still
## stops the chain.
git -C "${WORK_DIR}/${MAIN}" fetch -q
git -C "${WORK_DIR}/${MAIN}" merge -q --no-commit --no-ff "${advanced}" > /dev/null 2>&1 || true
if ! git -C "${WORK_DIR}/${MAIN}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
  fail "the test did not start a merge in ${MAIN}"
fi
if "${COMMANDS_DIR}/git-push-to" --no-pull-first \
  "${WORK_DIR}/${MAIN}" "${WORK_DIR}/proj-branch-part2" 2> "${WORK_DIR}/stderr"; then
  fail "git-push-to --no-pull-first merged from a directory with a merge in progress"
fi
if ! grep -q "a merge is in progress in ${WORK_DIR}/${MAIN}" "${WORK_DIR}/stderr"; then
  fail "wrong diagnostic for a merge in progress: $(cat "${WORK_DIR}/stderr")"
fi
git -C "${WORK_DIR}/${MAIN}" merge --abort
rm -f "${WORK_DIR}/${MAIN}/AGENT-TODO.md"

## Two chains of slugs, one for each ORG, start with the upstream's main,
## which is pulled only once.
make_counting_git "${WORK_DIR}/test-bin" "${WORK_DIR}/git-commands.log"
if ! (cd "${WORK_DIR}" && PATH="${WORK_DIR}/test-bin:${PATH}" \
  "${COMMANDS_DIR}/git-push-to" upstream:main part1); then
  fail "git-push-to failed on slugs"
fi
pulls="$(grep -c -e "-C [[:graph:]]*/${MAIN} .*pull" "${GIT_COMMAND_LOG}" || true)"
if [ "${pulls}" -ne 1 ]; then
  fail "two chains of slugs pulled ${MAIN} ${pulls} times, not once"
fi
for dir in proj-fork-me-branch-part1 proj-fork-you-branch-part1; do
  if ! has_commit "${dir}" "${advanced}"; then
    fail "the chain of slugs did not merge the remote's main into ${dir}"
  fi
done

## A chain that fails before it pulls the first directory exits with status
## 2, and a later chain of slugs pulls that directory again.  A chain that
## does not pull it exits with status 1.  The `git` in failing-pull-bin logs
## its arguments as the counting `git` does, and fails every pull of ${MAIN}.
mkdir -p "${WORK_DIR}/failing-pull-bin"
failing_pull_real="$(real_git "${WORK_DIR}/failing-pull-bin")"
cat > "${WORK_DIR}/failing-pull-bin/git" << FAILING_PULL_END
#!/bin/sh
printf '%s\\n' "\$*" >> "\${GIT_COMMAND_LOG}"
case "\$*" in
  "-C ${WORK_DIR}/${MAIN} "*pull*)
    echo "fatal: simulated failure to pull" >&2
    exit 1
    ;;
esac
exec "${failing_pull_real}" "\$@"
FAILING_PULL_END
chmod +x "${WORK_DIR}/failing-pull-bin/git"
set +e
PATH="${WORK_DIR}/failing-pull-bin:${PATH}" "${COMMANDS_DIR}/git-push-to" \
  "${WORK_DIR}/${MAIN}" "${WORK_DIR}/proj-branch-part2" 2> /dev/null
push_status=$?
"${COMMANDS_DIR}/git-push-to" --no-pull-first \
  "${WORK_DIR}/${MAIN}" "${WORK_DIR}/no-such-directory" 2> /dev/null
no_pull_status=$?
set -e
if [ "${push_status}" -ne 2 ]; then
  fail "git-push-to that could not pull the first directory exited with status ${push_status}, not 2"
fi
if [ "${no_pull_status}" -ne 1 ]; then
  fail "git-push-to --no-pull-first exited with status ${no_pull_status}, not 1"
fi
: > "${GIT_COMMAND_LOG}"
if (cd "${WORK_DIR}" && PATH="${WORK_DIR}/failing-pull-bin:${PATH}" \
  "${COMMANDS_DIR}/git-push-to" upstream:main part1 2> "${WORK_DIR}/stderr"); then
  fail "git-push-to on slugs succeeded without pulling ${MAIN}"
fi
pulls="$(grep -c -e "-C [[:graph:]]*/${MAIN} .*pull" "${GIT_COMMAND_LOG}" || true)"
if [ "${pulls}" -ne 2 ]; then
  fail "two chains of slugs whose pulls of ${MAIN} failed pulled it ${pulls} times, not twice: $(cat "${WORK_DIR}/stderr")"
fi

echo "${SCRIPT_NAME}: OK"
