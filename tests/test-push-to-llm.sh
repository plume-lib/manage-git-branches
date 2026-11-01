#!/bin/sh

# Tests that `git-push-to` asks an AI agent to resolve a merge that has
# conflicts, checks its work, and commits the merge; that it asks the agent to
# fix a failed build; that `--no-llm` prevents both; and that
# `git-pull-upstream` does the same.
#
# Usage:
#   tests/test-push-to-llm.sh
#
# Stub `claude` and `codex` commands stand in for the agents.  Environment
# variables STUB_MODE and STUB_BUILD say what the stubs do.
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

## The stub agents.  Each records its name in ${STUB_LOG} and its
## instructions in ${STUB_PROMPT}.  If file.txt has conflict markers, the stub
## acts according to ${STUB_MODE}:
##   good:   removes the conflict marker lines and the merge base's text,
##           keeping both sides
##   clean:  as "good", but also changes a line that merged cleanly
##   none:   changes nothing
##   fail:   exits with status 3
##   commit: as "good", but also commits the merge
##   create: as "good", but also creates a file
##   config: as "good", but also changes git's configuration
##   change-untracked: as "good", but also changes the untracked file notes.txt
##   delete-untracked: as "good", but also deletes the untracked file notes.txt
##   separator: as "good", but keeps the line "======="
##   hook-link: as "good", but also makes a hook a symbolic link to file.txt
## Otherwise, it is fixing a build, and it acts according to ${STUB_BUILD}:
##   fix:    removes the lines of other.txt that break the build
##   bad:    creates or changes notes.txt, which does not fix the build
##   once:   as "bad" the first time, and as "none" afterward
##   ignored: creates fix.local, a file that git ignores
##   none:   changes nothing (the default)
mkdir "${WORK_DIR}/test-bin"
cat > "${WORK_DIR}/test-bin/claude" << 'EOF'
#!/bin/sh
basename -- "$0" >> "${STUB_LOG}"
cat > "${STUB_PROMPT}"
if ! grep -q '^<<<<<<< ' file.txt; then
  case "${STUB_BUILD:-none}" in
    fix)
      sed -e '/BROKEN/d' other.txt > other.txt.new
      mv other.txt.new other.txt
      ;;
    bad) echo "an attempt" >> notes.txt ;;
    once)
      if [ ! -e notes.txt ]; then echo "an attempt" > notes.txt; fi
      ;;
    ignored) echo "a fix" > fix.local ;;
  esac
  exit 0
fi
if [ "${STUB_MODE}" = fail ]; then exit 3; fi
if [ "${STUB_MODE}" = none ]; then exit 0; fi
if [ "${STUB_MODE}" = separator ]; then
  sed -e '/^<<<<<<< /d' -e '/^||||||| /,/^=======$/{' -e '/^=======$/!d' -e '}' \
    -e '/^>>>>>>> /d' file.txt > file.txt.new
  mv file.txt.new file.txt
  exit 0
fi
sed -e '/^<<<<<<< /d' -e '/^||||||| /,/^=======$/d' -e '/^>>>>>>> /d' file.txt > file.txt.new
mv file.txt.new file.txt
if [ "${STUB_MODE}" = clean ]; then
  sed -e 's/^three$/THREE/' file.txt > file.txt.new
  mv file.txt.new file.txt
fi
if [ "${STUB_MODE}" = create ]; then
  echo "scratch" > scratch.txt
fi
if [ "${STUB_MODE}" = change-untracked ]; then
  echo "changed" >> notes.txt
fi
if [ "${STUB_MODE}" = delete-untracked ]; then
  rm notes.txt
fi
if [ "${STUB_MODE}" = hook-link ]; then
  ln -s ../../file.txt .git/hooks/pre-commit
fi
if [ "${STUB_MODE}" = config ]; then
  git config core.fsmonitor "echo pwned"
fi
if [ "${STUB_MODE}" = commit ]; then
  git add file.txt
  git commit -q -m "Resolved by the agent"
fi
exit 0
EOF
chmod +x "${WORK_DIR}/test-bin/claude"
cp "${WORK_DIR}/test-bin/claude" "${WORK_DIR}/test-bin/codex"
STUB_LOG="${WORK_DIR}/stub-log"
STUB_PROMPT="${WORK_DIR}/stub-prompt"
export STUB_LOG STUB_PROMPT

## Usage: setup_case NAME [KIND [LAST-LINE]]
## Creates a remote under ${WORK_DIR}/NAME with branches "main" and
## "feature", whose changes to file.txt conflict, and a clone of each.  Every
## version of file.txt ends with the line LAST-LINE, if it is given.  Sets
## ${main_dir} and ${feature_dir} to the clones and ${remote} to the remote.
## With KIND "build", the project has a Makefile, whose build fails if other.txt
## contains "BROKEN", and main adds "BROKEN" to other.txt.  With
## "build-modifies", the build also changes the tracked file other.txt if
## notes.txt exists.
setup_case() {
  case_last_line="${3-}"
  case_dir="${WORK_DIR}/$1"
  mkdir "${case_dir}"
  remote="${case_dir}/myrepo.git"
  git init -q --bare -b main "${remote}"
  git init -q -b main "${case_dir}/seed"
  write_file "${case_dir}/seed/file.txt" one two three four five six seven eight nine
  git -C "${case_dir}/seed" add file.txt
  if [ "${2:-}" = build ] || [ "${2:-}" = build-modifies ]; then
    echo 'all:' > "${case_dir}/seed/Makefile"
  fi
  if [ "${2:-}" = build-modifies ]; then
    printf '\t@if [ -e notes.txt ]; then echo "built" >> other.txt; fi\n' \
      >> "${case_dir}/seed/Makefile"
  fi
  if [ "${2:-}" = build ] || [ "${2:-}" = build-modifies ]; then
    printf '\t@if grep -n BROKEN other.txt; then echo "other.txt is broken" >&2; exit 1; fi\n' \
      >> "${case_dir}/seed/Makefile"
    echo "fine" > "${case_dir}/seed/other.txt"
    echo '*.local' > "${case_dir}/seed/.gitignore"
    git -C "${case_dir}/seed" add Makefile other.txt .gitignore
  fi
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

  write_file "${main_dir}/file.txt" ONE two three four five six SEVEN-main eight nine
  if [ "${2:-}" = build ] || [ "${2:-}" = build-modifies ]; then
    echo "BROKEN" >> "${main_dir}/other.txt"
  fi
  git -C "${main_dir}" commit -q -a -m "Change main"
  git -C "${main_dir}" push -q
  write_file "${feature_dir}/file.txt" one two three four five six SEVEN-feature eight nine
  git -C "${feature_dir}" commit -q -a -m "Change feature"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  : > "${STUB_LOG}"
}

## Usage: write_file FILE LINE...
## Writes the LINEs, and then ${case_last_line} if it is not empty, to FILE.
write_file() {
  write_file_name="$1"
  shift
  printf '%s\n' "$@" > "${write_file_name}"
  if [ -n "${case_last_line}" ]; then
    printf '%s\n' "${case_last_line}" >> "${write_file_name}"
  fi
}

## Usage: push_to MODE OPTION...
## Runs `git-push-to OPTION... ${main_dir} ${feature_dir}` with the stubs
## acting according to MODE.  Sets ${push_status} to its exit status and
## ${push_output} to its output.  It builds the project only if ${build} is 1.
build=0
push_to() {
  push_mode="$1"
  shift
  if [ "${build}" -eq 1 ]; then push_skip=''; else push_skip=1; fi
  if push_output="$(STUB_MODE="${push_mode}" PATH="${WORK_DIR}/test-bin:${PATH}" \
    MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT="${push_skip}" \
    "${COMMANDS_DIR}/git-push-to" "$@" "${main_dir}" "${feature_dir}" 2>&1)"; then
    push_status=0
  else
    push_status=$?
  fi
}

## Usage: check_resolved AGENT DESCRIPTION
## Checks that AGENT, and only it, resolved the conflicts, and that the merge
## was committed and pushed.  If AGENT is empty, checks that no agent ran.
check_resolved() {
  if [ "${push_status}" -ne 0 ]; then
    fail "$2: git-push-to failed: ${push_output}"
  fi
  if [ "$(cat "${STUB_LOG}")" != "$1" ]; then
    fail "$2: expected only $1 to run, but ran: $(cat "${STUB_LOG}")"
  fi
  if [ -n "$1" ] && ! grep -q 'file.txt' "${STUB_PROMPT}"; then
    fail "$2: the instructions do not name the conflicted file"
  fi
  remote_head="$(git -C "${remote}" rev-parse refs/heads/feature)"
  if [ "${remote_head}" != "$(git -C "${feature_dir}" rev-parse HEAD)" ]; then
    fail "$2: the merge was not pushed"
  fi
  if [ "$(git -C "${remote}" rev-parse "${remote_head}^1")" != "${feature_head}" ] \
    || [ "$(git -C "${remote}" rev-parse "${remote_head}^2")" != "$(git -C "${main_dir}" rev-parse HEAD)" ]; then
    fail "$2: the pushed commit is not the merge of main into feature"
  fi
  expected="$(printf '%s\n' ONE two three four five six SEVEN-feature SEVEN-main eight nine)"
  if [ "$(git -C "${remote}" show "${remote_head}:file.txt")" != "${expected}" ]; then
    fail "$2: wrong merge result: $(git -C "${remote}" show "${remote_head}:file.txt")"
  fi
  message="$(git -C "${remote}" log -1 --format=%B "${remote_head}")"
  if [ "${message}" != "Merge branch 'main' into feature" ]; then
    fail "$2: wrong merge message: ${message}"
  fi
}

## Usage: check_not_pushed DESCRIPTION
## Checks that git-push-to failed and pushed nothing.
check_not_pushed() {
  if [ "${push_status}" -eq 0 ]; then
    fail "$1: git-push-to succeeded"
  fi
  if [ "$(git -C "${remote}" rev-parse refs/heads/feature)" != "${feature_head}" ]; then
    fail "$1: pushed to feature"
  fi
}

## Usage: check_not_resolved DESCRIPTION
## Checks that git-push-to failed, pushed nothing, committed nothing, and left
## the merge in progress.
check_not_resolved() {
  check_not_pushed "$1"
  if [ "$(git -C "${feature_dir}" rev-parse HEAD)" != "${feature_head}" ]; then
    fail "$1: HEAD changed"
  fi
  if ! git -C "${feature_dir}" rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
    fail "$1: the merge is not in progress"
  fi
}

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

## An agent that is not installed is treated as with --no-llm.  The PATH
## leaves out the stand-ins, so the test is skipped if a real agent is on it.
no_agent_path="$(dirname -- "$(command -v git)"):/usr/bin:/bin"
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

## A change outside the conflict region is rejected.
setup_case clean
push_to clean --llm
check_not_resolved "change outside a conflict region"
case "${push_output}" in
  *"the text before the first conflict region changed"*) ;;
  *) fail "change outside a conflict region: wrong diagnostic: ${push_output}" ;;
esac

## Remaining conflict markers are rejected.
setup_case none
push_to none --llm
check_not_resolved "remaining conflict markers"
if ! grep -q '^||||||| ' "${feature_dir}/file.txt"; then
  fail "remaining conflict markers: the merge did not use the diff3 conflict style"
fi
case "${push_output}" in
  *"is a conflict marker"*) ;;
  *) fail "remaining conflict markers: wrong diagnostic: ${push_output}" ;;
esac

## A failing agent is reported.
setup_case fail
push_to fail --llm
check_not_resolved "failing agent"
case "${push_output}" in
  *"claude failed with status 3"*) ;;
  *) fail "failing agent: wrong diagnostic: ${push_output}" ;;
esac

## An agent that commits is rejected.
setup_case commit
push_to commit --llm
check_not_pushed "agent that commits"
case "${push_output}" in
  *"changed HEAD or MERGE_HEAD"*) ;;
  *) fail "agent that commits: wrong diagnostic: ${push_output}" ;;
esac

## An agent that creates a file is rejected.
setup_case create
push_to create --llm
check_not_resolved "agent that creates a file"
case "${push_output}" in
  *"created a file: scratch.txt"*) ;;
  *) fail "agent that creates a file: wrong diagnostic: ${push_output}" ;;
esac

## An agent that changes or deletes an untracked file is rejected.
for untracked_mode in change-untracked delete-untracked; do
  setup_case "${untracked_mode}"
  echo "notes" > "${feature_dir}/notes.txt"
  push_to "${untracked_mode}" --llm
  check_not_resolved "${untracked_mode}"
  case "${untracked_mode}:${push_output}" in
    change-untracked:*"changed an untracked file: notes.txt"*) ;;
    delete-untracked:*"deleted an untracked file: notes.txt"*) ;;
    *) fail "${untracked_mode}: wrong diagnostic: ${push_output}" ;;
  esac
done

## A file that contains a line that looks like a conflict marker is refused.
setup_case marker-like '' '>>>>>>> fixture'
push_to good --llm
check_not_resolved "marker-like line"
case "${push_output}" in
  *"contains lines that look like conflict markers"*) ;;
  *) fail "marker-like line: wrong diagnostic: ${push_output}" ;;
esac
if [ -s "${STUB_LOG}" ]; then
  fail "marker-like line: an agent ran: $(cat "${STUB_LOG}")"
fi

## A remaining separator is rejected.
setup_case separator
push_to separator --llm
check_not_resolved "remaining separator"
case "${push_output}" in
  *"is a conflict marker"*) ;;
  *) fail "remaining separator: wrong diagnostic: ${push_output}" ;;
esac

## An agent that adds a hook that is a symbolic link is rejected.
setup_case hook-link
push_to hook-link --llm
check_not_resolved "agent that adds a linked hook"
case "${push_output}" in
  *"changed git's configuration or hooks"*) ;;
  *) fail "agent that adds a linked hook: wrong diagnostic: ${push_output}" ;;
esac

## An agent that changes git's configuration is rejected.
setup_case config
push_to config --llm
check_not_resolved "agent that changes git's configuration"
case "${push_output}" in
  *"changed git's configuration or hooks"*) ;;
  *) fail "agent that changes git's configuration: wrong diagnostic: ${push_output}" ;;
esac

## A resolution that `git rerere` recorded needs no agent, whether or not
## rerere stages the files that it resolves, and is used even with --no-llm.
for rerere_case in false:--llm true:--llm false:--no-llm true:--no-llm; do
  auto_update="${rerere_case%%:*}"
  setup_case "rerere-${auto_update}${rerere_case#*:}"
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
  push_to none "${rerere_case#*:}"
  check_resolved "" "rerere (autoUpdate ${auto_update}, ${rerere_case#*:})"
done

## A failed build is fixed, and the fix is committed on top of the merge.
build=1
setup_case build-fix build
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "build fix: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != "$(printf '%s\n' claude claude)" ]; then
  fail "build fix: expected claude to run twice, but ran: $(cat "${STUB_LOG}")"
fi
if ! grep -q 'other.txt is broken' "${STUB_PROMPT}"; then
  fail "build fix: the instructions do not contain the build output"
fi
message="$(git -C "${remote}" log -1 --format=%B refs/heads/feature)"
if [ "${message}" != "Fix the build after merging branch 'main'" ]; then
  fail "build fix: wrong message for the fix: ${message}"
fi
if [ "$(git -C "${remote}" rev-parse refs/heads/feature^1^2)" != "$(git -C "${main_dir}" rev-parse HEAD)" ] \
  || [ "$(git -C "${remote}" show refs/heads/feature:other.txt)" != "fine" ]; then
  fail "build fix: the fix is not on top of the merge"
fi

## An agent that changes nothing gets one attempt.
setup_case build-none build
STUB_BUILD=none push_to good --llm
check_not_pushed "build not fixed"
case "${push_output}" in
  *"claude did not fix the build"*) ;;
  *) fail "build not fixed: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(wc -l < "${STUB_LOG}")" -ne 2 ]; then
  fail "build not fixed: expected claude to run twice, but ran: $(cat "${STUB_LOG}")"
fi

## An agent whose changes do not fix the build gets three attempts.
setup_case build-bad build
STUB_BUILD=bad push_to good --llm
check_not_pushed "bad build fix"
case "${push_output}" in
  *"in 3 attempts"*) ;;
  *) fail "bad build fix: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(wc -l < "${STUB_LOG}")" -ne 4 ]; then
  fail "bad build fix: expected claude to run 4 times, but ran: $(cat "${STUB_LOG}")"
fi
if ! git -C "${feature_dir}" diff --cached --name-only | grep -q -x notes.txt; then
  fail "bad build fix: the agent's changes are not staged"
fi
# A rerun does not build the staged changes, which would not be pushed.
: > "${STUB_LOG}"
STUB_BUILD=bad push_to good --llm
check_not_pushed "rerun after a bad build fix"
case "${push_output}" in
  *"has uncommitted changes"*) ;;
  *) fail "rerun after a bad build fix: wrong diagnostic: ${push_output}" ;;
esac
if [ -s "${STUB_LOG}" ]; then
  fail "rerun after a bad build fix: an agent ran: $(cat "${STUB_LOG}")"
fi

## Uncommitted changes are refused before the merge, which leaves no merge
## commit behind.
setup_case build-dirty build
echo "an edit" >> "${feature_dir}/other.txt"
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -eq 0 ]; then
  fail "uncommitted changes: git-push-to succeeded"
fi
if [ "$(git -C "${remote}" rev-parse refs/heads/feature)" != "${feature_head}" ]; then
  fail "uncommitted changes: pushed to feature"
fi
case "${push_output}" in
  *"has uncommitted changes"*) ;;
  *) fail "uncommitted changes: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(git -C "${feature_dir}" rev-parse HEAD)" != "${feature_head}" ]; then
  fail "uncommitted changes: a merge commit was made"
fi
if [ -s "${STUB_LOG}" ]; then
  fail "uncommitted changes: an agent ran: $(cat "${STUB_LOG}")"
fi

## An agent that creates a file that git ignores is rejected.
setup_case build-ignored build
STUB_BUILD=ignored push_to good --llm
check_not_pushed "build fix in an ignored file"
case "${push_output}" in
  *"created a file that git ignores: fix.local"*) ;;
  *) fail "build fix in an ignored file: wrong diagnostic: ${push_output}" ;;
esac

## An attempt that changes nothing ends the attempts, even after an earlier
## attempt changed files; the later attempt learns of the earlier one.
setup_case build-once build
STUB_BUILD=once push_to good --llm
check_not_pushed "build fix that gives up"
case "${push_output}" in
  *"it changed nothing"*) ;;
  *) fail "build fix that gives up: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(wc -l < "${STUB_LOG}")" -ne 3 ]; then
  fail "build fix that gives up: expected claude to run 3 times, but ran: $(cat "${STUB_LOG}")"
fi
if ! grep -q 'git diff --cached' "${STUB_PROMPT}"; then
  fail "build fix that gives up: the later attempt was not told of the earlier one"
fi

## A build that changes tracked files ends the attempts, so that its changes
## are not committed as the agent's.
setup_case build-modifies build-modifies
STUB_BUILD=bad push_to good --llm
check_not_pushed "build that changes tracked files"
case "${push_output}" in
  *"the build changed tracked files"*) ;;
  *) fail "build that changes tracked files: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(wc -l < "${STUB_LOG}")" -ne 2 ]; then
  fail "build that changes tracked files: expected claude to run twice, but ran: $(cat "${STUB_LOG}")"
fi

## With --no-llm, a failed build is not given to an agent.
setup_case build-no-llm build
STUB_BUILD=fix push_to good --no-llm
check_not_pushed "build with --no-llm"
if [ -s "${STUB_LOG}" ]; then
  fail "build with --no-llm: an agent ran: $(cat "${STUB_LOG}")"
fi
# The merge is now committed.  A rerun merges nothing, so the merge did not
# cause the failure, and no agent is asked to fix it.
STUB_BUILD=fix push_to good --llm
check_not_pushed "build failure without a merge"
if [ -s "${STUB_LOG}" ]; then
  fail "build failure without a merge: an agent ran: $(cat "${STUB_LOG}")"
fi
build=0

## An agent that is not installed is not asked to fix the build.  The merge
## has no conflicts, so that the build is reached.  As above, the test is
## skipped if a real agent is on the PATH.
if ! env PATH="${no_agent_path}" sh -c 'command -v claude' > /dev/null 2>&1; then
  setup_case build-no-agent build
  write_file "${feature_dir}/file.txt" ONE two three four five six SEVEN-main eight nine
  git -C "${feature_dir}" commit -q -a -m "Match main"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  if push_output="$(PATH="${no_agent_path}" MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT='' \
    "${COMMANDS_DIR}/git-push-to" --llm "${main_dir}" "${feature_dir}" 2>&1)"; then
    push_status=0
  else
    push_status=$?
  fi
  check_not_pushed "build with an agent that is not installed"
  case "${push_output}" in
    *"unable to build"*"cannot run claude, which is not on the PATH"*) ;;
    *) fail "build with an agent that is not installed: wrong diagnostic: ${push_output}" ;;
  esac
fi

## `git-pull-upstream` resolves conflicts too.
setup_case pull-upstream
git -C "${feature_dir}" remote set-head origin main
if ! pull_upstream_output="$(cd "${feature_dir}" && STUB_MODE=good PATH="${WORK_DIR}/test-bin:${PATH}" \
  "${COMMANDS_DIR}/git-pull-upstream" --llm 2>&1)"; then
  fail "git-pull-upstream --llm failed: ${pull_upstream_output}"
fi
expected="$(printf '%s\n' ONE two three four five six SEVEN-feature SEVEN-main eight nine)"
if [ "$(cat "${STUB_LOG}")" != claude ] \
  || [ "$(git -C "${remote}" show refs/heads/feature:file.txt)" != "${expected}" ]; then
  fail "git-pull-upstream --llm did not resolve the conflict"
fi

## `git-rebase-to` passes the option through.
setup_case rebase-to
if ! rebase_output="$(STUB_MODE=good PATH="${WORK_DIR}/test-bin:${PATH}" \
  "${COMMANDS_DIR}/git-rebase-to" --llm "${main_dir}" "${feature_dir}" 2>&1)"; then
  fail "git-rebase-to --llm failed: ${rebase_output}"
fi
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "git-rebase-to --llm: claude did not run"
fi

echo "${SCRIPT_NAME}: all tests passed"
