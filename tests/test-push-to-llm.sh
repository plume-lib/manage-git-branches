#!/bin/sh

# Tests that `git-push-to` asks an AI agent to resolve a merge that has
# conflicts, checks its work, and commits the merge; that it asks the agent to
# fix a failed build, including one that a pull broke; that `--no-llm`
# prevents both; and that `git-pull-upstream` does the same.
#
# Usage:
#   tests/test-push-to-llm.sh
#
# Stub `claude` and `codex` commands stand in for the agents.  Environment
# variables STUB_MODE and STUB_BUILD say what the stubs do, and the `codex`
# stub prints no session id if STUB_NO_SESSION is set.
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
##   fail-create: creates a file, then exits with status 3
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
##   fetch:  as "good", but also fetches main from origin, which overwrites
##           FETCH_HEAD
##   hang:   runs for 60 seconds, changing nothing
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
printf '%s\n' "$@" > "${STUB_ARGS}"
if [ "$(basename -- "$0")" = codex ] && [ -z "${STUB_NO_SESSION:-}" ]; then
  echo "session id: 01a19ac9-dab5-7570-93b6-6ba41bf65093" >&2
fi
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
if [ "${STUB_MODE}" = fail-create ]; then
  echo "scratch" > scratch.txt
  exit 3
fi
if [ "${STUB_MODE}" = none ]; then exit 0; fi
if [ "${STUB_MODE}" = hang ]; then exec sleep 60; fi
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
  fetch) git fetch -q origin main ;;
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
STUB_ARGS="${WORK_DIR}/stub-args"
export STUB_LOG STUB_PROMPT STUB_ARGS

## Usage: setup_case NAME [KIND [LAST-LINE]]
## Creates a remote under ${WORK_DIR}/NAME with branches "main" and
## "feature", whose changes to file.txt conflict, and a clone of each.  Every
## version of file.txt ends with the line LAST-LINE, if it is given.  Sets
## ${main_dir} and ${feature_dir} to the clones, ${remote} to the remote, and
## ${feature_head} to the commit at the head of feature.
## With KIND "build", the project has a Makefile, whose build fails if other.txt
## contains "BROKEN", and main adds "BROKEN" to other.txt.  With
## "build-modifies", the build also changes the tracked file other.txt if
## notes.txt exists.
##
## Creating the repositories takes about 30 processes, which are slow to
## start on macOS, so each case copies a template.  Every case of the same
## KIND without LAST-LINE copies the same template.
setup_case() {
  case_last_line="${3-}"
  case_dir="${WORK_DIR}/$1"
  if [ -e "${case_dir}" ]; then
    fail "setup_case: ${case_dir} already exists"
  fi
  remote="${case_dir}/myrepo.git"
  main_dir="${case_dir}/myrepo-branch-main"
  feature_dir="${case_dir}/myrepo-branch-feature"
  # No case can be named ".templates".  A case with LAST-LINE has a template
  # of its own, named after the case.
  case_template="${WORK_DIR}/.templates/${3:+$1-}${2:-plain}"
  if [ ! -d "${case_template}" ]; then
    mkdir -p "${WORK_DIR}/.templates"
    create_case_repositories "${case_template}" "${2:-}"
  fi
  cp -R "${case_template}" "${case_dir}"
  # A copied clone's origin is still the template's remote, and its index
  # records the template's files' inode numbers and times, so that git would
  # consider each file possibly changed.
  for case_clone in "${main_dir}" "${feature_dir}"; do
    git -C "${case_clone}" remote set-url origin "${remote}"
    git -C "${case_clone}" update-index -q --refresh
  done
  read -r feature_head < "${case_dir}/feature-head"
  : > "${STUB_LOG}"
}

## Usage: create_case_repositories DIR KIND
## Creates, in the new directory DIR, the repositories that `setup_case`
## describes for KIND, which is "", "build", or "build-modifies", and the file
## DIR/feature-head, which contains the commit at the head of feature.  Every
## version of file.txt ends with the line ${case_last_line}, if it is not
## empty.
create_case_repositories() {
  mkdir "$1"
  ccr_remote="$1/myrepo.git"
  git init -q --bare -b main "${ccr_remote}"
  git init -q -b main "$1/seed"
  write_file "$1/seed/file.txt" one two three four five six seven eight nine
  git -C "$1/seed" add file.txt
  if [ "$2" = build ] || [ "$2" = build-modifies ]; then
    echo 'all:' > "$1/seed/Makefile"
  fi
  if [ "$2" = build-modifies ]; then
    printf '\t@if [ -e notes.txt ]; then echo "built" >> other.txt; fi\n' \
      >> "$1/seed/Makefile"
  fi
  if [ "$2" = build ] || [ "$2" = build-modifies ]; then
    printf '\t@if grep -n BROKEN other.txt; then echo "other.txt is broken" >&2; exit 1; fi\n' \
      >> "$1/seed/Makefile"
    echo "fine" > "$1/seed/other.txt"
    echo '*.local' > "$1/seed/.gitignore"
    git -C "$1/seed" add Makefile other.txt .gitignore
  fi
  git -C "$1/seed" commit -q -m "Initial commit"
  git -C "$1/seed" push -q "${ccr_remote}" main main:refs/heads/feature
  # Nothing uses the seed after this push, and a copy of a template is
  # faster without it.
  rm -rf "$1/seed"

  ccr_main="$1/myrepo-branch-main"
  ccr_feature="$1/myrepo-branch-feature"
  git clone -q -b main "${ccr_remote}" "${ccr_main}"
  git clone -q -b feature "${ccr_remote}" "${ccr_feature}"
  git -C "${ccr_main}" config pull.rebase false
  git -C "${ccr_feature}" config pull.rebase false

  write_file "${ccr_main}/file.txt" ONE two three four five six SEVEN-main eight nine
  if [ "$2" = build ] || [ "$2" = build-modifies ]; then
    echo "BROKEN" >> "${ccr_main}/other.txt"
  fi
  git -C "${ccr_main}" commit -q -a -m "Change main"
  git -C "${ccr_main}" push -q
  write_file "${ccr_feature}/file.txt" one two three four five six SEVEN-feature eight nine
  git -C "${ccr_feature}" commit -q -a -m "Change feature"
  git -C "${ccr_feature}" push -q
  git -C "${ccr_feature}" rev-parse HEAD > "$1/feature-head"
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
## The command that continues Claude's session names the session that the
## stub was given.  The directory is a physical path, as on macOS, where
## the temporary directory is under a symbolic link.
session_id="$(sed -n -e '/^--session-id$/{n;p;}' "${STUB_ARGS}")"
session_dir="$(cd "${feature_dir}" && pwd -P)"
case "${session_id}" in
  "") fail "change outside a conflict region: claude was not given --session-id" ;;
  *)
    case "${push_output}" in
      *"to continue the session of claude:  cd ${session_dir} && claude --resume ${session_id}"*) ;;
      *) fail "change outside a conflict region: no command to continue the session: ${push_output}" ;;
    esac
    ## The command is also appended to AGENT-TODO.md, which starts with a
    ## title.
    todo="${feature_dir}/AGENT-TODO.md"
    if [ "$(head -n 1 "${todo}" 2> /dev/null)" != "# AI agent sessions to continue" ]; then
      fail "change outside a conflict region: AGENT-TODO.md has no title: $(cat "${todo}" 2> /dev/null)"
    fi
    if ! grep -q -x "## Resolve the conflicts in the merge of .* (git-push-to, .*)" "${todo}" \
      || ! grep -q -x -F "cd ${session_dir} && claude --resume ${session_id}" "${todo}"; then
      fail "change outside a conflict region: AGENT-TODO.md lacks the command: $(cat "${todo}")"
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

## A failing agent is reported.  The command that continues its session is
## appended to an existing AGENT-TODO.md, which gets no second title.
setup_case fail
printf '%s\n' '# AI agent sessions to continue' '' 'An earlier entry.' > "${feature_dir}/AGENT-TODO.md"
push_to fail --llm
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
push_to fail --llm
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
push_to fail --llm
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
push_to fail --llm
check_not_resolved "tracked AGENT-TODO.md"
case "${push_output}" in
  *"claude --resume "*"did not write AGENT-TODO.md, which git tracks"*) ;;
  *) fail "tracked AGENT-TODO.md: wrong diagnostic: ${push_output}" ;;
esac
if [ "$(cat "${feature_dir}/AGENT-TODO.md")" != "# Tracked" ]; then
  fail "tracked AGENT-TODO.md: the file was changed: $(cat "${feature_dir}/AGENT-TODO.md")"
fi

## The command that continues Codex's session names the session that Codex
## printed.
setup_case fail-codex
push_to fail --codex
check_not_resolved "failing codex"
case "${push_output}" in
  *"codex failed with status 3"*"to continue the session of codex:  cd "*" && codex resume 01a19ac9-dab5-7570-93b6-6ba41bf65093"*) ;;
  *) fail "failing codex: wrong diagnostic: ${push_output}" ;;
esac
if ! grep -q -x 'cd .* && codex resume 01a19ac9-dab5-7570-93b6-6ba41bf65093' "${feature_dir}/AGENT-TODO.md"; then
  fail "failing codex: AGENT-TODO.md lacks the command: $(cat "${feature_dir}/AGENT-TODO.md" 2> /dev/null)"
fi

## If Codex prints no session id, the user is told that its session cannot be
## continued, and AGENT-TODO.md is not written.
setup_case codex-no-session
STUB_NO_SESSION=1 push_to fail --codex
check_not_resolved "codex without a session id"
case "${push_output}" in
  *'codex printed no line "session id: UUID", so no command will be able to continue its session'*) ;;
  *) fail "codex without a session id: wrong diagnostic: ${push_output}" ;;
esac
case "${push_output}" in
  *"codex resume"*) fail "codex without a session id: a command to continue the session: ${push_output}" ;;
esac
if [ -e "${feature_dir}/AGENT-TODO.md" ]; then
  fail "codex without a session id: AGENT-TODO.md was written: $(cat "${feature_dir}/AGENT-TODO.md")"
fi

## The work of an agent that fails is checked too.
setup_case fail-create
push_to fail-create --llm
check_not_resolved "failing agent that creates a file"
case "${push_output}" in
  *"claude failed with status 3"*"created a file: scratch.txt"*) ;;
  *) fail "failing agent that creates a file: wrong diagnostic: ${push_output}" ;;
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

## A separator is permitted in a file whose sides contain a line "=======".
setup_case separator-content "" "======="
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

## An agent that runs longer than MANAGE_GIT_BRANCHES_LLM_TIMEOUT is stopped.
setup_case hang
hang_start="$(date +%s)"
MANAGE_GIT_BRANCHES_LLM_TIMEOUT=2
export MANAGE_GIT_BRANCHES_LLM_TIMEOUT
push_to hang --llm
unset MANAGE_GIT_BRANCHES_LLM_TIMEOUT
hang_seconds="$(($(date +%s) - hang_start))"
check_not_resolved "agent that runs too long"
case "${push_output}" in
  *"claude did not finish within 2 seconds"*) ;;
  *) fail "agent that runs too long: wrong diagnostic: ${push_output}" ;;
esac
if [ "${hang_seconds}" -ge 30 ]; then
  fail "agent that runs too long: took ${hang_seconds} seconds"
fi

## A time limit that is not a number is rejected.
setup_case bad-timeout
MANAGE_GIT_BRANCHES_LLM_TIMEOUT=soon
export MANAGE_GIT_BRANCHES_LLM_TIMEOUT
push_to good --llm
unset MANAGE_GIT_BRANCHES_LLM_TIMEOUT
check_not_resolved "bad MANAGE_GIT_BRANCHES_LLM_TIMEOUT"
case "${push_output}" in
  *"MANAGE_GIT_BRANCHES_LLM_TIMEOUT is not a number of seconds: soon"*) ;;
  *) fail "bad MANAGE_GIT_BRANCHES_LLM_TIMEOUT: wrong diagnostic: ${push_output}" ;;
esac

## A hook in the working tree, or a hook that links to a file in it, can be
## resolved like any other file.
setup_case hook-in-tree
git -C "${feature_dir}" config core.hooksPath .
push_to good --llm
check_resolved claude "core.hooksPath in the working tree"
setup_case hook-links-to-conflict
ln -s ../../file.txt "${feature_dir}/.git/hooks/pre-commit"
push_to good --llm
check_resolved claude "hook that links to a conflicted file"

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

## A rerun leaves the merge in progress if an AI agent is working in the
## directory.  The stand-in agent is a script named `claude`, which runs its
## arguments, or with none, runs until it is killed.  On Linux, a script's
## command name is the script's name.  On a system where `ps` names the
## script after its interpreter instead, these tests are skipped.
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

## Usage: start_agent DIR
## Starts the stand-in agent in DIR, and sets ${agent_pid} to its process id.
## Returns 1, after stopping the agent, if `ps` does not name it "claude".
start_agent() {
  (cd -- "$1" && exec "${WORK_DIR}/agent-bin/claude") &
  agent_pid=$!
  agent_tries=0
  until [ "$(basename -- "$(ps -o comm= -p "${agent_pid}")")" = claude ]; do
    agent_tries=$((agent_tries + 1))
    if [ "${agent_tries}" -gt 10 ]; then
      stop_agent
      return 1
    fi
    sleep 1
  done
}

## Usage: stop_agent
## Stops the stand-in agent that `start_agent` started.
stop_agent() {
  kill "${agent_pid}"
  wait "${agent_pid}" 2> /dev/null || true
}

if ! start_agent "${WORK_DIR}"; then
  echo "${SCRIPT_NAME}: skipping the tests of an AI agent working in a directory, because ps does not name a script after itself"
else
  stop_agent

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

## A merge in the history of the merged branch is not one that the fix
## follows:  it was built where that branch lives.  Main merges a side
## branch, so that its history has a merge commit.
setup_case build-fix-main-merge build
git -C "${main_dir}" switch -q -c side HEAD^
echo "side" > "${main_dir}/side.txt"
git -C "${main_dir}" add side.txt
git -C "${main_dir}" commit -q -m "Change side"
git -C "${main_dir}" switch -q main
git -C "${main_dir}" merge -q --no-ff --no-edit side
git -C "${main_dir}" push -q
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "build fix after a main with a merge: git-push-to failed: ${push_output}"
fi
message="$(git -C "${remote}" log -1 --format=%B refs/heads/feature)"
if [ "${message}" != "Fix the build after merging branch 'main'" ]; then
  fail "build fix after a main with a merge: wrong message for the fix: ${message}"
fi

## An agent that changes nothing gets one attempt.
setup_case build-none build
STUB_BUILD=none push_to good --llm
check_not_pushed "build not fixed"
case "${push_output}" in
  *"claude did not fix the build"*"claude --resume "*) ;;
  *) fail "build not fixed: wrong diagnostic: ${push_output}" ;;
esac
if ! grep -q -x "## Fix the build after merging branch 'main' (git-push-to, .*)" "${feature_dir}/AGENT-TODO.md"; then
  fail "build not fixed: AGENT-TODO.md lacks the entry: $(cat "${feature_dir}/AGENT-TODO.md" 2> /dev/null)"
fi
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
## Each attempt's session can be continued, but not the session that
## resolved the conflicts.
case "${push_output}" in
  *"to continue session 1 of 3 of claude:  cd "*"to continue session 2 of 3 of claude:  cd "*"to continue session 3 of 3 of claude:  cd "*) ;;
  *) fail "bad build fix: no command to continue each attempt's session: ${push_output}" ;;
esac
if [ "$(grep -c '^cd .* && claude --resume ' "${feature_dir}/AGENT-TODO.md")" -ne 3 ] \
  || ! grep -q -x 'Session 3 of 3:' "${feature_dir}/AGENT-TODO.md"; then
  fail "bad build fix: AGENT-TODO.md lacks a command per attempt: $(cat "${feature_dir}/AGENT-TODO.md")"
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

## With --no-llm, a failed build is not given to an agent.  Feature makes
## main's change to file.txt too, so that the merge has no conflicts, which
## --no-llm would leave unresolved, and the build runs.  Feature also adds a
## file, so that the merge's tree is not main's.
setup_case build-no-llm build
write_file "${feature_dir}/file.txt" ONE two three four five six SEVEN-main eight nine
echo "feature" > "${feature_dir}/feature.txt"
git -C "${feature_dir}" add feature.txt
git -C "${feature_dir}" commit -q -a -m "Change feature as main does"
git -C "${feature_dir}" push -q
feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
STUB_BUILD=fix push_to good --no-llm
check_not_pushed "build with --no-llm"
case "${push_output}" in
  *"unable to build"*) ;;
  *) fail "build with --no-llm: wrong diagnostic: ${push_output}" ;;
esac
if [ -s "${STUB_LOG}" ]; then
  fail "build with --no-llm: an agent ran: $(cat "${STUB_LOG}")"
fi
if ! git -C "${feature_dir}" merge-base --is-ancestor "$(git -C "${main_dir}" rev-parse HEAD)" HEAD; then
  fail "build with --no-llm: the merge was not committed"
fi
# The merge is now committed but not pushed.  A rerun merges nothing, but the
# unpushed merge might have caused the failure, so the agent is asked to fix
# it.
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "rerun after a failed build: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "rerun after a failed build: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi
if ! grep -q 'already contained commit' "${STUB_PROMPT}"; then
  fail "rerun after a failed build: the instructions do not say that the merge changed nothing: $(cat "${STUB_PROMPT}")"
fi
message="$(git -C "${remote}" log -1 --format=%B refs/heads/feature)"
if [ "${message}" != "Fix the build after merging branch 'main'" ]; then
  fail "rerun after a failed build: wrong message for the fix: ${message}"
fi

## A build that a commit, not a merge, broke is not given to an agent, which
## would merely work around the failure.  Main is reset to the initial
## commit, which feature already contains, so that merging main changes
## nothing.
setup_case build-no-merge build
git -C "${main_dir}" reset -q --hard HEAD^
git -C "${main_dir}" push -q --force
echo "BROKEN" >> "${feature_dir}/other.txt"
git -C "${feature_dir}" commit -q -a -m "Break the build locally"
STUB_BUILD=fix push_to good --llm
check_not_pushed "build failure without a merge"
case "${push_output}" in
  *"unable to build"*) ;;
  *) fail "build failure without a merge: wrong diagnostic: ${push_output}" ;;
esac
if [ -s "${STUB_LOG}" ]; then
  fail "build failure without a merge: an agent ran: $(cat "${STUB_LOG}")"
fi

## A merge that FROM_DIR's branch has but its remote lacks was not built, so
## the agent is asked to fix a build that it breaks, even when TO_DIR's
## branch fast-forwards to FROM_DIR's.  Main and feature are reset to the
## initial commit; then main makes a change and merges a side branch that
## adds "BROKEN" to other.txt, without pushing.
setup_case build-fast-forward-from-merge build
git -C "${main_dir}" reset -q --hard HEAD^
git -C "${main_dir}" push -q --force
git -C "${feature_dir}" reset -q --hard HEAD^
git -C "${feature_dir}" push -q --force
feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
git -C "${main_dir}" switch -q -c side
echo "BROKEN" >> "${main_dir}/other.txt"
git -C "${main_dir}" commit -q -a -m "Break the build on side"
git -C "${main_dir}" switch -q main
write_file "${main_dir}/file.txt" ONE two three four five six SEVEN-main eight nine
git -C "${main_dir}" commit -q -a -m "Change main locally"
git -C "${main_dir}" merge -q --no-ff --no-edit side
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "fast-forward to an unpushed merge: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "fast-forward to an unpushed merge: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi
if ! grep -q 'just fast-forwarded branch feature' "${STUB_PROMPT}"; then
  fail "fast-forward to an unpushed merge: the instructions do not say that the merge fast-forwarded: $(cat "${STUB_PROMPT}")"
fi
message="$(git -C "${remote}" log -1 --format=%B refs/heads/feature)"
if [ "${message}" != "Fix the build after merging branch 'side'" ]; then
  fail "fast-forward to an unpushed merge: wrong message for the fix: ${message}"
fi
if [ "$(git -C "${remote}" show refs/heads/feature:other.txt)" != "fine" ]; then
  fail "fast-forward to an unpushed merge: the build is not fixed"
fi

## The remote branch that the current branch pushes to is fetched before
## deciding whether a merge broke the build, if it is on a remote that the
## pull does not fetch.  Feature pushes to a fork.  A run with --no-llm
## merges main and fails to build; then the merge is pushed to the fork from
## elsewhere, which leaves the local remote-tracking branch out of date.  The
## fork has the merge, so the agent is not asked.
setup_case build-push-remote build
write_file "${feature_dir}/file.txt" ONE two three four five six SEVEN-main eight nine
echo "feature" > "${feature_dir}/feature.txt"
git -C "${feature_dir}" add feature.txt
git -C "${feature_dir}" commit -q -a -m "Change feature as main does"
git -C "${feature_dir}" push -q
fork="${case_dir}/fork.git"
git clone -q --bare "${remote}" "${fork}"
git -C "${feature_dir}" remote add fork "${fork}"
git -C "${feature_dir}" fetch -q fork
git -C "${feature_dir}" config branch.feature.pushRemote fork
# Git can name the branch that "simple" pushes to only if it is the upstream
# branch.
git -C "${feature_dir}" config push.default current
fork_head="$(git -C "${fork}" rev-parse refs/heads/feature)"
STUB_BUILD=fix push_to good --no-llm
if [ "${push_status}" -eq 0 ] || [ "$(git -C "${fork}" rev-parse refs/heads/feature)" != "${fork_head}" ]; then
  fail "build with a push remote: the first run pushed: ${push_output}"
fi
git -C "${feature_dir}" push -q fork feature
git -C "${feature_dir}" update-ref refs/remotes/fork/feature "${fork_head}"
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -eq 0 ]; then
  fail "build with an out-of-date push remote: git-push-to succeeded"
fi
case "${push_output}" in
  *"unable to build"*) ;;
  *) fail "build with an out-of-date push remote: wrong diagnostic: ${push_output}" ;;
esac
if [ -s "${STUB_LOG}" ]; then
  fail "build with an out-of-date push remote: an agent ran: $(cat "${STUB_LOG}")"
fi

## If git cannot name a remote branch that the current branch pushes to or
## pulls from, as when the branch's remote is a URL, a merge on the branch
## still counts as one that might have broken the build.
setup_case build-url-remote build
git -C "${feature_dir}" config branch.feature.remote "${remote}"
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "build fix with a URL remote: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != "$(printf '%s\n' claude claude)" ]; then
  fail "build fix with a URL remote: expected claude to run twice, but ran: $(cat "${STUB_LOG}")"
fi
# The heads that the pulls fetched were built, although no remote branch is
# known to have been.
if ! grep -q 'Branch feature has commits that are not in the histor' "${STUB_PROMPT}" \
  || grep -q 'no remote branch whose history is known to have been built' "${STUB_PROMPT}"; then
  fail "build fix with a URL remote: the instructions do not say that the commits are not in the fetched heads' histories: $(cat "${STUB_PROMPT}")"
fi
message="$(git -C "${remote}" log -1 --format=%B refs/heads/feature)"
if [ "${message}" != "Fix the build after merging branch 'main'" ]; then
  fail "build fix with a URL remote: wrong message for the fix: ${message}"
fi

## A build that succeeds, or a run with --no-llm, does not fetch the remote
## that FROM_DIR's branch pushes to.  Main pushes to a fork, whose main then
## changes, and main's build succeeds.  Feature makes main's change to
## file.txt too, so that the merge has no conflicts, which --no-llm would
## leave unresolved.
for llm_option in --llm --no-llm; do
  setup_case "build-no-fetch${llm_option}" build
  echo "fine" > "${main_dir}/other.txt"
  git -C "${main_dir}" commit -q -a -m "Fix the build on main"
  git -C "${main_dir}" push -q
  fork="${case_dir}/fork.git"
  git clone -q --bare "${remote}" "${fork}"
  git -C "${main_dir}" remote add fork "${fork}"
  git -C "${main_dir}" fetch -q fork
  fork_head="$(git -C "${main_dir}" rev-parse refs/remotes/fork/main)"
  # Change the fork's main without a push from main, which, because main has
  # a remote whose URL is the fork, could update refs/remotes/fork/main.
  git -C "${fork}" update-ref refs/heads/main \
    "$(git -C "${main_dir}" rev-list --max-parents=0 HEAD)"
  git -C "${main_dir}" config branch.main.pushRemote fork
  git -C "${main_dir}" config push.default current
  write_file "${feature_dir}/file.txt" ONE two three four five six SEVEN-main eight nine
  git -C "${feature_dir}" commit -q -a -m "Change feature as main does"
  git -C "${feature_dir}" push -q
  STUB_BUILD=fix push_to good "${llm_option}"
  if [ "${push_status}" -ne 0 ]; then
    fail "successful build with ${llm_option}: git-push-to failed: ${push_output}"
  fi
  if [ "$(git -C "${main_dir}" rev-parse refs/remotes/fork/main)" != "${fork_head}" ]; then
    fail "successful build with ${llm_option}: fetched the push remote of main"
  fi
  if [ -s "${STUB_LOG}" ]; then
    fail "successful build with ${llm_option}: an agent ran: $(cat "${STUB_LOG}")"
  fi
done

## A local branch that the current branch pulls from was not built
## elsewhere, so its unpushed merges might have broken the build.  Feature
## pulls from the local branch "base", whose merge of a side branch adds
## "BROKEN" to other.txt; the pull fast-forwards feature to base.  Main is
## reset to the initial commit, which feature already contains, so that
## merging main changes nothing.
setup_case build-local-upstream build
git -C "${main_dir}" reset -q --hard HEAD^
git -C "${main_dir}" push -q --force
git -C "${feature_dir}" switch -q -c side
echo "BROKEN" >> "${feature_dir}/other.txt"
git -C "${feature_dir}" commit -q -a -m "Break the build on side"
git -C "${feature_dir}" switch -q -c base feature
echo "base" > "${feature_dir}/base.txt"
git -C "${feature_dir}" add base.txt
git -C "${feature_dir}" commit -q -m "Change base"
git -C "${feature_dir}" merge -q --no-ff --no-edit side
git -C "${feature_dir}" switch -q feature
git -C "${feature_dir}" config branch.feature.remote .
git -C "${feature_dir}" config branch.feature.merge refs/heads/base
git -C "${feature_dir}" config branch.feature.pushRemote origin
git -C "${feature_dir}" config push.default current
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "build fix after a pull from a local branch: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "build fix after a pull from a local branch: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi
if [ "$(git -C "${remote}" show refs/heads/feature:other.txt)" != "fine" ]; then
  fail "build fix after a pull from a local branch: the build is not fixed"
fi

## Usage: set_pull_subject
## Sets ${pull_subject} to the subject of the merge that pulling feature from
## ${remote} makes, which names the remote-tracking branch rather than the
## remote's URL, and ${pull_description} to what it says was merged.
set_pull_subject() {
  pull_description="remote-tracking branch 'origin/feature'"
  pull_subject="Merge ${pull_description} into feature"
}

## Usage: setup_pull_breaks NAME [MAIN]
## Creates a case of kind "build" (see `setup_case`) in which pulling feature
## merges a local commit, which changes file.txt, with a commit of the remote
## that adds "BROKEN" to other.txt.  Unless MAIN is "main", main is reset to
## the initial commit, which feature already contains, so that merging main
## changes nothing.  Sets ${feature_head} to the remote's feature,
## ${local_head} to the local feature before the pull, ${pull_excluded} to
## the commits whose histories the agent is told were built (see
## `check_pull_fixed`), and the variables that `set_pull_subject` sets.
setup_pull_breaks() {
  setup_case "$1" build
  set_pull_subject
  if [ "${2:-}" = main ]; then
    pull_excluded="refs/remotes/origin/feature $(git -C "${remote}" rev-parse refs/heads/main)"
  else
    git -C "${main_dir}" reset -q --hard HEAD^
    git -C "${main_dir}" push -q --force
    pull_excluded=refs/remotes/origin/feature
  fi
  git clone -q -b feature "${remote}" "${case_dir}/other-clone"
  echo "BROKEN" >> "${case_dir}/other-clone/other.txt"
  git -C "${case_dir}/other-clone" commit -q -a -m "Break the build remotely"
  git -C "${case_dir}/other-clone" push -q
  feature_head="$(git -C "${remote}" rev-parse refs/heads/feature)"
  write_file "${feature_dir}/file.txt" one two three-local four five six SEVEN-feature eight nine
  git -C "${feature_dir}" commit -q -a -m "Change feature locally"
  local_head="$(git -C "${feature_dir}" rev-parse HEAD)"
}

## Usage: check_pull_fixed DESCRIPTION SUBJECT [LINE...]
## Checks that the fix of the build, whose message has the subject SUBJECT
## and contains each LINE, was committed on top of the merge of the pull of
## feature, which combines ${local_head} and ${feature_head}, and was pushed,
## that the agent was told how to list the commits that the remote's feature
## and the commits in ${pull_excluded} lack, and that no pushed commit
## message names the remote by its pathname.
check_pull_fixed() {
  check_description="$1"
  check_subject="$2"
  shift 2
  if ! grep -q -F "git log --graph --stat HEAD --not ${pull_excluded}\`" "${STUB_PROMPT}"; then
    fail "${check_description}: the instructions do not list the unpushed commits: $(cat "${STUB_PROMPT}")"
  fi
  message="$(git -C "${remote}" log -1 --format=%B refs/heads/feature)"
  if [ "$(printf '%s\n' "${message}" | head -n 1)" != "${check_subject}" ]; then
    fail "${check_description}: wrong message for the fix: ${message}"
  fi
  for check_line in "$@"; do
    if ! printf '%s\n' "${message}" | grep -q -x -F -- "${check_line}"; then
      fail "${check_description}: the message for the fix lacks [${check_line}]: ${message}"
    fi
  done
  if git -C "${remote}" log --format=%B refs/heads/feature | grep -q -F "${remote%.git}"; then
    fail "${check_description}: a pushed commit message names the remote by its pathname: $(git -C "${remote}" log --format=%B refs/heads/feature)"
  fi
  if [ "$(git -C "${remote}" show refs/heads/feature:other.txt)" != "fine" ]; then
    fail "${check_description}: the build is not fixed"
  fi
  if ! git -C "${remote}" merge-base --is-ancestor "${local_head}" refs/heads/feature \
    || ! git -C "${remote}" merge-base --is-ancestor "${feature_head}" refs/heads/feature; then
    fail "${check_description}: the fix is not on top of the merge of the pull"
  fi
}

## A pull that breaks the build, followed by a merge that changes nothing, is
## fixed too.
setup_pull_breaks pull-build
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "pull that breaks the build: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "pull that breaks the build: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi
check_pull_fixed "pull that breaks the build" \
  "Fix the build after merging ${pull_description}"
## The agent is told what each side of the pull's merge changed.
if ! grep -q -x -F "  It merged commit ${feature_head} into commit ${local_head}.  \`git log -p --remerge-diff ${feature_head}..${local_head}\` shows the commits that only ${local_head} had, and \`git log -p --remerge-diff ${local_head}..${feature_head}\` shows the commits that only ${feature_head} had." "${STUB_PROMPT}"; then
  fail "pull that breaks the build: the instructions do not say what each side of the pull's merge changed: $(cat "${STUB_PROMPT}")"
fi

## When both the pull and the merge change the branch, the fix's message
## lists both merges.
setup_pull_breaks pull-build-merge main
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "pull and merge that break the build: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != "$(printf '%s\n' claude claude)" ]; then
  fail "pull and merge that break the build: expected claude to run twice, but ran: $(cat "${STUB_LOG}")"
fi
check_pull_fixed "pull and merge that break the build" "Fix the build after merges" \
  "* ${pull_subject}" "* Merge branch 'main' into feature"

## A pull that fast-forwards makes no merge, so it did not break the build,
## which was already broken on the remote; no agent is asked to fix it.  Nor
## is one asked after a pull that makes a merge although it could have
## fast-forwarded:  the merge's tree is the remote's.
for ff in true false; do
  setup_pull_breaks "pull-build-fast-forward-${ff}"
  git -C "${feature_dir}" reset -q --hard HEAD^
  git -C "${feature_dir}" config pull.ff "${ff}"
  STUB_BUILD=fix push_to good --llm
  check_not_pushed "pull with pull.ff=${ff} to a broken build"
  case "${push_output}" in
    *"unable to build"*) ;;
    *) fail "pull with pull.ff=${ff} to a broken build: wrong diagnostic: ${push_output}" ;;
  esac
  if [ -s "${STUB_LOG}" ]; then
    fail "pull with pull.ff=${ff} to a broken build: an agent ran: $(cat "${STUB_LOG}")"
  fi
done

## Usage: setup_broken_clone_merge CASE
## Sets up a case named CASE, in which the feature branch of
## ${case_dir}/other-clone, a working clone of the remote, has a merge, not
## yet pushed, that combines a commit that adds remote.txt with one that adds
## "BROKEN" to other.txt.  Main is reset to the initial commit, which feature
## already contains, so that merging main changes nothing.
setup_broken_clone_merge() {
  setup_case "$1" build
  git -C "${main_dir}" reset -q --hard HEAD^
  git -C "${main_dir}" push -q --force
  git clone -q -b feature "${remote}" "${case_dir}/other-clone"
  git -C "${case_dir}/other-clone" switch -q -c side
  echo "BROKEN" >> "${case_dir}/other-clone/other.txt"
  git -C "${case_dir}/other-clone" commit -q -a -m "Break the build on side"
  git -C "${case_dir}/other-clone" switch -q feature
  echo "remote" > "${case_dir}/other-clone/remote.txt"
  git -C "${case_dir}/other-clone" add remote.txt
  git -C "${case_dir}/other-clone" commit -q -m "Add remote.txt"
  git -C "${case_dir}/other-clone" merge -q --no-ff --no-edit side
}

## When the branch's remote is a URL, no remote-tracking branch records the
## remote's feature, but the head that the pull fetched was built there too.
## So a pull that fast-forwards to a merge of the remote that breaks the
## build does not ask the agent.
setup_broken_clone_merge pull-build-fast-forward-url
git -C "${case_dir}/other-clone" push -q
feature_head="$(git -C "${remote}" rev-parse refs/heads/feature)"
git -C "${feature_dir}" config branch.feature.remote "${remote}"
STUB_BUILD=fix push_to good --llm
check_not_pushed "pull with a URL remote to a broken build"
case "${push_output}" in
  *"unable to build"*) ;;
  *) fail "pull with a URL remote to a broken build: wrong diagnostic: ${push_output}" ;;
esac
if [ -s "${STUB_LOG}" ]; then
  fail "pull with a URL remote to a broken build: an agent ran: $(cat "${STUB_LOG}")"
fi

## When the branch's remote is a URL, the pull updates no remote-tracking
## branch, so origin/feature lacks the commit that the pull merged and does
## not name it.  The merge's message names the remote by the last component of
## its pathname, which it does not reveal.  A clean merge does not report that
## it stopped before committing.
setup_pull_breaks pull-build-url-merge
git -C "${feature_dir}" config branch.feature.remote "${remote}"
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "pull with a URL remote that breaks the build: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "pull with a URL remote that breaks the build: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi
case "${push_output}" in
  *"stopped before committing"*)
    fail "pull with a URL remote that breaks the build: the output says that the merge stopped: ${push_output}"
    ;;
esac
url_remote_name="${remote%.git}"
url_remote_name="${url_remote_name##*/}"
message="$(git -C "${remote}" log -1 --format=%s refs/heads/feature)"
if [ "${message}" != "Fix the build after merging branch 'feature' of ${url_remote_name}" ]; then
  fail "pull with a URL remote that breaks the build: wrong message for the fix: ${message}"
fi
if git -C "${remote}" log --format=%B refs/heads/feature | grep -q -F "${remote%.git}"; then
  fail "pull with a URL remote that breaks the build: a pushed commit message names the remote by its pathname: $(git -C "${remote}" log --format=%B refs/heads/feature)"
fi

## A working clone in the local file system, unlike a bare repository, need
## not have pushed its branches, so the head that a pull from it fetched was
## not necessarily built.  A pull that fast-forwards to an unpushed merge of
## that clone that breaks the build asks the agent, whether the branch's
## remote is the clone's pathname or the name of a remote, whose
## remote-tracking branch then records the clone's feature.
for clone_remote in pathname name; do
  setup_broken_clone_merge "pull-build-fast-forward-clone-${clone_remote}"
  if [ "${clone_remote}" = name ]; then
    git -C "${feature_dir}" remote add clone "${case_dir}/other-clone"
    git -C "${feature_dir}" config branch.feature.remote clone
  else
    git -C "${feature_dir}" config branch.feature.remote "${case_dir}/other-clone"
  fi
  git -C "${feature_dir}" config branch.feature.pushRemote origin
  git -C "${feature_dir}" config push.default current
  STUB_BUILD=fix push_to good --llm
  if [ "${push_status}" -ne 0 ]; then
    fail "pull from a working clone, by ${clone_remote}, to a broken build: git-push-to failed: ${push_output}"
  fi
  if [ "$(cat "${STUB_LOG}")" != claude ]; then
    fail "pull from a working clone, by ${clone_remote}, to a broken build: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
  fi
  if [ "$(git -C "${remote}" show refs/heads/feature:other.txt)" != "fine" ]; then
    fail "pull from a working clone, by ${clone_remote}, to a broken build: the build is not fixed"
  fi
done

## A merge that a pull makes, although it could have fast-forwarded,
## combines no changes, so the fix's message does not list it.
setup_pull_breaks pull-build-no-ff-merge main
git -C "${feature_dir}" reset -q --hard HEAD^
local_head="$(git -C "${feature_dir}" rev-parse HEAD)"
git -C "${feature_dir}" config pull.ff false
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "pull with pull.ff=false and a merge that breaks the build: git-push-to failed: ${push_output}"
fi
check_pull_fixed "pull with pull.ff=false and a merge that breaks the build" \
  "Fix the build after merging branch 'main'"
if grep -q -F "${pull_subject}" "${STUB_PROMPT}"; then
  fail "pull with pull.ff=false and a merge that breaks the build: the instructions list the pull's merge: $(cat "${STUB_PROMPT}")"
fi

## The pull of TO_DIR merges even if `pull.rebase` is set, so the agent fixes
## the merge.
setup_pull_breaks pull-build-rebase
git -C "${feature_dir}" config pull.rebase true
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "pull with pull.rebase that breaks the build: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "pull with pull.rebase that breaks the build: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi
check_pull_fixed "pull with pull.rebase that breaks the build" \
  "Fix the build after merging ${pull_description}"

## In a rerun after a failed build, a pull that merges new commits of the
## remote does not hide the unpushed merge of the earlier run, which broke
## the build.
setup_case pull-build-rerun build
set_pull_subject
pull_excluded="refs/remotes/origin/feature $(git -C "${remote}" rev-parse refs/heads/main)"
STUB_BUILD=none push_to good --llm
check_not_pushed "failed build before a rerun"
: > "${STUB_LOG}"
local_head="$(git -C "${feature_dir}" rev-parse HEAD)"
git clone -q -b feature "${remote}" "${case_dir}/other-clone"
echo "unrelated" > "${case_dir}/other-clone/third.txt"
git -C "${case_dir}/other-clone" add third.txt
git -C "${case_dir}/other-clone" commit -q -m "Change feature remotely"
git -C "${case_dir}/other-clone" push -q
feature_head="$(git -C "${remote}" rev-parse refs/heads/feature)"
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "rerun whose pull merges: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "rerun whose pull merges: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi
check_pull_fixed "rerun whose pull merges" "Fix the build after merges" \
  "* Merge branch 'main' into feature" "* ${pull_subject}"

## Usage: push_remote_commit
## Pushes a commit to feature that adds the file remote.txt, which does not
## affect the build, from a clone other than ${feature_dir}.  Sets
## ${feature_head} to it.
push_remote_commit() {
  git clone -q -b feature "${remote}" "${case_dir}/other-clone"
  echo "remote" > "${case_dir}/other-clone/remote.txt"
  git -C "${case_dir}/other-clone" add remote.txt
  git -C "${case_dir}/other-clone" commit -q -m "Add remote.txt"
  git -C "${case_dir}/other-clone" push -q
  feature_head="$(git -C "${remote}" rev-parse refs/heads/feature)"
}

## A pull that fast-forwards makes no merge commit, so after it the fix's
## message names only the merge of main, which broke the build.
setup_case pull-ff-merge-build build
push_remote_commit
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "fast-forward pull and a merge that breaks the build: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != "$(printf '%s\n' claude claude)" ]; then
  fail "fast-forward pull and a merge that breaks the build: expected claude to run twice, but ran: $(cat "${STUB_LOG}")"
fi
message="$(git -C "${remote}" log -1 --format=%B refs/heads/feature)"
if [ "${message}" != "Fix the build after merging branch 'main'" ]; then
  fail "fast-forward pull and a merge that breaks the build: wrong message for the fix: ${message}"
fi

## When the merge fast-forwards to a merge commit that the pull of FROM_DIR
## made, the agent is asked to fix the build:  no remote branch of main or of
## feature contains that merge commit.
setup_case pull-from-ff-build build
git -C "${main_dir}" reset -q --hard HEAD^
git -C "${main_dir}" push -q --force
git -C "${feature_dir}" reset -q --hard "$(git -C "${main_dir}" rev-parse HEAD)"
git -C "${feature_dir}" push -q --force
git clone -q -b main "${remote}" "${case_dir}/other-clone"
echo "BROKEN" >> "${case_dir}/other-clone/other.txt"
git -C "${case_dir}/other-clone" commit -q -a -m "Break the build remotely"
git -C "${case_dir}/other-clone" push -q
echo "local" > "${main_dir}/local.txt"
git -C "${main_dir}" add local.txt
git -C "${main_dir}" commit -q -m "Add local.txt"
STUB_BUILD=fix push_to good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "fast-forward to a merge of FROM_DIR's pull: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "fast-forward to a merge of FROM_DIR's pull: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi
if ! grep -q 'just fast-forwarded branch feature' "${STUB_PROMPT}"; then
  fail "fast-forward to a merge of FROM_DIR's pull: the instructions do not say that the merge fast-forwarded: $(cat "${STUB_PROMPT}")"
fi
message="$(git -C "${remote}" log -1 --format=%B refs/heads/feature)"
if [ "${message}" != "Fix the build after merging remote-tracking branch 'origin/main'" ]; then
  fail "fast-forward to a merge of FROM_DIR's pull: wrong message for the fix: ${message}"
fi
if [ "$(git -C "${remote}" show refs/heads/feature:other.txt)" != "fine" ]; then
  fail "fast-forward to a merge of FROM_DIR's pull: the build is not fixed"
fi

## With --no-llm, a pull that breaks the build is not given to an agent.
setup_pull_breaks pull-build-no-llm
STUB_BUILD=fix push_to good --no-llm
check_not_pushed "pull that breaks the build, with --no-llm"
if [ -s "${STUB_LOG}" ]; then
  fail "pull that breaks the build, with --no-llm: an agent ran: $(cat "${STUB_LOG}")"
fi

## `git-pull-upstream` fixes a build that its pull breaks, even when merging
## the upstream repository's default branch changes nothing.
setup_pull_breaks pull-upstream-build
git -C "${feature_dir}" remote set-head origin main
if ! pull_upstream_output="$(cd "${feature_dir}" && STUB_BUILD=fix PATH="${WORK_DIR}/test-bin:${PATH}" \
  MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT='' "${COMMANDS_DIR}/git-pull-upstream" --llm 2>&1)"; then
  fail "git-pull-upstream after a pull that breaks the build failed: ${pull_upstream_output}"
fi
if [ "$(cat "${STUB_LOG}")" != claude ]; then
  fail "git-pull-upstream after a pull that breaks the build: expected claude to run once, but ran: $(cat "${STUB_LOG}")"
fi
check_pull_fixed "git-pull-upstream after a pull that breaks the build" \
  "Fix the build after merging ${pull_description}"
build=0

## An agent that is not installed is not asked to fix the build.  The merge
## has no conflicts, so that the build is reached, and its tree is not
## main's.  As above, the test is
## skipped if a real agent is on the PATH.
if ! env PATH="${no_agent_path}" sh -c 'command -v claude' > /dev/null 2>&1; then
  setup_case build-no-agent build
  write_file "${feature_dir}/file.txt" ONE two three four five six SEVEN-main eight nine
  echo "feature" > "${feature_dir}/feature.txt"
  git -C "${feature_dir}" add feature.txt
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
