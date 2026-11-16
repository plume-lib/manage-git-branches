# shellcheck shell=sh

# Functions that run an AI agent, such as Claude or Codex; that record, in the
# file AGENT-TODO.md, the agent sessions and merges that a person needs to
# continue; and that ask an agent to fix a failed build.
#
# `common-functions.sh` sources this file.  A script uses these functions by
# sourcing that file, which says what the script must set first.

## Usage: agent_available AGENT
## Succeeds if the command AGENT, "claude" or "codex", can be found and is
## ready to run (see `agent_ready`).  Otherwise prints a diagnostic and
## returns 1, after setting ${agent_unavailable_reason} to a sentence for an
## entry of AGENT-TODO.md that says why, such as "claude, an AI agent, did
## not run, because it was not ready to run, as when it is not logged in.",
## or to the empty string if AGENT is not on the PATH, as when the user does
## not use it.  Skips the check of `agent_ready` if an earlier check in the
## same run of the script succeeded (see `agent_ready_record`), because each
## check costs a request to the agent's service.
agent_available() {
  agent_unavailable_reason=''
  if ! command -v "$1" > /dev/null 2>&1; then
    echo "${SCRIPT_NAME}: cannot run $1, which is not on the PATH" >&2
    return 1
  fi
  if agent_available_record="$(agent_ready_record)" \
    && [ "$(cat -- "${agent_available_record}" 2> /dev/null)" = "$$ $1" ]; then
    return 0
  fi
  if ! agent_ready "$1"; then
    # shellcheck disable=SC2034 # set for the caller
    agent_unavailable_reason="$1, an AI agent, did not run, because it was not ready to run, as when it is not logged in."
    return 1
  fi
  return 0
}

## Usage: agent_ready_record
## Prints the pathname of the file in which `agent_ready` records that an AI
## agent was ready to run:  manage-git-branches-agent-ready in the common git
## directory of the current directory, such as
## "/home/me/myrepo/.git/manage-git-branches-agent-ready".  The file holds
## the process id of the script, which every subshell shares as `$$`, and the
## agent, as in "12345 claude", so that a later run of the script, which has
## another process id, checks again.  Neither agent can write the git
## directory.  Prints nothing, and returns 1, if the current directory is not
## in a working tree.
agent_ready_record() {
  agent_ready_dir="$(git rev-parse --path-format=absolute --git-common-dir 2> /dev/null)" \
    && [ -n "${agent_ready_dir}" ] \
    && printf '%s\n' "${agent_ready_dir}/manage-git-branches-agent-ready"
}

## Usage: agent_rerun_advice AGENT TASK [STEP]
## Prints a sentence for an entry of AGENT-TODO.md that says that running
## the same command again, once the AI agent AGENT can run, asks it to do
## TASK, such as "resolve the conflicts", so that no person needs to.  If
## STEP is given, such as "abort the merge with `git merge --abort`", the
## sentence says to do STEP before running the command again.  The sentence
## does not name the command:  `git-pull-from` and `git-rebase-to` run
## `git-push-to`, whose name ${SCRIPT_NAME} would then give.
## The end of the sentence that `agent_rerun_advice` prints, by which
## `prune_agent_todo` recognizes an entry that gives such advice.
agent_rerun_advice_end=', so no person needs to.'
agent_rerun_advice() {
  if [ -n "${3:-}" ]; then
    printf 'Once %s can run, %s; then running the same command again asks %s to %s%s\n' "$1" "$3" "$1" "$2" "${agent_rerun_advice_end}"
  else
    printf 'Once %s can run, running the same command again asks it to %s%s\n' "$1" "$2" "${agent_rerun_advice_end}"
  fi
}

## Usage: agent_unchanged_reason AGENT
## Prints a sentence for an entry of AGENT-TODO.md that says that the AI
## agent AGENT failed without changing anything and is not ready to run, as
## `run_agent` reports with status 3.
agent_unchanged_reason() {
  printf '%s, an AI agent, failed before changing anything, and it is not ready to run, as when it cannot reach its service.\n' "$1"
}

## Usage: agent_ready AGENT
## Succeeds if the AI agent AGENT, "claude" or "codex", is ready to run:  if
## it answers a request for a one-word reply.  The request fails if the agent
## is not logged in, if it has reached a usage limit, or if it cannot reach
## its service; it costs a fraction of a cent.  (`codex login status` would
## succeed in the last two cases, and Claude can report that a user is
## logged in although the login has expired.)  The request runs in the root
## directory, so that no file of a working tree configures the agent, with
## no tools for Claude and a read-only sandbox for Codex, and without
## keeping a session.  Otherwise prints a diagnostic, which includes the
## agent's own message, and returns 1.  Writes the file that
## `agent_ready_record` names after a success, and removes it after a
## failure.
agent_ready_prompt='Reply with the single word OK.'
agent_ready() {
  case "$1" in
    claude)
      agent_ready_login='claude auth login'
      agent_ready_output="$(cd / && printf '%s\n' "${agent_ready_prompt}" \
        | run_with_time_limit 120 claude -p --restricted --strict-mcp-config \
          --no-session-persistence --tools '' 2>&1)"
      ;;
    codex)
      agent_ready_login='codex login'
      agent_ready_output="$(cd / && printf '%s\n' "${agent_ready_prompt}" \
        | run_with_time_limit 120 codex exec --skip-git-repo-check --ephemeral \
          --sandbox read-only - 2>&1)"
      ;;
    *)
      echo "${SCRIPT_NAME}: unknown AI agent: $1" >&2
      return 1
      ;;
  esac
  agent_ready_status=$?
  agent_ready_file="$(agent_ready_record)" || agent_ready_file=''
  if [ "${agent_ready_status}" -eq 0 ]; then
    # A failure to write the record costs only another check.
    if [ -n "${agent_ready_file}" ]; then
      printf '%s %s\n' "$$" "$1" > "${agent_ready_file}" 2> /dev/null || true
    fi
    return 0
  fi
  if [ -n "${agent_ready_file}" ]; then
    rm -f -- "${agent_ready_file}"
  fi
  # The message gives the login command last:  checkbashisms takes a closing
  # backquote followed by text such as ".  It said" for a `.` command with
  # arguments.
  echo "${SCRIPT_NAME}: $1 is not ready to run (status ${agent_ready_status}).  It said: ${agent_ready_output}  If it is not logged in, log in with \`${agent_ready_login}\`" >&2
  return 1
}

## The number of times that `run_agent` runs an agent again after it fails
## without changing anything.
agent_retries=2

## Usage: index_digest
## Prints a checksum of the index of the current directory's working tree,
## such as "1234567890 512".  If two runs print the same checksum, then the
## index did not change in between, barring a checksum collision.
index_digest() {
  git ls-files --stage -z | cksum
}

## Usage: run_agent AGENT PROMPT [MARKER PATHS]
## Runs the AI agent AGENT, "claude" or "codex", in the current directory, the
## top level of a working tree, with
## the instructions PROMPT.  The agent can read and edit the files of the
## working tree and read the repository, but nothing else; PROMPT can contain
## text from other people, such as conflicting changes, which might try to
## make the agent do more.  Returns 2, after printing a diagnostic, if the
## agent changed git's configuration, attributes, or hooks, after which no git
## command should run in the current directory.  Returns 3, after printing a
## diagnostic, if the agent failed each time without changing anything and
## is not ready to run (see below).  Otherwise returns 1, after printing a
## diagnostic, if the agent fails.
##
## An agent that fails, other than by running out of time or by a signal, as
## when the user interrupts it, without changing HEAD, the index, or any file
## of the working tree, even one that git ignores, did no work that anyone
## must review, and it might succeed if it is run again, as when its service
## was briefly unavailable.  It is run again, up to ${agent_retries} more
## times, each after a pause of ${MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE}
## seconds, 60 by default.  All of the attempts, with the pauses between
## them, take at most ${MANAGE_GIT_BRANCHES_LLM_TIMEOUT} seconds together,
## 1800 by default, or 0 for no limit:  at that time, a running attempt is
## stopped, and no further attempt starts.  So an agent that runs long and
## then fails is run again only for the time that remains, if any.  If its
## last attempt fails so, and the agent is then not ready to run (see
## `agent_ready`), this function returns 3:  running the agent again once it
## is ready, as by running the script again, can succeed, and no person need
## finish its task.  An agent that fails so but is ready to run, as when it
## rejects an option that this function passes, makes this function return
## 1.
##
## MARKER and PATHS, if given, are what the caller uses to find the agent's
## changes:  MARKER is a file in the git directory, which neither agent can
## write, and PATHS is the output of `working_tree_paths`, which the caller
## ran after `wait_for_later_time MARKER`; see `resolve_with_agent`.  This
## function then uses them too, and leaves MARKER in place.  Otherwise, it
## writes a marker of its own, waits, and lists the pathnames, before the
## first attempt.  An attempt that changed nothing leaves both valid for the
## next attempt.
##
## Appends to ${agent_session_ids}, a blank-separated list, the UUID that
## names the agent's last attempt's session, such as
## "1e55b89c-cfb5-468f-a783-cb104201809b"; the earlier attempts did nothing
## worth continuing.  Appends nothing if this function returns 3, for the
## same reason.
## A caller that sets ${agent_session_ids} to the empty string first can
## report every session that the agent ran in since then, such as one per
## attempt to fix a build.  Prints a diagnostic and appends nothing if the
## session has no UUID:  for Claude, if this system cannot make one, and for
## Codex, if Codex does not print the one that it chose.  Also sets the
## variables that `report_agent_session` reads:  ${agent_session_agent}, which
## is AGENT; ${agent_session_command}, the command that continues a session
## given its UUID, "claude --resume" or "codex resume"; ${agent_session_dir},
## the current directory; and ${agent_session_todo}, the pathname of the file
## AGENT-TODO.md at the top level of the working tree, or the empty string if
## that file must not be written because git tracks it or the top level is
## unknown.  It is computed before the agent runs, because no git command
## should run after the agent has changed git's configuration.
##
## The agent can read every file of the working tree, including files that
## git ignores, such as a ".env" file, and the repository, including its
## configuration.  Instructions in the conflicting text can make it copy a
## secret from such a file into any file that git tracks, where no check
## finds it, and the script then commits and pushes that file.
run_agent() {
  # Each agent's sandbox keeps it from changing git's configuration or hooks,
  # which name commands that git runs.  Check that anyway.
  if ! run_agent_git_state="$(git_control_state)"; then
    echo "${SCRIPT_NAME}: cannot read git's configuration in $(pwd)" >&2
    return 1
  fi
  run_agent_limit="${MANAGE_GIT_BRANCHES_LLM_TIMEOUT:-1800}"
  case "${run_agent_limit}" in
    *[!0-9]*)
      echo "${SCRIPT_NAME}: MANAGE_GIT_BRANCHES_LLM_TIMEOUT is not a number of seconds: ${run_agent_limit}" >&2
      return 1
      ;;
  esac
  case "$1" in
    claude)
      agent_session_command="claude --resume"
      ;;
    codex)
      agent_session_command="codex resume"
      if ! run_agent_repository="$(git rev-parse --path-format=absolute --git-common-dir)" \
        || ! run_agent_codex="$(codex_installation)"; then
        echo "${SCRIPT_NAME}: cannot find the files that codex needs to read" >&2
        return 1
      fi
      # Codex chooses its session's UUID and prints it on standard error, in
      # a header line such as "session id: 01a19ac9-dab5-7570-93b6-6ba41bf65093".
      # `tee` copies standard error to a file, from which the first such line
      # is read, and still shows it to the user.  The file and the file that
      # holds Codex's exit status are in the git directory, which Codex
      # cannot write.
      if ! run_agent_git_dir="$(git rev-parse --absolute-git-dir)"; then
        echo "${SCRIPT_NAME}: cannot find the git directory of $(pwd)" >&2
        return 1
      fi
      run_agent_log="${run_agent_git_dir}/manage-git-branches-agent-stderr"
      run_agent_status_file="${run_agent_git_dir}/manage-git-branches-agent-status"
      ;;
    *)
      echo "${SCRIPT_NAME}: unknown AI agent: $1" >&2
      return 1
      ;;
  esac
  run_agent_retries_left="${agent_retries}"
  agent_session_agent="$1"
  agent_session_dir="$(pwd)"
  run_agent_session=''
  agent_session_todo="$(agent_todo_path)" || agent_session_todo=''
  run_agent_earlier_ids="${agent_session_ids:-}"
  # A failed attempt changed nothing if it changed neither HEAD nor the
  # index, compared by their contents, nor the working tree, compared by its
  # pathnames and by each file's ctime, as `resolve_with_agent` explains.
  # If no marker can be written, a failed attempt is not run again.
  # ${run_agent_own_marker} is the marker that this function wrote, which it
  # removes before it returns.
  run_agent_own_marker=''
  run_agent_watched=0
  if [ -n "${3:-}" ]; then
    run_agent_marker="$3"
    run_agent_paths="$4"
    run_agent_watched=1
  elif run_agent_marker="$(git rev-parse --path-format=absolute --git-path manage-git-branches-agent-attempt)" \
    && : > "${run_agent_marker}"; then
    run_agent_own_marker="${run_agent_marker}"
    if wait_for_later_time "${run_agent_marker}" "$(pwd)"; then
      run_agent_paths="$(working_tree_paths)"
      run_agent_watched=1
    fi
  fi
  if [ "${run_agent_watched}" -eq 1 ]; then
    run_agent_head="$(git rev-parse --verify --quiet HEAD)"
    run_agent_index="$(index_digest)"
  fi
  # Each agent reads its instructions from standard input.
  #
  # Claude's restricted mode confines the file tools to the current
  # directory, and it ignores the settings files, whose rules, such as a
  # user's "Write(*)", would otherwise permit edits anywhere; a project's
  # settings file could come from the merged branch.  `--strict-mcp-config`
  # leaves out MCP servers, whose tools could act elsewhere.  Of the git
  # commands that Claude can run, which read the repository, `git diff`,
  # `git log`, and `git show` can write a file named by `--output`.  Claude
  # refuses a shell redirection of their output to a file outside the
  # working tree or in `.git`.  `git diff` can also read any file, as in
  # `git diff --no-index /dev/null ~/.ssh/id_rsa`;
  # "blockReadsOutsideWorkingDirectories" refuses a command that names a file
  # outside the working tree.
  #
  # Codex's permission profile, which overrides any `sandbox_mode` in the
  # user's configuration, lets the commands that Codex runs write only the
  # working tree, other than `.git`, and read only the working tree, the
  # repository, the system's programs and libraries (":minimal"), and Codex's
  # own installation, which its sandbox runs.
  #
  # All attempts share one deadline, so that an attempt that runs long and
  # then fails leaves little or no time for another attempt.
  run_agent_deadline=$(($(date +%s) + run_agent_limit))
  while :; do
    agent_session_ids="${run_agent_earlier_ids}"
    # ${run_agent_attempt_limit} is the number of seconds that this attempt
    # can run, or 0 for no limit.
    run_agent_attempt_limit=0
    if [ "${run_agent_limit}" -ne 0 ]; then
      run_agent_attempt_limit=$((run_agent_deadline - $(date +%s)))
      # The pause before this attempt can end a moment after the deadline;
      # the check after this attempt then reports that time ran out.
      if [ "${run_agent_attempt_limit}" -lt 1 ]; then
        run_agent_attempt_limit=1
      fi
    fi
    case "$1" in
      claude)
        run_agent_session="$(new_uuid)"
        if [ -z "${run_agent_session}" ]; then
          echo "${SCRIPT_NAME}: cannot make a UUID to name claude's session, so no command will be able to continue it" >&2
        fi
        # The UUID contains no character that field splitting or globbing
        # would change, so the unquoted expansion is one option and its value.
        # shellcheck disable=SC2086
        printf '%s\n' "$2" | run_with_time_limit "${run_agent_attempt_limit}" claude -p --restricted --strict-mcp-config \
          ${run_agent_session:+--session-id ${run_agent_session}} \
          --settings '{"permissions": {"blockReadsOutsideWorkingDirectories": true}}' \
          --tools 'Read,Edit,Write,Grep,Glob,Bash' --permission-mode acceptEdits \
          --allowedTools 'Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*),Bash(git ls-files:*),Bash(git merge-base:*)' \
          --disallowedTools 'Bash(git diff *--output*),Bash(git log *--output*),Bash(git show *--output*)'
        run_agent_status=$?
        ;;
      codex)
        # Codex's sandbox protects some names in the working tree, even absent
        # ones, by creating an empty directory to mount over.  Each such
        # directory that did not exist before is removed afterwards.
        run_agent_absent=''
        for run_agent_name in .agents .aws .codex; do
          if [ ! -e "${run_agent_name}" ] && [ ! -L "${run_agent_name}" ]; then
            run_agent_absent="${run_agent_absent} ${run_agent_name}"
          fi
        done
        rm -f -- "${run_agent_status_file}"
        {
          {
            printf '%s\n' "$2" | run_with_time_limit "${run_agent_attempt_limit}" codex exec -c 'default_permissions="resolve_conflicts"' \
              -c "permissions.resolve_conflicts.filesystem={\":minimal\" = \"read\", \":project_roots\" = {\".\" = \"write\"}, $(toml_string "${run_agent_repository}") = \"read\", $(toml_string "${run_agent_codex}") = \"read\"}" \
              - 2>&1 1>&3 3>&-
            echo "$?" > "${run_agent_status_file}"
          } | tee -- "${run_agent_log}" >&2
        } 3>&1
        run_agent_status="$(cat -- "${run_agent_status_file}" 2> /dev/null)"
        case "${run_agent_status}" in
          "" | *[!0-9]*) run_agent_status=1 ;;
        esac
        run_agent_session="$(sed -n -e 's/^session id: //p' "${run_agent_log}" 2> /dev/null | head -n 1)"
        if ! is_uuid "${run_agent_session}"; then
          run_agent_session=''
          echo "${SCRIPT_NAME}: codex printed no line \"session id: UUID\", so no command will be able to continue its session" >&2
        fi
        rm -f -- "${run_agent_log}" "${run_agent_status_file}"
        for run_agent_name in ${run_agent_absent}; do
          if [ -d "${run_agent_name}" ] && [ ! -L "${run_agent_name}" ]; then
            # `rmdir` removes only an empty directory.
            rmdir -- "${run_agent_name}" 2> /dev/null || true
          fi
        done
        ;;
    esac
    if [ -n "${run_agent_session}" ]; then
      agent_session_ids="${agent_session_ids:-}${agent_session_ids:+ }${run_agent_session}"
    fi
    if [ "$(git_control_state)" != "${run_agent_git_state}" ]; then
      run_agent_remove_marker
      echo "${SCRIPT_NAME}: $1 changed git's configuration, attributes, or hooks in $(pwd); check them before running git there" >&2
      return 2
    fi
    # The agent left git's configuration unchanged, so git commands are safe.
    if [ "${run_agent_status}" -eq 0 ]; then
      run_agent_remove_marker
      return 0
    fi
    if [ "${run_agent_limit}" -ne 0 ] && [ "$(date +%s)" -ge "${run_agent_deadline}" ]; then
      run_agent_remove_marker
      echo "${SCRIPT_NAME}: $1 did not finish within ${run_agent_limit} seconds; set MANAGE_GIT_BRANCHES_LLM_TIMEOUT to change the limit" >&2
      return 1
    fi
    echo "${SCRIPT_NAME}: $1 failed with status ${run_agent_status}" >&2
    # A status above 128 means that a signal ended the agent, as when the
    # user interrupted it.
    if [ "${run_agent_status}" -gt 128 ]; then
      run_agent_remove_marker
      echo "${SCRIPT_NAME}: $1 was ended by signal $((run_agent_status - 128)), so it is not run again" >&2
      return 1
    fi
    if [ "${run_agent_watched}" -eq 0 ] \
      || [ "$(git rev-parse --verify --quiet HEAD)" != "${run_agent_head}" ] \
      || [ "$(index_digest)" != "${run_agent_index}" ] \
      || [ -n "$(: | working_tree_changes "${run_agent_paths}" "${run_agent_marker}")" ]; then
      run_agent_remove_marker
      return 1
    fi
    if [ "${run_agent_retries_left}" -eq 0 ]; then
      break
    fi
    # The pause is checked only when it is needed, so that a malformed value
    # stops no agent that succeeds at once.
    run_agent_pause="${MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE:-60}"
    case "${run_agent_pause}" in
      "" | *[!0-9]*)
        echo "${SCRIPT_NAME}: MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE is not a number of seconds, so $1 is not run again: ${run_agent_pause}" >&2
        break
        ;;
    esac
    if [ "${run_agent_limit}" -ne 0 ] \
      && [ "$(($(date +%s) + run_agent_pause))" -ge "${run_agent_deadline}" ]; then
      echo "${SCRIPT_NAME}: $1 changed nothing, and too little of the ${run_agent_limit} seconds that MANAGE_GIT_BRANCHES_LLM_TIMEOUT allows remains to run it again" >&2
      break
    fi
    run_agent_retries_left=$((run_agent_retries_left - 1))
    echo "${SCRIPT_NAME}: $1 changed nothing; running it again in ${run_agent_pause} seconds" >&2
    sleep "${run_agent_pause}"
  done
  run_agent_remove_marker
  # Every attempt failed without changing anything.
  if agent_ready "$1"; then
    echo "${SCRIPT_NAME}: $1 failed before changing anything in $(pwd), although it is ready to run" >&2
    return 1
  fi
  agent_session_ids="${run_agent_earlier_ids}"
  echo "${SCRIPT_NAME}: $1 failed before changing anything in $(pwd)" >&2
  return 3
}

## Usage: run_agent_remove_marker
## For `run_agent`:  removes the marker that it wrote, if any.
run_agent_remove_marker() {
  if [ -n "${run_agent_own_marker}" ]; then
    rm -f -- "${run_agent_own_marker}"
  fi
}

## Usage: report_agent_session TASK [NOTE]
## Prints a command that continues, interactively, each session of the AI
## agent that `run_agent` recorded in ${agent_session_ids}, such as
## "cd /home/me/myrepo && claude --resume 1e55b89c-cfb5-468f-a783-cb104201809b".
## The user can then ask the agent about its work, or tell it to finish the
## work in a way that its instructions forbade, such as by creating a file.
## Also appends the commands, under a heading that gives TASK and the time,
## and after NOTE, a paragraph such as `merge_in_progress_note` prints, if
## NOTE is given and not empty, to the file ${agent_session_todo} (see
## `append_agent_todo`), where the user is less likely to overlook them than
## in the script's output, and appends NOTE and the commands to the summary (see
## `append_summary`).  TASK is what
## the agent was asked to do, such as "Fix the build after merging branch
## 'main'"; only its first line is used.  Neither prints nor writes anything
## if no session is recorded.
##
## Runs no git command, because the agent might have changed git's
## configuration.
agent_todo_file=AGENT-TODO.md
report_agent_session() {
  if [ -z "${agent_session_ids:-}" ]; then
    return 0
  fi
  report_note="${2:-}"
  append_merge_note_summary "${report_note}"
  # The UUIDs contain no character that field splitting or globbing would
  # change, so each unquoted expansion below is the list of UUIDs.
  # shellcheck disable=SC2086
  set -- "$1" ${agent_session_ids}
  report_task="$(printf '%s\n' "$1" | head -n 1)"
  shift
  report_count=$#
  # The Markdown entry for ${agent_session_todo}.
  report_entry="
## ${report_task} (${SCRIPT_NAME}, $(date '+%Y-%m-%d %H:%M:%S'))
"
  if [ -n "${report_note}" ]; then
    report_entry="${report_entry}
${report_note}
"
  fi
  report_index=0
  for report_id in "$@"; do
    report_index=$((report_index + 1))
    report_command="cd $(shell_word "${agent_session_dir}") && ${agent_session_command} ${report_id}"
    if [ "${report_count}" -eq 1 ]; then
      report_session="the session"
    else
      report_session="session ${report_index} of ${report_count}"
      report_entry="${report_entry}
Session ${report_index} of ${report_count}:
"
    fi
    # `echo` in some shells, such as dash, would interpret a backslash in the
    # directory.
    printf '%s\n' "${SCRIPT_NAME}: to continue ${report_session} of ${agent_session_agent}:  ${report_command}" >&2
    append_summary "to continue ${report_session} of ${agent_session_agent} (${report_task}):  ${report_command}"
    report_entry="${report_entry}
\`\`\`sh
${report_command}
\`\`\`
"
  done
  if ! append_agent_todo "${agent_session_todo:-}" "${report_entry}"; then
    return 0
  fi
  if [ "${report_count}" -eq 1 ]; then
    echo "${SCRIPT_NAME}: appended that command to ${agent_session_todo}" >&2
  else
    echo "${SCRIPT_NAME}: appended those commands to ${agent_session_todo}" >&2
  fi
}

## Usage: is_unsafe_to_write FILE
## Returns 0 if FILE exists but is not a regular file with one link:  if it
## is a symbolic link or has another hard link, either of which could make it
## another file outside the working tree, or if it is anything else but a
## regular file.  Returns 1 if FILE does not exist or is a regular file with
## one link.
is_unsafe_to_write() {
  # `find -links +1` prints the file if it has more than one hard link.
  [ -L "$1" ] \
    || { [ -e "$1" ] && [ ! -f "$1" ]; } \
    || [ -n "$(find "$1" -prune -links +1 2> /dev/null)" ]
}

# The title and the explanation with which `append_agent_todo` starts a file
# AGENT-TODO.md.
# The backquotes are Markdown, not command substitutions.
# shellcheck disable=SC2016
agent_todo_preamble='# AI agent sessions to continue

A script of manage-git-branches, such as `git-push-to`, appends an entry
here when an AI agent fails, when the script rejects its work, or when
the script leaves a merge in progress.  An entry'"'"'s command continues the
agent'"'"'s session interactively.  Delete the entry once you have dealt with
it.'
# Another title and explanation that a file AGENT-TODO.md can start with,
# which do not mention a merge in progress.  `prune_agent_todo` treats them
# as it treats ${agent_todo_preamble}.
# shellcheck disable=SC2016
agent_todo_preamble_without_merge='# AI agent sessions to continue

A script of manage-git-branches, such as `git-push-to`, appends an entry
here when an AI agent fails or when the script rejects its work.  The
entry'"'"'s command continues the agent'"'"'s session interactively.  Delete the
entry once you have dealt with it.'

## Usage: append_agent_todo FILE ENTRY
## Appends ENTRY, Markdown text that begins with a blank line and a heading,
## to FILE, the pathname of a file AGENT-TODO.md, which this function creates,
## starting with ${agent_todo_preamble}, if it does not exist.  Returns 1, after
## printing a diagnostic, if it did not write FILE:  because FILE is empty, as
## `agent_todo_path` leaves it if the file must not be written; because FILE
## is unsafe to write (see `is_unsafe_to_write`); or because writing failed.
## Runs no git command.
append_agent_todo() {
  if [ -z "$1" ]; then
    echo "${SCRIPT_NAME}: did not write ${agent_todo_file}, which git tracks or whose working tree is unknown" >&2
    return 1
  fi
  if is_unsafe_to_write "$1"; then
    echo "${SCRIPT_NAME}: did not write $1, which is not a regular file with one link" >&2
    return 1
  fi
  append_todo_new=no
  if [ ! -e "$1" ]; then
    append_todo_new=yes
  fi
  if ! {
    if [ "${append_todo_new}" = yes ]; then
      printf '%s\n' "${agent_todo_preamble}"
    fi
    printf '%s' "$2"
  } >> "$1"; then
    echo "${SCRIPT_NAME}: cannot write $1" >&2
    return 1
  fi
  return 0
}

## Usage: agent_todo_path
## Prints the pathname of the file AGENT-TODO.md at the top level of the
## working tree that contains the current directory, such as
## "/home/me/myrepo/AGENT-TODO.md".  Prints nothing, and returns 1, if that
## file must not be written, because git tracks it or because the current
## directory is not in a working tree.
agent_todo_path() {
  agent_todo_top="$(git rev-parse --show-toplevel 2> /dev/null)" || return 1
  if [ -z "${agent_todo_top}" ] \
    || git -C "${agent_todo_top}" ls-files --error-unmatch -- "${agent_todo_file}" > /dev/null 2>&1; then
    return 1
  fi
  printf '%s\n' "${agent_todo_top}/${agent_todo_file}"
}

## Usage: prune_agent_todo BUILT [RERUN]
## Removes, from the file AGENT-TODO.md at the top level of the working tree
## that contains the current directory (see `agent_todo_path`), each entry
## that a script of this package wrote about that working tree and that no
## longer applies.  The heading of such an entry ends with the script's name
## and a time, as in "## Fix the build after merges (git-push-to,
## 2026-11-10 07:51:59)".  An entry no longer applies if
##  * it says that the merge of a commit is in progress in the working tree,
##    as `merge_in_progress_note` writes, and no merge of that commit is in
##    progress there, because someone finished or aborted it; or
##  * BUILT is 1, which says that the working tree's HEAD was just built
##    successfully, and the entry gives the command that continues an AI
##    agent's attempt to fix the build of the working tree, as
##    `report_agent_session` writes it for a task such as "Fix the build after
##    merging branch 'main'", or says that running the script again suffices
##    to fix the build of the working tree, as `merge_build_note` writes; or
##  * it says that running the script again suffices (see
##    `agent_rerun_advice`), and RERUN is "merge" and the entry is about the
##    merge in progress in the working tree, or RERUN is "build" and the
##    entry is about a failed build of the working tree, as when the script
##    is about to write a newer entry or to run the agent again.
## An entry is about the working tree if it names the working tree's top
## level.  Each other entry is kept:  one with a heading of another form, such
## as one that a person wrote; one of another kind, such as an entry of
## `fix-renovate-prs`; one about another working tree, as in the copy of
## AGENT-TODO.md that `git-new-branch` makes along with the rest of a working
## tree; and one to which a person added text, such as a note after its
## command.  Lines that follow the last entry belong to it.
##
## Deletes the file if no entry remains and the file holds nothing else but
## ${agent_todo_preamble} or ${agent_todo_preamble_without_merge}, even if no
## entry was removed.  Says what it removed.  Does nothing if the file does
## not exist or is unsafe to write (see `is_unsafe_to_write`).  Replaces the
## file atomically, keeping its permissions.  Just before it replaces or
## deletes the file, checks that the file has not changed since this function
## read it, as when another script appended an entry, and leaves a changed
## file unchanged; this narrows, but does not close, the window in which such
## an append is lost.  A failure to read or to rewrite the file leaves the
## entries for a person to delete, and is reported but is not an error, so
## this function always returns 0.
prune_agent_todo() {
  prune_built="$1"
  prune_rerun="${2:-}"
  prune_todo="$(agent_todo_path)" || return 0
  if [ ! -e "${prune_todo}" ] || is_unsafe_to_write "${prune_todo}"; then
    return 0
  fi
  # The top level of the working tree, as an entry can name it:  as git
  # prints it, with symbolic links resolved, and as `pwd` prints it, which
  # can contain symbolic links.  `merge_in_progress_note` and `run_agent`
  # name the current directory, which is the top level, as `pwd` prints it.
  prune_top="${prune_todo%/*}"
  prune_pwd_top="$(pwd)"
  if prune_prefix="$(git rev-parse --show-prefix)" && [ -n "${prune_prefix}" ]; then
    prune_pwd_top="${prune_pwd_top%/"${prune_prefix%/}"}"
  fi
  set -- "${prune_top}"
  if [ "${prune_pwd_top}" != "${prune_top}" ]; then
    set -- "$@" "${prune_pwd_top}"
  fi
  prune_dirs=''
  prune_prefixes=''
  for prune_dir in "$@"; do
    prune_dirs="${prune_dirs}${prune_dir}
"
    prune_prefixes="${prune_prefixes}$(printf 'cd %s && ' "$(shell_word "${prune_dir}")")
"
  done
  prune_merge_head="$(git rev-parse --verify --quiet MERGE_HEAD)" || prune_merge_head=''
  # A copy of the file, which awk reads, and awk's output are written in the
  # git directory, which is outside the working tree.  The copy also shows
  # whether the file changed while awk read the copy.
  if ! prune_base="$(git rev-parse --path-format=absolute --git-path manage-git-branches-agent-todo)"; then
    echo "${SCRIPT_NAME}: cannot find the git directory of $(pwd), so ${prune_todo} was not pruned" >&2
    return 0
  fi
  if ! prune_old="$(mktemp "${prune_base}.XXXXXX")"; then
    echo "${SCRIPT_NAME}: cannot create a temporary file in the git directory of $(pwd), so ${prune_todo} was not pruned" >&2
    return 0
  fi
  prune_output="${prune_old}.new"
  if ! cp "${prune_todo}" "${prune_old}"; then
    echo "${SCRIPT_NAME}: cannot read ${prune_todo}, so it was not pruned" >&2
    rm -f "${prune_old}"
    return 0
  fi
  # The first line of the output is the counts, and the rest is the new
  # content of the file.  The step fails if awk cannot run the script, as
  # when the script is missing, or if the output cannot be written; either
  # way, awk or the shell prints the cause.
  if ! PRUNE_DIRS="${prune_dirs}" PRUNE_CD_PREFIXES="${prune_prefixes}" \
    PRUNE_MERGE_HEAD="${prune_merge_head}" PRUNE_BUILT="${prune_built}" \
    PRUNE_RERUN="${prune_rerun}" PRUNE_RERUN_END="${agent_rerun_advice_end}" \
    awk -f "${SCRIPT_DIR}/prune-agent-todo.awk" < "${prune_old}" > "${prune_output}" \
    || ! prune_counts="$(head -n 1 "${prune_output}")" || [ -z "${prune_counts}" ]; then
    echo "${SCRIPT_NAME}: cannot process ${prune_todo} with ${SCRIPT_DIR}/prune-agent-todo.awk, so it was not pruned" >&2
    rm -f "${prune_old}" "${prune_output}"
    return 0
  fi
  prune_removed="${prune_counts% *}"
  prune_kept="${prune_counts#* }"
  # `tr` removes the carriage returns of CRLF line endings, and the command
  # substitution removes the final newline.
  prune_delete=0
  if [ "${prune_kept}" -eq 0 ]; then
    prune_rest="$(sed 1d "${prune_output}" | tr -d '\r')"
    if [ "${prune_rest}" = "${agent_todo_preamble}" ] \
      || [ "${prune_rest}" = "${agent_todo_preamble_without_merge}" ]; then
      prune_delete=1
    fi
  fi
  if [ "${prune_removed}" -eq 1 ]; then
    prune_what='1 entry that no longer applies'
  else
    prune_what="${prune_removed} entries that no longer apply"
  fi
  if [ "${prune_delete}" -eq 1 ]; then
    if [ "${prune_removed}" -eq 0 ]; then
      prune_why='which has no entry'
    else
      prune_why='whose entries no longer apply'
    fi
    if ! cmp -s "${prune_old}" "${prune_todo}"; then
      echo "${SCRIPT_NAME}: ${prune_todo} changed while it was being pruned, so it was not deleted" >&2
    elif rm -f "${prune_todo}"; then
      echo "${SCRIPT_NAME}: deleted ${prune_todo}, ${prune_why}" >&2
    else
      echo "${SCRIPT_NAME}: cannot delete ${prune_todo}, ${prune_why}" >&2
    fi
  elif [ "${prune_removed}" -gt 0 ]; then
    # The new file is a copy of the file, so that it keeps the file's
    # permissions, in the same directory, so that `mv` replaces the file
    # atomically.
    if ! prune_new="$(mktemp "${prune_top}/.${agent_todo_file}.XXXXXX")"; then
      echo "${SCRIPT_NAME}: cannot create a temporary file in ${prune_top}, so ${prune_todo} was not pruned" >&2
    elif ! cp -p "${prune_todo}" "${prune_new}" \
      || ! sed 1d "${prune_output}" > "${prune_new}"; then
      echo "${SCRIPT_NAME}: cannot write ${prune_new}, so ${prune_todo} was not pruned" >&2
      rm -f "${prune_new}"
    elif ! cmp -s "${prune_old}" "${prune_todo}"; then
      echo "${SCRIPT_NAME}: ${prune_todo} changed while it was being pruned, so it was not pruned" >&2
      rm -f "${prune_new}"
    elif mv -f "${prune_new}" "${prune_todo}"; then
      echo "${SCRIPT_NAME}: removed from ${prune_todo} ${prune_what}" >&2
    else
      echo "${SCRIPT_NAME}: cannot rewrite ${prune_todo} to remove ${prune_what}" >&2
      rm -f "${prune_new}"
    fi
  fi
  rm -f "${prune_old}" "${prune_output}"
  return 0
}

## Usage: merge_in_progress_note [REASON [UPSTREAM]]
## Prints a paragraph for an entry of AGENT-TODO.md that says that a merge is
## in progress in the current directory, the top level of a working tree.
## Its first line identifies the merge, as in "The merge of commit
## 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b is in progress in
## /home/me/myrepo-branch-feature."; then come REASON, such as "No conflicted
## file remains.", if it is given and not empty; then, if UPSTREAM is given
## and not empty, a line that says that the merge is probably redundant,
## because UPSTREAM, the name of the branch's upstream branch, such as
## "origin/feature", already contains both of its sides; and last, a line
## that says what to do, which is to abort the merge if it is redundant.
## Prints nothing if no merge is in progress.
merge_in_progress_note() {
  if ! note_merge_head="$(git rev-parse --verify --quiet MERGE_HEAD)"; then
    return 0
  fi
  printf 'The merge of commit %s is in progress in %s.\n' "${note_merge_head}" "$(pwd)"
  if [ -n "${1:-}" ]; then
    printf '%s\n' "$1"
  fi
  # The last line ends with "; then delete this entry.", by which
  # prune-agent-todo.awk recognizes the end of the paragraph.  The backquotes
  # are Markdown, not command substitutions.
  if [ -n "${2:-}" ]; then
    printf 'It is probably redundant:  %s, the upstream branch, already contains both of its sides.\n' "$2"
    # shellcheck disable=SC2016
    printf 'Unless its resolution has changes that %s lacks, abort it with `git merge --abort`, and run `%s` again; then delete this entry.\n' "$2" "${SCRIPT_NAME}"
  else
    # shellcheck disable=SC2016
    printf '%s\n' 'Finish it (resolve its conflicts and commit it), or abort it with `git merge --abort`; then delete this entry.'
  fi
}

## Usage: report_merge_in_progress [REASON [UPSTREAM [ADVICE]]]
## Appends to AGENT-TODO.md an entry that says that a merge is in progress in
## the current directory, the top level of a working tree, as
## `merge_in_progress_note` writes it, given REASON and UPSTREAM (see
## `append_agent_note`).  First removes each entry about a merge that is no
## longer in progress, and, unless ADVICE is "keep", each earlier entry about
## the same merge that says that running the script again suffices, whose
## advice is out of date (see `prune_agent_todo`).  ADVICE is "keep" when
## that advice still holds, as when the script refuses to start while the
## merge is in progress (see `refuse_merge_in_progress`).  Then does nothing
## if an entry of the file still has the note's first line, which identifies
## the merge, and its last line, which says what to do, as after an earlier
## run stopped at the same merge:  the earlier entry, such as one that asks a
## person for help, stays.  So an entry that says that a merge is redundant
## is appended even if an earlier entry, written before the merge was
## redundant, notes the same merge.  Does nothing if no merge is in
## progress.  Appends the note to the summary (see
## `append_merge_note_summary`) in each case.  Runs git commands, so it must
## not be called after an AI agent ran without its work being checked; see
## `report_agent_session`.
report_merge_in_progress() {
  report_merge_note="$(merge_in_progress_note "${1:-}" "${2:-}")"
  if [ -z "${report_merge_note}" ]; then
    return 0
  fi
  append_merge_note_summary "${report_merge_note}"
  report_merge_todo="$(agent_todo_path)" || report_merge_todo=''
  if [ "${3:-}" = keep ]; then
    prune_agent_todo 0
  else
    prune_agent_todo 0 merge
  fi
  # The awk program succeeds if an entry, which starts with a line "## ...",
  # has the line ${REPORT_FIRST} and then the line ${REPORT_LAST}.
  if [ -n "${report_merge_todo}" ] && [ -f "${report_merge_todo}" ] \
    && REPORT_FIRST="$(printf '%s\n' "${report_merge_note}" | head -n 1)" \
      REPORT_LAST="$(printf '%s\n' "${report_merge_note}" | tail -n 1)" \
      awk '/^## / { first = 0 }
        first && $0 == ENVIRON["REPORT_LAST"] { found = 1 }
        $0 == ENVIRON["REPORT_FIRST"] { first = 1 }
        END { exit !found }' "${report_merge_todo}"; then
    return 0
  fi
  if append_agent_note "${report_merge_todo}" 'Finish the merge in progress' "${report_merge_note}"; then
    echo "${SCRIPT_NAME}: noted the merge in progress in ${report_merge_todo}" >&2
  fi
}

## Usage: append_agent_note FILE TASK NOTE
## Appends to FILE, a file AGENT-TODO.md (see `append_agent_todo`), an entry
## under a heading that gives the first line of TASK, such as "Finish the
## merge in progress", and the time, whose text is NOTE, a paragraph such as
## `merge_in_progress_note` prints.  Returns 1, after printing a diagnostic,
## if it does not write FILE.  Runs no git command.
append_agent_note() {
  append_agent_note_task="$(printf '%s\n' "$2" | head -n 1)"
  append_agent_todo "$1" "
## ${append_agent_note_task} (${SCRIPT_NAME}, $(date '+%Y-%m-%d %H:%M:%S'))

$3
"
}

## Usage: stop_at_merge DIAGNOSTIC REASON [UPSTREAM]
## Prints DIAGNOSTIC, which says why the caller leaves the merge in progress
## in the current directory, the top level of a working tree.  If UPSTREAM,
## the name of the branch's upstream branch, such as "origin/feature", is
## given and not empty, then the merge is redundant (see
## `redundant_merge_upstream`):  DIAGNOSTIC does not say what
## to do, and this function then prints a diagnostic that says that the
## merge is probably redundant and should be aborted.  Otherwise DIAGNOSTIC
## says what to do.  Notes the merge in AGENT-TODO.md, with REASON, such as
## "No conflicted file remains.", and with UPSTREAM (see
## `report_merge_in_progress`).
stop_at_merge() {
  echo "$1" >&2
  if [ -n "${3:-}" ]; then
    echo "${SCRIPT_NAME}: the merge is probably redundant:  $3, the upstream branch, already contains both of its sides; unless its resolution has changes that $3 lacks, abort it with \`git merge --abort\`, and run \`${SCRIPT_NAME}\` again" >&2
  fi
  report_merge_in_progress "$2" "${3:-}"
}

## Usage: new_uuid
## Prints a new random UUID in lowercase, such as
## "1e55b89c-cfb5-468f-a783-cb104201809b", or prints nothing if this system
## cannot make one.
new_uuid() {
  if command -v uuidgen > /dev/null 2>&1; then
    new_uuid_value="$(uuidgen 2> /dev/null | tr 'A-F' 'a-f')"
  else
    new_uuid_value="$(cat /proc/sys/kernel/random/uuid 2> /dev/null)"
  fi
  if is_uuid "${new_uuid_value}"; then
    printf '%s\n' "${new_uuid_value}"
  fi
}

## Usage: is_uuid STRING
## Succeeds if STRING is a UUID in lowercase, such as
## "1e55b89c-cfb5-468f-a783-cb104201809b".
is_uuid() {
  printf '%s\n' "$1" \
    | grep -x -q '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}'
}

## Usage: codex_installation
## Prints the absolute pathname of the directory that contains Codex's
## programs:  the parent of the directory that contains the `codex` command
## on the PATH, after any symbolic links to that command are followed, such
## as "~/.codex/packages/standalone/releases/0.165.0-x86_64-unknown-linux-musl"
## for ".../bin/codex", or the `@openai/codex` package of an npm installation
## for ".../bin/codex.js".  Returns 1 if `codex` is not on the PATH.
codex_installation() {
  codex_installation_file="$(command -v codex)" || return 1
  codex_installation_links=0
  while [ -L "${codex_installation_file}" ]; do
    codex_installation_links=$((codex_installation_links + 1))
    if [ "${codex_installation_links}" -gt 40 ]; then return 1; fi
    codex_installation_link="$(readlink -- "${codex_installation_file}")" || return 1
    case "${codex_installation_link}" in
      /*) codex_installation_file="${codex_installation_link}" ;;
      *) codex_installation_file="$(dirname -- "${codex_installation_file}")/${codex_installation_link}" ;;
    esac
  done
  physical_path "$(dirname -- "${codex_installation_file}")/.."
}

## Usage: toml_string STRING
## Prints STRING as a TOML basic string, in quotation marks, such as
## "a\"b" for a"b.
toml_string() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

## Usage: git_control_state
## Prints a summary of what in the current repository names commands that git
## runs, or chooses among them:  git's configuration, including each file
## that it includes; the repository's `info/attributes` file; and its hooks
## that are outside the working tree.  The summary changes if any of them
## changes.  The current directory must be the top level of the working tree.
git_control_state() {
  # The configuration's values, rather than its files, are summarized, so
  # that a change to a file that the configuration includes, such as through
  # "include.path", changes the summary.
  git_control_config="$(git config --list)" || return 1
  printf '%s\n' "${git_control_config}" | cksum
  git_control_attributes="$(git rev-parse --path-format=absolute --git-path info/attributes)" || return 1
  if [ -f "${git_control_attributes}" ]; then
    cksum < "${git_control_attributes}"
  else
    echo "no ${git_control_attributes}"
  fi
  git_control_hooks="$(git rev-parse --path-format=absolute --git-path hooks)" || return 1
  if [ ! -d "${git_control_hooks}" ]; then
    return 0
  fi
  # A hook in the working tree, as with `core.hooksPath` ".githooks", is a
  # file of the working tree, which `resolve_with_agent` checks:  it rejects
  # an agent's change to such a hook unless the hook is a conflicted file,
  # whose conflicts the agent resolves.  So the summary omits the contents of a
  # directory of hooks in the working tree, and the contents of the file that
  # a hook links to.  A link is summarized by its target.
  git_control_hooks_physical="$(physical_path "${git_control_hooks}")" || return 1
  git_control_top="$(pwd -P)"
  case "${git_control_hooks_physical}/" in
    "${git_control_top}/.git/"*) ;;
    "${git_control_top}/"*)
      echo "hooks in the working tree: ${git_control_hooks}"
      return 0
      ;;
  esac
  # shellcheck disable=SC2016 # The inner shell expands ${link}.
  find "${git_control_hooks}" \( -type f -exec cksum {} + \) \
    -o \( -type l -exec sh -c 'for link; do printf "%s -> %s\n" "${link}" "$(readlink -- "${link}")"; done' sh {} + \) \
    -o -print | sort
}

## Usage: working_tree_hooks
## Prints the pathname, relative to the top level of the working tree, of
## the directory of git's hooks, if that directory is in the working tree but
## not in `.git`, as with `core.hooksPath` ".githooks"; prints "." if it is
## the top level itself; and prints nothing otherwise.  The directory need
## not exist.  The current directory must be the top level of the working
## tree.  Git resolves a symbolic link in `core.hooksPath`, so the pathname
## is that of the directory that the link leads to; `git_control_state`
## detects a change to such a link.
working_tree_hooks() {
  wth_hooks="$(git rev-parse --path-format=absolute --git-path hooks)" || return 0
  wth_physical="$(physical_path "${wth_hooks}" 2> /dev/null)" || wth_physical="${wth_hooks}"
  wth_physical="${wth_physical%/}"
  for wth_top in "$(pwd -P)" "$(pwd)"; do
    case "${wth_physical}/" in
      "${wth_top}/") echo "." ;;
      "${wth_top}/.git/"*) ;;
      "${wth_top}/"*) printf '%s\n' "${wth_physical#"${wth_top}"/}" ;;
      *) continue ;;
    esac
    return 0
  done
}

## Usage: build_logged LOG
## Runs `compile-project` in the current directory, writing its output, both
## standard output and standard error, to standard output and to the file LOG.
## Returns the exit status of `compile-project`.
build_logged() {
  # `tee` ignores SIGINT, so that after a Ctrl-C, it still copies the output
  # that `compile-project` prints when it is interrupted.
  { "${SCRIPT_DIR}"/compile-project 2>&1; echo "$?" > "$1.status"; } | (
    trap '' INT
    exec tee "$1"
  )
  build_logged_status="$(cat "$1.status")"
  return "${build_logged_status:-1}"
}

## Usage: fix_failed_build AGENT LOG MESSAGE ACCOUNT
## Asks the AI agent AGENT ("claude" or "codex") to fix the build of the
## current directory, the top level of a working tree, which failed with the
## output in the file LOG, without building; then builds again with
## `compile-project`, writing the output to LOG.  It makes up to
## ${build_fix_attempts} attempts.  The agent's instructions begin with
## ACCOUNT, which says what might have broken the build and which commands
## show it, such as "The script just merged commit 1a2b3c4d into branch
## feature.  Branch feature has commits that ...".  Once the build succeeds,
## commits the agent's changes, if any, with the message MESSAGE, such as
## "Fix the build after merging branch 'main'", and prints a notice that
## names the commit, for review (see `review_notice`).  If a pre-commit hook
## rejects the commit after changing files, builds again before committing
## the files as the hook left them (see `commit_staged`).  Returns 1, after
## printing a diagnostic, if the build still fails or the changes cannot be
## committed; the agent's changes then remain, staged but not committed.
## Returns 3 instead if `run_agent` returned 3 for the first attempt:  the
## agent failed each time without changing anything and is not ready to
## run, so nothing remains to review, and no session can be continued.
build_fix_attempts=3
fix_failed_build() {
  fix_with="$1"
  fix_log="$2"
  # No session is reported if this function fails before the agent runs.
  agent_session_ids=''
  # The agent's changes are committed below, and so would be any change that
  # the build made to tracked files.
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "${SCRIPT_NAME}: the build changed tracked files in $(pwd); fix the build by hand" >&2
    return 1
  fi
  fix_head="$(git rev-parse --verify HEAD)" || return 1
  fix_attempt=1
  fix_earlier=''
  while :; do
    if ! fix_untracked="$(untracked_files)"; then
      echo "${SCRIPT_NAME}: cannot list the untracked files of $(pwd)" >&2
      return 1
    fi
    fix_ignored="$(ignored_files)"
    if [ "${fix_attempt}" -gt 1 ]; then
      fix_earlier="

Earlier attempts to fix the build changed files, but the build still failed.  Their changes are staged; \`git diff --cached\` shows them."
    fi
    fix_prompt="You are fixing a failed build in the git working tree $(pwd).
$4  A script then built the project, which failed.  The end of the build output is below; the full output is in ${fix_log}.${fix_earlier}

Rules:

* Make the smallest change that fixes the build and that respects the intent of the current branch and of every branch merged into it.  Often, merging combined changes that do not fit together, such as a call to a method that another branch renamed.
* Do not disable, delete, or weaken tests, checks, or warnings to make the build pass.
* Do not run any git command that changes the index, HEAD, or any other ref, such as \`git add\`, \`git commit\`, \`git checkout\`, \`git restore\`, \`git reset\`, \`git merge\`, \`git stash\`, or \`git rebase\`.  The script commits your changes.
* Run commands in the current directory, which is the working tree, without \`cd\` or \`git -C\`.  A command in another form needs approval, which nobody is present to give.
* Do not build the project or run its tests; the script builds it after you finish.
* Do not create another working copy.
* If you cannot fix the build with confidence, change nothing, and say why.

Finish with a brief summary of the cause of the failure and of your fix.

The end of the build output:

$(tail -n 100 "${fix_log}")"
    echo "${SCRIPT_NAME}: asking ${fix_with} to fix the build in $(pwd) (attempt ${fix_attempt} of ${build_fix_attempts})" >&2
    run_agent "${fix_with}" "${fix_prompt}"
    fix_agent_status=$?
    if [ "${fix_agent_status}" -ne 0 ]; then
      # After a later attempt, the earlier attempts' changes remain staged.
      if [ "${fix_agent_status}" -eq 3 ] && [ "${fix_attempt}" -eq 1 ]; then
        return 3
      fi
      return 1
    fi
    if [ "$(git rev-parse --verify HEAD)" != "${fix_head}" ]; then
      echo "${SCRIPT_NAME}: ${fix_with} changed HEAD in $(pwd)" >&2
      return 1
    fi
    # Stage the agent's changes:  to tracked files, and the files that it
    # created.  The changes of earlier attempts are already staged.
    if ! fix_now_untracked="$(untracked_files)"; then
      echo "${SCRIPT_NAME}: cannot list the untracked files of $(pwd)" >&2
      return 1
    fi
    fix_new="$(printf '%s\n' "${fix_now_untracked}" | grep -F -x -v -- "${fix_untracked}")"
    # A file that git ignores would not be committed, but the build could use
    # it.
    fix_new_ignored="$(ignored_files | grep -F -x -v -- "${fix_ignored}")"
    if [ -n "${fix_new_ignored}" ]; then
      printf '%s\n' "${fix_new_ignored}" | sed -e "s/^/${SCRIPT_NAME}: ${fix_with} created a file that git ignores: /" >&2
      return 1
    fi
    if git diff --quiet && [ -z "${fix_new}" ]; then
      echo "${SCRIPT_NAME}: ${fix_with} did not fix the build in $(pwd); it changed nothing" >&2
      return 1
    fi
    if ! git add -u \
      || ! printf '%s\n' "${fix_new}" | while IFS= read -r fix_file; do
        if [ -n "${fix_file}" ]; then
          GIT_LITERAL_PATHSPECS=1 git add -- "${fix_file}" || exit 1
        fi
      done; then
      echo "${SCRIPT_NAME}: cannot stage the changes of ${fix_with} in $(pwd)" >&2
      return 1
    fi
    if git diff --cached --quiet; then
      echo "${SCRIPT_NAME}: ${fix_with} did not fix the build in $(pwd); its changes undo one another" >&2
      return 1
    fi
    if build_logged "${fix_log}"; then
      break
    fi
    echo "${SCRIPT_NAME}: unable to build in $(pwd)" >&2
    # The next attempt's changes are staged with \`git add -u\`, which would
    # also stage any change that the build made.
    if ! git diff --quiet; then
      echo "${SCRIPT_NAME}: the build changed tracked files in $(pwd); fix the build by hand" >&2
      return 1
    fi
    if [ "${fix_attempt}" -ge "${build_fix_attempts}" ]; then
      echo "${SCRIPT_NAME}: ${fix_with} did not fix the build in $(pwd) in ${build_fix_attempts} attempts; its changes are staged" >&2
      return 1
    fi
    fix_attempt=$((fix_attempt + 1))
  done
  # A pre-commit hook that changes the files is followed by another build.
  if ! commit_staged "$3" "${SCRIPT_DIR}"/compile-project; then
    echo "${SCRIPT_NAME}: cannot commit the changes of ${fix_with} in $(pwd)" >&2
    return 1
  fi
  review_notice "${fix_with} fixed the build in commit $(git rev-parse --short HEAD); review it"
  return 0
}

## The AI agent that the commands ask to resolve merge conflicts and to fix a
## failed build:  "claude", "codex", or empty for none.  `parse_llm_option`
## sets it.
llm_agent=claude
## The AI agent that "--llm" turns on.  `parse_llm_option` sets it.
llm_choice=claude
## The usage of the options that `parse_llm_option` recognizes.
# shellcheck disable=SC2034 # used by the commands that source this file
llm_options_usage='[--llm | --no-llm] [--claude | --codex]'

## Usage: parse_llm_option OPTION
## Returns 0, after setting ${llm_agent}, if OPTION chooses the AI agent:
## "--claude" and "--codex" choose it and turn it on, "--no-llm" turns it off,
## and "--llm" turns it on.  The agent that "--llm" turns on is the one that
## the last "--claude" or "--codex" chose, or Claude if neither was given.
## Returns 1 if OPTION is not one of those.
# shellcheck disable=SC2034 # llm_agent is used by the commands that source this file
parse_llm_option() {
  case "$1" in
    --llm) llm_agent="${llm_choice}" ;;
    --no-llm) llm_agent='' ;;
    --claude | --codex)
      llm_choice="${1#--}"
      llm_agent="${llm_choice}"
      ;;
    *) return 1 ;;
  esac
  return 0
}
