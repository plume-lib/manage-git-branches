# Setup that is shared by the tests `test-push-to-llm-*.sh`, which test that
# `git-push-to` asks an AI agent to resolve a merge that has conflicts, checks
# its work, and commits the merge; that it asks the agent to fix a failed
# build, including one that a pull broke; that `--no-llm` prevents both; and
# that `git-pull-upstream` does the same.  Set TESTS_DIR to this directory,
# then source this file:
#
#   TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
#   . "${TESTS_DIR}/lib-push-to-llm.sh"
#
# This file is sourced rather than run, so it has no shebang line and is not
# executable.  Its name does not begin with `test-`, so `run-tests.sh` does
# not treat it as a test.
#
# Stub `claude` and `codex` commands stand in for the agents.  Environment
# variables STUB_MODE and STUB_BUILD say what the stubs do, the `codex`
# stub prints no session id if STUB_NO_SESSION is set, and the check that an
# agent is ready to run fails if STUB_READY is "fail".  A stub that fails
# without changing anything acts as if its service were unavailable:  the
# next check that it is ready to run fails, unless STUB_READY is "ok".  Each
# check that an agent is ready to run appends a line to ${STUB_LOG}.ready.
#
# Each test creates its repositories under a temporary directory, which it
# removes when it exits.

# shellcheck shell=sh

set -e

SCRIPT_NAME="$(basename -- "$0")"
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
# A stub agent that fails is run again at once.
MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE=0
export MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE

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
##   ours:   replaces file.txt with HEAD's version, discarding main's changes,
##           and resolves the conflicts of other.txt, if any, as "good" does
##   theirs: replaces file.txt with MERGE_HEAD's version, discarding
##           feature's changes, and resolves the conflicts of other.txt, if
##           any, as "good" does
##   ours-other: as "ours", but also changes other.txt, which git tracks, and
##           creates scratch.txt
##   ours-whitespace: as "ours", but also adds a blank line and indents a
##           line
##   delete-conflicted: deletes file.txt
##   none:   changes nothing
##   fail:   exits with status 3, as if its service were unavailable (see
##           `stub_outage`)
##   fail-once: as "fail" the first time, and as "good" afterward
##   fail-slow: as "fail", but after running for 3 seconds
##   interrupted: exits with status 130, as when SIGINT ends it
##   fail-untracked: changes the untracked file notes.txt, then exits with
##           status 3
##   fail-index: stages file.txt with its conflict markers, changing no file,
##           then exits with status 3
##   fail-head: makes HEAD name a new commit, changing no file, then exits
##           with status 3
##   commit: as "good", but also commits the merge
##   create: as "good", but also creates a file
##   change-tracked: as "good", but also changes other.txt, which git tracks
##   delete-tracked: as "good", but also deletes other.txt, which git tracks
##   change-quoted-tracked: as "good", but also changes q"x.txt, which git
##           tracks
##   unignore: as "good", but also empties .gitignore, which git tracks
##   change-hook: as "good", but also changes .githooks/pre-commit
##   relink-hooks: as "good", but also makes the symbolic link .githooks
##           point to the directory other-hooks
##   config: as "good", but also changes git's configuration
##   new-branch: as "good", but also creates the branch other, with an entry
##           in git's configuration, as another process can while the agent
##           runs
##   delete-branch: as "good", but also deletes the branch old, and with it
##           its entries in git's configuration, as another process can while
##           the agent runs
##   branch-config: as "good", but also changes the configuration of the
##           branch feature
##   push-upstream: as "good", but also sets the upstream of the branch
##           other, as another process's `git push -u` can while the agent
##           runs
##   upstream-url: as "good", but also sets branch.other.remote to a URL,
##           which names no configured remote
##   current-upstream: as "good", but also changes the upstream of the
##           current branch, feature
##   switch-upstream: as "good", but also changes the upstream of the
##           current branch, feature, and then makes the branch other, at the
##           same commit, the current branch
##   deleted-branch-config: as "good", but also deletes the branch old and
##           sets its pushRemote to a URL
##   other-upstream: as "good", but also changes the upstream of the branch
##           other
##   multiline-config: as "good", but also changes the second line of the
##           value of core.pager, a line that looks like an entry for a branch
##           that does not exist
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
##   theirs-rerere: as "good", but also replaces other.txt, whose conflict
##           `git rerere` resolved, with MERGE_HEAD's version
##   copy-markers: as "good", but first appends file.txt, with its conflict
##           markers, to other.txt, which git tracks
##   create-markers: as "good", but first copies file.txt, with its conflict
##           markers, to the new file copy.txt
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
##   once-fail: as "bad" the first time, and as "fail" afterward
##   ignored: creates fix.local, a file that git ignores
##   fail:   exits with status 3, changing nothing, as "fail" above does
##   none:   changes nothing (the default)
mkdir "${WORK_DIR}/test-bin"
cat > "${WORK_DIR}/test-bin/claude" << 'EOF'
#!/bin/sh
# `agent_ready` checks that the agent can run; ${STUB_READY} "fail" makes
# the check fail.  So does an outage that `stub_outage` recorded, once.
case "$(basename -- "$0") $*" in
  "codex exec --skip-git-repo-check "* | "claude "*--no-session-persistence*)
    basename -- "$0" >> "${STUB_LOG}.ready"
    if [ "${STUB_READY:-}" = fail ]; then
      echo "Not logged in"
      exit 1
    fi
    if [ -e "${STUB_LOG}.outage" ]; then
      rm -f -- "${STUB_LOG}.outage"
      echo "Service unavailable"
      exit 1
    fi
    echo OK
    exit 0
    ;;
esac
## Usage: stub_outage
## Exits with status 3, as an agent does when its service is unavailable,
## which the next check that the agent is ready to run then finds, unless
## ${STUB_READY} is "ok", as for an agent that rejects its options.
stub_outage() {
  if [ "${STUB_READY:-}" != ok ]; then
    : > "${STUB_LOG}.outage"
  fi
  exit 3
}
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
    once-fail)
      if [ -e notes.txt ]; then stub_outage; fi
      echo "an attempt" > notes.txt
      ;;
    ignored) echo "a fix" > fix.local ;;
    fail) stub_outage ;;
  esac
  exit 0
fi
if [ "${STUB_MODE}" = fail ]; then stub_outage; fi
if [ "${STUB_MODE}" = interrupted ]; then exit 130; fi
if [ "${STUB_MODE}" = fail-once ] && [ "$(grep -c . "${STUB_LOG}")" -eq 1 ]; then stub_outage; fi
if [ "${STUB_MODE}" = fail-slow ]; then
  sleep 3
  stub_outage
fi
if [ "${STUB_MODE}" = fail-untracked ]; then
  echo "changed" >> notes.txt
  exit 3
fi
if [ "${STUB_MODE}" = fail-index ]; then
  git add file.txt
  exit 3
fi
if [ "${STUB_MODE}" = fail-head ]; then
  git update-ref HEAD "$(git commit-tree -p HEAD -m "An agent's commit" 'HEAD^{tree}')"
  exit 3
fi
if [ "${STUB_MODE}" = ours ] || [ "${STUB_MODE}" = ours-other ] \
  || [ "${STUB_MODE}" = ours-whitespace ] || [ "${STUB_MODE}" = theirs ]; then
  if [ "${STUB_MODE}" = theirs ]; then stub_stage=3; else stub_stage=2; fi
  git show ":${stub_stage}:file.txt" > file.txt.new
  mv file.txt.new file.txt
  if [ "${STUB_MODE}" = ours ] || [ "${STUB_MODE}" = theirs ] \
    && grep -q '^<<<<<<< ' other.txt 2> /dev/null; then
    sed -e '/^<<<<<<< /d' -e '/^||||||| /,/^=======$/d' -e '/^=======$/d' -e '/^>>>>>>> /d' \
      other.txt > other.txt.new
    mv other.txt.new other.txt
  fi
  if [ "${STUB_MODE}" = ours-other ]; then
    echo "agent" >> other.txt
    echo "scratch" > scratch.txt
  fi
  if [ "${STUB_MODE}" = ours-whitespace ]; then
    sed -e 's/^two$/  two/' -e 's/^four$/four\
/' file.txt > file.txt.new
    mv file.txt.new file.txt
  fi
  exit 0
fi
case "${STUB_MODE}" in
  copy-markers) cat file.txt >> other.txt ;;
  create-markers) cp file.txt copy.txt ;;
esac
if [ "${STUB_MODE}" = delete-conflicted ]; then
  rm file.txt
  exit 0
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
  change-rerere | change-tracked) echo "agent" >> other.txt ;;
  theirs-rerere) git show :3:other.txt > other.txt ;;
  delete-tracked) rm other.txt ;;
  change-quoted-tracked) echo "agent" >> 'q"x.txt' ;;
  unignore) : > .gitignore ;;
  change-hook) echo "echo pwned" >> .githooks/pre-commit ;;
  relink-hooks)
    rm .githooks
    ln -s other-hooks .githooks
    ;;
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
case "${STUB_MODE}" in
  config) git config core.fsmonitor "echo pwned" ;;
  new-branch)
    git branch other
    git config branch.other.createdForBranchDirectory true
    ;;
  delete-branch) git branch -q -D old ;;
  branch-config) git config branch.feature.pushRemote elsewhere ;;
  push-upstream)
    git config branch.other.remote origin
    git config branch.other.merge refs/heads/other
    ;;
  upstream-url) git config branch.other.remote https://example.com/elsewhere.git ;;
  current-upstream) git config branch.feature.merge refs/heads/other ;;
  switch-upstream)
    git config branch.feature.merge refs/heads/other
    git symbolic-ref HEAD refs/heads/other
    ;;
  deleted-branch-config)
    git branch -q -D old
    git config branch.old.pushRemote https://example.com/elsewhere.git
    ;;
  other-upstream) git config branch.other.merge refs/heads/main ;;
  multiline-config) git config core.pager "$(printf 'less\nbranch.gone.remote=pwned')" ;;
esac
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
  rm -f -- "${STUB_LOG}.outage" "${STUB_LOG}.ready"
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

## Usage: push_to [NAME=VALUE...] MODE OPTION...
## Runs `git-push-to OPTION... ${main_dir} ${feature_dir}` with the stubs
## acting according to MODE, and with each environment variable NAME, such as
## STUB_BUILD, set to VALUE.  Sets ${push_status} to its exit status and
## ${push_output} to its output.  It builds the project only if ${build} is 1.
## A NAME=VALUE argument sets NAME for this call alone, as an assignment
## prefixed to a command does.  Such an assignment must not be prefixed to a
## call of this function:  bash 3.2, which is /bin/sh on macOS, keeps an
## assignment that is prefixed to a function call after the function returns,
## so it would apply to every later call too.
build=0
push_to() {
  if [ "${build}" -eq 1 ]; then push_skip=''; else push_skip=1; fi
  # The command substitution is a subshell, so the variables that
  # `push_to_run` exports do not outlive it.
  if push_output="$(push_to_run "$@" 2>&1)"; then
    push_status=0
  else
    push_status=$?
  fi
}

## Usage: push_to_run [NAME=VALUE...] MODE OPTION...
## Exports each NAME as VALUE, and then runs
## `git-push-to OPTION... ${main_dir} ${feature_dir}` as `push_to` describes.
## Run it in a subshell, so that the exported variables do not outlive it.
push_to_run() {
  while [ "$#" -gt 0 ]; do
    # shellcheck disable=SC2163 # $1 is NAME=VALUE, which exports NAME.
    case "$1" in
      *=*) export "$1" ;;
      *) break ;;
    esac
    shift
  done
  push_mode="$1"
  shift
  STUB_MODE="${push_mode}" PATH="${WORK_DIR}/test-bin:${PATH}" \
    MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT="${push_skip}" \
    "${COMMANDS_DIR}/git-push-to" "$@" "${main_dir}" "${feature_dir}"
}

## Usage: check_resolved AGENT DESCRIPTION [LINE...]
## Checks that AGENT, and only it, resolved the conflicts, and that the merge
## was committed and pushed.  If AGENT is empty, checks that no agent ran.
## Checks that the merge's file.txt consists of the LINEs, which are by
## default those of keeping both sides' changes in the case that
## `setup_case` created.
check_resolved() {
  check_resolved_agent="$1"
  check_resolved_description="$2"
  shift 2
  if [ "$#" -eq 0 ]; then
    set -- ONE two three four five six SEVEN-feature SEVEN-main eight nine
  fi
  if [ "${push_status}" -ne 0 ]; then
    fail "${check_resolved_description}: git-push-to failed: ${push_output}"
  fi
  if [ "$(cat "${STUB_LOG}")" != "${check_resolved_agent}" ]; then
    fail "${check_resolved_description}: expected only ${check_resolved_agent} to run, but ran: $(cat "${STUB_LOG}")"
  fi
  if [ -n "${check_resolved_agent}" ] && ! grep -q 'file.txt' "${STUB_PROMPT}"; then
    fail "${check_resolved_description}: the instructions do not name the conflicted file"
  fi
  remote_head="$(git -C "${remote}" rev-parse refs/heads/feature)"
  if [ "${remote_head}" != "$(git -C "${feature_dir}" rev-parse HEAD)" ]; then
    fail "${check_resolved_description}: the merge was not pushed"
  fi
  if [ "$(git -C "${remote}" rev-parse "${remote_head}^1")" != "${feature_head}" ] \
    || [ "$(git -C "${remote}" rev-parse "${remote_head}^2")" != "$(git -C "${main_dir}" rev-parse HEAD)" ]; then
    fail "${check_resolved_description}: the pushed commit is not the merge of main into feature"
  fi
  expected="$(printf '%s\n' "$@")"
  if [ "$(git -C "${remote}" show "${remote_head}:file.txt")" != "${expected}" ]; then
    fail "${check_resolved_description}: wrong merge result: $(git -C "${remote}" show "${remote_head}:file.txt")"
  fi
  message="$(git -C "${remote}" log -1 --format=%B "${remote_head}")"
  if [ "${message}" != "Merge branch 'main' into feature" ]; then
    fail "${check_resolved_description}: wrong merge message: ${message}"
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

## A PATH on which no AI agent is installed:  it holds `git` and the system's
## commands, but not the stand-in agents.  A test that uses it is skipped if a
## real agent is on it.
# shellcheck disable=SC2034 # The tests that source this file use it.
no_agent_path="$(dirname -- "$(command -v git)"):/usr/bin:/bin"
