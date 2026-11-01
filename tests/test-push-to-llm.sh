#!/bin/sh

# Tests that `git-push-to` asks an AI agent to resolve a merge that has
# conflicts, checks its work, and commits the merge; that `--no-llm` prevents
# that; and that `git-pull-upstream` does the same.
#
# Usage:
#   tests/test-push-to-llm.sh
#
# Stub `claude` and `codex` commands stand in for the agents.  Environment
# variable STUB_MODE says what the stubs do.
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
## instructions in ${STUB_PROMPT}, then acts according to ${STUB_MODE}:
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
##   stage:  stages a resolution that changes a line that merged cleanly, then
##           writes the resolution of "good"
##   create-ignored: as "good", but also creates build/new.class in the
##           ignored directory build
##   change-ignored: as "good", but also changes the ignored file build/old.txt
##   include: as "good", but also changes local.gitconfig, which git's
##           configuration includes
##   attributes: as "good", but also changes .git/info/attributes
##   change-rerere: as "good", but also changes other.txt, whose conflict
##           `git rerere` resolved
##   change-quoted: as "good", but also changes the untracked file a"b\c
##   change-nested: as "good", but also changes nested/file.txt in an
##           untracked nested repository
##   separator-long: removes the conflict marker lines other than separators
##           of any length
##   auto-merge: as "good", but also makes AUTO_MERGE name HEAD's tree
##   sandbox-dirs: as "good", but also creates the empty directories that
##           Codex's sandbox creates
mkdir "${WORK_DIR}/test-bin"
cat > "${WORK_DIR}/test-bin/claude" << 'EOF'
#!/bin/sh
basename -- "$0" >> "${STUB_LOG}"
cat > "${STUB_PROMPT}"
if [ "${STUB_MODE}" = fail ]; then exit 3; fi
if [ "${STUB_MODE}" = none ]; then exit 0; fi
if [ "${STUB_MODE}" = separator-long ]; then
  sed -e '/^<<<<<<</d' -e '/^>>>>>>>/d' file.txt > file.txt.new
  mv file.txt.new file.txt
  exit 0
fi
if [ "${STUB_MODE}" = separator ]; then
  sed -e '/^<<<<<<< /d' -e '/^||||||| /,/^=======$/{' -e '/^=======$/!d' -e '}' \
    -e '/^>>>>>>> /d' file.txt > file.txt.new
  mv file.txt.new file.txt
  exit 0
fi
sed -e '/^<<<<<<< /d' -e '/^||||||| /,/^=======$/d' -e '/^=======$/d' -e '/^>>>>>>> /d' \
  file.txt > file.txt.new
mv file.txt.new file.txt
if [ "${STUB_MODE}" = stage ]; then
  cp file.txt good.tmp
  sed -e 's/^three$/THREE/' good.tmp > file.txt
  git add file.txt
  mv good.tmp file.txt
fi
case "${STUB_MODE}" in
  create-ignored) echo "class" > build/new.class ;;
  change-ignored) echo "changed" >> build/old.txt ;;
  include) printf '[core]\n\tfsmonitor = echo pwned\n' >> local.gitconfig ;;
  attributes) echo '* diff=pwned' >> .git/info/attributes ;;
  change-rerere) echo "agent" >> other.txt ;;
  change-quoted) echo "changed" >> 'a"b\c' ;;
  change-nested) echo "changed" >> nested/file.txt ;;
  auto-merge) git update-ref AUTO_MERGE "$(git rev-parse 'HEAD^{tree}')" ;;
  sandbox-dirs) mkdir .agents .aws .codex ;;
esac
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

## Usage: setup_case NAME [LAST-LINE]
## Creates a remote under ${WORK_DIR}/NAME with branches "main" and
## "feature", whose changes to file.txt conflict, and a clone of each.  Every
## version of file.txt ends with the line LAST-LINE, if it is given.  Sets
## ${main_dir} and ${feature_dir} to the clones and ${remote} to the remote.
setup_case() {
  case_last_line="${2-}"
  case_dir="${WORK_DIR}/$1"
  mkdir "${case_dir}"
  remote="${case_dir}/myrepo.git"
  git init -q --bare -b main "${remote}"
  git init -q -b main "${case_dir}/seed"
  write_file "${case_dir}/seed/file.txt" one two three four five six seven eight nine
  git -C "${case_dir}/seed" add file.txt
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
## ${push_output} to its output.
push_to() {
  push_mode="$1"
  shift
  if push_output="$(STUB_MODE="${push_mode}" PATH="${WORK_DIR}/test-bin:${PATH}" \
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
  *"changed HEAD, MERGE_HEAD, or AUTO_MERGE"*) ;;
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
    change-untracked:*"changed a file: notes.txt"*) ;;
    delete-untracked:*"deleted a file: notes.txt"*) ;;
    *) fail "${untracked_mode}: wrong diagnostic: ${push_output}" ;;
  esac
done

## A file that contains a line that looks like a conflict marker is refused.
setup_case marker-like '>>>>>>> fixture'
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

## A separator is permitted in a file whose sides contain a line "=======".
setup_case separator-content "======="
push_to separator --llm
if [ "${push_status}" -ne 0 ]; then
  fail "separator in a file that contains one: git-push-to failed: ${push_output}"
fi

## A remaining separator that is longer than 7 "=" is rejected.  Git writes
## one for a file whose attribute `conflict-marker-size` is larger.
setup_case separator-long
echo 'file.txt conflict-marker-size=10' > "${feature_dir}/.git/info/attributes"
push_to separator-long --llm
check_not_resolved "remaining long separator"
case "${push_output}" in
  *"is a conflict marker"*) ;;
  *) fail "remaining long separator: wrong diagnostic: ${push_output}" ;;
esac

## An agent that changes AUTO_MERGE is rejected.
setup_case auto-merge
push_to auto-merge --llm
check_not_pushed "agent that changes AUTO_MERGE"
case "${push_output}" in
  *"changed HEAD, MERGE_HEAD, or AUTO_MERGE"*) ;;
  *) fail "agent that changes AUTO_MERGE: wrong diagnostic: ${push_output}" ;;
esac

## The empty directories that Codex's sandbox creates are removed, and do
## not keep the resolution from being committed.
setup_case sandbox-dirs
push_to sandbox-dirs --codex
check_resolved codex "Codex's sandbox directories"
for sandbox_dir in .agents .aws .codex; do
  if [ -e "${feature_dir}/${sandbox_dir}" ]; then
    fail "Codex's sandbox directories: ${sandbox_dir} remains"
  fi
done

## An agent that adds a hook that is a symbolic link is rejected.
setup_case hook-link
push_to hook-link --llm
check_not_resolved "agent that adds a linked hook"
case "${push_output}" in
  *"changed git's configuration, attributes, or hooks"*) ;;
  *) fail "agent that adds a linked hook: wrong diagnostic: ${push_output}" ;;
esac

## An agent that changes git's configuration is rejected.
setup_case config
push_to config --llm
check_not_resolved "agent that changes git's configuration"
case "${push_output}" in
  *"changed git's configuration, attributes, or hooks"*) ;;
  *) fail "agent that changes git's configuration: wrong diagnostic: ${push_output}" ;;
esac

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

## An agent that changes a file whose conflict `git rerere` resolved is
## rejected.  Only the other conflicted file is named to the agent.
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
check_not_resolved "change-rerere"
if grep -q 'other.txt' "${STUB_PROMPT}"; then
  fail "change-rerere: the instructions name the file that rerere resolved"
fi
case "${push_output}" in
  *"changed a file: other.txt"*) ;;
  *) fail "change-rerere: wrong diagnostic: ${push_output}" ;;
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
