# shellcheck shell=sh

# Functions that resolve the conflicts of a merge in progress, with
# `git rerere` or an AI agent, and that check each resolution.
#
# `common-functions.sh` sources this file.  A script uses these functions by
# sourcing that file, which says what the script must set first.

## Usage: check_conflict_resolution FILE CONTAINS_SEPARATOR [MARKER_SIZE]
## Checks the resolution of the conflicts in FILE against AUTO_MERGE, the git
## ref that names git's automatic merge, which contains the conflict markers:
## returns 0 if the text outside the conflict regions is unchanged and no
## conflict marker remains, and returns 1 otherwise.  This check suits a
## resolution that `git rerere` made, which changes only the conflict
## regions; an AI agent can change any text (see `check_agent_resolution`).
## Prints a diagnostic for each problem.  check-conflict-resolution.awk
## states exactly what is acceptable.  FILE is a pathname relative to the top
## level of the working tree, which must be the current directory.
## CONTAINS_SEPARATOR is "yes" if HEAD's or MERGE_HEAD's version of FILE
## contains a line of 7 or more "=", such as "=======",
## which can then be content in the resolution, such as a Markdown heading's
## underline, rather than a conflict marker; and "no" otherwise.
## MARKER_SIZE is the length of FILE's conflict markers, as
## `conflict_marker_size` prints it; it is computed if it is not given.
##
## This compares content rather than the hunks of `git diff`, which can put a
## change on either of two identical lines, one inside a region and one
## outside it.
check_conflict_resolution() {
  if [ ! -f "$1" ]; then
    echo "${SCRIPT_NAME}: $1: the file was deleted" >&2
    return 1
  fi

  # This function passes FILE in AUTO_MERGE to the awk program
  # check-conflict-resolution.awk as MERGED, on standard input, and FILE in
  # the working tree as RESOLVED.  The "./" keeps awk from taking a
  # FILE such as "x=y" for a variable assignment.  `--filters` converts
  # AUTO_MERGE's file as a checkout would, such as to CRLF line endings, to
  # match the working tree.
  #
  # awk does not tell whether the last line of its input ends with a newline.
  # So `echo` appends a newline to AUTO_MERGE's file, whose last line as awk
  # reads it is then empty if and only if the file ends with a newline.
  # Whether the working tree's file ends with a newline is passed to the
  # checking program separately.
  check_conflict_ends_with_newline=yes
  if ! ends_with_newline < "$1"; then
    check_conflict_ends_with_newline=no
  fi

  check_conflict_marker_size="${3:-$(conflict_marker_size "$1")}"
  {
    git cat-file --filters "AUTO_MERGE:$1"
    echo
  } | CCR_FILE="$1" CCR_SCRIPT_NAME="${SCRIPT_NAME}" \
    CCR_RESOLVED_ENDS_WITH_NEWLINE="${check_conflict_ends_with_newline}" \
    CCR_CONTAINS_SEPARATOR="$2" CCR_MARKER_SIZE="${check_conflict_marker_size}" \
    awk -f "${SCRIPT_DIR}/check-conflict-resolution.awk" - "./$1"
}

## Usage: conflict_marker_size FILE
## Prints the length of the conflict markers that git wrote in FILE, a
## pathname relative to the top level of the working tree, in AUTO_MERGE,
## such as 7 for "<<<<<<<", or 0 if FILE in AUTO_MERGE has no conflict
## region, as when FILE has a conflict other than a content conflict.
## check-conflict-resolution.awk, under CCR_PRINT_MARKER_SIZE, says how.
##
## The attribute `conflict-marker-size` sets the length, but git applies the
## attributes from before the merge, so the attributes in the working tree,
## which the merge can change, do not tell what git wrote.
conflict_marker_size() {
  git cat-file blob "AUTO_MERGE:$1" 2> /dev/null \
    | CCR_PRINT_MARKER_SIZE=yes awk -f "${SCRIPT_DIR}/check-conflict-resolution.awk" -
}

## Usage: scan_conflict_markers BLOB [MARKER_SIZE]
## Prints "marker" if BLOB, a blob such as ":1:file.txt", has a line that
## looks like a conflict marker, or else "separator" if it has a line of 7
## or more "=", or else nothing.  check-conflict-resolution.awk, under
## CCR_SCAN, says which lines look like conflict markers; MARKER_SIZE, if it
## is given and not empty, is the length of the conflict markers in the
## file's conflict regions, as `conflict_marker_size` prints it.
scan_conflict_markers() {
  git cat-file blob "$1" 2> /dev/null \
    | CCR_SCAN=yes CCR_MARKER_SIZE="${2-}" awk -f "${SCRIPT_DIR}/check-conflict-resolution.awk" -
}

## Usage: ends_with_newline
## Succeeds if standard input is empty or ends with a newline.
ends_with_newline() {
  # Command substitution removes a final newline, so the last character of
  # input that ends with one is empty.
  [ -z "$(tail -c 1)" ]
}

## Usage: resolve_merge_conflicts RESOLVER COMMIT SOURCE
## Resolves the conflicts of the merge of COMMIT that is in progress in the
## current directory, the top level of a working tree, and stages the result.
## Conflicts that `git rerere` has already resolved need no more work.  For
## any others, this function asks an AI agent, RESOLVER ("claude" or
## "codex"), to resolve them, or fails if RESOLVER is empty or cannot be run.
## The agent can edit any part of any file, not just the conflict regions
## (see `resolve_with_agent`).  This function checks each resolution that
## `git rerere` made with `check_conflict_resolution`, and the agent's work
## with `check_agent_resolution`.  SOURCE names COMMIT in diagnostics and in the
## agent's instructions.  Returns 1, after printing a diagnostic, on failure,
## and leaves the merge in progress, which it notes in AGENT-TODO.md, with
## the command that continues the agent's session if one ran (see
## `report_merge_in_progress` and `report_agent_session`).  Before any agent
## runs, it records the conflicted files (see `record_conflicted_files`).
## If the agent is not ready to run, or fails without changing anything each
## time that it runs and then is not ready to run (see `run_agent`), the note
## says how to have it try again instead of asking for a person's help (see
## `resolve_rerun_advice`).
## The merge must have been made with
## `rerere.autoUpdate` false, so that the index lists every conflicted file as
## unmerged, including each one that rerere resolved.
##
## Only content conflicts are resolved, in which every conflicted file
## contains conflict markers.  For any other conflict, such as a file that one
## side modified and the other deleted, no check could tell whether the agent
## chose well.  Also refused are a file whose versions contain lines that look
## like conflict markers, other than the longer markers that git puts in the
## merge of several merge bases, and a working tree with changes other than
## the conflicted files, which would be committed with them.
resolve_merge_conflicts() {
  rmc_with="$1"
  rmc_commit="$2"
  rmc_source="$3"
  rmc_failed="${SCRIPT_NAME}: the merge of ${rmc_source} is still in progress in $(pwd)"

  # The checks compare the working tree with AUTO_MERGE, so an agent that
  # changed it would defeat them; `resolve_with_agent` checks that it did not.
  if ! rmc_auto_merge="$(git rev-parse --verify --quiet AUTO_MERGE)"; then
    echo "${SCRIPT_NAME}: no AUTO_MERGE, which git 2.42 and later write, in $(pwd)" >&2
    resolve_stopped
    return 1
  fi
  if ! rmc_head="$(git rev-parse --verify HEAD)" \
    || ! rmc_merge_head="$(git rev-parse --verify --quiet MERGE_HEAD)" \
    || [ "${rmc_merge_head}" != "$(git rev-parse --verify --quiet "${rmc_commit}^{commit}")" ]; then
    echo "${SCRIPT_NAME}: no merge of ${rmc_source} is in progress in $(pwd)" >&2
    return 1
  fi

  # The conflicted files, one per line.  `conflicted_files` replaces each
  # newline within a pathname by the byte 001, so the `case` below detects
  # and refuses any conflicted file whose name contains a newline.
  if ! rmc_conflicted="$(conflicted_files)" || [ -z "${rmc_conflicted}" ]; then
    echo "${SCRIPT_NAME}: cannot list the conflicted files in $(pwd)" >&2
    resolve_stopped
    return 1
  fi
  case "${rmc_conflicted}" in
    *"$(printf '\001')"*)
      echo "${SCRIPT_NAME}: a conflicted file has a newline in its name; resolve the conflicts by hand" >&2
      resolve_stopped
      return 1
      ;;
  esac
  # Any other change would be blamed on the agent below, or committed.
  if ! rmc_other="$(resolve_other_changes "${rmc_conflicted}")"; then
    echo "${SCRIPT_NAME}: cannot list the changed files in $(pwd)" >&2
    resolve_stopped
    return 1
  fi
  if [ -n "${rmc_other}" ]; then
    printf '%s\n' "${rmc_other}" | sed -e "s/^/${SCRIPT_NAME}: changed, but not conflicted: /" >&2
    echo "${SCRIPT_NAME}: the working tree has changes that are not part of the merge; resolve the conflicts by hand" >&2
    resolve_stopped
    return 1
  fi

  # Checks each conflicted file, and lists each one that `git rerere` did not
  # resolve acceptably.
  #
  # Neither `check_conflict_resolution` nor `check_conflict_markers` can tell
  # a conflict marker from a line of the file that looks like one, as in a
  # test of merging, so such a file is refused.  The sides are the versions
  # of the file that the merge combined, which the index holds as stages 1
  # (the merge base), 2 (HEAD), and 3 (MERGE_HEAD).  Each stage is under the
  # conflicted pathname even if a side has the file under another name,
  # before or after a rename.  The merge base matters too, because a merge
  # with `merge.conflictStyle` "diff3" puts its text in the conflict regions.
  # With several merge bases, as after criss-cross merges, stage 1 is their
  # merge, which can itself contain conflict markers.  Git makes those
  # markers longer than the file's own, such as
  # "<<<<<<<<< Temporary merge branch 1", and check-conflict-resolution.awk
  # takes such a line in a conflict region for part of the region's text.
  # A resolution keeps none of them, because neither side contains one.  So
  # in stage 1, only a line that would start or end a conflict region of the
  # file's own marker length (see `conflict_marker_size`) makes the file
  # refused.  The
  # merge of the merge bases also copies in text from their own merge base,
  # a deeper ancestor, so that check covers that text too.  A line of 7 or
  # more "=", such as "=======", in HEAD's or MERGE_HEAD's version is
  # content, so `check_conflict_resolution` and `check_conflict_markers`
  # permit such a line in the resolution.  (Git writes a separator of more
  # than 7 "=" for a file whose attribute `conflict-marker-size` is larger.)
  #
  # check-conflict-resolution.awk, under CCR_SCAN, reports whether a stage
  # has a line that looks like a conflict marker, or else a line of 7 or
  # more "=".  For stages 2 and 3, the definition of a conflict marker is
  # looser than that of the check of a resolution, so that it refuses every
  # file that contains a line that might be taken for one.
  # ${rmc_checks} has a line "separator FILE" for each conflicted file
  # in which a line of 7 or more "=" is permitted, and a line
  # "unresolved FILE" for each one that `git rerere` did not resolve
  # acceptably.
  if ! rmc_checks="$(printf '%s\n' "${rmc_conflicted}" | {
    rmc_status=0
    while IFS= read -r rmc_conflicted_file; do
      rmc_size="$(conflict_marker_size "${rmc_conflicted_file}")"
      if [ "${rmc_size}" -eq 0 ]; then
        echo "${SCRIPT_NAME}: ${rmc_conflicted_file} has a conflict other than a content conflict; resolve it by hand" >&2
        rmc_status=1
        continue
      fi
      rmc_contains_separator=no
      for rmc_stage in 1 2 3; do
        # Only stage 1 is scanned for markers of length ${rmc_size}.
        rmc_scan_size=''
        if [ "${rmc_stage}" -eq 1 ]; then
          rmc_scan_size="${rmc_size}"
        fi
        # The "(" before each pattern lets bash 3.2, which is /bin/sh on
        # macOS, parse a case statement inside a command substitution.
        case "$(scan_conflict_markers ":${rmc_stage}:${rmc_conflicted_file}" "${rmc_scan_size}")" in
          (marker)
            echo "${SCRIPT_NAME}: ${rmc_conflicted_file} contains lines that look like conflict markers; resolve its conflicts by hand" >&2
            rmc_status=1
            continue 2
            ;;
          (separator)
            if [ "${rmc_stage}" -ne 1 ]; then
              rmc_contains_separator=yes
            fi
            ;;
        esac
      done
      if [ "${rmc_contains_separator}" = yes ]; then
        printf 'separator %s\n' "${rmc_conflicted_file}"
      fi
      if check_conflict_resolution "${rmc_conflicted_file}" "${rmc_contains_separator}" "${rmc_size}" 2> /dev/null; then
        continue
      fi
      # A file without a conflict region was resolved by `git rerere`, but
      # not acceptably, as when the recorded resolution changed text outside
      # the conflict regions.  An agent would see no conflict to resolve, and
      # the check of its work would not find what is wrong.
      if [ -f "${rmc_conflicted_file}" ] && ! grep -q '^<<<<<<<' "${rmc_conflicted_file}"; then
        check_conflict_resolution "${rmc_conflicted_file}" "${rmc_contains_separator}" "${rmc_size}" || true
        echo "${SCRIPT_NAME}: \`git rerere\` did not resolve ${rmc_conflicted_file} acceptably; resolve its conflicts by hand" >&2
        rmc_status=1
        continue
      fi
      printf 'unresolved %s\n' "${rmc_conflicted_file}"
    done
    exit "${rmc_status}"
  })"; then
    resolve_stopped
    return 1
  fi
  # The files in which a line of 7 or more "=" is permitted, one per line;
  # `separator_permitted` reads it.
  rmc_separators="$(printf '%s\n' "${rmc_checks}" | sed -n -e 's/^separator //p')"
  # The files that `git rerere` did not resolve, one per line.
  rmc_unresolved="$(printf '%s\n' "${rmc_checks}" | sed -n -e 's/^unresolved //p')"
  # Before an agent edits them, so that a later run can tell whether anyone
  # changed them after this one stopped.
  record_conflicted_files

  if [ -z "${rmc_unresolved}" ]; then
    echo "${SCRIPT_NAME}: \`git rerere\` resolved the conflicts in $(pwd)" >&2
  elif [ -z "${rmc_with}" ]; then
    report_unresolved "${rmc_unresolved}"
    resolve_stopped
    return 1
  elif ! agent_available "${rmc_with}"; then
    report_unresolved "${rmc_unresolved}"
    resolve_stopped "${agent_unavailable_reason:+${agent_unavailable_reason}  $(resolve_rerun_advice)}"
    return 1
  else
    # The notes are composed before the agent runs, because no git command
    # should run after an agent has changed git's configuration, which
    # `resolve_with_agent` reports as ${rwa_agent_status} 2.
    # The entry in AGENT-TODO.md is read by a person or by a later agent,
    # which should not try alone what this agent could not do.
    rmc_agent_reason="${rmc_with}, an AI agent, could not resolve the merge's conflicts acceptably.  Ask a person for help with them before you finish the merge."
    rmc_note="$(merge_in_progress_note "${rmc_agent_reason}")"
    # An earlier entry that says that running the script again suffices is
    # out of date once the agent runs:  its outcome writes a new entry, or
    # the merge is committed.
    prune_agent_todo 0 merge
    rwa_agent_status=0
    # 1 once `resolve_with_agent` has started the agent.  If it failed
    # before then, a rerun can succeed, so the note asks for no help.
    rwa_agent_ran=0
    if ! resolve_with_agent; then
      # An agent that `run_agent` reports as status 3 tried nothing that a
      # person must take over, and it left no session to continue, so the
      # note is written by `resolve_stopped`.  Composing that note runs git
      # commands, which are safe after status 3.
      if [ "${rwa_agent_status}" -eq 3 ]; then
        rmc_agent_reason="$(agent_unchanged_reason "${rmc_with}")  $(resolve_rerun_advice)"
      fi
      if [ -n "${agent_session_ids:-}" ]; then
        report_agent_session "Resolve the conflicts in the merge of ${rmc_source}" "${rmc_note}"
        echo "${rmc_failed}" >&2
      elif [ "${rwa_agent_status}" -ne 2 ] && [ "${rwa_agent_ran}" -eq 1 ]; then
        resolve_stopped "${rmc_agent_reason}"
      elif [ "${rwa_agent_status}" -ne 2 ]; then
        resolve_stopped
      else
        echo "${rmc_failed}" >&2
      fi
      return 1
    fi
  fi

  # `git add -u` stages every change to a tracked file:  the resolution of
  # each conflicted file, and each other change that the agent made.  Before
  # the agent ran, no tracked file other than the conflicted ones differed
  # from AUTO_MERGE.
  if ! git add -u \
    || [ -n "$(git ls-files -u)" ]; then
    echo "${SCRIPT_NAME}: cannot stage the resolved files in $(pwd)" >&2
    resolve_stopped
    return 1
  fi
  return 0
}

## 1 if running the command again finishes a merge that it leaves in progress
## in the current directory, as `git-push-to` does for its TO_DIR, and 0 if
## running it again refuses to start while the merge is in progress.
rerun_finishes_merge=0

## Usage: resolve_rerun_advice
## For `resolve_merge_conflicts`:  prints a sentence for an entry of
## AGENT-TODO.md that says how to have the AI agent ${rmc_with} resolve
## the conflicts of the merge in progress once it can run (see
## `agent_rerun_advice`).  If ${rerun_finishes_merge} is 1, running this
## script again finishes the merge in progress in the current directory;
## otherwise, running it again refuses to start while the merge is in
## progress, so the sentence says to abort the merge first.
resolve_rerun_advice() {
  if [ "${rerun_finishes_merge}" -eq 1 ]; then
    agent_rerun_advice "${rmc_with}" 'resolve the conflicts'
  else
    # The backquotes are Markdown, not a command substitution.
    # shellcheck disable=SC2016
    agent_rerun_advice "${rmc_with}" 'resolve the conflicts' 'abort the merge with `git merge --abort`'
  fi
}

## Usage: resolve_stopped [REASON]
## For `resolve_merge_conflicts`, which is leaving the merge in progress:
## says so, and notes the merge in AGENT-TODO.md, given REASON (see
## `report_merge_in_progress`).
resolve_stopped() {
  echo "${rmc_failed}" >&2
  report_merge_in_progress "${1:-}"
}

## Usage: resolve_with_agent
## Asks the AI agent ${rmc_with} to resolve the conflicts in the files
## ${rmc_unresolved}, and checks its work.  Returns 1, after printing a
## diagnostic, if the agent fails or if its work is not acceptable.  Only
## `resolve_merge_conflicts` calls this function, which reads that function's
## variables.
##
## The agent can change any part of any file that git tracks, not just the
## conflict regions:  git's automatic merge of the text outside them, and of
## the files without conflicts, can combine changes that do not fit together,
## such as a call to a method that the other side renamed.  It can also
## change a conflicted file that `git rerere` resolved, and delete a file that
## git tracks.  Any other change is rejected:  to the index, to HEAD or
## MERGE_HEAD, to git's configuration or hooks, or to any file that git does
## not track, whether untracked or ignored, including the creation of a file.
## A file that git does not track would not be committed, but a later build
## could use it.  A created file is rejected rather than committed, because
## a command that the agent runs can create files as a side effect, such as
## a cache of compiled code, which would then be committed and pushed.  A hook in the working tree, as with
## `core.hooksPath` ".githooks", can be changed only if it is a conflicted
## file, because the commit of the merge runs it outside the agent's
## sandbox.  But the agent can change a tracked file that a hook or the build
## reads or runs, such as prek.toml, .pre-commit-config.yaml, a script that
## a hook calls, or a Makefile; the commit and the build then run that code
## outside the sandbox.  The build-fix agent can do the same (see
## `fix_failed_build`).  Each conflicted file must be acceptably resolved (see
## `check_agent_resolution`), and no other file that the agent changed or
## created can contain a conflict marker line that AUTO_MERGE's version of
## it lacks (see `check_added_markers`).
resolve_with_agent() {
  # No session is reported if this function fails before the agent runs.
  agent_session_ids=''
  # The index is compared by its contents.  The working tree, which can hold
  # many large files, such as build output, is compared by its pathnames and
  # by the time at which each file last changed (its "ctime").  Unlike a
  # file's modification time, an unprivileged process cannot set its ctime.
  # A file changed since the marker file was written if its ctime is later
  # than the marker's modification time.  The marker is in the git
  # directory, which neither agent can write, so the agent cannot change the
  # marker's time.  The agent starts only once the working tree's file
  # system records a later time than the marker's, so that a file that it
  # changes has a later ctime.  The working tree and the git directory can
  # be on different file systems.  The working tree's pathnames are listed
  # after the wait, which creates a directory in the working tree and then
  # removes it.
  rwa_index="$(index_digest)"
  if ! rwa_marker="$(git rev-parse --path-format=absolute --git-path manage-git-branches-agent-start)" \
    || ! : > "${rwa_marker}"; then
    echo "${SCRIPT_NAME}: cannot write a file in the git directory of $(pwd)" >&2
    return 1
  fi
  if ! wait_for_later_time "${rwa_marker}" "$(pwd)"; then
    rm -f -- "${rwa_marker}"
    return 1
  fi
  rwa_paths="$(working_tree_paths)"
  # The files that git tracks, which the agent can change or delete.  `-z`
  # keeps git from quoting a pathname, as it quotes one that contains a
  # quotation mark.  `print_nul_lines` turns each newline within a pathname
  # into the byte 001, so that such a pathname matches no file, and a change
  # to that file is rejected.  The index holds a conflicted file at several
  # stages, and `--deduplicate`, which needs git 2.31, lists it once.
  if ! rwa_tracked="$(print_nul_lines git ls-files -z --deduplicate)"; then
    echo "${SCRIPT_NAME}: cannot list the files that git tracks in $(pwd)" >&2
    rm -f -- "${rwa_marker}"
    return 1
  fi
  # Git runs a hook when the script commits, outside the agent's sandbox.
  rwa_hooks="$(working_tree_hooks)"
  rwa_branch="$(current_branch)" || rwa_branch="HEAD"
  # The conflicted files that `git rerere` resolved, one per line.
  rwa_rerere="$(printf '%s\n' "${rmc_conflicted}" | grep -F -x -v -- "${rmc_unresolved}")"
  # A line "HASH FILE" for each of them, where HASH is the hash of the
  # resolution, as `git hash-object` computes it, such as
  # "3b18e512dba79e4c8300dd08aeb37f8e728b8dad".  `rerere_resolution_unchanged`
  # reads it to tell whether the agent changed the resolution.
  rwa_rerere_hashes="$(printf '%s\n' "${rwa_rerere}" | while IFS= read -r rwa_conflicted_file; do
    if [ -n "${rwa_conflicted_file}" ]; then
      printf '%s %s\n' "$(git hash-object -- "${rwa_conflicted_file}")" "${rwa_conflicted_file}"
    fi
  done)"
  rwa_rerere_text=''
  if [ -n "${rwa_rerere}" ]; then
    rwa_rerere_text="
\`git rerere\` resolved the conflicts in these files, by replaying resolutions that were recorded earlier.  Review them as part of the merge too:

$(printf '%s\n' "${rwa_rerere}" | sed -e 's/^/  /')
"
  fi
  # The general procedure is in a file that a person can use too, such as by
  # naming it in an agent's instructions.  The rules that follow it are
  # specific to this script.
  if ! rwa_instructions="$(cat -- "${SCRIPT_DIR}/merge-conflict-instructions.md")"; then
    echo "${SCRIPT_NAME}: cannot read ${SCRIPT_DIR}/merge-conflict-instructions.md" >&2
    rm -f -- "${rwa_marker}"
    return 1
  fi
  rwa_prompt="You are resolving merge conflicts in the git working tree $(pwd).
\`git merge\` of ${rmc_source} into branch ${rwa_branch} stopped with conflicts.  HEAD is ${rwa_branch}, and MERGE_HEAD is ${rmc_source}.  These files contain conflict markers:

$(printf '%s\n' "${rmc_unresolved}" | sed -e 's/^/  /')
${rwa_rerere_text}
Follow the instructions below, which are the contents of the file merge-conflict-instructions.md; you need not read that file, or use a skill, to resolve these conflicts.  They override any other instructions that you have about resolving merge conflicts, such as a rule to change only the conflict regions.  After them come rules for this session, which nobody is watching.

${rwa_instructions}

# Rules for this session

* Do not run any git command that changes the index, HEAD, or any other ref, such as \`git add\`, \`git rm\`, \`git mv\`, \`git commit\`, \`git checkout\`, \`git restore\`, \`git reset\`, \`git merge\`, \`git stash\`, or \`git rebase\`.  A script stages your changes and commits the merge after you finish.
* Run commands in the current directory, which is the working tree, without \`cd\` or \`git -C\`.  A command in another form needs approval, which nobody is present to give.
* Do not build the project or run its tests; the script does that.
* Do not create another working copy, do not create any file, and do not change any file that git does not track.  The script rejects the resolution if any new file appears, even as a side effect of a command that you run.  If combining the two sides requires a new file, leave the related conflict markers in place, and say so.
* The script rejects the resolution if a conflict marker line remains, or if any file that you change contains a conflict marker line that git's merge did not put there.
* If you cannot resolve a conflict with confidence, leave its conflict markers in place, and say why.

Finish with a summary that says, for each conflict, what each side changed and how your resolution combines the changes; and that lists each change that you made outside the conflict regions, and why."

  echo "${SCRIPT_NAME}: asking ${rmc_with} to resolve the conflicts in $(pwd)" >&2
  rwa_agent_ran=1
  # `run_agent` uses the same marker and pathnames to tell whether a failed
  # attempt changed anything.
  run_agent "${rmc_with}" "${rwa_prompt}" "${rwa_marker}" "${rwa_paths}"
  rwa_agent_status=$?
  # The files that the agent can change or delete:  the tracked files, except
  # a hook in the working tree, unless it is conflicted.  A file that existed before, but
  # that git ignored until the agent changed .gitignore, is neither a change
  # nor committed.
  rwa_changes="$( {
    printf '%s\n' "${rwa_tracked}" | RESOLVE_HOOKS="${rwa_hooks}" awk '
      ENVIRON["RESOLVE_HOOKS"] == "" { print; next }
      ENVIRON["RESOLVE_HOOKS"] != "." && index($0, ENVIRON["RESOLVE_HOOKS"] "/") != 1'
    printf '%s\n' "${rmc_conflicted}"
  } | working_tree_changes "${rwa_paths}" "${rwa_marker}")"
  rm -f -- "${rwa_marker}"

  # Check the agent's work even if the agent failed, so that the user learns
  # of every change that it made.
  rwa_ok=1
  if [ -n "${rwa_changes}" ]; then
    printf '%s\n' "${rwa_changes}" | while IFS= read -r rwa_change; do
      review_notice "${rmc_with} ${rwa_change}"
    done
    rwa_ok=0
  fi
  if [ "${rwa_agent_status}" -eq 2 ]; then
    # The agent changed what names the commands that git runs, so no git
    # command runs until someone has checked it.
    return 1
  fi
  rwa_refs_ok=1
  if [ "$(git rev-parse --verify HEAD)" != "${rmc_head}" ] \
    || [ "$(git rev-parse --verify --quiet MERGE_HEAD)" != "${rmc_merge_head}" ] \
    || [ "$(git rev-parse --verify --quiet AUTO_MERGE)" != "${rmc_auto_merge}" ]; then
    review_notice "${rmc_with} changed HEAD, MERGE_HEAD, or AUTO_MERGE"
    rwa_refs_ok=0
    rwa_ok=0
  fi
  if [ "$(index_digest)" != "${rwa_index}" ]; then
    review_notice "${rmc_with} changed the index"
    rwa_ok=0
  fi
  # The agent's changes outside the conflict regions deserve the user's
  # review, as the resolutions do.  They are reported whether or not the
  # agent's work is accepted:  a rejected agent's changes remain in the
  # working tree.  The changes to the conflicted files outside their
  # conflict regions are found by the check that a resolution from
  # `git rerere` must pass; a file that still has conflict markers fails it
  # anyway, so it is not reported.  A change to a resolution that
  # `git rerere` made is reported wherever it is.  So is a resolution by the
  # agent that is one side's version of the file, unless that side already
  # contains the other side's changes to it (see `one_sided_description`).
  # Each other file that the agent changed is also checked for conflict
  # markers, as when the agent copied a conflict region into it.
  # The conflicted files that the agent resolved as one side's version of
  # the file, one per line.  No conflicted pathname contains a newline,
  # which `resolve_merge_conflicts` refuses.
  rwa_one_sided_files=''
  # The conflicted files that `git rerere` resolved and whose resolution the
  # agent changed or deleted, one per line.
  rwa_rerere_changed=''
  if [ "${rwa_refs_ok}" -eq 1 ]; then
    # The agent's work is rejected if the files that it changed cannot be
    # listed, and so cannot be checked.
    if ! rwa_agent_other="$(resolve_other_changes "${rmc_conflicted}")"; then
      echo "${SCRIPT_NAME}: cannot list the files that ${rmc_with} changed in $(pwd)" >&2
      rwa_ok=0
    fi
    printf '%s\n' "${rwa_agent_other}" | while IFS= read -r rwa_other_file; do
      if [ -n "${rwa_other_file}" ]; then
        review_notice "${rmc_with} also changed: ${rwa_other_file}"
      fi
    done
    # The loop runs in this shell, not in a pipe's subshell, so that its
    # assignments last.  The shell splits ${rmc_conflicted} on newlines,
    # with globbing off so that no pathname is expanded; the body restores
    # both.  It hashes each file once.
    rwa_saved_ifs="${IFS}"
    IFS='
'
    set -f
    for rwa_conflicted_file in ${rmc_conflicted}; do
      set +f
      IFS="${rwa_saved_ifs}"
      # `git hash-object` fails for a file that the agent deleted.
      rwa_hash="$(git hash-object -- "${rwa_conflicted_file}" 2> /dev/null)" || rwa_hash=''
      if [ -n "${rwa_hash}" ] \
        && rerere_resolution_unchanged "${rwa_conflicted_file}" "${rwa_hash}"; then
        continue
      fi
      if printf '%s\n' "${rwa_rerere}" | grep -F -x -q -- "${rwa_conflicted_file}"; then
        rwa_rerere_changed="${rwa_rerere_changed}${rwa_conflicted_file}
"
      fi
      if [ -n "${rwa_hash}" ]; then
        # `one_sided_description` runs in this shell, not in a command
        # substitution's subshell, so that the merge bases that
        # `changes_present_merge_base` caches last from one file to the next.
        if one_sided_description "${rwa_conflicted_file}" "${rwa_hash}"; then
          rwa_one_sided_status=0
        else
          rwa_one_sided_status="$?"
        fi
        if [ "${rwa_one_sided_status}" -ne 1 ]; then
          rwa_one_sided_files="${rwa_one_sided_files}${rwa_conflicted_file}
"
        fi
        # A resolution whose side already contains the other side's changes
        # needs no review, so it is reported only as a diagnostic.
        case "${rwa_one_sided_status}" in
          0) review_notice "${osd_description}; review it" ;;
          2) printf '%s\n' "${SCRIPT_NAME}: ${osd_description}" >&2 ;;
        esac
      fi
    done
    set +f
    IFS="${rwa_saved_ifs}"
    # `git rerere` does not record a resolution that is one side's version
    # (see `rerere_skip_files`), whether or not the agent's work is
    # accepted:  after a rejection, a person who finishes the merge might
    # keep it.
    rerere_skip_files "${rwa_one_sided_files}"
    printf '%s\n' "${rmc_unresolved}" | while IFS= read -r rwa_conflicted_file; do
      rwa_file_separator="$(separator_permitted "${rwa_conflicted_file}")"
      # A resolution that is one side's version drops the other side's
      # changes outside the conflict regions too; it is reported once.
      if [ -f "${rwa_conflicted_file}" ] \
        && check_conflict_markers "${rwa_conflicted_file}" "${rwa_file_separator}" 2> /dev/null \
        && ! printf '%s\n' "${rwa_one_sided_files}" | grep -F -x -q -- "${rwa_conflicted_file}" \
        && ! check_conflict_resolution "${rwa_conflicted_file}" "${rwa_file_separator}" 2> /dev/null; then
        review_notice "${rmc_with} changed text outside the conflict regions of ${rwa_conflicted_file}"
      fi
    done
    printf '%s' "${rwa_rerere_changed}" | while IFS= read -r rwa_conflicted_file; do
      review_notice "${rmc_with} changed the resolution that \`git rerere\` made of ${rwa_conflicted_file}"
    done
    if ! printf '%s\n' "${rwa_agent_other}" | {
      rwa_loop_ok=1
      while IFS= read -r rwa_other_file; do
        if [ -n "${rwa_other_file}" ] && ! check_added_markers "${rwa_other_file}"; then
          rwa_loop_ok=0
        fi
      done
      [ "${rwa_loop_ok}" -eq 1 ]
    }; then
      rwa_ok=0
    fi
  fi
  # Every conflicted file is checked, unless HEAD, MERGE_HEAD, or AUTO_MERGE
  # changed, including one that the agent did not change, whose conflict
  # markers remain.  After the agent failed, each file that is not
  # acceptably resolved is reported briefly, as when no agent runs.
  if [ "${rwa_refs_ok}" -eq 0 ]; then
    :
  elif [ "${rwa_agent_status}" -ne 0 ]; then
    report_unresolved "${rmc_conflicted}" check_agent_resolution
  elif ! printf '%s\n' "${rmc_conflicted}" | {
    rwa_loop_ok=1
    while IFS= read -r rwa_conflicted_file; do
      if ! check_agent_resolution "${rwa_conflicted_file}"; then
        rwa_loop_ok=0
      fi
    done
    [ "${rwa_loop_ok}" -eq 1 ]
  }; then
    rwa_ok=0
  fi
  if [ "${rwa_agent_status}" -ne 0 ]; then
    return 1
  fi
  if [ "${rwa_ok}" -eq 0 ]; then
    echo "${SCRIPT_NAME}: ${rmc_with} did not resolve the conflicts acceptably" >&2
    return 1
  fi
  return 0
}

## Usage: check_agent_resolution FILE
## Checks the resolution of FILE, a file that the merge in progress in the
## current directory left conflicted, after an AI agent resolved the
## conflicts.  Returns 0 if the resolution is acceptable.  Returns 1, after
## printing a diagnostic, if FILE no longer exists or if it contains a
## conflict marker line.  A line of 7 or more "=" is not a conflict marker if
## `separator_permitted` permits one in FILE.  A resolution that is identical
## to one side's version of FILE is acceptable, because the agent's
## instructions say when it is correct, but `resolve_with_agent` reports it
## for the user's review, unless that side already contains the other side's
## changes to FILE (see `one_sided_description`).  Only
## `resolve_with_agent` calls this function, which reads the variables of
## `resolve_merge_conflicts` and of `resolve_with_agent`.
check_agent_resolution() {
  if [ ! -f "$1" ]; then
    echo "${SCRIPT_NAME}: $1: the conflicted file was deleted" >&2
    return 1
  fi
  check_conflict_markers "$1" "$(separator_permitted "$1")"
}

## Usage: rerere_resolution_unchanged FILE HASH
## Succeeds if FILE is one of the conflicted files that `git rerere`
## resolved, and HASH, FILE's hash as `git hash-object -- FILE` prints it,
## is the same as when `resolve_with_agent` asked the agent to resolve the
## conflicts, as recorded in ${rwa_rerere_hashes}.
rerere_resolution_unchanged() {
  printf '%s\n' "${rwa_rerere_hashes}" | grep -F -x -q -- "$2 $1"
}

## Usage: one_sided_description FILE HASH
## Sets ${osd_description} to a description, such as "claude resolved foo.c
## as the version on feature, which keeps none of the changes of branch
## 'main' to the file", if FILE, a conflicted file of the merge in progress
## in the current directory, is the same as its version on either side of
## the merge, apart from whitespace and blank lines.  HASH is FILE's hash, as
## `git hash-object -- FILE` prints it, such as
## "3b18e512dba79e4c8300dd08aeb37f8e728b8dad".  Such a resolution keeps none
## of the changes that the other side made to the file, including the
## changes that git merged cleanly.  It is correct only if every change of
## the other side is already present in it or is obsolete, which a person
## should confirm.  A resolution that differs from a side's version only in
## whitespace and blank lines counts only if the other side's version
## differs from the merge base's version in more than whitespace and blank
## lines:  when the other side's changes are only to whitespace, such a
## resolution can keep them.  Returns 1, and sets ${osd_description} to "",
## if FILE is not such a resolution.
##
## Returns 2 if FILE is exactly the version of a side that already contains
## the other side's changes to the file, as `changes_already_present`
## determines; the description then says so, as in "..., which keeps none of
## the changes of branch 'main' to the file, but branch 'main' changed it only
## in commit 9ec8e71, whose change is that of commit 7a3827e on feature".  A
## resolution that differs from that side's version in whitespace does not
## qualify, because the agent's changes to the whitespace deserve review.
## Returns 0 otherwise.  Reads the variables of `resolve_merge_conflicts` and
## of `resolve_with_agent`.
one_sided_description() {
  osd_description=''
  # Stage 1 of the index is the merge base's version, stage 2 is HEAD's, and
  # stage 3 is MERGE_HEAD's.  `git hash-object` converts the file as
  # `git add` would, such as from CRLF line endings, so that HASH is
  # comparable to the hashes in the index.
  osd_how=''
  if [ "$2" = "$(git rev-parse --verify --quiet ":2:$1")" ]; then
    osd_stage=2
  elif [ "$2" = "$(git rev-parse --verify --quiet ":3:$1")" ]; then
    osd_stage=3
  elif grep -q -e '^<<<<<<<$' -e '^<<<<<<< ' -- "$1"; then
    # A file that still has a conflict marker matches neither side, whose
    # versions have no such line:  `resolve_merge_conflicts` refuses a
    # file whose versions do.
    return 1
  else
    # The merge base's version is read only if FILE matches a side.
    osd_file="$(squeezed_cksum < "$1")"
    osd_ours="$(git cat-file blob ":2:$1" 2> /dev/null | squeezed_cksum)"
    osd_theirs="$(git cat-file blob ":3:$1" 2> /dev/null | squeezed_cksum)"
    if [ "${osd_file}" = "${osd_ours}" ]; then
      osd_stage=2
      osd_other="${osd_theirs}"
    elif [ "${osd_file}" = "${osd_theirs}" ]; then
      osd_stage=3
      osd_other="${osd_ours}"
    else
      return 1
    fi
    if [ "$(git cat-file blob ":1:$1" 2> /dev/null | squeezed_cksum)" = "${osd_other}" ]; then
      return 1
    fi
    osd_how=', apart from whitespace and blank lines'
  fi
  if [ "${osd_stage}" -eq 2 ]; then
    osd_description="${rmc_with} resolved $1 as the version on ${rwa_branch}${osd_how}, which keeps none of the changes of ${rmc_source} to the file"
    osd_kept='HEAD'
    osd_kept_name="${rwa_branch}"
    osd_other_rev='MERGE_HEAD'
    osd_other_name="${rmc_source}"
  else
    osd_description="${rmc_with} resolved $1 as the version in ${rmc_source}${osd_how}, which keeps none of the changes of ${rwa_branch} to the file"
    osd_kept='MERGE_HEAD'
    osd_kept_name="${rmc_source}"
    osd_other_rev='HEAD'
    osd_other_name="${rwa_branch}"
  fi
  if [ -n "${osd_how}" ] || ! changes_already_present "$1" "${osd_kept}" "${osd_other_rev}"; then
    return 0
  fi
  case "${cap_others}" in
    *,*) osd_description="${osd_description}, but ${osd_other_name} changed it only in commits ${cap_others}, whose changes are those of" ;;
    *) osd_description="${osd_description}, but ${osd_other_name} changed it only in commit ${cap_others}, whose change is that of" ;;
  esac
  case "${cap_kepts}" in
    *,*) osd_description="${osd_description} commits ${cap_kepts} on ${osd_kept_name}" ;;
    *) osd_description="${osd_description} commit ${cap_kepts} on ${osd_kept_name}" ;;
  esac
  return 2
}

## Usage: changes_already_present FILE KEPT OTHER
## Succeeds if commit KEPT already contains every change that commit OTHER
## made to FILE since their merge base, because each such change was made by a
## commit that merged, into the history of OTHER, the changes of a commit that
## KEPT contains:  for example, a squash-merge into OTHER of a pull request
## whose branch KEPT merged.  KEPT and OTHER are revisions, such as "HEAD" and
## "MERGE_HEAD".  FILE is a file name relative to the top level of the
## working tree, such as "src/foo.c".  On success, sets ${cap_others} to the
## abbreviated hashes of the commits on OTHER's side that changed FILE,
## newest first, and ${cap_kepts} to the abbreviated hashes of the commits
## that KEPT contains whose changes they made, each once, in the same order;
## each is a list such as "9ec8e71" or "1a2b3c4, 5d6e7f8".
##
## Fails if git is older than 2.44, or if it cannot show that KEPT contains
## the changes:  if no commit on OTHER's side changed FILE, as when only merge
## commits that made no change of their own to FILE brought OTHER's changes to
## it; or if OTHER's side changed FILE in a merge commit that made a change of
## its own to FILE, in more than ${changes_present_max_commits} commits, or in
## a commit whose change is not the merge of a commit that KEPT contains.
##
## A commit C on OTHER's side made the changes of a commit Y that KEPT
## contains if C's version of FILE is the clean three-way merge of the
## version of C's parent, with the merge base of C's parent and Y as the base
## version and Y's version as the other version.  That is how GitHub
## computes the squash-merge of a pull request whose last commit is Y, and
## the merge uses the histogram diff algorithm, as GitHub's does.  Only the
## ${changes_present_max_candidates} most recent commits that only KEPT
## contains and that changed FILE are tried as Y, and only those that have
## exactly one merge base with C's parent:  with several, as in a
## criss-cross history, the base version is not well defined.
##
## In a partial clone, it fetches no object that the clone lacks, because
## each such fetch makes a network round trip, and without a network it
## waits and then fails.  A merge that needs such an object counts as not
## making the change, as does one that has conflicts.
##
## When more than ${changes_present_max_unfiltered} commits are tried as Y,
## `changes_present_plausible` first rules out most of those whose version of
## FILE cannot yield C's.
changes_present_max_commits=20
changes_present_max_candidates=100
changes_present_max_unfiltered=3
changes_already_present() {
  cap_file="$1"
  cap_kept="$2"
  cap_other="$3"
  cap_others=''
  cap_kepts=''
  # `git merge-file --object-id` and `git --no-lazy-fetch` need git 2.44.
  git_at_least 44 || return 1
  # The merge base whose version of FILE is ${cap_base_blob}.  Most
  # candidates share one merge base, the point where KEPT and OTHER forked.
  cap_base=''
  # The empty blob stands for FILE in a commit that lacks it.
  cap_empty="$(git hash-object -w --stdin < /dev/null)" || return 1
  # With its default history simplification, `git rev-list` lists a merge
  # commit only if it made a change of its own to FILE.  It lists at most
  # one commit more than the limit, so that exceeding the limit is detected.
  # Each line is a commit's hash followed by the hashes of its parents,
  # which `%P`, unlike `--parents`, does not rewrite to skip the commits that
  # did not change FILE.  GIT_LITERAL_PATHSPECS keeps git from interpreting
  # glob characters in FILE.
  cap_commits="$(GIT_LITERAL_PATHSPECS=1 git --no-lazy-fetch rev-list --no-commit-header --format='%H %P' \
    --max-count="$((changes_present_max_commits + 1))" "${cap_other}" --not "${cap_kept}" -- "${cap_file}")" \
    || return 1
  # A merge commit, which has several parents, does not qualify; nor does a
  # root commit, which has none.  Each hash is checked, because it becomes
  # part of a variable name.
  if [ -z "${cap_commits}" ] \
    || ! printf '%s\n' "${cap_commits}" | awk -v max="${changes_present_max_commits}" '
        NR > max || NF != 2 || $1 !~ /^[0-9a-f]+$/ || $2 !~ /^[0-9a-f]+$/ { exit 1 }'; then
    return 1
  fi
  cap_candidates="$(GIT_LITERAL_PATHSPECS=1 git --no-lazy-fetch rev-list \
    --max-count="${changes_present_max_candidates}" "${cap_kept}" --not "${cap_other}" -- "${cap_file}")" \
    || return 1
  if [ -z "${cap_candidates}" ] \
    || ! printf '%s\n' "${cap_candidates}" | awk '$0 !~ /^[0-9a-f]+$/ { exit 1 }'; then
    return 1
  fi
  # shellcheck disable=SC2086 # Each candidate is one word.
  set -- ${cap_candidates}
  cap_count="$#"
  # One `git cat-file` reads every candidate's version of FILE, into
  # ${cap_blob_CANDIDATE}.  It prints a line such as "REV:FILE missing",
  # which becomes "-", for a candidate that lacks FILE, and also, in a partial
  # clone, for one whose version the clone lacks.  `git rev-parse`, which
  # does not read the version, tells them apart.
  cap_candidate_blobs="$(printf '%s\n' "${cap_candidates}" \
    | CAP_FILE="${cap_file}" awk '{ print $0 ":" ENVIRON["CAP_FILE"] }' \
    | git --no-lazy-fetch cat-file --batch-check='%(objectname)' \
    | awk '/^[0-9a-f]+$/ { print; next } { print "-" }')" \
    || return 1
  # shellcheck disable=SC2086 # Each line is one word.
  set -- ${cap_candidate_blobs}
  for cap_candidate in ${cap_candidates}; do
    if [ "$#" -eq 0 ]; then
      return 1
    elif [ "$1" = '-' ]; then
      # shellcheck disable=SC2034 # The `eval` below reads cap_blob.
      cap_blob="$(git --no-lazy-fetch rev-parse --verify --quiet "${cap_candidate}:${cap_file}")" \
        || cap_blob="${cap_empty}"
      eval "cap_blob_${cap_candidate}=\${cap_blob}"
    else
      eval "cap_blob_${cap_candidate}=\$1"
    fi
    shift
  done
  # shellcheck disable=SC2086 # Each line is two words.
  set -- ${cap_commits}
  while [ "$#" -ge 2 ]; do
    cap_commit="$1"
    cap_parent="$2"
    shift 2
    # A commit that deleted FILE does not qualify.
    cap_want="$(git --no-lazy-fetch rev-parse --verify --quiet "${cap_commit}:${cap_file}")" || return 1
    cap_current="$(git --no-lazy-fetch rev-parse --verify --quiet "${cap_parent}:${cap_file}")" \
      || cap_current="${cap_empty}"
    cap_found=''
    # The candidates that `changes_present_plausible` printed, each preceded
    # and followed by a space; or "", which admits every candidate.  The
    # filter costs more processes than a few merges, so it runs only for many
    # candidates.  It omits a candidate whose version the repository lacks,
    # which loses no match:  a merge needs that version unless the result is
    # that version, and then WANT is that version, which the repository
    # lacks too, so the filter prints every candidate.
    cap_plausible=''
    if [ "${cap_count}" -gt "${changes_present_max_unfiltered}" ]; then
      # shellcheck disable=SC2086 # Each candidate is one word.
      cap_plausible=" $(changes_present_plausible "${cap_file}" "${cap_current}" "${cap_want}" ${cap_candidates} \
        | tr '\n' ' ')"
    fi
    for cap_candidate in ${cap_candidates}; do
      case "${cap_plausible}" in
        '' | *" ${cap_candidate} "*) ;;
        *) continue ;;
      esac
      eval "cap_candidate_blob=\${cap_blob_${cap_candidate}}"
      # Merging the parent's own version into it leaves the parent's
      # version, which is not C's.
      # shellcheck disable=SC2154 # The `eval` above sets cap_candidate_blob.
      if [ "${cap_candidate_blob}" = "${cap_current}" ] \
        || ! changes_present_merge_base "${cap_parent}" "${cap_candidate}"; then
        continue
      fi
      if [ "${cpm_base}" != "${cap_base}" ]; then
        cap_base="${cpm_base}"
        cap_base_blob="$(git --no-lazy-fetch rev-parse --verify --quiet "${cap_base}:${cap_file}")" \
          || cap_base_blob="${cap_empty}"
      fi
      if [ "${cap_candidate_blob}" = "${cap_base_blob}" ]; then
        # The merge leaves the parent's version, as above.
        continue
      elif [ "${cap_base_blob}" = "${cap_current}" ]; then
        # The merge yields the candidate's version.
        cap_merged="${cap_candidate_blob}"
      else
        # The merge is hashed without being written to the repository, as
        # `git merge-file --object-id` without `-p` would write it.
        # `git merge-file` fails if the merge has conflicts or a version is
        # binary or missing.  Its exit status is lost in the pipe, so on
        # failure its output is followed by the hash ${cap_want}, which makes
        # the hash of the whole differ from ${cap_want}:  a blob that
        # contains its own hash is infeasible to find.
        cap_merged="$({ git --no-lazy-fetch merge-file -p --object-id --diff-algorithm=histogram \
          "${cap_current}" "${cap_base_blob}" "${cap_candidate_blob}" 2> /dev/null \
          || printf '\n%s\n' "${cap_want}"; } | git hash-object --stdin)" || return 1
      fi
      if [ "${cap_merged}" = "${cap_want}" ]; then
        cap_found="${cap_candidate}"
        break
      fi
    done
    if [ -z "${cap_found}" ]; then
      return 1
    fi
    cap_others="${cap_others:+${cap_others}, }$(git rev-parse --short "${cap_commit}")"
    cap_found="$(git rev-parse --short "${cap_found}")"
    case ", ${cap_kepts}, " in
      *", ${cap_found}, "*) ;;
      *) cap_kepts="${cap_kepts:+${cap_kepts}, }${cap_found}" ;;
    esac
  done
}

## Usage: changes_present_plausible FILE CURRENT WANT CANDIDATE...
## Prints, one per line, each CANDIDATE whose version of FILE could be the
## other version in a clean three-way merge whose own version is CURRENT and
## whose result is WANT.  CURRENT and WANT are hashes of blobs, such as
## "3b18e512dba79e4c8300dd08aeb37f8e728b8dad", and each CANDIDATE is the full
## hash of a commit.  FILE is a file name relative to the top level of the
## working tree, such as "src/foo.c".
##
## Such a merge takes each line of its result from its own version or from
## the other version, so the other version contains each line that WANT has
## more times than CURRENT has.  Only the 10 longest such lines, which tend
## to occur in the fewest other versions, are checked, and each only as a
## substring of a line.  So the check is cheap and conservative:  one
## `git grep` checks every CANDIDATE, whereas a merge needs several processes
## per CANDIDATE.
## Prints every CANDIDATE if no line qualifies, as when WANT only deletes
## lines of CURRENT or the repository lacks CURRENT or WANT; or if git cannot
## search the candidates, as when a CANDIDATE is not a commit or a line is
## too long to pass as an argument.  Otherwise, does not print a CANDIDATE
## whose version of FILE the repository lacks, as a partial clone can.
changes_present_plausible() {
  cpp_file="$1"
  # The 10 longest lines that WANT has more times than CURRENT has, longest
  # first, one per line.  A line that holds a NUL does not qualify, because
  # the shell cannot pass it as an argument.
  cpp_lines="$(git --no-lazy-fetch cat-file blob "$2" 2> /dev/null \
    | LC_ALL=C CPP_WANT="$3" awk '
        { count[$0]++ }
        END {
          cmd = "git --no-lazy-fetch cat-file blob " ENVIRON["CPP_WANT"] " 2> /dev/null"
          while ((cmd | getline line) > 0) {
            if (count[line] > 0) {
              count[line]--
            } else if (line != "" && line ~ /^[\t\r -~\200-\377]*$/ && !(line in seen)) {
              seen[line] = 1
              lines[++n] = line
            }
          }
          close(cmd)
          for (k = 1; k <= n && k <= 10; k++) {
            longest = k
            for (i = k + 1; i <= n; i++) {
              if (length(lines[i]) > length(lines[longest])) {
                longest = i
              }
            }
            print lines[longest]
            lines[longest] = lines[k]
          }
        }')"
  shift 3
  if [ -z "${cpp_lines}" ]; then
    printf '%s\n' "$@"
    return 0
  fi
  cpp_candidates="$*"
  # The arguments become `-e LINE` for each line.  The shell splits
  # ${cpp_lines} on newlines, with globbing off so that no line is expanded.
  set --
  cpp_saved_ifs="${IFS}"
  IFS='
'
  set -f
  for cpp_line in ${cpp_lines}; do
    set -- "$@" -e "${cpp_line}"
  done
  set +f
  IFS="${cpp_saved_ifs}"
  # `git grep` prints a line such as "REV:FILE" for each CANDIDATE whose
  # version contains every line, and exits with status 1 if there is none.
  # It skips a version that it cannot read, with a message and without
  # changing its exit status.
  # shellcheck disable=SC2086 # Each candidate is one word.
  if cpp_found="$(GIT_LITERAL_PATHSPECS=1 git --no-lazy-fetch grep --no-color -l --all-match -F \
    "$@" ${cpp_candidates} -- "${cpp_file}" 2> /dev/null)"; then
    printf '%s\n' "${cpp_found}" | sed 's/:.*//'
  elif [ "$?" -ne 1 ]; then
    printf '%s\n' ${cpp_candidates}
  fi
}

## Usage: changes_present_merge_base COMMIT1 COMMIT2
## Sets ${cpm_base} to the hash of the merge base of the given commits, and
## succeeds, if they have exactly one merge base; fails otherwise.  COMMIT1
## and COMMIT2 are full hashes, such as
## "3b18e512dba79e4c8300dd08aeb37f8e728b8dad".  The result is cached in
## ${changes_present_merge_base_COMMIT1_COMMIT2}, which is "" if there is not
## exactly one merge base, so that the conflicted files of a merge share it.
changes_present_merge_base() {
  eval "cpm_cached=\${changes_present_merge_base_$1_$2+1}"
  if [ -n "${cpm_cached}" ]; then
    eval "cpm_base=\${changes_present_merge_base_$1_$2}"
  else
    cpm_base="$(git merge-base --all "$1" "$2")" || cpm_base=''
    case "${cpm_base}" in
      *"
"*) cpm_base='' ;;
    esac
    eval "changes_present_merge_base_$1_$2=\${cpm_base}"
  fi
  [ -n "${cpm_base}" ]
}

## Usage: squeezed_cksum
## Prints the checksum, as `cksum` prints it, of standard input with all
## whitespace removed from each line and the lines that become empty
## removed.  Two files have the same such checksum if they differ only in
## whitespace and blank lines (or, with negligible probability, otherwise).
squeezed_cksum() {
  awk '{ gsub(/[ \t\r\f\v]+/, ""); if ($0 != "") print }' | cksum
}

## Usage: rerere_skip_files FILES
## Keeps `git rerere` from recording the resolution of each of FILES, which
## are conflicted files of the merge in progress in the current directory,
## one per line, when the merge is committed, and removes the record of
## each one's conflict, its preimage.  Prints a diagnostic if it cannot.  A
## file whose resolution is one side's version, which an agent wrote, needs
## this:  the side's version also drops the other side's changes outside the
## conflict regions, and a later merge with the same conflicts, to which
## `git rerere` applied that resolution, would fail
## `check_conflict_resolution`.  Without the removal, `git rerere` would
## record the same conflict anew, as another variant of it, at each later
## merge that had it.
rerere_skip_files() {
  if [ -z "$1" ] \
    || ! rsf_merge_rr="$(git rev-parse --git-path MERGE_RR)" \
    || ! rsf_rr_cache="$(git rev-parse --git-path rr-cache)" \
    || [ ! -f "${rsf_merge_rr}" ]; then
    return 0
  fi
  # Git writes MERGE_RR, in the git directory, as it writes its other files:
  # it creates the lock MERGE_RR.lock, which must not exist, writes the new
  # content there, and renames the lock to MERGE_RR.  This function does
  # the same.  `set -C` makes the redirection fail if the lock exists.
  rsf_lock="${rsf_merge_rr}.lock"
  if ! (set -C && : > "${rsf_lock}") 2> /dev/null; then
    echo "${SCRIPT_NAME}: cannot create ${rsf_lock}, so \`git rerere\` can record the resolutions that keep one side's version" >&2
    return 0
  fi
  # `git rerere` records the resolution of each file that MERGE_RR lists.
  # Each entry of MERGE_RR is "ID<TAB>PATHNAME<NUL>", where ID names the
  # conflict and its variant, as in "3b18e512dba79e4c8300dd08aeb37f8e728b8dad"
  # for variant 0 or "3b18e512dba79e4c8300dd08aeb37f8e728b8dad.1" for
  # variant 1, whose preimage is the file preimage or preimage.1 in the
  # directory rr-cache/3b18e512dba79e4c8300dd08aeb37f8e728b8dad.  No
  # conflicted pathname contains a newline, which `resolve_merge_conflicts`
  # refuses, so `tr` can turn each entry into a line.  The awk program
  # prints "keep ENTRY" for each entry to keep, and "skip ID" for each
  # other one; its "$0" is awk's, not the shell's.  Its exit status, which
  # is the pipeline's, is checked before MERGE_RR is replaced.
  # shellcheck disable=SC2016
  if ! rsf_entries="$(tr '\000' '\n' < "${rsf_merge_rr}" | RSF_FILES="$1" awk '
      BEGIN { n = split(ENVIRON["RSF_FILES"], files, "\n"); for (i = 1; i <= n; i++) skip[files[i]] = 1 }
      { id = $0; sub(/\t.*/, "", id); pathname = $0; sub(/^[^\t]*\t/, "", pathname) }
      !(pathname in skip) { print "keep " $0; next }
      id ~ /^[0-9a-f]+(\.[0-9]+)?$/ { print "skip " id }')" \
    || ! printf '%s\n' "${rsf_entries}" | sed -n -e 's/^keep //p' | tr '\n' '\000' > "${rsf_lock}" \
    || ! mv -f -- "${rsf_lock}" "${rsf_merge_rr}"; then
    rm -f -- "${rsf_lock}"
    echo "${SCRIPT_NAME}: cannot keep \`git rerere\` from recording the resolutions that keep one side's version" >&2
    return 0
  fi
  printf '%s\n' "${rsf_entries}" | sed -n -e 's/^skip //p' | while IFS= read -r rsf_id; do
    if [ -n "${rsf_id}" ]; then
      case "${rsf_id}" in
        *.*) rsf_preimage="${rsf_rr_cache}/${rsf_id%%.*}/preimage.${rsf_id#*.}" ;;
        *) rsf_preimage="${rsf_rr_cache}/${rsf_id}/preimage" ;;
      esac
      rm -f -- "${rsf_preimage}"
      # The directory remains if it records another variant.
      rmdir -- "${rsf_rr_cache}/${rsf_id%%.*}" 2> /dev/null || true
    fi
  done
}

## Usage: check_conflict_markers FILE CONTAINS_SEPARATOR
## Returns 0 if no line of FILE, a file of the working tree, is a conflict
## marker.  Otherwise, prints a diagnostic for each such line and returns 1.
## check-conflict-resolution.awk defines a conflict marker.  A line of 7 or
## more "=", such as "=======", is a conflict marker unless
## CONTAINS_SEPARATOR is "yes".
check_conflict_markers() {
  # The "./" keeps awk from taking a FILE such as "x=y" for a variable
  # assignment.
  CCR_FILE="$1" CCR_SCRIPT_NAME="${SCRIPT_NAME}" CCR_CONTAINS_SEPARATOR="$2" \
    CCR_MARKERS_ONLY=yes awk -f "${SCRIPT_DIR}/check-conflict-resolution.awk" /dev/null "./$1"
}

## Usage: check_added_markers FILE
## Returns 0 if FILE, a file of the working tree that is not conflicted,
## contains no conflict marker line that its version in AUTO_MERGE lacks, or
## if FILE does not exist.  A file that is not in AUTO_MERGE, such as a new
## file, lacks every line.  Otherwise, prints a diagnostic for each such line
## and returns 1.  check-conflict-resolution.awk defines a conflict marker;
## here, a line of 7 or more "=", such as "=======", is not one, because it
## is common content, as a Markdown heading's underline, and a conflict
## region copied into FILE has the other markers too.
check_added_markers() {
  if [ ! -f "$1" ]; then
    return 0
  fi
  # `--filters` converts AUTO_MERGE's file as a checkout would, such as to
  # CRLF line endings, to match the working tree.  The "./" keeps awk from
  # taking a FILE such as "x=y" for a variable assignment.
  git cat-file --filters "AUTO_MERGE:$1" 2> /dev/null \
    | CCR_FILE="$1" CCR_SCRIPT_NAME="${SCRIPT_NAME}" CCR_CONTAINS_SEPARATOR=yes \
      CCR_MARKERS_ONLY=yes awk -f "${SCRIPT_DIR}/check-conflict-resolution.awk" - "./$1"
}

## Usage: working_tree_paths
## Prints the pathname of each file and directory of the working tree whose
## top level is the current directory, other than the contents of `.git`,
## one per line.  Each pathname begins with "./", as in "./src/main.c".  A
## pathname that contains a newline spans several lines.
working_tree_paths() {
  find . -path './.git/*' -prune -o -print
}

## Usage: working_tree_changes PATHS MARKER
## Compares the working tree whose top level is the current directory with
## PATHS, an earlier output of `working_tree_paths`.  Prints, one per line,
## "created a file: FILE" or "deleted a file: FILE" for each pathname that
## was added to or removed from PATHS, and "changed a file: FILE" for each
## other file, not a directory, whose status changed after MARKER, a file,
## was last modified.  FILE is relative to the top level.  Standard input is
## a list of the pathnames whose creation, deletion, or change is permitted,
## one per line, relative to the top level, such as "src/main.c"; nothing is
## printed for one of them or for a directory that contains one of them.
## The list is read from standard input, rather than from an argument or an
## environment variable, because it can be long, such as every file that git
## tracks.
working_tree_changes() {
  {
    sed -e 's/^/allowed /'
    printf '%s\n' "$1" | sed -e 's/^/before /'
    working_tree_paths | sed -e 's/^/after /'
    find . -path './.git/*' -prune -o ! -type d -cnewer "$2" -print \
      | sed -e 's/^/changed /'
  } | awk '
    # A permitted pathname, and each directory that contains it, such as
    # "./src" for "src/main.c".
    /^allowed / {
      path = "./" substr($0, 9)
      allowed[path] = 1
      # A directory that is already permitted has permitted ancestors.
      while (sub(/\/[^\/]*$/, "", path) && path != "." && !(path in allowed)) allowed[path] = 1
      next
    }
    # Each list can hold a pathname more than once, if a pathname that
    # contains a newline spans lines that are also pathnames, so the lists
    # are compared as multisets.
    /^before / { count[substr($0, 8)]--; next }
    /^after / { count[substr($0, 7)]++; next }
    /^changed / {
      file = substr($0, 9)
      if (!(file in allowed)) changed[file] = 1
    }
    function relative(file) { sub(/^\.\//, "", file); return file }
    END {
      for (file in count) {
        if (file in allowed) continue
        if (count[file] > 0) print "created a file: " relative(file)
        else if (count[file] < 0) print "deleted a file: " relative(file)
      }
      for (file in changed) {
        if (count[file] == 0) print "changed a file: " relative(file)
      }
    }' | LC_ALL=C sort
}

## Usage: wait_for_later_time FILE DIR [TRIES]
## Returns 0 once every file in DIR, an absolute pathname of a directory,
## that changes from now on has a later status-change time (ctime) than the
## modification time of FILE, an absolute pathname, as `find -cnewer`
## compares them.  A file system can record times to the second, or it can
## record finer times but advance its clock only every few milliseconds.
## DIR and FILE can be on different file systems.
##
## Creates, and then removes, the directory
## DIR/.manage-git-branches-time-probe, which must not already exist.  It
## removes the directory even if a signal such as SIGINT ends the wait.
## Returns 1, after printing a diagnostic, if it cannot create or remove that
## directory, or if the time does not advance within TRIES checks, 20 if
## TRIES is not given; each check after the 10th first sleeps 1 second, so
## 20 checks take about 10 seconds.
##
## The function runs in a subshell, so that its traps do not replace the
## caller's.
wait_for_later_time() (
  wait_probe="$2/.manage-git-branches-time-probe"
  wait_max_tries="${3:-20}"
  # `mkdir` fails if anything, even a symbolic link, already has that name.
  # By contrast, `set -C` lets a redirection open an existing file that is
  # not a regular file, such as a FIFO or a symbolic link to /dev/null.
  if ! mkdir -- "${wait_probe}"; then
    echo "${SCRIPT_NAME}: cannot create the directory ${wait_probe}, which must not already exist" >&2
    exit 1
  fi
  # A probe left behind would make every later wait in DIR fail.
  trap 'rmdir -- "${wait_probe}"' EXIT
  trap 'wait_end_by_signal HUP "${wait_probe}"' HUP
  trap 'wait_end_by_signal INT "${wait_probe}"' INT
  trap 'wait_end_by_signal TERM "${wait_probe}"' TERM
  wait_tries=1
  until [ -n "$(find "${wait_probe}" -cnewer "$1" -print)" ]; do
    if [ "${wait_tries}" -ge "${wait_max_tries}" ]; then
      echo "${SCRIPT_NAME}: after ${wait_tries} tries, the time that the file system records in $2 is not later than the modification time of $1" >&2
      exit 1
    fi
    # A file system whose clock advances every few milliseconds needs no
    # sleep:  each try takes about that long.  POSIX `sleep` accepts only a
    # whole number of seconds.
    if [ "${wait_tries}" -ge 10 ]; then sleep 1; fi
    if ! touch -- "${wait_probe}"; then
      echo "${SCRIPT_NAME}: cannot change the time of the directory ${wait_probe}" >&2
      exit 1
    fi
    wait_tries=$((wait_tries + 1))
  done
  # Removing the probe here, not in the EXIT trap, makes the function fail if
  # the removal fails:  the status of an EXIT trap does not change the
  # subshell's exit status.
  trap - EXIT
  if ! rmdir -- "${wait_probe}"; then
    echo "${SCRIPT_NAME}: cannot remove the directory ${wait_probe}" >&2
    exit 1
  fi
)

## Usage: wait_end_by_signal SIGNAL DIR
## For the traps of `wait_for_later_time`.  Removes DIR, a probe directory;
## restores the default disposition of SIGNAL, a signal name such as INT; and
## re-sends SIGNAL to the subshell that runs `wait_for_later_time`, so that
## the caller sees that the signal ended the wait.  If the subshell merely
## exited, bash would continue the caller.  `$$` would name the main shell,
## not the subshell.
wait_end_by_signal() {
  rmdir -- "$2"
  trap - "$1" EXIT
  kill -s "$1" "$(exec sh -c 'echo "$PPID"')"
}

## Usage: report_unresolved FILES [CHECK]
## Says why each of FILES, a list of conflicted files one per line, is not
## acceptably resolved:  that it still has conflict markers, or else what
## CHECK finds wrong with its resolution.  CHECK is `check_agent_resolution`,
## for the work of an AI agent, or `check_conflict_resolution` (the default),
## for the work of `git rerere`.
report_unresolved() {
  printf '%s\n' "$1" | while IFS= read -r report_unresolved_file; do
    if grep -q '^<<<<<<<' "${report_unresolved_file}" 2> /dev/null; then
      echo "${SCRIPT_NAME}: conflicted: ${report_unresolved_file}" >&2
    elif [ "${2:-}" = check_agent_resolution ]; then
      check_agent_resolution "${report_unresolved_file}" || true
    else
      check_conflict_resolution "${report_unresolved_file}" \
        "$(separator_permitted "${report_unresolved_file}")" || true
    fi
  done
}

## Usage: separator_permitted FILE
## Prints "yes" if a line of 7 or more "=" is permitted in the resolution of
## FILE, because FILE is in ${rmc_separators}, and "no" otherwise.
separator_permitted() {
  if printf '%s\n' "${rmc_separators}" | grep -F -x -q -- "$1"; then
    echo yes
  else
    echo no
  fi
}

## Usage: conflicted_files
## Prints, one per line, each conflicted file of the merge in progress in the
## current directory, the top level of a working tree, as in "src/main.c".
## `-z` keeps git from quoting a pathname, and `print_nul_lines` keeps a
## pathname that contains a newline from being split.  Returns the exit
## status of git.
conflicted_files() {
  print_nul_lines git diff --name-only --diff-filter=U -z
}

## Usage: resolve_other_changes FILES
## Prints, one per line, each file that differs from AUTO_MERGE in the working
## tree or in the index and is not in FILES, the conflicted files, one per
## line.  Both FILES and the output give each pathname as `conflicted_files`
## prints it, with each newline in it replaced by the byte 001.  Returns 1 if
## git cannot list the files that differ from AUTO_MERGE.
resolve_other_changes() {
  roc_worktree="$(print_nul_lines git diff --no-renames --name-only -z AUTO_MERGE)" || return 1
  roc_index="$(print_nul_lines git diff --cached --no-renames --name-only -z AUTO_MERGE)" || return 1
  # `printf` prints an empty listing as an empty line, which `sed` removes.
  # `grep` returns 1 when it prints nothing.
  printf '%s\n%s\n' "${roc_worktree}" "${roc_index}" \
    | sed -e '/^$/d' | sort -u | grep -F -x -v -- "$1" || true
}

## Usage: record_conflicted_files
## Records, in the file manage-git-branches-conflicts in the git directory of
## the current directory, the top level of a working tree, MERGE_HEAD and the
## content of each of ${rmc_conflicted}, the files that the merge in
## progress left conflicted, as they are in the working tree:  as git and
## `git rerere` left them, before any AI agent edits them.
## `changed_conflicted_files` reads the record.  Neither agent can write the
## git directory.  Only `resolve_merge_conflicts` calls this function, which
## reads that function's variables.  A failure to write the record goes
## unreported, because without it `changed_conflicted_files` reports more
## files, not fewer.
record_conflicted_files() {
  if ! record_conflicts="$(git rev-parse --path-format=absolute --git-path manage-git-branches-conflicts)"; then
    return 0
  fi
  {
    printf 'merge %s\n' "${rmc_merge_head}"
    printf '%s\n' "${rmc_conflicted}" | while IFS= read -r record_file; do
      if record_hash="$(git hash-object --no-filters -- "${record_file}" 2> /dev/null)"; then
        printf '%s\t%s\n' "${record_hash}" "${record_file}"
      fi
    done
  } > "${record_conflicts}" 2> /dev/null || true
}

## Usage: forget_conflicted_files
## Removes the record that `record_conflicted_files` writes in the current
## directory's git directory, once the merge is committed.
forget_conflicted_files() {
  if forget_conflicts="$(git rev-parse --path-format=absolute --git-path manage-git-branches-conflicts)"; then
    rm -f -- "${forget_conflicts}"
  fi
}

## Usage: changed_conflicted_files
## Prints, one per line, each conflicted file of the merge in progress in the
## current directory, the top level of a working tree, whose content in the
## working tree differs both from its version in AUTO_MERGE, git's automatic
## merge, which contains the conflict markers, and from the content that
## `record_conflicted_files` recorded for this merge.  Such a file was changed
## after git, `git rerere`, and this package's scripts last left it:  for
## example, by an AI agent whose work a script rejected, or by a person.  A
## file that was deleted is printed too.  Returns 1, without printing
## anything, if the conflicted files cannot be listed.
changed_conflicted_files() {
  changed_record=''
  if changed_conflicts="$(git rev-parse --git-path manage-git-branches-conflicts)" \
    && [ -f "${changed_conflicts}" ] \
    && changed_merge_head="$(git rev-parse --verify --quiet MERGE_HEAD)" \
    && [ "$(head -n 1 "${changed_conflicts}")" = "merge ${changed_merge_head}" ]; then
    changed_record="$(sed -e 1d "${changed_conflicts}")"
  fi
  if ! changed_files="$(conflicted_files)"; then
    return 1
  fi
  printf '%s\n' "${changed_files}" | while IFS= read -r changed_file; do
    if [ -z "${changed_file}" ]; then
      continue
    fi
    # `--filters` converts AUTO_MERGE's file as a checkout would.
    if [ -f "${changed_file}" ] \
      && git cat-file --filters "AUTO_MERGE:${changed_file}" 2> /dev/null | cmp -s - "${changed_file}"; then
      continue
    fi
    if [ -n "${changed_record}" ] \
      && changed_hash="$(git hash-object --no-filters -- "${changed_file}" 2> /dev/null)" \
      && printf '%s\n' "${changed_record}" | grep -F -x -q -- "$(printf '%s\t%s' "${changed_hash}" "${changed_file}")"; then
      continue
    fi
    printf '%s\n' "${changed_file}"
  done
}
