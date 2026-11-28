#!/bin/sh

# Tests which AI agent `git-push-to` runs to resolve a merge that has
# conflicts, what it tells the agent, how it checks the agent's resolution,
# and what it does when the agent fails, is not ready to run, or is
# interrupted.
#
# `lib-push-to-llm.sh` describes the stub agents that stand in for `claude`
# and `codex`.
#
# Usage:
#   tests/test-push-to-llm-agents.sh

TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib-push-to-llm.sh
. "${TESTS_DIR}/lib-push-to-llm.sh"

## With --no-llm, no agent runs.
setup_case no-llm
push_to good --no-llm
check_not_resolved "--no-llm"
if [ -s "${STUB_LOG}" ]; then
  fail "--no-llm: an agent ran: $(cat "${STUB_LOG}")"
fi

## The last of --no-llm and --codex wins.
setup_case codex-no-llm
push_to good --codex --no-llm
check_not_resolved "--codex --no-llm"
if [ -s "${STUB_LOG}" ]; then
  fail "--codex --no-llm: an agent ran: $(cat "${STUB_LOG}")"
fi
setup_case no-llm-codex
push_to good --no-llm --codex
check_resolved codex "--no-llm --codex"

## Claude is the default.
setup_case default
push_to good
check_resolved claude "no option"

setup_case claude
push_to good --llm
check_resolved claude "--llm"

## The merge uses the configured conflict style, which can be "diff3".
setup_case diff3
git -C "${feature_dir}" config merge.conflictStyle diff3
push_to none --llm
if ! grep -q '^||||||| ' "${feature_dir}/file.txt"; then
  fail "diff3: the merge did not use the configured conflict style"
fi
setup_case diff3-good
git -C "${feature_dir}" config merge.conflictStyle diff3
push_to good --llm
check_resolved claude "diff3"

## --codex implies --llm.
setup_case codex
push_to good --codex
check_resolved codex "--codex"

## --llm does not override --codex.
setup_case codex-resolve
push_to good --codex --llm
check_resolved codex "--codex --llm"

## --llm turns on the agent that was chosen before --no-llm.
setup_case codex-no-llm-llm
push_to good --codex --no-llm --llm
check_resolved codex "--codex --no-llm --llm"

## The last of --claude and --codex wins.
setup_case codex-claude
push_to good --codex --claude
check_resolved claude "--codex --claude"

## An agent that is not installed is treated as with --no-llm.  The test is
## skipped if a real agent is on ${no_agent_path}.
if env PATH="${no_agent_path}" sh -c 'command -v claude' > /dev/null 2>&1; then
  echo "${SCRIPT_NAME}: skipping the test of a missing agent, because claude is in ${no_agent_path}" >&2
else
  setup_case no-agent
  if push_output="$(PATH="${no_agent_path}" \
    "${COMMANDS_DIR}/git-push-to" --llm "${main_dir}" "${feature_dir}" 2>&1)"; then
    push_status=0
  else
    push_status=$?
  fi
  check_not_resolved "agent not installed"
  case "${push_output}" in
    *"cannot run claude, which is not on the PATH"*"conflicted: file.txt"*) ;;
    *) fail "agent not installed: wrong diagnostic: ${push_output}" ;;
  esac
fi

## The instructions tell the agent to examine both sides' changes, permit it
## to edit any part of any file, and say when it can take one side.
setup_case instructions
push_to good --llm
check_resolved claude "instructions"
for instruction in 'git diff HEAD...MERGE_HEAD' 'git diff MERGE_HEAD...HEAD' \
  'edit any part of any file' 'by taking one side' 'Step 3:  check that no change was lost' \
  'HEAD is feature, and MERGE_HEAD is main' '# Rules for this session' \
  'you need not read that file, or use a skill' 'discards the other side'"'"'s changes that git'; do
  if ! grep -q -F -- "${instruction}" "${STUB_PROMPT}"; then
    fail "instructions: they lack \"${instruction}\": $(cat "${STUB_PROMPT}")"
  fi
done

## A change outside the conflict region is accepted.
setup_case clean
push_to clean --llm
if [ "${push_status}" -ne 0 ]; then
  fail "change outside a conflict region: git-push-to failed: ${push_output}"
fi
expected="$(printf '%s\n' ONE two THREE four five six SEVEN-feature SEVEN-main eight nine)"
if [ "$(git -C "${remote}" show refs/heads/feature:file.txt)" != "${expected}" ]; then
  fail "change outside a conflict region: wrong merge result: $(git -C "${remote}" show refs/heads/feature:file.txt)"
fi
case "${push_output}" in
  *"claude changed text outside the conflict regions of file.txt"*) ;;
  *) fail "change outside a conflict region: not reported: ${push_output}" ;;
esac

## Usage: check_side_resolved DESCRIPTION EXPECTED
## Checks that git-push-to committed and pushed the merge of main into
## feature, and that its file.txt is EXPECTED.  DESCRIPTION names the test
## case; used for diagnostics.
check_side_resolved() {
  if [ "${push_status}" -ne 0 ]; then
    fail "$1: git-push-to failed: ${push_output}"
  fi
  side_remote_head="$(git -C "${remote}" rev-parse refs/heads/feature)"
  if [ "${side_remote_head}" != "$(git -C "${feature_dir}" rev-parse HEAD)" ]; then
    fail "$1: the merge was not pushed"
  fi
  if [ "$(git -C "${remote}" rev-parse "${side_remote_head}^1")" != "${feature_head}" ] \
    || [ "$(git -C "${remote}" rev-parse "${side_remote_head}^2")" != "$(git -C "${main_dir}" rev-parse HEAD)" ]; then
    fail "$1: the pushed commit is not the merge of main into feature"
  fi
  if [ "$(git -C "${remote}" show "${side_remote_head}:file.txt")" != "$2" ]; then
    fail "$1: wrong merge result: $(git -C "${remote}" show "${side_remote_head}:file.txt")"
  fi
}

## Usage: read_recorded_resolutions DESCRIPTION
## Sets ${recorded} to the content of each resolution that `git rerere`
## recorded in ${feature_dir}, and ${recorded_conflicts} to the number of
## conflicts that it recorded, each as a file preimage or preimage.N.  Fails
## if ${feature_dir} has no rr-cache directory, in which `git rerere`
## records each conflict when the merge stops.  DESCRIPTION names the test
## case; used for diagnostics.
read_recorded_resolutions() {
  rr_cache="$(git -C "${feature_dir}" rev-parse --path-format=absolute --git-path rr-cache)"
  if [ ! -d "${rr_cache}" ]; then
    fail "$1: \`git rerere\` recorded no conflict in ${rr_cache}"
  fi
  recorded="$(find "${rr_cache}" -name postimage -exec cat {} +)"
  recorded_conflicts="$(find "${rr_cache}" -name 'preimage*' | wc -l | tr -d ' ')"
}

## A resolution that is identical to either side's version is accepted, and
## AGENT-TODO.md is not written, but the script's output asks the user to
## review it, because it drops the other side's changes that git merged
## cleanly.  Here each side also adds other.txt, whose conflict the agent
## resolves by keeping both sides.
for side_mode in ours theirs; do
  setup_case "side-${side_mode}"
  echo "other-feature" > "${feature_dir}/other.txt"
  git -C "${feature_dir}" add other.txt
  git -C "${feature_dir}" commit -q -m "Add other.txt"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  echo "other-main" > "${main_dir}/other.txt"
  git -C "${main_dir}" add other.txt
  git -C "${main_dir}" commit -q -m "Add other.txt"
  git -C "${main_dir}" push -q
  git -C "${feature_dir}" config rerere.enabled true
  push_to "${side_mode}" --llm
  if [ "${side_mode}" = ours ]; then
    side_expected="$(printf '%s\n' one two three four five six SEVEN-feature eight nine)"
  else
    side_expected="$(printf '%s\n' ONE two three four five six SEVEN-main eight nine)"
  fi
  check_side_resolved "${side_mode}" "${side_expected}"
  case "${side_mode}:${push_output}" in
    ours:*"claude resolved file.txt as the version on feature, which keeps none of the changes of main"*" to the file; review it"*) ;;
    theirs:*"claude resolved file.txt as the version in main"*", which keeps none of the changes of feature to the file; review it"*) ;;
    *) fail "${side_mode}: the user is not asked to review: ${push_output}" ;;
  esac
  # The dropped changes outside the conflict regions are not reported again.
  case "${push_output}" in
    *"changed text outside the conflict regions"*) fail "${side_mode}: reported twice: ${push_output}" ;;
  esac
  if [ -e "${feature_dir}/AGENT-TODO.md" ]; then
    fail "${side_mode}: AGENT-TODO.md was written: $(cat "${feature_dir}/AGENT-TODO.md")"
  fi
  # `git rerere` records the resolution of other.txt but not that of
  # file.txt, which a later merge with the same conflict would replay and
  # then reject, and it keeps no record of file.txt's conflict.
  read_recorded_resolutions "${side_mode}"
  if [ "${recorded}" != "$(printf '%s\n' other-feature other-main)" ]; then
    fail "${side_mode}: \`git rerere\` recorded the wrong resolutions: ${recorded}"
  fi
  if [ "${recorded_conflicts}" -ne 1 ]; then
    fail "${side_mode}: \`git rerere\` kept ${recorded_conflicts} conflicts, not 1"
  fi
done

## So is a resolution that differs from a side's version only in whitespace
## and blank lines.
setup_case side-whitespace
push_to ours-whitespace --llm
check_side_resolved "ours-whitespace" "$(printf '%s\n' one '  two' three four '' five six SEVEN-feature eight nine)"
case "${push_output}" in
  *"claude resolved file.txt as the version on feature, apart from whitespace and blank lines, which keeps none of the changes of main"*" to the file; review it"*) ;;
  *) fail "ours-whitespace: the user is not asked to review: ${push_output}" ;;
esac

## When one side's version of the conflicted file already contains every
## change of the other side to it, because the other side's version is in
## the first side's history after the merge base, an agent's resolution that
## is that side's version is correct, and it is accepted, as in the merge of
## a branch that merged a pull request's branch with a main branch that
## landed the squashed pull request.  The user is not asked to review it,
## but the output says which commits already made the other side's changes.
## In contained-ours, feature first reaches main's version of file.txt, as
## by merging a squashed copy of main's change, and then changes it further,
## next to main's change but not in it.  In contained-theirs, main reaches
## feature's version, and changes it further.
for side_mode in ours theirs; do
  side_name="contained-${side_mode}"
  setup_case "${side_name}"
  case "${side_mode}" in
    theirs)
      printf '%s\n' one two three four five six SEVEN-feature eight nine > "${main_dir}/file.txt"
      git -C "${main_dir}" commit -q -a -m "Reach feature's version"
      printf '%s\n' ONE two three four five six SEVEN-feature EIGHT-later nine > "${main_dir}/file.txt"
      git -C "${main_dir}" commit -q -a -m "Change main again"
      git -C "${main_dir}" push -q
      side_expected="$(printf '%s\n' ONE two three four five six SEVEN-feature EIGHT-later nine)"
      side_taken="in main"
      ;;
    *)
      printf '%s\n' ONE two three four five six SEVEN-main eight nine > "${feature_dir}/file.txt"
      git -C "${feature_dir}" commit -q -a -m "Reach main's version"
      printf '%s\n' ONE two three four five six SEVEN-main EIGHT-later nine > "${feature_dir}/file.txt"
      git -C "${feature_dir}" commit -q -a -m "Change feature again"
      git -C "${feature_dir}" push -q
      feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
      side_expected="$(printf '%s\n' ONE two three four five six SEVEN-main EIGHT-later nine)"
      side_taken="on feature"
      ;;
  esac
  git -C "${feature_dir}" config rerere.enabled true
  push_to "${side_mode}" --llm
  check_side_resolved "${side_name}" "${side_expected}"
  case "${push_output}" in
    *"claude resolved file.txt as the version ${side_taken}"*", which keeps none of the changes of "*" to the file, but "*" changed it only in commit "*", whose change"*" of commit "*) ;;
    *) fail "${side_name}: the output does not say that the changes are present: ${push_output}" ;;
  esac
  case "${push_output}" in
    *"review it"*) fail "${side_name}: the user is asked to review: ${push_output}" ;;
  esac
  # `git rerere` does not record the side's version as a resolution, which
  # would drop the other side's changes outside the conflict regions from a
  # later merge with the same conflict.
  read_recorded_resolutions "${side_name}"
  if [ -n "${recorded}" ] || [ "${recorded_conflicts}" -ne 0 ]; then
    fail "${side_name}: \`git rerere\` recorded the side's version as a resolution, or kept the conflict: ${recorded}"
  fi
done

## A squash-merge into main of a pull request whose branch feature merged
## makes main's change to file.txt that of a commit that feature contains,
## so a resolution that is exactly feature's version needs no review, even
## though feature changed the pull request's line further.  The pull
## request's branch, pr, starts at main and changes line 3; feature merges it
## and then changes line 3 again; main lands a squashed copy of pr.  In
## squash-whitespace, the resolution differs from feature's version in
## whitespace, and the agent's changes to the whitespace need review.  In
## squash-differs, main changes line 3 differently from pr, so that feature
## has no commit whose change main's commit made, and the resolution, which
## drops main's change, needs review.
for squash_name in squash squash-whitespace squash-differs; do
  case "${squash_name}" in
    squash-differs) squash_main_line=THREE-main ;;
    *) squash_main_line=THREE-pr ;;
  esac
  case "${squash_name}" in
    squash-whitespace) squash_mode=ours-whitespace ;;
    *) squash_mode=ours ;;
  esac
  setup_case "${squash_name}"
  git -C "${feature_dir}" fetch -q origin
  git -C "${feature_dir}" branch -q pr origin/main
  git -C "${feature_dir}" checkout -q pr
  write_file "${feature_dir}/file.txt" ONE two THREE-pr four five six SEVEN-main eight nine
  git -C "${feature_dir}" commit -q -a -m "Change line 3"
  squash_pr="$(git -C "${feature_dir}" rev-parse --short HEAD)"
  git -C "${feature_dir}" checkout -q feature
  git -C "${feature_dir}" merge -q pr > /dev/null 2>&1 || :
  write_file "${feature_dir}/file.txt" ONE two THREE-pr four five six SEVEN-feature eight nine
  git -C "${feature_dir}" add file.txt
  git -C "${feature_dir}" commit -q --no-edit
  write_file "${feature_dir}/file.txt" ONE two THREE-feature four five six SEVEN-feature eight nine
  git -C "${feature_dir}" commit -q -a -m "Change line 3 further"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  write_file "${main_dir}/file.txt" ONE two "${squash_main_line}" four five six SEVEN-main eight nine
  git -C "${main_dir}" commit -q -a -m "Change line 3 (#1)"
  git -C "${main_dir}" push -q
  squash_commit="$(git -C "${main_dir}" rev-parse --short HEAD)"
  push_to "${squash_mode}" --llm
  case "${squash_name}" in
    squash)
      check_side_resolved "${squash_name}" "$(printf '%s\n' ONE two THREE-feature four five six SEVEN-feature eight nine)"
      case "${push_output}" in
        *"claude resolved file.txt as the version on feature, which keeps none of the changes of main"*" to the file, but main"*" changed it only in commit ${squash_commit}, whose change is that of commit ${squash_pr} on feature"*) ;;
        *) fail "${squash_name}: the output does not name the squash-merge and the pull request's commit: ${push_output}" ;;
      esac
      case "${push_output}" in
        *"review it"*) fail "${squash_name}: the user is asked to review: ${push_output}" ;;
      esac
      ;;
    squash-whitespace)
      check_side_resolved "${squash_name}" "$(printf '%s\n' ONE '  two' THREE-feature four '' five six SEVEN-feature eight nine)"
      case "${push_output}" in
        *"claude resolved file.txt as the version on feature, apart from whitespace and blank lines, which keeps none of the changes of main"*" to the file; review it"*) ;;
        *) fail "${squash_name}: the user is not asked to review: ${push_output}" ;;
      esac
      ;;
    *)
      check_side_resolved "${squash_name}" "$(printf '%s\n' ONE two THREE-feature four five six SEVEN-feature eight nine)"
      case "${push_output}" in
        *"claude resolved file.txt as the version on feature, which keeps none of the changes of main"*" to the file; review it"*) ;;
        *) fail "${squash_name}: the user is not asked to review: ${push_output}" ;;
      esac
      ;;
  esac
done

## The changes that a rejected agent made outside the conflicted files are
## reported.
setup_case ours-other
echo "other" > "${feature_dir}/other.txt"
git -C "${feature_dir}" add other.txt
git -C "${feature_dir}" commit -q -m "Add other.txt"
git -C "${feature_dir}" push -q
feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
git -C "${feature_dir}" config rerere.enabled true
push_to ours-other --llm
check_not_resolved "ours-other"
case "${push_output}" in
  *"claude created a file: scratch.txt"*"claude also changed: other.txt"*) ;;
  *) fail "ours-other: wrong diagnostic: ${push_output}" ;;
esac
## Even when the agent's work is rejected, `git rerere` does not record its
## resolution that is one side's version, which a person can commit.
git -C "${feature_dir}" add -u
git -C "${feature_dir}" commit -q --no-edit
read_recorded_resolutions "ours-other"
if [ -n "${recorded}" ] || [ "${recorded_conflicts}" -ne 0 ]; then
  fail "ours-other: \`git rerere\` recorded the one-sided resolution, or kept the conflict: ${recorded}"
fi

## Deleting the conflicted file is rejected.
setup_case delete-conflicted
push_to delete-conflicted --llm
check_not_resolved "delete-conflicted"
case "${push_output}" in
  *"file.txt: the conflicted file was deleted"*) ;;
  *) fail "delete-conflicted: wrong diagnostic: ${push_output}" ;;
esac

## When the agent's work is rejected, the user is told how to continue its
## session.
setup_case session
push_to create --llm
check_not_resolved "rejected resolution"
## The command that continues Claude's session names the session that the
## stub was given.  The directory is a physical path, as on macOS, where
## the temporary directory is under a symbolic link.
session_id="$(sed -n -e '/^--session-id$/{n;p;}' "${STUB_ARGS}")"
session_dir="$(cd "${feature_dir}" && pwd -P)"
case "${session_id}" in
  "") fail "rejected resolution: claude was not given --session-id" ;;
  *)
    case "${push_output}" in
      *"to continue the session of claude:  cd ${session_dir} && claude --resume ${session_id}"*) ;;
      *) fail "rejected resolution: no command to continue the session: ${push_output}" ;;
    esac
    ## The command is also appended to AGENT-TODO.md, which starts with a
    ## title.
    todo="${feature_dir}/AGENT-TODO.md"
    if [ "$(head -n 1 "${todo}" 2> /dev/null)" != "# AI agent sessions to continue" ]; then
      fail "rejected resolution: AGENT-TODO.md has no title: $(cat "${todo}" 2> /dev/null)"
    fi
    if ! grep -q -x "## Resolve the conflicts in the merge of .* (git-push-to, .*)" "${todo}" \
      || ! grep -q -x -F "cd ${session_dir} && claude --resume ${session_id}" "${todo}"; then
      fail "rejected resolution: AGENT-TODO.md lacks the command: $(cat "${todo}")"
    fi
    ## The entry tells an agent that reads it to get a person's help.
    if ! grep -q -x -F "claude, an AI agent, could not resolve the merge's conflicts acceptably.  Ask a person for help with them before you finish the merge." "${todo}"; then
      fail "rejected resolution: AGENT-TODO.md does not ask for help: $(cat "${todo}")"
    fi
    ;;
esac

## Remaining conflict markers are rejected.
setup_case none
push_to none --llm
check_not_resolved "remaining conflict markers"
case "${push_output}" in
  *"is a conflict marker"*) ;;
  *) fail "remaining conflict markers: wrong diagnostic: ${push_output}" ;;
esac

## A failing agent is reported.  (It is ready to run, so its failure is not
## taken for an outage, after which no session is reported.)  The command
## that continues its session is appended to an existing AGENT-TODO.md, which
## gets no second title.
setup_case fail
printf '%s\n' '# AI agent sessions to continue' '' 'An earlier entry.' > "${feature_dir}/AGENT-TODO.md"
push_to STUB_READY=ok fail --llm
check_not_resolved "failing agent"
case "${push_output}" in
  *"claude failed with status 3"*"conflicted: file.txt"*"claude --resume "*) ;;
  *) fail "failing agent: wrong diagnostic: ${push_output}" ;;
esac
todo="${feature_dir}/AGENT-TODO.md"
if [ "$(grep -c '^# ' "${todo}")" -ne 1 ] \
  || ! grep -q -x 'An earlier entry.' "${todo}" \
  || ! grep -q '^cd .* && claude --resume ' "${todo}"; then
  fail "failing agent: AGENT-TODO.md was not appended to: $(cat "${todo}")"
fi

## AGENT-TODO.md is not written through a symbolic link, which could point
## outside the working tree.
setup_case todo-link
echo "outside" > "${case_dir}/outside.txt"
ln -s ../outside.txt "${feature_dir}/AGENT-TODO.md"
push_to STUB_READY=ok fail --llm
check_not_resolved "AGENT-TODO.md link"
case "${push_output}" in
  *"claude --resume "*"did not write "*"AGENT-TODO.md, which is not a regular file with one link"*) ;;
  *) fail "AGENT-TODO.md link: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(cat "${case_dir}/outside.txt")" != outside ]; then
  fail "AGENT-TODO.md link: the link's target was changed: $(cat "${case_dir}/outside.txt")"
fi

## Nor is it written through a hard link.
setup_case todo-hard-link
echo "outside" > "${case_dir}/outside.txt"
ln "${case_dir}/outside.txt" "${feature_dir}/AGENT-TODO.md"
push_to STUB_READY=ok fail --llm
check_not_resolved "AGENT-TODO.md hard link"
case "${push_output}" in
  *"claude --resume "*"did not write "*"AGENT-TODO.md, which is not a regular file with one link"*) ;;
  *) fail "AGENT-TODO.md hard link: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(cat "${case_dir}/outside.txt")" != outside ]; then
  fail "AGENT-TODO.md hard link: the link's target was changed: $(cat "${case_dir}/outside.txt")"
fi

## Nor is it written if git tracks it.
setup_case todo-tracked
echo "# Tracked" > "${feature_dir}/AGENT-TODO.md"
git -C "${feature_dir}" add AGENT-TODO.md
git -C "${feature_dir}" commit -q -m "Add AGENT-TODO.md"
git -C "${feature_dir}" push -q
feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
push_to STUB_READY=ok fail --llm
check_not_resolved "tracked AGENT-TODO.md"
case "${push_output}" in
  *"claude --resume "*"did not write AGENT-TODO.md, which git tracks"*) ;;
  *) fail "tracked AGENT-TODO.md: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(cat "${feature_dir}/AGENT-TODO.md")" != "# Tracked" ]; then
  fail "tracked AGENT-TODO.md: the file was changed: $(cat "${feature_dir}/AGENT-TODO.md")"
fi

## The command that continues Codex's session names the session that Codex
## printed.  Codex is ready to run, so its session is reported.
setup_case fail-codex
push_to STUB_READY=ok fail --codex
check_not_resolved "failing codex"
case "${push_output}" in
  *"codex failed with status 3"*"to continue the session of codex:  cd "*" && codex resume 01a19ac9-dab5-7570-93b6-6ba41bf65093"*) ;;
  *) fail "failing codex: wrong diagnostic: ${push_output}" ;;
esac
if ! grep -q -x 'cd .* && codex resume 01a19ac9-dab5-7570-93b6-6ba41bf65093' "${feature_dir}/AGENT-TODO.md"; then
  fail "failing codex: AGENT-TODO.md lacks the command: $(cat "${feature_dir}/AGENT-TODO.md" 2> /dev/null)"
fi

## If Codex prints no session id, the user is told that its session cannot be
## continued, and AGENT-TODO.md notes the merge in progress but gives no
## command.
setup_case codex-no-session
push_to STUB_NO_SESSION=1 fail --codex
check_not_resolved "codex without a session id"
case "${push_output}" in
  *'codex printed no line "session id: UUID", so no command will be able to continue its session'*) ;;
  *) fail "codex without a session id: wrong diagnostic: ${push_output}" ;;
esac
case "${push_output}" in
  *"codex resume"*) fail "codex without a session id: a command to continue the session: ${push_output}" ;;
esac
if grep -q 'codex resume' "${feature_dir}/AGENT-TODO.md" 2> /dev/null \
  || ! grep -q -x 'The merge of commit .* is in progress in .*' "${feature_dir}/AGENT-TODO.md" 2> /dev/null \
  || ! grep -q -x -F "codex, an AI agent, failed before changing anything, and it is not ready to run, as when it cannot reach its service.  Once codex can run, running the same command again asks it to resolve the conflicts, so no person needs to." "${feature_dir}/AGENT-TODO.md"; then
  fail "codex without a session id: wrong AGENT-TODO.md: $(cat "${feature_dir}/AGENT-TODO.md" 2> /dev/null)"
fi

## The work of an agent that fails is checked too.
setup_case fail-untracked
echo "notes" > "${feature_dir}/notes.txt"
push_to fail-untracked --llm
check_not_resolved "failing agent that changes an untracked file"
case "${push_output}" in
  *"claude failed with status 3"*"changed a file: notes.txt"*) ;;
  *) fail "failing agent that changes an untracked file: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "failing agent that changes an untracked file: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi
if ! grep -q -x -F "claude, an AI agent, could not resolve the merge's conflicts acceptably.  Ask a person for help with them before you finish the merge." "${feature_dir}/AGENT-TODO.md"; then
  fail "failing agent that changes an untracked file: AGENT-TODO.md does not ask for help: $(cat "${feature_dir}/AGENT-TODO.md" 2> /dev/null)"
fi

## A failing agent that changes the index or HEAD, but no file, is not run
## again either.
setup_case fail-index
push_to fail-index --llm
check_not_resolved "failing agent that changes the index"
case "${push_output}" in
  *"claude failed with status 3"*"claude changed the index"*) ;;
  *) fail "failing agent that changes the index: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "failing agent that changes the index: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi
setup_case fail-head
push_to fail-head --llm
check_not_pushed "failing agent that changes HEAD"
if [ "$(git -C "${feature_dir}" log -1 --format=%s HEAD)" != "An agent's commit" ]; then
  fail "failing agent that changes HEAD: HEAD is not the agent's commit"
fi
case "${push_output}" in
  *"claude failed with status 3"*"claude changed HEAD, MERGE_HEAD, or AUTO_MERGE"*) ;;
  *) fail "failing agent that changes HEAD: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "failing agent that changes HEAD: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi

## An agent that fails without changing any file, as when its service is
## unavailable, is run again, twice.  It is then not ready to run, so
## AGENT-TODO.md gives no command to continue a session, which did nothing,
## and says that running git-push-to again suffices; a rerun does resolve the
## conflicts.
setup_case fail-unchanged
push_to fail --llm
check_not_resolved "agent that fails without changing any file"
if [ "$(cat "${STUB_LOG}")" != "$(printf '%s\n' claude claude claude)" ]; then
  fail "agent that fails without changing any file: expected claude to run 3 times, but ran: $(cat "${STUB_LOG}")"
fi
case "${push_output}" in
  *"claude changed nothing; running it again in 0 seconds"*"claude is not ready to run"*"It said: Service unavailable"*"claude failed before changing anything in "*) ;;
  *) fail "agent that fails without changing any file: wrong diagnostic: ${push_output}" ;;
esac
todo="${feature_dir}/AGENT-TODO.md"
if ! grep -q -x -F "claude, an AI agent, failed before changing anything, and it is not ready to run, as when it cannot reach its service.  Once claude can run, running the same command again asks it to resolve the conflicts, so no person needs to." "${todo}" \
  || grep -q 'Ask a person' "${todo}" \
  || grep -q 'claude --resume ' "${todo}"; then
  fail "agent that fails without changing any file: wrong AGENT-TODO.md: $(cat "${todo}" 2> /dev/null)"
fi
: > "${STUB_LOG}"
push_to good --llm
check_resolved claude "rerun after an agent that failed without changing any file"

## An agent that fails once without changing any file succeeds when it is
## run again.  So does one that is ready to run again at once, as after a
## brief outage, and Codex, whose login status is not the same as being
## ready to run.
setup_case fail-once
push_to fail-once --llm
check_resolved "$(printf '%s\n' claude claude)" "agent that fails once"
setup_case fail-once-ready
push_to STUB_READY=ok fail-once --llm
check_resolved "$(printf '%s\n' claude claude)" "agent that fails once and is ready at once"
setup_case fail-once-codex
push_to fail-once --codex
check_resolved "$(printf '%s\n' codex codex)" "codex that fails once"
if [ "$(cat "${STUB_LOG}.ready")" != codex ]; then
  fail "codex that fails once: expected one check that codex is ready, but got: $(cat "${STUB_LOG}.ready")"
fi

## A malformed pause matters only when an agent is to run again.
setup_case bad-pause
MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE=1m
export MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE
push_to good --llm
MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE=0
check_resolved claude "agent that succeeds, with a malformed pause"
setup_case bad-pause-fail
MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE=1m
export MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE
push_to fail --llm
MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE=0
check_not_resolved "agent that fails, with a malformed pause"
case "${push_output}" in
  *"MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE is not a number of seconds, so claude is not run again: 1m"*) ;;
  *) fail "agent that fails, with a malformed pause: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "agent that fails, with a malformed pause: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi

## MANAGE_GIT_BRANCHES_LLM_TIMEOUT limits all of an agent's attempts
## together.  An agent that fails without changing any file after 3 of its 5
## seconds is run again for the time that remains, which is too little.
## Each attempt takes less than 5 seconds, so a limit on each attempt alone
## would let all 3 attempts finish.
setup_case fail-slow
MANAGE_GIT_BRANCHES_LLM_TIMEOUT=5
export MANAGE_GIT_BRANCHES_LLM_TIMEOUT
push_to fail-slow --llm
unset MANAGE_GIT_BRANCHES_LLM_TIMEOUT
check_not_resolved "agent that fails slowly"
if [ "$(cat "${STUB_LOG}")" != "$(printf '%s\n' claude claude)" ]; then
  fail "agent that fails slowly: expected claude to run twice, but ran: $(cat "${STUB_LOG}")"
fi
case "${push_output}" in
  *"claude did not finish within 5 seconds"*) ;;
  *) fail "agent that fails slowly: wrong diagnostic: ${push_output}" ;;
esac

## An agent is not run again if the pause would reach the time limit.
setup_case pause-past-limit
MANAGE_GIT_BRANCHES_LLM_TIMEOUT=30
MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE=40
export MANAGE_GIT_BRANCHES_LLM_TIMEOUT MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE
push_to fail --llm
unset MANAGE_GIT_BRANCHES_LLM_TIMEOUT
MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE=0
check_not_resolved "agent whose pause would reach the time limit"
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "agent whose pause would reach the time limit: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi
case "${push_output}" in
  *"claude changed nothing, and too little of the 30 seconds that MANAGE_GIT_BRANCHES_LLM_TIMEOUT allows remains to run it again"*"claude failed before changing anything in "*) ;;
  *) fail "agent whose pause would reach the time limit: wrong diagnostic: ${push_output}" ;;
esac

## An agent that fails without changing any file each time, but that is
## then ready to run, as when it rejects an option that the script passes,
## makes AGENT-TODO.md ask a person for help.
setup_case fail-ready
push_to STUB_READY=ok fail --llm
check_not_resolved "agent that fails but is ready"
if [ "$(cat "${STUB_LOG}")" != "$(printf '%s\n' claude claude claude)" ]; then
  fail "agent that fails but is ready: expected claude to run 3 times, but ran: $(cat "${STUB_LOG}")"
fi
case "${push_output}" in
  *"claude failed before changing anything in "*", although it is ready to run"*) ;;
  *) fail "agent that fails but is ready: wrong diagnostic: ${push_output}" ;;
esac
if ! grep -q -x -F "claude, an AI agent, could not resolve the merge's conflicts acceptably.  Ask a person for help with them before you finish the merge." "${feature_dir}/AGENT-TODO.md" \
  || grep -q 'no person needs to' "${feature_dir}/AGENT-TODO.md"; then
  fail "agent that fails but is ready: wrong AGENT-TODO.md: $(cat "${feature_dir}/AGENT-TODO.md" 2> /dev/null)"
fi

## A run stops at a merge in progress in the first directory, whose pull
## then refuses to start, so if the agent was not ready to resolve that
## merge's conflicts, AGENT-TODO.md says to abort the merge before running
## git-push-to again.  A rerun without the abort refuses to start and keeps
## that advice.  A run after the abort removes the entry and does resolve
## the conflicts.
setup_case from-pull-not-ready
git clone -q -b main "${remote}" "${case_dir}/other-clone"
write_file "${case_dir}/other-clone/file.txt" ONE two-remote three four five six SEVEN-main eight nine
git -C "${case_dir}/other-clone" commit -q -a -m "Change main remotely"
git -C "${case_dir}/other-clone" push -q
write_file "${main_dir}/file.txt" ONE two-local three four five six SEVEN-main eight nine
git -C "${main_dir}" commit -q -a -m "Change main locally"
push_to STUB_READY=fail good --llm
if [ "${push_status}" -eq 0 ] \
  || ! git -C "${main_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
  fail "agent that is not ready for the first directory's pull: no merge in progress there: ${push_output}"
fi
todo="${main_dir}/AGENT-TODO.md"
abort_line="claude, an AI agent, did not run, because it was not ready to run, as when it is not logged in.  Once claude can run, abort the merge with \`git merge --abort\`; then running the same command again asks claude to resolve the conflicts, so no person needs to."
if ! grep -q -x -F "${abort_line}" "${todo}"; then
  fail "agent that is not ready for the first directory's pull: wrong AGENT-TODO.md: $(cat "${todo}" 2> /dev/null)"
fi
push_to good --llm
if [ "${push_status}" -eq 0 ] \
  || ! git -C "${main_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
  fail "rerun without aborting the first directory's pull: no merge in progress there: ${push_output}"
fi
if ! grep -q -x -F "${abort_line}" "${todo}" \
  || [ "$(grep -c '^The merge of commit ' "${todo}")" -ne 1 ]; then
  fail "rerun without aborting the first directory's pull: wrong AGENT-TODO.md: $(cat "${todo}" 2> /dev/null)"
fi
git -C "${main_dir}" merge --abort
push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "rerun after aborting the first directory's pull: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != "$(printf '%s\n' claude claude)" ]; then
  fail "rerun after aborting the first directory's pull: expected claude to run twice, but ran: $(cat "${STUB_LOG}")"
fi
if [ -e "${todo}" ]; then
  fail "rerun after aborting the first directory's pull: AGENT-TODO.md remains: $(cat "${todo}")"
fi

## An agent that is not ready to run, as when it is not logged in, is not
## asked to resolve the conflicts.  AGENT-TODO.md says that running
## git-push-to again suffices; a rerun, once the agent is ready, does
## resolve the conflicts.
setup_case not-ready
push_to STUB_READY=fail good --llm
check_not_resolved "agent that is not ready"
if [ -s "${STUB_LOG}" ]; then
  fail "agent that is not ready: an agent ran: $(cat "${STUB_LOG}")"
fi
case "${push_output}" in
  *"claude is not ready to run (status 1)"*"It said: Not logged in"*) ;;
  *) fail "agent that is not ready: wrong diagnostic: ${push_output}" ;;
esac
todo="${feature_dir}/AGENT-TODO.md"
if ! grep -q -x -F "claude, an AI agent, did not run, because it was not ready to run, as when it is not logged in.  Once claude can run, running the same command again asks it to resolve the conflicts, so no person needs to." "${todo}" \
  || grep -q 'Ask a person' "${todo}"; then
  fail "agent that is not ready: wrong AGENT-TODO.md: $(cat "${todo}" 2> /dev/null)"
fi
push_to good --llm
check_resolved claude "rerun after an agent that was not ready"
if [ -e "${todo}" ]; then
  fail "rerun after an agent that was not ready: AGENT-TODO.md remains: $(cat "${todo}")"
fi

## An entry about a merge replaces an earlier one about the same merge, whose
## advice is out of date:  here, that no person needs to help, after an agent
## then failed after changing a file, and printed no session id.
setup_case not-ready-then-fail
echo "notes" > "${feature_dir}/notes.txt"
push_to STUB_READY=fail good --codex
todo="${feature_dir}/AGENT-TODO.md"
if ! grep -q 'no person needs to' "${todo}"; then
  fail "agent that is not ready, then fails: the first run's AGENT-TODO.md is wrong: $(cat "${todo}" 2> /dev/null)"
fi
push_to STUB_NO_SESSION=1 fail-untracked --codex
check_not_resolved "agent that is not ready, then fails"
if grep -q 'no person needs to' "${todo}" \
  || ! grep -q -x -F "codex, an AI agent, could not resolve the merge's conflicts acceptably.  Ask a person for help with them before you finish the merge." "${todo}" \
  || [ "$(grep -c -x 'The merge of commit .* is in progress in .*' "${todo}")" -ne 1 ]; then
  fail "agent that is not ready, then fails: wrong AGENT-TODO.md: $(cat "${todo}" 2> /dev/null)"
fi
## A later entry about the same merge does not replace one that asks a
## person for help.
push_to STUB_READY=fail good --codex
check_not_resolved "agent that fails, then is not ready"
if grep -q 'no person needs to' "${todo}" \
  || ! grep -q -x -F "codex, an AI agent, could not resolve the merge's conflicts acceptably.  Ask a person for help with them before you finish the merge." "${todo}"; then
  fail "agent that fails, then is not ready: wrong AGENT-TODO.md: $(cat "${todo}" 2> /dev/null)"
fi

## An agent that a signal ends, as when the user interrupts it, is not run
## again.
setup_case interrupted
push_to interrupted --llm
check_not_resolved "interrupted agent"
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "interrupted agent: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi
case "${push_output}" in
  *"claude was ended by signal 2, so it is not run again"*) ;;
  *) fail "interrupted agent: wrong diagnostic: ${push_output}" ;;
esac

## The cases from here to the matching "fi" are disabled; set
## ${run_history_cases} to 1 to run them.  Each is a merge in which one
## side's history contains the other side's version of a conflicted file,
## which can suggest, rightly or wrongly, that the side's version already
## has every change of the other side.  The stub agent judges nothing from
## history, so each case checks only what other cases already check:  that
## the agent runs, or that the merge stops before it does.  They are kept as
## examples of such merges.
run_history_cases=0
if [ "${run_history_cases}" -eq 1 ]; then
  ## With --no-llm, the merge stops even when a side's version of the
  ## conflicted file contains every change of the other side:  here feature
  ## reaches main's version of file.txt, as by merging a squashed copy of
  ## main's change, and then changes it further, next to main's change but not
  ## in it.
  setup_case contained-ours-no-llm
  printf '%s\n' ONE two three four five six SEVEN-main eight nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Reach main's version"
  printf '%s\n' ONE two three four five six SEVEN-main EIGHT-later nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Change feature again"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  push_to none --no-llm
  check_not_resolved "contained-ours-no-llm"
  if [ -s "${STUB_LOG}" ]; then
    fail "contained-ours-no-llm: an agent ran: $(cat "${STUB_LOG}")"
  fi

  ## A conflicted file that must be resolved by hand stops the merge before
  ## any agent runs, and leaves the other conflicted files as git left them,
  ## even one whose version on a side contains every change of the other side:
  ## here marker.txt, whose versions contain a line that looks like a conflict
  ## marker, and file.txt, whose version on feature contains main's changes.
  setup_case contained-blocked
  printf '%s\n' ONE two three four five six SEVEN-main eight nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Reach main's version"
  printf '%s\n' ONE two three four five six SEVEN-main EIGHT-later nine > "${feature_dir}/file.txt"
  printf '%s\n' '<<<<<<< feature' > "${feature_dir}/marker.txt"
  git -C "${feature_dir}" add marker.txt
  git -C "${feature_dir}" commit -q -a -m "Change feature again"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  printf '%s\n' '<<<<<<< main' > "${main_dir}/marker.txt"
  git -C "${main_dir}" add marker.txt
  git -C "${main_dir}" commit -q -m "Add marker.txt"
  git -C "${main_dir}" push -q
  push_to none --llm
  check_not_resolved "contained-blocked"
  case "${push_output}" in
    *"marker.txt contains lines that look like conflict markers"*) ;;
    *) fail "contained-blocked: wrong diagnostic: ${push_output}" ;;
  esac
  if [ -s "${STUB_LOG}" ]; then
    fail "contained-blocked: an agent ran: $(cat "${STUB_LOG}")"
  fi
  if ! grep -q '^<<<<<<< ' "${feature_dir}/file.txt"; then
    fail "contained-blocked: file.txt lost its conflict markers: $(cat "${feature_dir}/file.txt")"
  fi

  ## In each of the following cases, a side's history after the merge base, or
  ## at the conflicted pathname, contains the other side's version of the file,
  ## but the side's version does not contain every change of the other side,
  ## so a resolution that is that side's version would be wrong.  The agent
  ## runs, and here it leaves the conflict markers in place.
  ##
  ## Each side's history after the merge base contains the other side's
  ## version:  here feature changes file.txt to main's version and then to
  ## another, and main changes it to that other version and then to its
  ## own.  Neither side then contains the other's last change.
  setup_case contained-both
  printf '%s\n' ONE two three four five six SEVEN-main eight nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Reach main's version"
  printf '%s\n' ONE two three four five six SEVEN-main EIGHT-later nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Change feature again"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  printf '%s\n' ONE two three four five six SEVEN-main EIGHT-later nine > "${main_dir}/file.txt"
  git -C "${main_dir}" commit -q -a -m "Reach feature's version"
  printf '%s\n' ONE two three four five six SEVEN-main eight nine > "${main_dir}/file.txt"
  git -C "${main_dir}" commit -q -a -m "Change main again"
  git -C "${main_dir}" push -q
  push_to none --llm
  check_not_resolved "contained-both"
  if [ "$(cat "${STUB_LOG}")" != claude ]; then
    fail "contained-both: the agent did not run: ${push_output}"
  fi

  ## A side's history after the merge base contains the other side's content but
  ## not the other side's mode:  here main also makes file.txt executable.
  setup_case contained-mode
  printf '%s\n' ONE two three four five six SEVEN-main eight nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Reach main's version"
  printf '%s\n' ONE two three four five six SEVEN-main EIGHT-later nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Change feature again"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  chmod +x "${main_dir}/file.txt"
  git -C "${main_dir}" commit -q -a -m "Make file.txt executable"
  git -C "${main_dir}" push -q
  push_to none --llm
  check_not_resolved "contained-mode"
  if [ "$(cat "${STUB_LOG}")" != claude ]; then
    fail "contained-mode: the agent did not run: ${push_output}"
  fi

  ## A side reached the other side's version, including its change of mode, and
  ## then changed the mode back:  here main makes file.txt executable, and
  ## feature reaches main's version, and then makes file.txt not executable and
  ## changes a line that main did not change.
  setup_case contained-mode-reverted
  chmod +x "${main_dir}/file.txt"
  git -C "${main_dir}" commit -q -a -m "Make file.txt executable"
  git -C "${main_dir}" push -q
  printf '%s\n' ONE two three four five six SEVEN-main eight nine > "${feature_dir}/file.txt"
  chmod +x "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Reach main's version"
  printf '%s\n' ONE two three four five six SEVEN-main EIGHT-later nine > "${feature_dir}/file.txt"
  chmod -x "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Change feature again"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  push_to none --llm
  check_not_resolved "contained-mode-reverted"
  if [ "$(cat "${STUB_LOG}")" != claude ]; then
    fail "contained-mode-reverted: the agent did not run: ${push_output}"
  fi

  ## The other side's version is in a side's history only before the merge
  ## base:  then the other side changed the file back, as by a revert.  Here main
  ## merges feature, keeping main's version, so that feature's head becomes the
  ## merge base; then main changes file.txt back to the initial version, which is
  ## in feature's history before the merge base, and feature changes it further.
  setup_case contained-before-base
  git -C "${main_dir}" fetch -q
  git -C "${main_dir}" merge -q -s ours --no-edit origin/feature
  printf '%s\n' one two three four five six seven eight nine > "${main_dir}/file.txt"
  git -C "${main_dir}" commit -q -a -m "Change file.txt back to the initial version"
  git -C "${main_dir}" push -q
  printf '%s\n' one two three four five six SEVEN-feature-2 eight nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Change feature again"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  push_to none --llm
  check_not_resolved "contained-before-base"
  if [ "$(cat "${STUB_LOG}")" != claude ]; then
    fail "contained-before-base: the agent did not run: ${push_output}"
  fi

  ## After reaching the other side's version, a side changed the lines that the
  ## other side changed, as by a revert.  Here feature reaches main's version, as
  ## by cherry-picking main's change, then reverts that change, and then changes
  ## the file further, so that its version lacks main's change to line 1.
  setup_case contained-reverted
  printf '%s\n' ONE two three four five six SEVEN-main eight nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Reach main's version"
  git -C "${feature_dir}" revert --no-edit HEAD > /dev/null
  printf '%s\n' one two three four five six SEVEN-later eight nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Change feature again"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  push_to none --llm
  check_not_resolved "contained-reverted"
  if [ "$(cat "${STUB_LOG}")" != claude ]; then
    fail "contained-reverted: the agent did not run: ${push_output}"
  fi

  ## A side reverted the change that reached the other side's version, which
  ## restores no earlier version of the file:  here feature reaches main's
  ## version, changes line 4, and then reverts the change that reached main's
  ## version.
  setup_case contained-partly-reverted
  printf '%s\n' ONE two three four five six SEVEN-main eight nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Reach main's version"
  printf '%s\n' ONE two three FOUR-later five six SEVEN-main eight nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Change feature again"
  git -C "${feature_dir}" revert --no-edit HEAD~1 > /dev/null
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  push_to none --llm
  check_not_resolved "contained-partly-reverted"
  if [ "$(cat "${STUB_LOG}")" != claude ]; then
    fail "contained-partly-reverted: the agent did not run: ${push_output}"
  fi

  ## After reaching the other side's version, a side changed the lines that the
  ## other side changed in a way that might keep the other side's change, which
  ## only an agent can judge:  here feature reaches main's version and then
  ## changes main's line 7 again.
  setup_case contained-overlap
  printf '%s\n' ONE two three four five six SEVEN-main eight nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Reach main's version"
  printf '%s\n' ONE two three four five six SEVEN-later eight nine > "${feature_dir}/file.txt"
  git -C "${feature_dir}" commit -q -a -m "Change feature again"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  push_to none --llm
  check_not_resolved "contained-overlap"
  if [ "$(cat "${STUB_LOG}")" != claude ]; then
    fail "contained-overlap: the agent did not run: ${push_output}"
  fi

  ## A side has the conflicted file under another name, so the history of the
  ## other side at the conflicted pathname is not the file's history.  Here main
  ## renames file.txt to new.txt, and feature's history after the merge base has
  ## an unrelated new.txt, since deleted, whose content is main's version of
  ## file.txt.
  setup_case contained-renamed
  git -C "${main_dir}" mv file.txt new.txt
  git -C "${main_dir}" commit -q -m "Rename file.txt to new.txt"
  git -C "${main_dir}" push -q
  printf '%s\n' ONE two three four five six SEVEN-main eight nine > "${feature_dir}/new.txt"
  git -C "${feature_dir}" add new.txt
  git -C "${feature_dir}" commit -q -m "Add new.txt"
  git -C "${feature_dir}" rm -q new.txt
  git -C "${feature_dir}" commit -q -m "Remove new.txt"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  push_to none --llm
  check_not_resolved "contained-renamed"
  if [ "$(cat "${STUB_LOG}")" != claude ]; then
    fail "contained-renamed: the agent did not run: ${push_output}"
  fi
fi

echo "${SCRIPT_NAME}: all tests passed"
