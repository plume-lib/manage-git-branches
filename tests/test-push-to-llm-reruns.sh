#!/bin/sh

# Tests that a rerun of `git-push-to` finishes a merge that an earlier run
# left in progress, that it notes such a merge in AGENT-TODO.md, that it
# aborts or stops at a redundant merge, and that it handles staged, ignored,
# and rerere-resolved changes and conflicts in a pull.
#
# `lib-push-to-llm.sh` describes the stub agents that stand in for `claude`
# and `codex`.
#
# Usage:
#   tests/test-push-to-llm-reruns.sh

TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib-push-to-llm.sh
. "${TESTS_DIR}/lib-push-to-llm.sh"

## A rerun finishes the merge that an earlier run left in progress:  it asks
## the agent to resolve the conflicts, commits the merge with the merge's own
## message, and pushes.
setup_case rerun
push_to none --llm
: > "${STUB_LOG}"
push_to good --llm
check_resolved claude "rerun"
case "${push_output}" in
  *"finishing the merge of branch 'main' that is in progress"*) ;;
  *) fail "rerun: wrong diagnostic: ${push_output}" ;;
esac
setup_case rerun-codex
push_to none --codex
: > "${STUB_LOG}"
push_to good --codex
check_resolved codex "rerun with --codex"

## With --no-llm, a rerun leaves the merge in progress.
setup_case rerun-no-llm
push_to none --llm
: > "${STUB_LOG}"
push_to good --no-llm
check_not_resolved "rerun with --no-llm"
if [ -s "${STUB_LOG}" ]; then
  fail "rerun with --no-llm: an agent ran: $(cat "${STUB_LOG}")"
fi

## A rerun leaves alone a merge whose conflicts were resolved and staged.
setup_case rerun-staged
push_to none --llm
write_file "${feature_dir}/file.txt" ONE two three four five six SEVEN-feature SEVEN-main eight nine
git -C "${feature_dir}" add file.txt
: > "${STUB_LOG}"
push_to good --llm
check_not_resolved "rerun after staging"
case "${push_output}" in
  *"has no conflicted file"*) ;;
  *) fail "rerun after staging: wrong diagnostic: ${push_output}" ;;
esac
if [ -s "${STUB_LOG}" ]; then
  fail "rerun after staging: an agent ran: $(cat "${STUB_LOG}")"
fi

## Usage: check_todo_merge DESCRIPTION
## Checks that ${feature_dir}/AGENT-TODO.md says exactly once that the merge
## in progress in ${feature_dir} is in progress.
check_todo_merge() {
  todo_merge_head="$(git -C "${feature_dir}" rev-parse MERGE_HEAD)"
  todo_count="$(grep -c -x "The merge of commit ${todo_merge_head} is in progress in .*/myrepo-branch-feature\." \
    "${feature_dir}/AGENT-TODO.md" 2> /dev/null)" || true
  if [ "${todo_count}" != 1 ]; then
    fail "$1: AGENT-TODO.md does not note the merge exactly once: $(cat "${feature_dir}/AGENT-TODO.md" 2> /dev/null)"
  fi
}

## A run that leaves a merge in progress without running an agent notes the
## merge in AGENT-TODO.md, and a rerun that stops at the same merge does not
## note it again.  So does a run whose agent was rejected, in the entry that
## gives the command to continue the agent's session.
setup_case todo-no-llm
push_to good --no-llm
check_not_resolved "AGENT-TODO.md without an agent"
if ! grep -q -x '## Finish the merge in progress (git-push-to, .*)' "${feature_dir}/AGENT-TODO.md"; then
  fail "AGENT-TODO.md without an agent: no entry: $(cat "${feature_dir}/AGENT-TODO.md" 2> /dev/null)"
fi
check_todo_merge "AGENT-TODO.md without an agent"
push_to good --no-llm
check_not_resolved "AGENT-TODO.md without an agent, rerun"
check_todo_merge "AGENT-TODO.md without an agent, rerun"
# Once a person finishes the merge, a rerun that pushes deletes the entry,
# and with it the file, which holds nothing else.
git -C "${feature_dir}" diff --name-only --diff-filter=U -z \
  | xargs -0 git -C "${feature_dir}" checkout --ours --
git -C "${feature_dir}" commit -q -a --no-edit
push_to good --no-llm
if [ "${push_status}" -ne 0 ]; then
  fail "AGENT-TODO.md without an agent, merge finished: git-push-to failed: ${push_output}"
fi
if [ -e "${feature_dir}/AGENT-TODO.md" ]; then
  fail "AGENT-TODO.md without an agent, merge finished: the file was not deleted: $(cat "${feature_dir}/AGENT-TODO.md")"
fi

## Usage: push_same_merge
## Makes, in another clone of ${remote}, the merge of main into feature that
## is in progress in ${feature_dir}, resolves its conflicts by keeping both
## sides' changes, and pushes it.
push_same_merge() {
  git clone -q -b feature "${remote}" "${case_dir}/other-clone"
  git -C "${case_dir}/other-clone" pull -q --no-rebase --no-edit origin main > /dev/null 2>&1 || true
  write_file "${case_dir}/other-clone/file.txt" ONE two three four five six SEVEN-feature SEVEN-main eight nine
  git -C "${case_dir}/other-clone" commit -q -a --no-edit
  git -C "${case_dir}/other-clone" push -q
}

## A merge in progress whose sides the upstream branch already contains, as
## when another clone made the same merge and pushed it, is redundant.  If
## nobody has worked on it, a rerun aborts it, the pull fast-forwards the
## branch, and the entry about the merge is removed.
setup_case redundant-merge
push_to good --no-llm
check_not_resolved "redundant merge"
push_same_merge
push_to good --no-llm
if [ "${push_status}" -ne 0 ]; then
  fail "redundant merge: git-push-to failed: ${push_output}"
fi
case "${push_output}" in
  *"aborting the merge of commit "*", which is redundant:  origin/feature, the upstream branch, already contains both of its sides"*) ;;
  *) fail "redundant merge: wrong diagnostic: ${push_output}" ;;
esac
if git -C "${feature_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
  fail "redundant merge: the merge is still in progress"
fi
if [ "$(git -C "${feature_dir}" rev-parse HEAD)" != "$(git -C "${case_dir}/other-clone" rev-parse HEAD)" ]; then
  fail "redundant merge: the branch was not fast-forwarded to the other clone's merge"
fi
if [ -e "${feature_dir}/AGENT-TODO.md" ]; then
  fail "redundant merge: AGENT-TODO.md was not deleted: $(cat "${feature_dir}/AGENT-TODO.md")"
fi

## A redundant merge that somebody has worked on is left in progress, but the
## diagnostic says that it is probably redundant.
setup_case redundant-merge-touched
push_to good --no-llm
check_not_resolved "touched redundant merge"
push_same_merge
write_file "${feature_dir}/file.txt" ONE two three four five six SEVEN-feature eight nine
push_to good --no-llm
# The other clone pushed, so `check_not_resolved` does not apply.
if [ "${push_status}" -eq 0 ]; then
  fail "touched redundant merge: git-push-to succeeded"
fi
if [ "$(git -C "${feature_dir}" rev-parse HEAD)" != "${feature_head}" ]; then
  fail "touched redundant merge: HEAD changed"
fi
case "${push_output}" in
  *"the merge is probably redundant:  origin/feature, the upstream branch, already contains both of its sides"*) ;;
  *) fail "touched redundant merge: wrong diagnostic: ${push_output}" ;;
esac
if ! git -C "${feature_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
  fail "touched redundant merge: the merge was aborted"
fi
if [ "$(cat "${feature_dir}/file.txt")" != "$(printf '%s\n' ONE two three four five six SEVEN-feature eight nine)" ]; then
  fail "touched redundant merge: file.txt was changed: $(cat "${feature_dir}/file.txt")"
fi
# The first run noted the merge in AGENT-TODO.md before it was redundant, so
# this run appended a second entry, which says that it is redundant.
if [ "$(grep -c -x 'It is probably redundant:  origin/feature, the upstream branch, already contains both of its sides.' "${feature_dir}/AGENT-TODO.md")" -ne 1 ]; then
  fail "touched redundant merge: AGENT-TODO.md does not say once that the merge is redundant: $(cat "${feature_dir}/AGENT-TODO.md")"
fi
# The backquotes are Markdown, not command substitutions.
# shellcheck disable=SC2016
if ! grep -F -x -q 'Unless its resolution has changes that origin/feature lacks, abort it with `git merge --abort`, and run `git-push-to` again; then delete this entry.' "${feature_dir}/AGENT-TODO.md"; then
  fail "touched redundant merge: AGENT-TODO.md does not say to abort the merge: $(cat "${feature_dir}/AGENT-TODO.md")"
fi
# Another run appends no third entry.
push_to good --no-llm
if [ "$(grep -c '^## ' "${feature_dir}/AGENT-TODO.md")" -ne 2 ]; then
  fail "touched redundant merge, run again: AGENT-TODO.md does not have exactly 2 entries: $(cat "${feature_dir}/AGENT-TODO.md")"
fi
# Once the person aborts the merge, a run removes both entries, and with them
# the file, which holds nothing else.
git -C "${feature_dir}" merge --abort
push_to good --no-llm
if [ "${push_status}" -ne 0 ]; then
  fail "touched redundant merge, aborted: git-push-to failed: ${push_output}"
fi
if [ -e "${feature_dir}/AGENT-TODO.md" ]; then
  fail "touched redundant merge, aborted: AGENT-TODO.md was not deleted: $(cat "${feature_dir}/AGENT-TODO.md")"
fi

## Usage: check_redundant_stopped DESCRIPTION DIAGNOSTIC
## Checks that git-push-to failed, left the merge in progress in
## ${feature_dir}, printed DIAGNOSTIC, and said that the merge is probably
## redundant, and not that it should be finished.
check_redundant_stopped() {
  if [ "${push_status}" -eq 0 ]; then
    fail "$1: git-push-to succeeded: ${push_output}"
  fi
  if ! git -C "${feature_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
    fail "$1: the merge was aborted or committed"
  fi
  case "${push_output}" in
    *"$2"*) ;;
    *) fail "$1: no diagnostic \"$2\": ${push_output}" ;;
  esac
  case "${push_output}" in
    *"the merge is probably redundant:  origin/feature, the upstream branch, already contains both of its sides"*) ;;
    *) fail "$1: no diagnostic that the merge is redundant: ${push_output}" ;;
  esac
  case "${push_output}" in
    *"; finish "*) fail "$1: a diagnostic says to finish the redundant merge: ${push_output}" ;;
  esac
}

## A redundant merge in which a file that the merge did not leave conflicted
## changed is neither aborted nor finished.
setup_case redundant-merge-other build
push_to good --no-llm
check_not_resolved "redundant merge, other file changed"
push_same_merge
echo changed >> "${feature_dir}/other.txt"
push_to good --no-llm
check_redundant_stopped "redundant merge, other file changed" \
  "Files that it did not leave conflicted changed after it stopped:  other.txt."
if [ "$(tail -n 1 "${feature_dir}/other.txt")" != changed ]; then
  fail "redundant merge, other file changed: other.txt was changed: $(cat "${feature_dir}/other.txt")"
fi

## A redundant merge whose resolution is staged is neither aborted nor
## finished.
setup_case redundant-merge-staged
push_to good --no-llm
check_not_resolved "redundant merge, resolution staged"
push_same_merge
write_file "${feature_dir}/file.txt" ONE two three four five six SEVEN-feature SEVEN-main eight nine
git -C "${feature_dir}" add file.txt
push_to good --no-llm
check_redundant_stopped "redundant merge, resolution staged" "No conflicted file remains."

## A merge whose upstream branch cannot be fetched, so that whether it is
## redundant is unknown, is not finished, although the agent could resolve
## it.  A directory in place of FETCH_HEAD makes the fetch fail.
setup_case redundant-merge-unknown
push_to good --no-llm
check_not_resolved "merge, upstream branch not fetched"
rm -f "${feature_dir}/.git/FETCH_HEAD"
mkdir "${feature_dir}/.git/FETCH_HEAD"
: > "${STUB_LOG}"
push_to good
check_not_resolved "merge, upstream branch not fetched"
if [ -s "${STUB_LOG}" ]; then
  fail "merge, upstream branch not fetched: an agent ran: $(cat "${STUB_LOG}")"
fi
case "${push_output}" in
  *"cannot fetch origin/feature, so whether the merge in progress in "*" is redundant is unknown"*) ;;
  *) fail "merge, upstream branch not fetched: wrong diagnostic: ${push_output}" ;;
esac

## An octopus merge is redundant only if the upstream branch contains every
## commit that it merges.  A second line of MERGE_HEAD, for a commit that the
## upstream branch lacks, makes the merge an octopus merge.
setup_case redundant-merge-octopus
push_to good --no-llm
check_not_resolved "octopus merge"
push_same_merge
git -C "${feature_dir}" commit-tree -p HEAD -m "Not pushed" "HEAD^{tree}" \
  >> "${feature_dir}/.git/MERGE_HEAD"
push_to good --no-llm
# The other clone pushed, so `check_not_resolved` does not apply.
if [ "$(git -C "${feature_dir}" rev-parse HEAD)" != "${feature_head}" ]; then
  fail "octopus merge: HEAD changed"
fi
if ! git -C "${feature_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
  fail "octopus merge: the merge was aborted or committed"
fi
case "${push_output}" in
  *"aborting the merge"* | *"probably redundant"*) fail "octopus merge: the merge was taken for a redundant one: ${push_output}" ;;
esac

## A redundant merge is recognized, and aborted, even if the remote's fetch
## refspec does not cover the upstream branch, so that fetching it updates no
## remote-tracking branch, and origin/feature is stale.
setup_case redundant-merge-refspec
push_to good --no-llm
check_not_resolved "redundant merge, refspec without the branch"
push_same_merge
git -C "${feature_dir}" config remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
push_to good --no-llm
if [ "${push_status}" -ne 0 ]; then
  fail "redundant merge, refspec without the branch: git-push-to failed: ${push_output}"
fi
case "${push_output}" in
  *"aborting the merge of commit "*", which is redundant:  branch 'feature' of origin, the upstream branch, already contains both of its sides"*) ;;
  *) fail "redundant merge, refspec without the branch: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(git -C "${feature_dir}" rev-parse HEAD)" != "$(git -C "${case_dir}/other-clone" rev-parse HEAD)" ]; then
  fail "redundant merge, refspec without the branch: the branch was not fast-forwarded to the other clone's merge"
fi

## A redundant merge is recognized, and aborted, if the upstream branch is a
## local branch, "base", which the fetch of no remote changes.  Base holds a
## merge of both sides that origin lacks.
setup_case redundant-merge-local-upstream
push_to good --no-llm
check_not_resolved "redundant merge, local upstream branch"
git -C "${feature_dir}" branch base "$(git -C "${feature_dir}" commit-tree -p HEAD -p MERGE_HEAD \
  -m "Merge main into base" "HEAD^{tree}")"
git -C "${feature_dir}" config branch.feature.remote .
git -C "${feature_dir}" config branch.feature.merge refs/heads/base
git -C "${feature_dir}" config branch.feature.pushRemote origin
git -C "${feature_dir}" config push.default current
push_to good --no-llm
if [ "${push_status}" -ne 0 ]; then
  fail "redundant merge, local upstream branch: git-push-to failed: ${push_output}"
fi
case "${push_output}" in
  *"aborting the merge of commit "*", which is redundant:  base, the upstream branch, already contains both of its sides"*) ;;
  *) fail "redundant merge, local upstream branch: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(git -C "${feature_dir}" rev-parse HEAD)" != "$(git -C "${feature_dir}" rev-parse base)" ]; then
  fail "redundant merge, local upstream branch: the branch was not fast-forwarded to base"
fi

## Usage: start_redundant_merge_in_main
## Starts, in ${main_dir}, a merge of feature into main, which has conflicts,
## and makes the same merge in another clone of ${remote}, resolves its
## conflicts by keeping both sides' changes, and pushes it to main.
start_redundant_merge_in_main() {
  git -C "${main_dir}" fetch -q
  git -C "${main_dir}" merge -q --no-edit origin/feature > /dev/null 2>&1 || true
  if ! git -C "${main_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
    fail "start_redundant_merge_in_main: no merge is in progress in ${main_dir}"
  fi
  git clone -q -b main "${remote}" "${case_dir}/other-main"
  git -C "${case_dir}/other-main" merge -q --no-edit origin/feature > /dev/null 2>&1 || true
  write_file "${case_dir}/other-main/file.txt" ONE two three four five six SEVEN-feature SEVEN-main eight nine
  git -C "${case_dir}/other-main" commit -q -a --no-edit
  git -C "${case_dir}/other-main" push -q
}

## A redundant merge in progress in the first directory that nobody has
## worked on is aborted, and the pull fast-forwards the branch.
setup_case redundant-merge-first
start_redundant_merge_in_main
push_to good --no-llm
if [ "${push_status}" -ne 0 ]; then
  fail "redundant merge in the first directory: git-push-to failed: ${push_output}"
fi
case "${push_output}" in
  *"aborting the merge of commit "*"myrepo-branch-main, which is redundant:  origin/main, the upstream branch, already contains both of its sides"*) ;;
  *) fail "redundant merge in the first directory: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(git -C "${main_dir}" rev-parse HEAD)" != "$(git -C "${case_dir}/other-main" rev-parse HEAD)" ]; then
  fail "redundant merge in the first directory: main was not fast-forwarded to the other clone's merge"
fi

## A redundant merge in progress in the first directory that somebody has
## worked on makes git-push-to stop, saying that it is probably redundant.
setup_case redundant-merge-first-touched
start_redundant_merge_in_main
write_file "${main_dir}/file.txt" ONE two three four five six SEVEN-main eight nine
push_to good --no-llm
if [ "${push_status}" -eq 0 ]; then
  fail "touched redundant merge in the first directory: git-push-to succeeded"
fi
if ! git -C "${main_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
  fail "touched redundant merge in the first directory: the merge was aborted or committed"
fi
case "${push_output}" in
  *"the merge is probably redundant:  origin/main, the upstream branch, already contains both of its sides"*) ;;
  *) fail "touched redundant merge in the first directory: wrong diagnostic: ${push_output}" ;;
esac
if ! grep -F -x -q 'It is probably redundant:  origin/main, the upstream branch, already contains both of its sides.' "${main_dir}/AGENT-TODO.md"; then
  fail "touched redundant merge in the first directory: AGENT-TODO.md does not say that the merge is redundant: $(cat "${main_dir}/AGENT-TODO.md" 2>&1)"
fi

## Without the pull of the first directory, a redundant merge in progress
## there that nobody has worked on is still aborted.
setup_case redundant-merge-first-no-pull
start_redundant_merge_in_main
push_to good --no-llm --no-pull-first
case "${push_output}" in
  *"aborting the merge of commit "*"myrepo-branch-main, which is redundant:  origin/main, the upstream branch, already contains both of its sides"*) ;;
  *) fail "redundant merge in the first directory, --no-pull-first: wrong diagnostic: ${push_output}" ;;
esac
if git -C "${main_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
  fail "redundant merge in the first directory, --no-pull-first: the merge is still in progress"
fi

## Without the pull of the first directory, a merge in progress there whose
## upstream branch cannot be fetched, so that whether it is redundant is
## unknown, is refused with the usual diagnostic, which says what to do, and
## with the reason of `git-push-to`.  A directory in place of FETCH_HEAD makes
## the fetch fail.
setup_case redundant-merge-first-no-pull-unknown
start_redundant_merge_in_main
rm -f "${main_dir}/.git/FETCH_HEAD"
mkdir "${main_dir}/.git/FETCH_HEAD"
push_to good --no-llm --no-pull-first
if [ "${push_status}" -eq 0 ]; then
  fail "unfetchable merge in the first directory, --no-pull-first: git-push-to succeeded"
fi
if ! git -C "${main_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
  fail "unfetchable merge in the first directory, --no-pull-first: the merge was aborted or committed"
fi
case "${push_output}" in
  *"cannot fetch origin/main, so whether the merge in progress in "*" is redundant is unknown"*"a merge is in progress in "*"; finish it, or abort it with \`git merge --abort\`"*) ;;
  *) fail "unfetchable merge in the first directory, --no-pull-first: wrong diagnostic: ${push_output}" ;;
esac
if ! grep -F -q "It was in progress when \`git-push-to\` was about to merge from it." "${main_dir}/AGENT-TODO.md"; then
  fail "unfetchable merge in the first directory, --no-pull-first: AGENT-TODO.md lacks the reason: $(cat "${main_dir}/AGENT-TODO.md" 2>&1)"
fi

## `git-pull-upstream` aborts a redundant merge in progress that nobody has
## worked on, and its pull fast-forwards the branch.
setup_case pull-upstream-redundant-merge
git -C "${feature_dir}" remote set-head origin main
git -C "${feature_dir}" fetch -q
git -C "${feature_dir}" merge -q --no-edit origin/main > /dev/null 2>&1 || true
if ! git -C "${feature_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
  fail "git-pull-upstream, redundant merge: no merge is in progress"
fi
push_same_merge
if ! pull_upstream_output="$(cd "${feature_dir}" && PATH="${WORK_DIR}/test-bin:${PATH}" \
  "${COMMANDS_DIR}/git-pull-upstream" --no-llm 2>&1)"; then
  fail "git-pull-upstream, redundant merge: failed: ${pull_upstream_output}"
fi
case "${pull_upstream_output}" in
  *"aborting the merge of commit "*", which is redundant:  origin/feature, the upstream branch, already contains both of its sides"*) ;;
  *) fail "git-pull-upstream, redundant merge: wrong diagnostic: ${pull_upstream_output}" ;;
esac
if [ "$(git -C "${feature_dir}" rev-parse HEAD)" != "$(git -C "${case_dir}/other-clone" rev-parse HEAD)" ]; then
  fail "git-pull-upstream, redundant merge: the branch was not fast-forwarded to the other clone's merge"
fi

setup_case todo-agent
push_to none --llm
check_not_resolved "AGENT-TODO.md with an agent"
check_todo_merge "AGENT-TODO.md with an agent"
if ! grep -q '^cd .* && claude --resume ' "${feature_dir}/AGENT-TODO.md"; then
  fail "AGENT-TODO.md with an agent: no command: $(cat "${feature_dir}/AGENT-TODO.md")"
fi
push_to good --no-llm
check_todo_merge "AGENT-TODO.md with an agent, rerun"

## A rerun leaves alone a merge whose conflicted files changed after it
## stopped, as when the agent's work was rejected, even if the files have no
## conflict markers.
setup_case rerun-rejected
push_to create --llm
check_not_resolved "rejected agent"
: > "${STUB_LOG}"
push_to good --llm
check_not_resolved "rerun after a rejected agent"
case "${push_output}" in
  *"changed after the merge stopped: file.txt"*) ;;
  *) fail "rerun after a rejected agent: wrong diagnostic: ${push_output}" ;;
esac
if [ -s "${STUB_LOG}" ]; then
  fail "rerun after a rejected agent: an agent ran: $(cat "${STUB_LOG}")"
fi

## A rerun applies a resolution that `git rerere` recorded after the merge
## stopped, here in another working tree of the same repository, and needs no
## agent.
setup_case rerun-rerere
git -C "${feature_dir}" config rerere.enabled true
push_to none --llm
: > "${STUB_LOG}"
git -C "${feature_dir}" worktree add -q --detach "${case_dir}/other" "${feature_head}"
git -C "${case_dir}/other" merge -q "$(git -C "${feature_dir}" rev-parse MERGE_HEAD)" > /dev/null 2>&1 || true
write_file "${case_dir}/other/file.txt" ONE two three four five six SEVEN-feature SEVEN-main eight nine
git -C "${case_dir}/other" add file.txt
git -C "${case_dir}/other" commit -q --no-edit > /dev/null 2>&1
push_to good --no-llm
check_resolved "" "rerun with a resolution that rerere recorded later"

## The merge's message loses git's list of conflicts whatever the comment
## character.
setup_case rerun-comment-char
git -C "${feature_dir}" config core.commentChar ';'
push_to none --llm
: > "${STUB_LOG}"
push_to good --llm
check_resolved claude "rerun with core.commentChar"

## A rerun leaves the merge in progress if an AI agent is working in the
## directory.  The stand-in agent is a copy of `sleep` named `claude`, whose
## command name is "claude" on every system.  Where such a copy cannot run,
## as where `sleep` is a link to a multi-call binary such as BusyBox, the
## stand-in is instead the script `claude` below, run with no arguments.  The
## script runs its arguments, or with none, runs until it is killed.  On
## Linux, a script's command name is the script's name.  On a system where
## `ps` names the script after its interpreter instead, and the copy of
## `sleep` cannot run, these tests are skipped.
mkdir "${WORK_DIR}/agent-bin"
cat > "${WORK_DIR}/agent-bin/claude" << 'AGENT_EOF'
#!/bin/sh
if [ "$#" -eq 0 ]; then
  while :; do sleep 1; done
fi
# Not the last command, so that the shell does not replace itself with "$@".
"$@"
exit "$?"
AGENT_EOF
chmod +x "${WORK_DIR}/agent-bin/claude"
mkdir "${WORK_DIR}/agent-sleep-bin"
agent_sleep="${WORK_DIR}/agent-sleep-bin/claude"
if ! cp -- "$(command -v sleep)" "${agent_sleep}" 2> /dev/null \
  || ! "${agent_sleep}" 0 > /dev/null 2>&1; then
  agent_sleep=''
fi

## Usage: start_agent DIR
## Starts the stand-in agent in DIR, and sets ${agent_pid} to its process id.
## Returns 1, after stopping the agent, if the stand-in is the script and
## `ps` does not name it "claude" within 10 seconds.  Fails the test if the
## stand-in exits, if `ps` fails while it runs, or if `ps` does not name the
## copy of `sleep` "claude".
start_agent() {
  if [ -n "${agent_sleep}" ]; then
    (cd -- "$1" && exec "${agent_sleep}" 100000) &
  else
    (cd -- "$1" && exec "${WORK_DIR}/agent-bin/claude") &
  fi
  agent_pid=$!
  agent_tries=0
  while :; do
    # Until the subshell runs `exec`, `ps` names it after the shell.
    if ! agent_command="$(ps -o comm= -p "${agent_pid}")"; then
      if kill -0 "${agent_pid}" 2> /dev/null; then
        stop_agent
        fail "ps failed for the stand-in agent, process ${agent_pid}"
      fi
      wait "${agent_pid}" 2> /dev/null || true
      fail "the stand-in agent in $1 exited"
    fi
    if [ "$(basename -- "${agent_command}")" = claude ]; then
      return 0
    fi
    agent_tries=$((agent_tries + 1))
    if [ "${agent_tries}" -gt 10 ]; then
      stop_agent
      if [ -n "${agent_sleep}" ]; then
        fail "ps names the stand-in agent ${agent_command}, not claude"
      fi
      return 1
    fi
    sleep 1
  done
}

## Usage: stop_agent
## Stops the stand-in agent that `start_agent` started.
stop_agent() {
  kill "${agent_pid}" 2> /dev/null || true
  wait "${agent_pid}" 2> /dev/null || true
}

if ! start_agent "${WORK_DIR}"; then
  echo "${SCRIPT_NAME}: skipping the tests of an AI agent working in a directory, because ps does not name a script after itself"
else
  stop_agent

  ## A rerun leaves the merge in progress if the current directory of a
  ## running agent cannot be read, here because a stand-in `readlink` fails
  ## for it.  The stand-in matters only where /proc is read.
  if [ -d /proc/self ]; then
    mkdir "${WORK_DIR}/readlink-bin"
    cat > "${WORK_DIR}/readlink-bin/readlink" << READLINK_EOF
#!/bin/sh
if [ "\$#" -eq 1 ] && [ "\$1" = "/proc/\${UNREADABLE_CWD_PID}/cwd" ]; then
  exit 1
fi
exec '$(command -v readlink)' "\$@"
READLINK_EOF
    chmod +x "${WORK_DIR}/readlink-bin/readlink"
    setup_case rerun-agent-unreadable
    push_to none --llm
    : > "${STUB_LOG}"
    start_agent "${feature_dir}" || fail "the stand-in agent did not start"
    saved_path="${PATH}"
    PATH="${WORK_DIR}/readlink-bin:${PATH}"
    UNREADABLE_CWD_PID="${agent_pid}"
    export UNREADABLE_CWD_PID
    push_to good --llm
    PATH="${saved_path}"
    unset UNREADABLE_CWD_PID
    stop_agent
    check_not_resolved "rerun with an agent whose current directory cannot be read"
    case "${push_output}" in
      *"cannot read the current directory of claude (process ${agent_pid})"*"might be working there"*) ;;
      *) fail "rerun with an agent whose current directory cannot be read: wrong diagnostic: ${push_output}" ;;
    esac
    if [ -s "${STUB_LOG}" ]; then
      fail "rerun with an agent whose current directory cannot be read: an agent ran: $(cat "${STUB_LOG}")"
    fi
  fi

  for agent_subdir in '' /sub; do
    setup_case "rerun-agent${agent_subdir#/}"
    push_to none --llm
    : > "${STUB_LOG}"
    mkdir -p "${feature_dir}${agent_subdir}"
    start_agent "${feature_dir}${agent_subdir}" || fail "the stand-in agent did not start"
    push_to good --llm
    stop_agent
    check_not_resolved "rerun with an agent in ${feature_dir}${agent_subdir}"
    case "${push_output}" in
      *"claude (process ${agent_pid}) is working in"*"an AI agent is working there"*) ;;
      *) fail "rerun with an agent in ${feature_dir}${agent_subdir}: wrong diagnostic: ${push_output}" ;;
    esac
    if [ -s "${STUB_LOG}" ]; then
      fail "rerun with an agent: an agent ran: $(cat "${STUB_LOG}")"
    fi
  done

  ## An inherited $GIT_DIR, as in a git hook, does not hide the agent.  With
  ## $GIT_DIR set, git would take the agent's subdirectory for the top level
  ## of its working tree.
  setup_case rerun-agent-git-dir
  push_to none --llm
  : > "${STUB_LOG}"
  mkdir -p "${feature_dir}/sub"
  start_agent "${feature_dir}/sub" || fail "the stand-in agent did not start"
  GIT_DIR="${main_dir}/.git"
  export GIT_DIR
  push_to good --llm
  unset GIT_DIR
  stop_agent
  check_not_resolved "rerun with an agent and an inherited GIT_DIR"
  case "${push_output}" in
    *"claude (process ${agent_pid}) is working in"*) ;;
    *) fail "rerun with an agent and an inherited GIT_DIR: wrong diagnostic: ${push_output}" ;;
  esac

  ## An agent in another directory, or in a worktree nested in the
  ## directory, does not keep a rerun from finishing the merge.
  for agent_location in main nested; do
    setup_case "rerun-agent-${agent_location}"
    push_to none --llm
    : > "${STUB_LOG}"
    if [ "${agent_location}" = main ]; then
      start_agent "${main_dir}" || fail "the stand-in agent did not start"
    else
      echo 'nested/' >> "${feature_dir}/.git/info/exclude"
      git -C "${feature_dir}" worktree add -q --detach nested HEAD
      start_agent "${feature_dir}/nested" || fail "the stand-in agent did not start"
    fi
    push_to good --llm
    stop_agent
    check_resolved claude "rerun with an agent in ${agent_location}"
  done

  ## An agent that ran `git-push-to` in the directory does not keep it from
  ## finishing the merge.
  setup_case rerun-agent-ancestor
  push_to none --llm
  : > "${STUB_LOG}"
  if push_output="$(cd -- "${feature_dir}" \
    && STUB_MODE=good PATH="${WORK_DIR}/test-bin:${PATH}" \
      "${WORK_DIR}/agent-bin/claude" \
      "${COMMANDS_DIR}/git-push-to" --llm "${main_dir}" "${feature_dir}" 2>&1)"; then
    push_status=0
  else
    push_status=$?
  fi
  check_resolved claude "rerun from an agent in the directory"

  ## A redundant merge in progress in the first directory that nobody has
  ## worked on is not aborted while an agent works there, although
  ## git-push-to does not finish a merge in that directory.
  setup_case redundant-merge-first-agent
  start_redundant_merge_in_main
  start_agent "${main_dir}" || fail "the stand-in agent did not start"
  push_to good --no-llm
  stop_agent
  if [ "${push_status}" -eq 0 ]; then
    fail "redundant merge in the first directory with an agent: git-push-to succeeded"
  fi
  if ! git -C "${main_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
    fail "redundant merge in the first directory with an agent: the merge was aborted or committed"
  fi
  case "${push_output}" in
    *"claude (process ${agent_pid}) is working in"*"an AI agent is working there"*"the merge is probably redundant:  origin/main, the upstream branch, already contains both of its sides"*) ;;
    *) fail "redundant merge in the first directory with an agent: wrong diagnostic: ${push_output}" ;;
  esac
  case "${push_output}" in
    *"aborting the merge"*) fail "redundant merge in the first directory with an agent: the merge was aborted: ${push_output}" ;;
  esac
fi

## An agent that stages a file is rejected, even if the working tree holds an
## acceptable resolution.
setup_case stage
push_to stage --llm
check_not_resolved "agent that stages a file"
case "${push_output}" in
  *"changed the index"*) ;;
  *) fail "agent that stages a file: wrong diagnostic: ${push_output}" ;;
esac

## An agent that creates or changes a file that git ignores is rejected, even
## in a directory that git ignores entirely.  The ignored files do not keep
## an acceptable resolution from being committed.
for ignored_mode in good create-ignored change-ignored; do
  setup_case "ignored-${ignored_mode}"
  echo 'build/' >> "${feature_dir}/.git/info/exclude"
  mkdir "${feature_dir}/build"
  echo "old" > "${feature_dir}/build/old.txt"
  push_to "${ignored_mode}" --llm
  case "${ignored_mode}" in
    good)
      check_resolved claude "ignored files"
      continue
      ;;
  esac
  check_not_resolved "${ignored_mode}"
  case "${ignored_mode}:${push_output}" in
    create-ignored:*"created a file: build/new.class"*) ;;
    change-ignored:*"changed a file: build/old.txt"*) ;;
    *) fail "${ignored_mode}: wrong diagnostic: ${push_output}" ;;
  esac
done

## An agent that changes an untracked file whose name git quotes, or a file
## in an untracked nested repository, is rejected.
setup_case change-quoted
echo "notes" > "${feature_dir}/a\"b\\c"
push_to change-quoted --llm
check_not_resolved "change-quoted"
case "${push_output}" in
  *'changed a file: a"b\c'*) ;;
  *) fail "change-quoted: wrong diagnostic: ${push_output}" ;;
esac
setup_case change-nested
git init -q "${feature_dir}/nested"
echo "nested" > "${feature_dir}/nested/file.txt"
push_to change-nested --llm
check_not_resolved "change-nested"
case "${push_output}" in
  *"changed a file: nested/file.txt"*) ;;
  *) fail "change-nested: wrong diagnostic: ${push_output}" ;;
esac

## An agent that changes a file that git's configuration includes, or the
## repository's attributes, is rejected.
for control_mode in include attributes; do
  setup_case "${control_mode}"
  echo 'local.gitconfig' >> "${feature_dir}/.git/info/exclude"
  : > "${feature_dir}/local.gitconfig"
  git -C "${feature_dir}" config include.path ../local.gitconfig
  push_to "${control_mode}" --llm
  check_not_resolved "${control_mode}"
  case "${push_output}" in
    *"changed git's configuration, attributes, or hooks"*) ;;
    *) fail "${control_mode}: wrong diagnostic: ${push_output}" ;;
  esac
done

## An agent can change a file whose conflict `git rerere` resolved, which is
## named to the agent as such.
setup_case change-rerere
echo "other main" > "${main_dir}/other.txt"
git -C "${main_dir}" add other.txt
git -C "${main_dir}" commit -q -m "Add other.txt on main"
git -C "${main_dir}" push -q
echo "other feature" > "${feature_dir}/other.txt"
git -C "${feature_dir}" add other.txt
git -C "${feature_dir}" commit -q -m "Add other.txt on feature"
git -C "${feature_dir}" push -q
feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
git -C "${feature_dir}" config rerere.enabled true
git -C "${feature_dir}" fetch -q
if git -C "${feature_dir}" merge -q --no-edit origin/main > /dev/null 2>&1; then
  fail "change-rerere: the merge has no conflicts"
fi
printf '%s\n' "other feature" "other main" > "${feature_dir}/other.txt"
git -C "${feature_dir}" rerere 2> /dev/null
git -C "${feature_dir}" merge --abort
push_to change-rerere --llm
check_resolved claude "change-rerere"
if ! grep -q -x '  other.txt' "${STUB_PROMPT}"; then
  fail "change-rerere: the instructions do not name the file that rerere resolved"
fi
if [ "$(git -C "${remote}" show refs/heads/feature:other.txt)" != "$(printf '%s\n' "other feature" "other main" agent)" ]; then
  fail "change-rerere: wrong other.txt: $(git -C "${remote}" show refs/heads/feature:other.txt)"
fi
case "${push_output}" in
  *"claude changed the resolution that \`git rerere\` made of other.txt"*) ;;
  *) fail "change-rerere: the change was not reported: ${push_output}" ;;
esac

## It can replace such a file with one side's version.
setup_case theirs-rerere
echo "other main" > "${main_dir}/other.txt"
git -C "${main_dir}" add other.txt
git -C "${main_dir}" commit -q -m "Add other.txt on main"
git -C "${main_dir}" push -q
echo "other feature" > "${feature_dir}/other.txt"
git -C "${feature_dir}" add other.txt
git -C "${feature_dir}" commit -q -m "Add other.txt on feature"
git -C "${feature_dir}" push -q
feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
git -C "${feature_dir}" config rerere.enabled true
git -C "${feature_dir}" fetch -q
if git -C "${feature_dir}" merge -q --no-edit origin/main > /dev/null 2>&1; then
  fail "theirs-rerere: the merge has no conflicts"
fi
printf '%s\n' "other feature" "other main" > "${feature_dir}/other.txt"
git -C "${feature_dir}" rerere 2> /dev/null
git -C "${feature_dir}" merge --abort
push_to theirs-rerere --llm
check_resolved claude "theirs-rerere"
if [ "$(git -C "${remote}" show refs/heads/feature:other.txt)" != "other main" ]; then
  fail "theirs-rerere: wrong other.txt: $(git -C "${remote}" show refs/heads/feature:other.txt)"
fi
case "${push_output}" in
  *"claude changed the resolution that \`git rerere\` made of other.txt"*) ;;
  *) fail "theirs-rerere: the changed resolution is not reported: ${push_output}" ;;
esac
case "${push_output}" in
  *"claude resolved other.txt as the version in main"*", which keeps none of the changes of feature to the file; review it"*) ;;
  *) fail "theirs-rerere: the one-sided resolution is not reported: ${push_output}" ;;
esac

## A resolution that `git rerere` recorded needs no agent, whether or not
## rerere stages the files that it resolves.  test-push-to-rerere.sh tests
## such a resolution with --no-llm.
for auto_update in false true; do
  setup_case "rerere-${auto_update}"
  git -C "${feature_dir}" config rerere.enabled true
  git -C "${feature_dir}" config rerere.autoUpdate "${auto_update}"
  git -C "${feature_dir}" fetch -q
  if git -C "${feature_dir}" merge -q --no-edit origin/main > /dev/null 2>&1; then
    fail "rerere (autoUpdate ${auto_update}): the merge has no conflicts"
  fi
  (cd "${feature_dir}" && sed -e '/^<<<<<<< /d' -e '/^||||||| /,/^=======$/d' -e '/^=======$/d' \
    -e '/^>>>>>>> /d' file.txt > file.txt.new \
    && mv file.txt.new file.txt && git add file.txt && git commit -q --no-edit) 2> /dev/null
  git -C "${feature_dir}" reset -q --hard "${feature_head}"
  push_to none --llm
  check_resolved "" "rerere (autoUpdate ${auto_update})"
done

## A conflict in pulling TO_DIR from its remote is resolved too.  The merge's
## message names the source that the pull fetched, even if the agent fetches
## something else while it resolves the conflict.
for pull_mode in good fetch; do
  setup_case "pull-${pull_mode}"
  git clone -q -b feature "${remote}" "${case_dir}/other-clone"
  printf '%s\n' one two three-remote four five six SEVEN-feature eight nine > "${case_dir}/other-clone/file.txt"
  git -C "${case_dir}/other-clone" commit -q -a -m "Change feature remotely"
  git -C "${case_dir}/other-clone" push -q
  printf '%s\n' one two three-local four five six SEVEN-feature eight nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Change feature locally"
  push_to "${pull_mode}" --llm
  if [ "${push_status}" -ne 0 ]; then
    fail "conflict in pulling (${pull_mode}): git-push-to failed: ${push_output}"
  fi
  if [ "$(cat "${STUB_LOG}")" != "$(printf '%s\n' claude claude)" ]; then
    fail "conflict in pulling (${pull_mode}): expected claude to run twice, but ran: $(cat "${STUB_LOG}")"
  fi
  expected="$(printf '%s\n' ONE two three-local three-remote four five six SEVEN-feature SEVEN-main eight nine)"
  if [ "$(git -C "${remote}" show refs/heads/feature:file.txt)" != "${expected}" ]; then
    fail "conflict in pulling (${pull_mode}): wrong result: $(git -C "${remote}" show refs/heads/feature:file.txt)"
  fi
  message="$(git -C "${remote}" log -1 --format=%B refs/heads/feature^1)"
  if [ "${message}" != "Merge remote-tracking branch 'origin/feature' into feature" ]; then
    fail "conflict in pulling (${pull_mode}): wrong message for the merge of the pull: ${message}"
  fi
done

## A conflict in pulling that `git rerere` resolves needs no agent, even when
## rerere stages the files that it resolves.
setup_case pull-rerere
git -C "${feature_dir}" config rerere.enabled true
git -C "${feature_dir}" config rerere.autoUpdate true
git clone -q -b feature "${remote}" "${case_dir}/other-clone"
printf '%s\n' one two three-remote four five six SEVEN-feature eight nine > "${case_dir}/other-clone/file.txt"
git -C "${case_dir}/other-clone" commit -q -a -m "Change feature remotely"
git -C "${case_dir}/other-clone" push -q
printf '%s\n' one two three-local four five six SEVEN-feature eight nine > "${feature_dir}/file.txt"
git -C "${feature_dir}" commit -q -a -m "Change feature locally"
local_head="$(git -C "${feature_dir}" rev-parse HEAD)"
if git -C "${feature_dir}" pull -q --no-rebase --no-edit > /dev/null 2>&1; then
  fail "pull-rerere: the pull has no conflicts"
fi
printf '%s\n' one two three-local three-remote four five six SEVEN-feature eight nine > "${feature_dir}/file.txt"
git -C "${feature_dir}" add file.txt
git -C "${feature_dir}" commit -q --no-edit 2> /dev/null
git -C "${feature_dir}" reset -q --hard "${local_head}"
push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "pull-rerere: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "pull-rerere: expected claude to run once, for the merge of main, but ran: $(cat "${STUB_LOG}")"
fi
expected="$(printf '%s\n' ONE two three-local three-remote four five six SEVEN-feature SEVEN-main eight nine)"
if [ "$(git -C "${remote}" show refs/heads/feature:file.txt)" != "${expected}" ]; then
  fail "pull-rerere: wrong result: $(git -C "${remote}" show refs/heads/feature:file.txt)"
fi

echo "${SCRIPT_NAME}: all tests passed"
