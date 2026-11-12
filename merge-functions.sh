# shellcheck shell=sh

# Functions that pull and resolve the resulting conflicts; that prepare, or
# refuse to continue, a merge in progress; and that commit staged changes and
# merges.
#
# `common-functions.sh` sources this file.  A script uses these functions by
# sourcing that file, which says what the script must set first.

## Usage: pull_resolving RESOLVER DIRECTORY [--no-rebase]
## Runs `git -C DIRECTORY pull -q [--no-rebase]`, which pulls the branch
## checked out in DIRECTORY from its upstream branch, but names the source of
## a merge that the pull makes without its URL where it can, with the message
## that `pull_merge_message` composes:  for example, "Merge remote-tracking
## branch 'origin/feature' into feature" rather than "Merge branch 'feature'
## of /home/me/repos/proj into feature".  If the pull merges and the merge
## has conflicts, resolves them with `resolve_merge_conflicts`, asking
## RESOLVER, if it is not empty, about any that `git rerere` did not resolve,
## and commits the merge with that message.  (A pull that rebases, as
## `pull.rebase` can make it do unless `--no-rebase` is given, cannot be
## resolved this way.)
## Sets ${pull_fetched} to the head of the upstream branch that the pull
## fetched, which it merged, fast-forwarded to, rebased onto, or found already
## in the branch, as a full hash such as
## "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b".  That commit's history was
## built where it was pushed, even if no remote-tracking branch records it,
## as when `branch.BRANCH.remote` is a URL.  Sets ${pull_fetched} to the empty
## string instead if the branches of the upstream branch's repository need
## not have been built (see `is_built_remote`), or if the pull did not record
## the head in FETCH_HEAD.
## Before it pulls, runs `refuse_merge_in_progress`, which aborts a merge
## already in progress in DIRECTORY if it is redundant and nobody has worked
## on it, and which refuses any other.
## Returns 1, after printing a diagnostic, if `refuse_merge_in_progress`
## refuses, as when another merge is already in progress in DIRECTORY, if
## the pull fails without a merge in progress, as when the
## fetch fails or a rebase has conflicts, if the merge's message cannot be
## composed, or if the merge's conflicts are not resolved or the merge cannot
## be committed.  A merge without conflicts whose commit a pre-merge-commit
## hook rejected is committed as `commit_rejected_merge` describes.
pull_resolving() {
  pull_resolver="$1"
  pull_dir="$2"
  shift 2
  pull_fetched=''
  # Otherwise, `git pull` would refuse to run, and the merge in progress would
  # seem to be the pull's.
  if ! refuse_merge_in_progress "${pull_dir}" "It was in progress when \`${SCRIPT_NAME}\` tried to pull."; then
    return 1
  fi
  # `git pull` decides, as usual, whether to rebase, to fast-forward, or to
  # merge.  `--edit` makes it run the editor on the message of a merge
  # commit that it makes, and `GIT_EDITOR` names a command that replaces
  # that message with the one that `pull_merge_message` composes from
  # FETCH_HEAD.  The command runs in another shell, so it sources this file
  # and reads ${SCRIPT_DIR} and ${SCRIPT_NAME} from its environment.  A pull
  # that fast-forwards, rebases, or stops at conflicts runs no editor.
  # `rerere.autoUpdate` false and the configured conflict style are as for
  # the merge in `merge_build_push`.
  # The state of the working tree before the pull, for
  # `commit_rejected_merge`.
  commit_staged_clean=0
  if pull_top="$(git -C "${pull_dir}" rev-parse --show-toplevel)"; then
    commit_staged_before "${pull_top}"
  fi
  # shellcheck disable=SC2016 # the editor's shell expands the variables
  if SCRIPT_DIR="${SCRIPT_DIR}" SCRIPT_NAME="${SCRIPT_NAME}" \
    GIT_EDITOR='sh -c ". \"\${SCRIPT_DIR}/common-functions.sh\" && pull_merge_message > \"\$1\"" pull-merge-message' \
    git -C "${pull_dir}" -c rerere.autoUpdate=false pull -q --edit "$@"; then
    pull_merging=0
  else
    echo "${SCRIPT_NAME}: problem pulling in ${pull_dir}" >&2
    if ! git -C "${pull_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
      return 1
    fi
    pull_merging=1
    # A pull that stops at conflicts runs no editor, and neither does one
    # whose pre-merge-commit hook rejects the commit of a merge without
    # conflicts, so the message is composed here.  (A merge without conflicts
    # is also in progress if the editor failed; `commit_rejected_merge` then
    # finds no change by a hook, and does not commit.)  The message is
    # composed at the top level of the working tree, where git runs the
    # editor and against which git resolves a remote's relative URL.
    if ! pull_top="$(git -C "${pull_dir}" rev-parse --show-toplevel)" \
      || ! pull_message="$(cd -- "${pull_top}" && pull_merge_message)"; then
      echo "${SCRIPT_NAME}: cannot compose a message for the merge that the pull made in ${pull_dir}; the merge is in progress; finish it with \`git commit\`, or abort it with \`git merge --abort\`" >&2
      report_merge_in_progress_in "${pull_dir}" "\`${SCRIPT_NAME}\` could not compose its message."
      return 1
    fi
  fi
  # FETCH_HEAD is read now, before `resolve_merge_conflicts` runs an agent,
  # which might fetch and so overwrite it.  FETCH_HEAD names first the commit
  # that the pull merges, fast-forwards to, or rebases onto.
  if pull_branch="$(current_branch "${pull_dir}")" \
    && pull_remote="$(git -C "${pull_dir}" config --get "branch.${pull_branch}.remote")" \
    && is_built_remote "${pull_dir}" "${pull_remote}"; then
    # shellcheck disable=SC2034 # used by the commands that source this file
    pull_fetched="$(git -C "${pull_dir}" rev-parse --verify --quiet 'FETCH_HEAD^{commit}')" || true
  fi
  if [ "${pull_merging}" -eq 0 ]; then
    return 0
  fi
  # Git names the conflicted files relative to the top level of the working
  # tree, so `commit_resolved_merge` runs there, in a subshell that leaves
  # the current directory unchanged.
  (
    if ! pull_top="$(git -C "${pull_dir}" rev-parse --show-toplevel)" \
      || ! cd "${pull_top}"; then
      echo "${SCRIPT_NAME}: cannot cd to the top level of ${pull_dir}" >&2
      exit 1
    fi
    commit_resolved_merge "${pull_resolver}" MERGE_HEAD "$(upstream_description)" "${pull_message}"
  )
}

## Usage: agent_processes_in DIRECTORY
## Prints, one per line, the process id and command name, such as
## "4242 claude", of each process of the current user that runs an AI agent
## and whose current directory is in the working tree whose top level is
## DIRECTORY, an absolute pathname with symbolic links resolved.  A process
## runs an AI agent if its command name is "claude" or "codex", as for Claude
## Code and Codex installed as native executables.  A process whose current
## directory is in another working tree nested in DIRECTORY, such as one in
## DIRECTORY/.claude/worktrees/NAME, is not printed.  Neither is a process
## that is the running script or an ancestor of it, such as a Claude Code
## session that ran the script.  Returns 1, after printing a diagnostic, if
## the system has neither /proc nor `lsof`, so that the current directories
## of processes cannot be read.  Returns 2, after printing a diagnostic for
## each, if the current directory of some such process that is still running
## cannot be read, so that whether it works in DIRECTORY is unknown; it still
## prints the processes that it found in DIRECTORY.
## It runs git in the current directories of those processes, so the script
## must first run `unset_git_location_variables`.
agent_processes_in() {
  if [ -d /proc/self ]; then
    agent_processes_via=proc
  elif command -v lsof > /dev/null 2>&1; then
    agent_processes_via=lsof
  else
    echo "${SCRIPT_NAME}: cannot tell whether an AI agent is working in $1, because this system has neither /proc nor lsof" >&2
    return 1
  fi
  # The process ids of this shell and its ancestors, each followed by a blank.
  agent_processes_ancestors=' '
  agent_processes_pid=$$
  while [ -n "${agent_processes_pid}" ] && [ "${agent_processes_pid}" -gt 1 ]; do
    agent_processes_ancestors="${agent_processes_ancestors}${agent_processes_pid} "
    agent_processes_pid="$(ps -o ppid= -p "${agent_processes_pid}" 2> /dev/null | tr -d ' ')"
  done
  # On macOS, `ps` prints a command name as the executable's full pathname,
  # which can contain blanks.
  # The loop runs in an explicit subshell, so that its exit status is the
  # pipeline's even in a shell that runs a pipeline's last command in the
  # current shell.
  ps -U "$(id -u)" -o pid= -o comm= | (
    agent_processes_status=0
    while read -r agent_processes_pid agent_processes_command; do
      case "${agent_processes_command##*/}" in
        claude | codex) ;;
        *) continue ;;
      esac
      case "${agent_processes_ancestors}" in
        *" ${agent_processes_pid} "*) continue ;;
      esac
      if [ "${agent_processes_via}" = proc ]; then
        agent_processes_cwd="$(readlink "/proc/${agent_processes_pid}/cwd" 2> /dev/null)"
      else
        agent_processes_cwd="$(lsof -a -p "${agent_processes_pid}" -d cwd -Fn 2> /dev/null | sed -n -e 's/^n//p')"
      fi
      if [ -z "${agent_processes_cwd}" ]; then
        # A process that has exited since `ps` listed it, or a zombie, has no
        # current directory and works nowhere.  For any other process, the
        # lookup failed, and the process might be working in the directory.
        case "$(ps -o stat= -p "${agent_processes_pid}" 2> /dev/null | tr -d ' ')" in
          '' | Z*) continue ;;
        esac
        echo "${SCRIPT_NAME}: cannot read the current directory of ${agent_processes_command##*/} (process ${agent_processes_pid})" >&2
        agent_processes_status=2
        continue
      fi
      case "${agent_processes_cwd}" in
        "$1" | "$1"/*) ;;
        *) continue ;;
      esac
      # The test above is cheap; this one excludes a nested working tree.
      if agent_processes_top="$(git -C "${agent_processes_cwd}" rev-parse --show-toplevel 2> /dev/null)" \
        && [ "$(physical_path "${agent_processes_top}" 2> /dev/null)" = "$1" ]; then
        printf '%s %s\n' "${agent_processes_pid}" "${agent_processes_command##*/}"
      fi
    done
    exit "${agent_processes_status}"
  )
}

## Usage: merge_sides_in COMMIT MERGE-HEADS
## Returns 0 if COMMIT, a commit or a ref such as "refs/heads/feature",
## contains both sides of the merge in progress in the current directory:
## HEAD, and each of MERGE-HEADS, the full hashes, one per line, that
## MERGE_HEAD holds.  Returns 1 otherwise, as when COMMIT does not exist.
merge_sides_in() {
  # Each line of MERGE-HEADS is a full hash, which field splitting does not
  # change.
  # shellcheck disable=SC2086
  for sides_commit in HEAD $2; do
    if ! git merge-base --is-ancestor "${sides_commit}" "$1" 2> /dev/null; then
      return 1
    fi
  done
  return 0
}

## Usage: redundant_merge_upstream
## Prints the name of the upstream branch of the branch checked out in the
## current directory, the top level of a working tree, such as
## "origin/feature", if that upstream branch contains both sides of the merge
## in progress:  HEAD, and each commit in MERGE_HEAD, which holds several for
## an octopus merge.  That happens when another clone made the same merge and
## pushed it.  The test first uses the upstream branch itself, if it is a
## local branch, or else its remote-tracking branch, if it has one, which
## records its head as of the last fetch.  If that does not contain both
## sides, and the upstream branch is not a local branch, this function then
## fetches the upstream branch, and only it, and tests the head that the
## fetch recorded in FETCH_HEAD.  So the result does not depend on a
## remote-tracking branch, which the fetch does not update if the remote's
## fetch refspec does not cover the upstream branch; then the name is like
## "branch 'feature' of origin".  The fetch can prompt, as for a
## passphrase, as a pull can.  Returns 1, printing nothing, if the upstream
## branch does not contain both sides of the merge, or if the branch has no
## upstream branch.  Returns 2, after printing a diagnostic, if the fetch
## fails, so that whether the merge is redundant is unknown.
redundant_merge_upstream() {
  if ! redundant_branch="$(current_branch)" \
    || ! redundant_remote="$(git config --get "branch.${redundant_branch}.remote")" \
    || ! redundant_merge="$(git config --get "branch.${redundant_branch}.merge")" \
    || ! redundant_merge_heads="$(cat -- "$(git rev-parse --git-path MERGE_HEAD)")"; then
    return 1
  fi
  if ! redundant_name="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2> /dev/null)" \
    || [ -z "${redundant_name}" ]; then
    redundant_name="branch '${redundant_merge#refs/heads/}' of ${redundant_remote}"
  fi
  if merge_sides_in '@{upstream}' "${redundant_merge_heads}"; then
    printf '%s\n' "${redundant_name}"
    return 0
  fi
  if [ "${redundant_remote}" = . ]; then
    return 1
  fi
  if ! git fetch --quiet "${redundant_remote}" "${redundant_merge}" \
    || ! redundant_head="$(git rev-parse --verify --quiet 'FETCH_HEAD^{commit}')"; then
    echo "${SCRIPT_NAME}: cannot fetch ${redundant_name}, so whether the merge in progress in $(pwd) is redundant is unknown" >&2
    return 2
  fi
  if ! merge_sides_in "${redundant_head}" "${redundant_merge_heads}"; then
    return 1
  fi
  printf '%s\n' "${redundant_name}"
}

## Usage: merge_work
## Prints a sentence that says how somebody has worked on the merge in
## progress in the current directory, the top level of a working tree, since
## git, `git rerere`, and this package's scripts left it, such as "No
## conflicted file remains." or "Its conflicted files changed after the merge
## stopped:  file.txt."  Somebody has worked on it if no conflicted file
## remains (see `conflicted_files`), as when the conflicts were resolved and
## staged; if a conflicted file changed after then (see
## `changed_conflicted_files`); or if another file differs from AUTO_MERGE,
## git's automatic merge, in the working tree or in the index (see
## `resolve_other_changes`).  Without AUTO_MERGE, whether somebody has worked
## on it is unknown, which the sentence says, as it is if the conflicted
## files cannot be listed.  Prints nothing if nobody has
## worked on it; then `git merge --abort` discards nothing but git's
## automatic merge and the resolutions that `git rerere` applied, which it
## can apply again.
merge_work() {
  if ! work_files="$(conflicted_files)"; then
    echo "Its conflicted files could not be listed."
    return 0
  fi
  if [ -z "${work_files}" ]; then
    echo "No conflicted file remains."
    return 0
  fi
  if ! git rev-parse --verify --quiet AUTO_MERGE > /dev/null; then
    echo "Git recorded no AUTO_MERGE for it, so whether anybody has worked on it is unknown."
    return 0
  fi
  if ! work_changed="$(changed_conflicted_files)"; then
    echo "Its conflicted files could not be listed."
    return 0
  fi
  if [ -n "${work_changed}" ]; then
    echo "Its conflicted files changed after the merge stopped:  $(printf '%s\n' "${work_changed}" | paste -s -d ' ' -)."
    return 0
  fi
  work_other="$(resolve_other_changes "${work_files}")"
  if [ -n "${work_other}" ]; then
    echo "Files that it did not leave conflicted changed after it stopped:  $(printf '%s\n' "${work_other}" | paste -s -d ' ' -)."
  fi
}

## Usage: stop_for_agents DIRECTORY UPSTREAM REASON
## Returns 1, after printing a diagnostic, if an AI agent is working in
## DIRECTORY, the top level of a working tree and the current directory (see
## `agent_processes_in`), as when the user is resolving the conflicts of the
## merge in progress there in a session that a script of this package
## printed a command to resume, or if the current directory of a running AI
## agent cannot be read, so that it might be working in DIRECTORY; it then
## leaves the merge in progress, and notes it in AGENT-TODO.md with REASON,
## which is empty or ends with a sentence, and with UPSTREAM (see
## `stop_at_merge`).  Returns 0 otherwise.  If `agent_processes_in` cannot
## tell at all whether an AI agent is working in DIRECTORY, because the
## system has neither /proc nor `lsof`, this function returns 0, after
## printing a diagnostic that says that it proceeds as if none is.
stop_for_agents() {
  # `agent_processes_in` has said why it cannot tell.
  agents_found="$(agent_processes_in "$1")"
  agents_status=$?
  case "${agents_status}" in
    0 | 2) ;;
    *)
      echo "${SCRIPT_NAME}: proceeding as if no AI agent is working in $1" >&2
      return 0
      ;;
  esac
  # What to do, unless `stop_at_merge` says to abort a redundant merge.
  agents_todo=''
  if [ -z "$2" ]; then
    agents_todo="; finish the merge, or abort it with \`git merge --abort\`"
  fi
  if [ -n "${agents_found}" ]; then
    printf '%s\n' "${agents_found}" | while read -r agents_pid agents_command; do
      echo "${SCRIPT_NAME}: ${agents_command} (process ${agents_pid}) is working in $1" >&2
    done
    stop_at_merge "${SCRIPT_NAME}: a merge is in progress in $1, and an AI agent is working there${agents_todo}" \
      "${3:+$3  }An AI agent was working in the directory:  $(printf '%s\n' "${agents_found}" \
        | sed -e 's/^\([0-9]*\) \(.*\)/\2 (process \1)/' | paste -s -d ' ' -)." "$2"
    return 1
  fi
  if [ "${agents_status}" -eq 2 ]; then
    stop_at_merge "${SCRIPT_NAME}: a merge is in progress in $1, and an AI agent whose current directory cannot be read might be working there${agents_todo}" \
      "${3:+$3  }The current directory of an AI agent's process could not be read, so the agent might have been working in the directory." "$2"
    return 1
  fi
  return 0
}

## Usage: settle_merge_in_progress DIRECTORY FINISH [REASON]
## Prepares the merge in progress, if any, in DIRECTORY, the top level of a
## working tree and the current directory, for the caller to finish it, if
## FINISH is 1, or to refuse it and not pull DIRECTORY, if FINISH is 0.  If
## the merge is redundant, because the branch's upstream branch already
## contains both of its sides (see `redundant_merge_upstream`), as when
## another clone of the repository made the same merge and pushed it, and
## nobody has worked on it (see `merge_work`), aborts it, and removes the
## entries of AGENT-TODO.md about it (see `prune_agent_todo`).  Aborting it
## loses nothing, and a pull of DIRECTORY then fast-forwards the branch.
##
## Returns 0 if no merge is in progress in DIRECTORY when this function
## returns, and 2 if a merge remains in progress for the caller to finish or
## to refuse:  one that is not redundant, or, if FINISH is 0, one whose
## upstream branch cannot be fetched, so that whether it is redundant is
## unknown.  Returns 1, after printing a diagnostic, and leaves the merge in
## progress, which it notes in AGENT-TODO.md with REASON, such as "It was in
## progress when `git-push-to` tried to pull.", followed by a sentence that
## says why (see `stop_at_merge`), in these cases:
##  * An AI agent is working in DIRECTORY, or might be (see
##    `stop_for_agents`).  If FINISH is 0, this matters only for a merge
##    that would be aborted.
##  * FINISH is 1, and the upstream branch cannot be fetched, so that whether
##    the merge is redundant is unknown.  Finishing a redundant merge would
##    duplicate the merge that the upstream branch already contains.
##  * The merge is redundant, but somebody has worked on it, which the
##    diagnostic says, or it cannot be aborted.
settle_merge_in_progress() {
  if ! git rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
    return 0
  fi
  settle_in_progress="${SCRIPT_NAME}: a merge is in progress in $1"
  settle_reason="${3:+$3  }"
  # A caller that finishes the merge must not do so while an agent works on
  # it, whether or not it is redundant.
  if [ "$2" -eq 1 ] && ! stop_for_agents "$1" '' "${3:-}"; then
    return 1
  fi
  settle_upstream="$(redundant_merge_upstream)"
  case "$?" in
    0) ;;
    2)
      if [ "$2" -eq 0 ]; then
        return 2
      fi
      stop_at_merge "${settle_in_progress}, and whether it is redundant is unknown; run \`${SCRIPT_NAME}\` again once its upstream branch can be fetched" \
        "${settle_reason}Whether it is redundant is unknown, because its upstream branch could not be fetched."
      return 1
      ;;
    *) return 2 ;;
  esac
  settle_work="$(merge_work)"
  if [ -n "${settle_work}" ]; then
    stop_at_merge "${settle_in_progress}.  ${settle_work}" "${settle_reason}${settle_work}" "${settle_upstream}"
    return 1
  fi
  if [ "$2" -eq 0 ] && ! stop_for_agents "$1" "${settle_upstream}" "${3:-}"; then
    return 1
  fi
  echo "${SCRIPT_NAME}: aborting the merge of commit $(git rev-parse --verify --quiet MERGE_HEAD) in $1, which is redundant:  ${settle_upstream}, the upstream branch, already contains both of its sides" >&2
  if ! git merge --abort; then
    stop_at_merge "${settle_in_progress}, and cannot be aborted" \
      "${settle_reason}\`${SCRIPT_NAME}\` could not abort it." "${settle_upstream}"
    return 1
  fi
  forget_conflicted_files
  prune_agent_todo 0
  return 0
}

## Usage: refuse_merge_in_progress DIRECTORY REASON
## Runs `settle_merge_in_progress` at the top level of the working tree that
## contains DIRECTORY, so that a merge in progress there that is redundant
## and that nobody has worked on is aborted:  the function might fetch the
## branch's upstream branch, and might abort the merge.  Then returns 1,
## after printing a diagnostic, if a merge remains in progress in DIRECTORY,
## or if the index of DIRECTORY has unmerged files, as after a cherry-pick, a
## revert, or a `git stash apply` that stopped at conflicts.  `git pull`
## refuses to run in either case.  Returns 0 otherwise.  A merge that remains
## in progress is noted in AGENT-TODO.md with REASON, such as "It was in
## progress when `git-push-to` tried to pull.":  by
## `settle_merge_in_progress`, followed by a sentence that says why, if it
## stopped at the merge, as when an AI agent is working there or when the
## merge is redundant but somebody has worked on it; and otherwise by
## `report_merge_in_progress_in`, as when the merge is not redundant or the
## upstream branch cannot be fetched, keeping an entry of AGENT-TODO.md that
## says that running the script again suffices (see `agent_rerun_advice`).
refuse_merge_in_progress() {
  if git -C "$1" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
    # A subshell leaves the current directory unchanged.
    (
      if ! refuse_top="$(git -C "$1" rev-parse --show-toplevel)" \
        || ! refuse_top="$(physical_path "${refuse_top}")" \
        || ! cd -- "${refuse_top}"; then
        echo "${SCRIPT_NAME}: cannot cd to the top level of $1" >&2
        exit 2
      fi
      settle_merge_in_progress "${refuse_top}" 0 "$2"
    )
    case "$?" in
      0) ;;
      1) return 1 ;;
      *)
        echo "${SCRIPT_NAME}: a merge is in progress in $1; finish it, or abort it with \`git merge --abort\`" >&2
        # An entry that says to abort the merge and then to run the script
        # again still holds.
        report_merge_in_progress_in "$1" "$2" keep
        return 1
        ;;
    esac
  fi
  if [ -n "$(git -C "$1" ls-files --unmerged)" ]; then
    echo "${SCRIPT_NAME}: $1 has unmerged files; resolve them, or abort the operation that left them, such as a cherry-pick" >&2
    return 1
  fi
  return 0
}

## Usage: upstream_fetch_head DIRECTORY
## Prints the head of the upstream branch of the branch checked out in
## DIRECTORY, as a full hash such as
## "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b", that the latest fetch of that
## upstream branch recorded in FETCH_HEAD, as a pull does, if the upstream
## branch's repository is one whose branches were built where they were
## pushed (see `is_built_remote`).  That commit's history was built there,
## even if no remote-tracking branch records it, as when
## `branch.BRANCH.remote` is a URL.  Returns 1, printing nothing, if the
## first line of FETCH_HEAD is not for that upstream branch, as when the
## latest fetch fetched another repository or branch, or if the branches of
## the upstream branch's repository need not have been built.
upstream_fetch_head() {
  if ! fetch_head_branch="$(current_branch "$1")" \
    || ! fetch_head_remote="$(git -C "$1" config --get "branch.${fetch_head_branch}.remote")" \
    || ! fetch_head_merge="$(git -C "$1" config --get "branch.${fetch_head_branch}.merge")" \
    || ! is_built_remote "$1" "${fetch_head_remote}" \
    || ! fetch_head_url="$(git -C "$1" ls-remote --get-url "${fetch_head_remote}" 2> /dev/null)" \
    || ! fetch_head_file="$(git -C "$1" rev-parse --path-format=absolute --git-path FETCH_HEAD)" \
    || [ ! -f "${fetch_head_file}" ]; then
    return 1
  fi
  # The first line of FETCH_HEAD is "HASH<TAB><TAB>branch 'BRANCH' of
  # LOCATION" for the branch that a pull merges; see `pull_merge_message`.
  IFS= read -r fetch_head_line < "${fetch_head_file}" || return 1
  fetch_head_hash="${fetch_head_line%%"	"*}"
  fetch_head_source="${fetch_head_line#*"		"}"
  if [ "${fetch_head_source}" = "${fetch_head_line}" ]; then
    return 1
  fi
  case "${fetch_head_source}" in
    "branch '${fetch_head_merge#refs/heads/}' of "*) ;;
    *) return 1 ;;
  esac
  if ! is_fetch_head_location "$1" "${fetch_head_source#"branch '${fetch_head_merge#refs/heads/}' of "}" "${fetch_head_url}" \
    || ! git -C "$1" rev-parse --verify --quiet "${fetch_head_hash}^{commit}"; then
    return 1
  fi
}

## Usage: is_fetch_head_location DIRECTORY LOCATION URL
## Returns 0 if LOCATION, the location of a repository as `git fetch` writes
## it in FETCH_HEAD, such as "github.com:org/proj" or "/srv/proj", names the
## repository that URL names in DIRECTORY, where URL is a URL as
## `git ls-remote --get-url` prints it, such as "git@github.com:org/proj.git";
## returns 1 otherwise.  `git fetch` writes the URL without trailing slashes
## and then without a trailing ".git".  LOCATION is compared with URL
## stripped that way, as well as by key (see `url_key`), because a pathname
## that git wrote, such as "/srv/proj" for "/srv/proj.git", might name no
## directory and so have no key.
is_fetch_head_location() {
  fetch_location_stripped="${3%"${3##*[!/]}"}"
  fetch_location_stripped="${fetch_location_stripped%.git}"
  if [ "${fetch_location_stripped}" = "$2" ]; then
    return 0
  fi
  fetch_location_key="$(url_key "$1" "$2")"
  [ -n "${fetch_location_key}" ] && [ "$(url_key "$1" "$3")" = "${fetch_location_key}" ]
}

## Usage: is_pulled_first_dir DIRECTORY
## Returns 0 if DIRECTORY, the first directory of a chain of `git-push-to`,
## is one of ${pulled_first_dirs}, the first directories, each followed by a
## newline, that earlier chains of the same run pulled; returns 1 otherwise.
## A later chain that starts with DIRECTORY does not pull it again, so that
## every chain merges the same commit of it; see `git-push-to`, under
## "Several chains".
is_pulled_first_dir() {
  case "
${pulled_first_dirs:-}" in
    *"
$1
"*) return 0 ;;
  esac
  return 1
}

## Usage: add_pulled_first_dir DIRECTORY
## Adds DIRECTORY to ${pulled_first_dirs} (see `is_pulled_first_dir`), unless
## it is already there.
add_pulled_first_dir() {
  if ! is_pulled_first_dir "$1"; then
    pulled_first_dirs="${pulled_first_dirs:-}$1
"
  fi
}

## Usage: report_merge_in_progress_in DIRECTORY [REASON [ADVICE]]
## Runs `report_merge_in_progress` with REASON, no upstream branch, and
## ADVICE at the top level of the working tree that contains DIRECTORY, in a
## subshell that leaves the current directory unchanged.
report_merge_in_progress_in() {
  (
    if report_in_top="$(git -C "$1" rev-parse --show-toplevel)" && cd -- "${report_in_top}"; then
      report_merge_in_progress "${2:-}" '' "${3:-}"
    fi
  )
}

## Usage: commit_staged_before DIRECTORY
## Records the state of the working tree whose top level is DIRECTORY, before
## a commit or a merge, for `commit_staged_again`:  sets
## ${commit_staged_clean} to 1 if the working tree matches the index and its
## untracked files can be listed, and to 0 otherwise, and sets
## ${commit_staged_untracked} to those files, as `untracked_files` prints
## them.
commit_staged_before() {
  commit_staged_clean=0
  if git -C "$1" diff --quiet \
    && commit_staged_untracked="$(cd -- "$1" && untracked_files)"; then
    commit_staged_clean=1
  fi
}

## Usage: untracked_files_changed
## Returns 0 if the files of the working tree in the current directory that
## git does not track and does not ignore differ from those in
## ${commit_staged_untracked} (see `commit_staged_before`), or if they cannot
## be listed, and 1 otherwise.
untracked_files_changed() {
  ! untracked_files_changed_list="$(untracked_files)" \
    || [ "${untracked_files_changed_list}" != "${commit_staged_untracked}" ]
}

## Usage: commit_staged MESSAGE [COMMAND...]
## Commits the changes that are staged in the current directory, the top
## level of a working tree, with the message MESSAGE; the commit is a merge
## commit if a merge is in progress.  `--cleanup=whitespace` keeps every line
## of MESSAGE, whatever comment character the configuration names.  If a
## pre-commit hook rejects the commit, commits again if
## `commit_staged_again`, given COMMAND, can.
##
## Returns 0 if a commit succeeded, and a nonzero status otherwise.
commit_staged() {
  commit_staged_message="$1"
  shift
  commit_staged_before .
  # `git write-tree` fails if the index has unmerged entries, as git's
  # commit does.
  commit_staged_tree="$(git write-tree 2> /dev/null)" || commit_staged_tree=''
  if printf '%s\n' "${commit_staged_message}" | git commit -q --cleanup=whitespace -F -; then
    return 0
  fi
  commit_staged_again pre-commit "${commit_staged_message}" "${commit_staged_tree}" "$@"
}

## Usage: review_hook_changes HOOK FILES RESULT
## Prints a notice for each of the FILES, which are pathnames, one per line,
## that the hook HOOK, such as "pre-commit", changed although the commit that
## the hook checked does not otherwise change them, and appends the notice to
## the summary (see `review_notice`).  The notice asks for a review of the
## hook's changes, which RESULT, such as "are staged, but not committed".
review_hook_changes() {
  printf '%s\n' "$2" | while IFS= read -r review_hook_file; do
    if [ -n "${review_hook_file}" ]; then
      review_notice "the $1 hook changed ${review_hook_file}, which the commit does not otherwise change; review the hook's changes, which $3"
    fi
  done
}

## Usage: review_unstaged_changes HOOK RESULT
## Prints a notice for each file that has unstaged changes in the current
## directory, the top level of a working tree, after this package's scripts
## staged the changes of the hook HOOK, such as "pre-commit", as when the hook
## changed the file again when it ran again, and appends the notice to the
## summary (see `review_notice`).  The notice asks for a review of the
## changes, which RESULT, such as "are not staged".
review_unstaged_changes() {
  print_nul_lines git diff --name-only --no-renames -z | while IFS= read -r review_unstaged_file; do
    if [ -n "${review_unstaged_file}" ]; then
      review_notice "${review_unstaged_file} changed after the $1 hook's changes were staged; review its changes, which $2"
    fi
  done
}

## Usage: commit_staged_again HOOK MESSAGE TREE [COMMAND...]
## Commits again, with `git commit` and the message MESSAGE, in the current
## directory, the top level of a working tree, after the hook HOOK, such as
## "pre-commit", rejected a commit there.  A hook, such as one that runs a
## formatter, can reject a commit after changing the files that the commit
## changes, so that a commit of the files as the hook left them succeeds.  A
## hook that formats the whole project, such as one that runs
## `./gradlew spotlessApply`, can also change a file that the commit does not
## change, relative to HEAD, if that file was not formatted at HEAD; the
## commit then includes the hook's changes to that file too.
## TREE is the tree that the rejected commit would have had, as a hash such
## as "4b825dc642cb6eb9a060e54bf8d69288fbee4904", or empty if it is not
## known.  This function stages the hook's changes only if
##  * the working tree matched the index before the commit, as
##    ${commit_staged_clean} says (see `commit_staged_before`);
##  * the index still has the tree TREE, so that the hook staged nothing;
##  * the untracked files are still those in ${commit_staged_untracked}, so
##    that the hook created and deleted none (a file that git ignores is not
##    checked); and
##  * the hook changed at least one file, and only modified files.
## Then, if HOOK is "pre-merge-commit", which `git commit` does not run, it
## runs the hook again, with `GIT_EDITOR=:`, as `git merge` runs it, on the
## files as the hook left them, and requires that it succeed without
## changing or staging a file or creating or deleting an untracked file.
## Then it runs COMMAND, if it is given, as a check of those files, and
## commits only if COMMAND succeeds.  `git commit` runs the pre-commit hook
## again.  For each file that the hook changed but the commit does not
## otherwise change, it prints a notice that says whether the commit
## includes the hook's changes, and appends the notice to the summary (see
## `review_hook_changes`).  It does the same for each file that has unstaged
## changes afterward, as when the hook changed a file again when it ran
## again (see `review_unstaged_changes`).
##
## Returns 0 if the commit succeeded, and a nonzero status otherwise.
commit_staged_again() {
  commit_again_hook="$1"
  commit_again_message="$2"
  commit_again_tree="$3"
  shift 3
  # The record is of the state before one commit, so it is not used again.
  commit_again_clean="${commit_staged_clean:-0}"
  commit_staged_clean=0
  # Without a working tree that matched the index before the commit, or
  # without TREE, the hook's changes cannot be told from others.
  # `git diff --name-status -z TREE` writes, for each file that differs
  # between TREE and the working tree, a status, such as "M" for a modified
  # file, and then a pathname, so the lines alternate between the two.
  # `--no-renames` keeps git from pairing a deleted file with an added one.
  # An empty status means that the hook changed nothing.
  if [ "${commit_again_clean}" != 1 ] || [ -z "${commit_again_tree}" ] \
    || ! commit_again_status="$(print_nul_lines git diff --name-status --no-renames -z "${commit_again_tree}")" \
    || [ -z "${commit_again_status}" ] \
    || ! commit_again_committed="$(print_nul_lines git diff --name-only --no-renames -z HEAD "${commit_again_tree}")"; then
    return 1
  fi
  commit_again_changed="$(printf '%s\n' "${commit_again_status}" | sed -n -e 'n;p')"
  # The files that the hook changed but the commit does not otherwise change.
  # awk reads the files that the commit changes, then an empty line, which is
  # no pathname, then the files that the hook changed.  Unlike an argument,
  # its standard input has no limit on its size.
  commit_again_outside="$({
    printf '%s\n' "${commit_again_committed}" ''
    printf '%s\n' "${commit_again_changed}"
  } | awk '
    hook_changed { if ($0 != "" && !($0 in committed)) print; next }
    $0 == "" { hook_changed = 1; next }
    { committed[$0] = 1 }')"
  if [ "$(git write-tree 2> /dev/null)" != "${commit_again_tree}" ]; then
    commit_again_refusal="the ${commit_again_hook} hook staged a change"
  elif untracked_files_changed; then
    commit_again_refusal="the ${commit_again_hook} hook created or deleted an untracked file"
  elif printf '%s\n' "${commit_again_status}" | sed -n -e 'p;n' | grep -v -x -q M; then
    commit_again_refusal="the ${commit_again_hook} hook did more than modify files"
  elif ! git add -u || ! commit_again_staged="$(git write-tree)"; then
    commit_again_refusal="the hook's changes cannot be staged"
  else
    commit_again_refusal=''
  fi
  if [ -n "${commit_again_refusal}" ]; then
    echo "${SCRIPT_NAME}: not committing again in $(pwd), because ${commit_again_refusal}" >&2
    review_hook_changes "${commit_again_hook}" "${commit_again_outside}" "are not committed"
    return 1
  fi
  printf '%s\n' "${commit_again_changed}" | while IFS= read -r commit_again_file; do
    echo "${SCRIPT_NAME}: the ${commit_again_hook} hook changed ${commit_again_file}; staged its changes" >&2
  done

  commit_again_failure=''
  if [ "${commit_again_hook}" = pre-merge-commit ]; then
    # `git merge` runs the hook with `GIT_EDITOR=:`, which a hook can
    # require; `git hook run` does not set it.
    if ! GIT_EDITOR=: git hook run --ignore-missing pre-merge-commit; then
      commit_again_failure="the pre-merge-commit hook, run again, failed"
    elif ! git diff --quiet; then
      commit_again_failure="the pre-merge-commit hook, run again, changed a file"
    elif [ "$(git write-tree 2> /dev/null)" != "${commit_again_staged}" ]; then
      commit_again_failure="the pre-merge-commit hook, run again, staged a change"
    elif untracked_files_changed; then
      commit_again_failure="the pre-merge-commit hook, run again, created or deleted an untracked file"
    fi
  fi
  if [ -z "${commit_again_failure}" ] && [ $# -gt 0 ] && ! "$@"; then
    commit_again_failure="\`$*\` failed"
  fi
  if [ -z "${commit_again_failure}" ]; then
    echo "${SCRIPT_NAME}: committing again in $(pwd)" >&2
    if ! printf '%s\n' "${commit_again_message}" | git commit -q --cleanup=whitespace -F -; then
      commit_again_failure="the commit failed"
    fi
  fi
  if [ -n "${commit_again_failure}" ]; then
    commit_again_later=''
    if [ "$(git write-tree 2> /dev/null)" != "${commit_again_staged}" ]; then
      commit_again_later="; later changes are staged too"
    fi
    if ! git diff --quiet || untracked_files_changed; then
      commit_again_later="${commit_again_later}; the working tree has later changes, which are not staged"
    fi
    echo "${SCRIPT_NAME}: not committed in $(pwd), because ${commit_again_failure}; the changes that the ${commit_again_hook} hook made when it rejected the commit are staged${commit_again_later}" >&2
    review_hook_changes "${commit_again_hook}" "${commit_again_outside}" \
      "are staged, but not committed${commit_again_later}"
    review_unstaged_changes "${commit_again_hook}" "are not staged"
    return 1
  fi
  review_hook_changes "${commit_again_hook}" "${commit_again_outside}" \
    "commit $(git rev-parse --short HEAD) includes"
  review_unstaged_changes "${commit_again_hook}" "are not committed"
}

## Usage: commit_rejected_merge MESSAGE
## Commits, with the message MESSAGE, the merge without conflicts that is in
## progress in the current directory, the top level of a working tree, after
## a pre-merge-commit hook rejected the commit that `git merge` or `git pull`
## tried to make.  It commits as `commit_staged_again` describes, which
## requires that `commit_staged_before` recorded the state of the working
## tree before the merge.  Before committing, it runs the pre-merge-commit
## hook again, on the files as the hook left them; `git commit` then runs the
## pre-commit hook, as for a merge whose conflicts were resolved.
##
## Returns 0 if the commit succeeded, and a nonzero status otherwise.
commit_rejected_merge() {
  # The tree of the merge, which the index held when the hook ran.
  commit_rejected_tree="$(git merge-tree --write-tree --no-messages HEAD MERGE_HEAD 2> /dev/null)" \
    || commit_rejected_tree=''
  commit_staged_again pre-merge-commit "$1" "${commit_rejected_tree}"
}

## Usage: commit_resolved_merge RESOLVER COMMIT SOURCE MESSAGE
## Resolves the conflicts of the merge of COMMIT that is in progress in the
## current directory, the top level of a working tree, with
## `resolve_merge_conflicts`, given RESOLVER, COMMIT, and SOURCE, and commits
## the merge with the message MESSAGE.  A merge without conflicts, whose
## commit a pre-merge-commit hook rejected, is committed with
## `commit_rejected_merge` instead.  Returns 1, after printing a diagnostic,
## on failure, and leaves the merge in progress, which it notes in
## AGENT-TODO.md, as `resolve_merge_conflicts` does.
commit_resolved_merge() {
  if [ -z "$(git ls-files --unmerged)" ]; then
    commit_resolved_with=commit_rejected_merge
  elif ! resolve_merge_conflicts "$1" "$2" "$3"; then
    return 1
  else
    commit_resolved_with=commit_staged
  fi
  # The message is MESSAGE, rather than MERGE_MSG, to which `git merge`
  # appended a list of the conflicts.
  if ! "${commit_resolved_with}" "$4"; then
    stop_at_merge "${SCRIPT_NAME}: cannot commit the merge of $3 in $(pwd); the merge is in progress; finish it with \`git commit\`, or abort it with \`git merge --abort\`" \
      "\`${SCRIPT_NAME}\` could not commit it."
    return 1
  fi
  forget_conflicted_files
  # The entries of AGENT-TODO.md about the merge are out of date.
  prune_agent_todo 0
  return 0
}
