#!/bin/sh

# Tests that `git-push-to` asks an AI agent to fix a failed build, including
# one that a pull broke, and that `git-pull-upstream` and `git-rebase-to` pass
# `--llm` through.
#
# `lib-push-to-llm.sh` describes the stub agents that stand in for `claude`
# and `codex`.
#
# Usage:
#   tests/test-push-to-llm-builds.sh

TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib-push-to-llm.sh
. "${TESTS_DIR}/lib-push-to-llm.sh"

## A failed build is fixed, and the fix is committed on top of the merge.
build=1
setup_case build-fix build
push_to STUB_BUILD=fix good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "build fix: git-push-to failed: ${push_output}"
fi
if [ "$(cat "${STUB_LOG}")" != "$(printf '%s\n' claude claude)" ]; then
  fail "build fix: expected claude to run twice, but ran: $(cat "${STUB_LOG}")"
fi
# The check that claude is ready to run, before it resolves the conflicts,
# also serves for the build fix.
if [ "$(cat "${STUB_LOG}.ready")" != claude ]; then
  fail "build fix: expected one check that claude is ready, but got: $(cat "${STUB_LOG}.ready" 2> /dev/null)"
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

## A pre-commit hook that, like a formatter's, rejects the commit of the fix
## after reformatting the fixed file does not stop git-push-to, which builds
## the file as the hook left it and commits it.  The hook leaves a merge
## commit alone.
setup_case build-fix-hook build
install_git_hook "${feature_dir}" pre-commit \
  'if git rev-parse --verify --quiet MERGE_HEAD > /dev/null; then exit 0; fi' \
  "tr 'a-z' 'A-Z' < other.txt > hook.tmp" \
  'if cmp -s other.txt hook.tmp; then rm hook.tmp; exit 0; fi' \
  'mv hook.tmp other.txt' \
  'exit 1'
push_to STUB_BUILD=fix good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "build fix with a reformatting hook: git-push-to failed: ${push_output}"
fi
case "${push_output}" in
  *"the pre-commit hook changed other.txt"*) ;;
  *) fail "build fix with a reformatting hook: no diagnostic about the hook: ${push_output}" ;;
esac
message="$(git -C "${remote}" log -1 --format=%B refs/heads/feature)"
if [ "${message}" != "Fix the build after merging branch 'main'" ]; then
  fail "build fix with a reformatting hook: wrong message for the fix: ${message}"
fi
if [ "$(git -C "${remote}" rev-parse refs/heads/feature^1^2)" != "$(git -C "${main_dir}" rev-parse HEAD)" ]; then
  fail "build fix with a reformatting hook: the fix is not on top of the merge"
fi
if [ "$(git -C "${remote}" show refs/heads/feature:other.txt)" != "FINE" ]; then
  fail "build fix with a reformatting hook: wrong other.txt: $(git -C "${remote}" show refs/heads/feature:other.txt)"
fi

## A pre-commit hook that rejects the commit of the fix after breaking the
## build stops git-push-to, which builds the files as the hook left them and
## does not commit them.
setup_case build-fix-hook-breaks build
install_git_hook "${feature_dir}" pre-commit \
  'if git rev-parse --verify --quiet MERGE_HEAD > /dev/null; then exit 0; fi' \
  'if grep -q HOOKED other.txt; then exit 0; fi' \
  'echo "BROKEN HOOKED" >> other.txt' \
  'exit 1'
push_to STUB_BUILD=fix good --llm
check_not_pushed "build fix with a hook that breaks the build"
case "${push_output}" in
  *"not committed again, because "*"compile-project\` failed"*"cannot commit the changes of claude"*) ;;
  *) fail "build fix with a hook that breaks the build: wrong diagnostic: ${push_output}" ;;
esac
# The diagnostic names the directory by a physical path, as on macOS, where
# the temporary directory is reached through a symbolic link.
broken_head="$(git -C "${feature_dir}" rev-parse --short HEAD)"
failed_log="$(git -C "${feature_dir}" rev-parse --path-format=absolute --git-path "manage-git-branches-build-failed-${broken_head}.log")"
case "${push_output}" in
  *"git-push-to: in $(cd "${feature_dir}" && pwd -P): the build of commit ${broken_head} failed; the changes that claude staged fix the build, but they cannot be committed; its output is in ${failed_log}"*) ;;
  *) fail "build fix with a hook that breaks the build: the diagnostic does not say that the commit failed: ${push_output}" ;;
esac
if [ "$(git -C "${feature_dir}" log -1 --format=%s HEAD)" != "Merge branch 'main' into feature" ]; then
  fail "build fix with a hook that breaks the build: committed the fix"
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
push_to STUB_BUILD=fix good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "build fix after a main with a merge: git-push-to failed: ${push_output}"
fi
message="$(git -C "${remote}" log -1 --format=%B refs/heads/feature)"
if [ "${message}" != "Fix the build after merging branch 'main'" ]; then
  fail "build fix after a main with a merge: wrong message for the fix: ${message}"
fi

## An agent that changes nothing gets one attempt.
setup_case build-none build
push_to STUB_BUILD=none good --llm
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
# Once a person fixes the build, a rerun that builds and pushes deletes the
# entry, and with it the file, which holds nothing else.
echo "fine" > "${feature_dir}/other.txt"
git -C "${feature_dir}" commit -q -a -m "Fix the build by hand"
push_to good --no-llm
if [ "${push_status}" -ne 0 ]; then
  fail "build fixed by hand: git-push-to failed: ${push_output}"
fi
if [ -e "${feature_dir}/AGENT-TODO.md" ]; then
  fail "build fixed by hand: AGENT-TODO.md was not deleted: $(cat "${feature_dir}/AGENT-TODO.md")"
fi
# The diagnostic names the file by a physical path, as on macOS, where the
# temporary directory is under a symbolic link.
case "${push_output}" in
  *"deleted $(cd "${feature_dir}" && pwd -P)/AGENT-TODO.md, whose entries no longer apply"*) ;;
  *) fail "build fixed by hand: wrong diagnostic: ${push_output}" ;;
esac

## An agent whose changes do not fix the build gets three attempts.
setup_case build-bad build
push_to STUB_BUILD=bad good --llm
check_not_pushed "bad build fix"
case "${push_output}" in
  *"in 3 attempts"*) ;;
  *) fail "bad build fix: wrong diagnostic: ${push_output}" ;;
esac
# The diagnostic names a copy of the output of the last build, which built
# the agent's changes.
broken_head="$(git -C "${feature_dir}" rev-parse --short HEAD)"
failed_log="$(git -C "${feature_dir}" rev-parse --path-format=absolute --git-path "manage-git-branches-build-failed-${broken_head}-claude.log")"
case "${push_output}" in
  *"git-push-to: in $(cd "${feature_dir}" && pwd -P): the build of commit ${broken_head} with the changes that claude staged to fix its build failed; its output is in ${failed_log}"*) ;;
  *) fail "bad build fix: the diagnostic does not name the last build's output: ${push_output}" ;;
esac
if ! grep -q 'other.txt is broken' "${failed_log}" 2> /dev/null; then
  fail "bad build fix: no copy of the last build's output in ${failed_log}"
fi
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
push_to STUB_BUILD=bad good --llm
check_not_pushed "rerun after a bad build fix"
case "${push_output}" in
  *"has uncommitted changes"*) ;;
  *) fail "rerun after a bad build fix: wrong diagnostic: ${push_output}" ;;
esac
if [ -s "${STUB_LOG}" ]; then
  fail "rerun after a bad build fix: an agent ran: $(cat "${STUB_LOG}")"
fi

## An agent that fails to fix the build without changing any file, after an
## earlier attempt changed files, is run again, twice, and is then not ready
## to run.  Because the earlier attempt's changes remain staged, a person
## must deal with them:  the earlier attempt's session can be continued, and
## AGENT-TODO.md does not say that running git-push-to again suffices.
setup_case build-fail-later build
push_to STUB_BUILD=once-fail good --llm
check_not_pushed "build-fixing agent that fails on its second attempt"
if [ "$(wc -l < "${STUB_LOG}")" -ne 5 ]; then
  fail "build-fixing agent that fails on its second attempt: expected claude to run 5 times, but ran: $(cat "${STUB_LOG}")"
fi
case "${push_output}" in
  *"attempt 2 of 3"*"claude failed before changing anything in "*"to continue the session of claude:  cd "*) ;;
  *) fail "build-fixing agent that fails on its second attempt: wrong diagnostic: ${push_output}" ;;
esac
todo="${feature_dir}/AGENT-TODO.md"
if [ "$(grep -c '^cd .* && claude --resume ' "${todo}")" != 1 ] \
  || grep -q 'no person needs to' "${todo}"; then
  fail "build-fixing agent that fails on its second attempt: wrong AGENT-TODO.md: $(cat "${todo}" 2> /dev/null)"
fi
if ! git -C "${feature_dir}" diff --cached --name-only | grep -q -x notes.txt; then
  fail "build-fixing agent that fails on its second attempt: the first attempt's changes are not staged"
fi

## An agent that fails to fix the build without changing any file is run
## again, twice.  AGENT-TODO.md then says that running git-push-to again
## suffices; a rerun does fix the build.
setup_case build-fail-unchanged build
push_to STUB_BUILD=fail good --llm
check_not_pushed "build-fixing agent that fails without changing any file"
if [ "$(cat "${STUB_LOG}")" != "$(printf '%s\n' claude claude claude claude)" ]; then
  fail "build-fixing agent that fails without changing any file: expected claude to run 4 times, but ran: $(cat "${STUB_LOG}")"
fi
todo="${feature_dir}/AGENT-TODO.md"
if ! grep -q -x -F "claude, an AI agent, failed before changing anything, and it is not ready to run, as when it cannot reach its service.  Once claude can run, running the same command again asks it to fix the build, so no person needs to." "${todo}" \
  || grep -q 'claude --resume ' "${todo}"; then
  fail "build-fixing agent that fails without changing any file: wrong AGENT-TODO.md: $(cat "${todo}" 2> /dev/null)"
fi
## A rerun while the agent is not ready to run notes that in AGENT-TODO.md.
: > "${STUB_LOG}"
push_to STUB_READY=fail STUB_BUILD=fix good --llm
check_not_pushed "build fix while the agent is not ready"
if [ -s "${STUB_LOG}" ]; then
  fail "build fix while the agent is not ready: an agent ran: $(cat "${STUB_LOG}")"
fi
if ! grep -q -x -F "claude, an AI agent, did not run, because it was not ready to run, as when it is not logged in.  Once claude can run, running the same command again asks it to fix the build, so no person needs to." "${todo}" \
  || grep -q 'failed before changing anything' "${todo}" \
  || [ "$(grep -c '^## Fix the build' "${todo}")" -ne 1 ]; then
  fail "build fix while the agent is not ready: wrong AGENT-TODO.md: $(cat "${todo}" 2> /dev/null)"
fi
: > "${STUB_LOG}"
push_to STUB_BUILD=fix good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "rerun after a build-fixing agent that failed without changing any file: git-push-to failed: ${push_output}"
fi
if [ "$(git -C "${remote}" show refs/heads/feature:other.txt)" != "fine" ]; then
  fail "rerun after a build-fixing agent that failed without changing any file: the build was not fixed"
fi
if [ -e "${todo}" ]; then
  fail "rerun after a build-fixing agent that failed without changing any file: AGENT-TODO.md remains: $(cat "${todo}")"
fi

## An agent that is not ready to run is not asked to fix the build.
## AGENT-TODO.md says that running git-push-to again suffices; a rerun while
## the agent is still not ready replaces that entry, and a rerun once it is
## ready fixes the build and removes the entry.  The merge has no conflicts.
setup_case build-not-ready build
write_file "${feature_dir}/file.txt" ONE two three four five six SEVEN-main eight nine
echo "feature" > "${feature_dir}/feature.txt"
git -C "${feature_dir}" add feature.txt
git -C "${feature_dir}" commit -q -a -m "Change feature as main does"
git -C "${feature_dir}" push -q
feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
todo="${feature_dir}/AGENT-TODO.md"
not_ready_line="claude, an AI agent, did not run, because it was not ready to run, as when it is not logged in.  Once claude can run, running the same command again asks it to fix the build, so no person needs to."
## The directory is a physical path, as on macOS, where the temporary
## directory is under a symbolic link.
build_failed_line="The build failed in $(cd "${feature_dir}" && pwd -P)."
push_to STUB_READY=fail STUB_BUILD=fix good --llm
check_not_pushed "build fix while the agent is not ready"
if [ -s "${STUB_LOG}" ]; then
  fail "build fix while the agent is not ready: an agent ran: $(cat "${STUB_LOG}")"
fi
if ! grep -q -x -F "${not_ready_line}" "${todo}" \
  || ! grep -q -x -F "${build_failed_line}" "${todo}"; then
  fail "build fix while the agent is not ready: wrong AGENT-TODO.md: $(cat "${todo}" 2> /dev/null)"
fi
push_to STUB_READY=fail STUB_BUILD=fix good --llm
check_not_pushed "build fix while the agent is still not ready"
if [ "$(grep -c '^## Fix the build' "${todo}")" != 1 ]; then
  fail "build fix while the agent is still not ready: wrong AGENT-TODO.md: $(cat "${todo}" 2> /dev/null)"
fi
: > "${STUB_LOG}"
push_to STUB_BUILD=fix good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "rerun once the agent is ready to fix the build: git-push-to failed: ${push_output}"
fi
if [ "$(git -C "${remote}" show refs/heads/feature:other.txt)" != "fine" ]; then
  fail "rerun once the agent is ready to fix the build: the build was not fixed"
fi
if [ -e "${todo}" ]; then
  fail "rerun once the agent is ready to fix the build: AGENT-TODO.md remains: $(cat "${todo}")"
fi

## Uncommitted changes are refused before the merge, which leaves no merge
## commit behind.
setup_case build-dirty build
echo "an edit" >> "${feature_dir}/other.txt"
push_to STUB_BUILD=fix good --llm
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
push_to STUB_BUILD=ignored good --llm
check_not_pushed "build fix in an ignored file"
case "${push_output}" in
  *"created a file that git ignores: fix.local"*) ;;
  *) fail "build fix in an ignored file: wrong diagnostic: ${push_output}" ;;
esac

## An attempt that changes nothing ends the attempts, even after an earlier
## attempt changed files; the later attempt learns of the earlier one.
setup_case build-once build
push_to STUB_BUILD=once good --llm
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
push_to STUB_BUILD=bad good --llm
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
push_to STUB_BUILD=fix good --no-llm
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
push_to STUB_BUILD=fix good --llm
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
push_to STUB_BUILD=fix good --llm
check_not_pushed "build failure without a merge"
case "${push_output}" in
  *"unable to build"*) ;;
  *) fail "build failure without a merge: wrong diagnostic: ${push_output}" ;;
esac
if [ -s "${STUB_LOG}" ]; then
  fail "build failure without a merge: an agent ran: $(cat "${STUB_LOG}")"
fi
# The diagnostic and the summary say why the agent was not asked, and name a
# copy of the build's output that is named for the commit.
broken_head="$(git -C "${feature_dir}" rev-parse --short HEAD)"
failed_log="$(git -C "${feature_dir}" rev-parse --path-format=absolute --git-path "manage-git-branches-build-failed-${broken_head}.log")"
expected="in $(cd "${feature_dir}" && pwd -P): the build of commit ${broken_head} failed; claude was not asked to fix it, because every merge that combined changes is in refs/remotes/origin/feature, so no merge broke the build; its output is in ${failed_log}"
case "${push_output}" in
  *"git-push-to: ${expected}"*) ;;
  *) fail "build failure without a merge: the diagnostic does not say why the agent was not asked: ${push_output}" ;;
esac
if ! grep -q 'other.txt is broken' "${failed_log}" 2> /dev/null; then
  fail "build failure without a merge: no copy of the build's output in ${failed_log}"
fi

## The summary says why the agent was not asked to fix a build that a pushed
## commit broke, and the copy of the build's output outlasts a later build.
setup_case build-pushed-no-merge build
git -C "${main_dir}" reset -q --hard HEAD^
git -C "${main_dir}" push -q --force
echo "BROKEN" >> "${feature_dir}/other.txt"
git -C "${feature_dir}" commit -q -a -m "Break the build and push"
git -C "${feature_dir}" push -q
feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
summary_file="${case_dir}/summary"
push_to STUB_BUILD=fix good --llm --summary "${summary_file}"
check_not_pushed "pushed build failure without a merge"
broken_head="$(git -C "${feature_dir}" rev-parse --short HEAD)"
failed_log="$(git -C "${feature_dir}" rev-parse --path-format=absolute --git-path "manage-git-branches-build-failed-${broken_head}.log")"
expected="$(printf '%s\n' \
  "in $(cd "${feature_dir}" && pwd -P): the build of commit ${broken_head} failed; claude was not asked to fix it, because refs/remotes/origin/feature has the same files, so no merge broke the build; its output is in ${failed_log}" \
  "failed to push ${main_dir} into ${feature_dir}, while building")"
if [ "$(cat "${summary_file}")" != "${expected}" ]; then
  fail "pushed build failure without a merge: wrong summary: $(cat "${summary_file}")"
fi
if [ -s "${STUB_LOG}" ]; then
  fail "pushed build failure without a merge: an agent ran: $(cat "${STUB_LOG}")"
fi
echo "fine" > "${feature_dir}/other.txt"
git -C "${feature_dir}" commit -q -a -m "Fix the build"
push_to STUB_BUILD=fix good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "build after a failed build: git-push-to failed: ${push_output}"
fi
if ! grep -q 'other.txt is broken' "${failed_log}" 2> /dev/null; then
  fail "build after a failed build: the copy of the failed build's output in ${failed_log} did not last"
fi

## When a merge's build fails, but the build already failed before the merge
## with no merge to blame, the agent is told so, and the message of its fix
## says so.  Feature pushes a commit that breaks its build; the first run
## merges nothing, so it fails without asking the agent, and records the
## commit.  Then main makes a change, which the second run merges.
setup_case build-already-failed build
git -C "${main_dir}" reset -q --hard HEAD^
git -C "${main_dir}" push -q --force
echo "BROKEN" >> "${feature_dir}/other.txt"
git -C "${feature_dir}" commit -q -a -m "Break the build and push"
git -C "${feature_dir}" push -q
broken_head="$(git -C "${feature_dir}" rev-parse HEAD)"
feature_head="${broken_head}"
push_to STUB_BUILD=fix good --llm
check_not_pushed "build that already failed, first run"
if ! grep -q -x -F "${broken_head}" "$(git -C "${feature_dir}" rev-parse --path-format=absolute --git-path manage-git-branches-build-failures)" 2> /dev/null; then
  fail "build that already failed: the first run did not record the commit whose build failed"
fi
echo "main" > "${main_dir}/main.txt"
git -C "${main_dir}" add main.txt
git -C "${main_dir}" commit -q -m "Add main.txt"
git -C "${main_dir}" push -q
push_to STUB_BUILD=fix good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "build that already failed: git-push-to failed: ${push_output}"
fi
if ! grep -q "the build of branch feature already failed at commit ${broken_head}, which no merge had broken" "${STUB_PROMPT}"; then
  fail "build that already failed: the instructions do not say that the build already failed: $(cat "${STUB_PROMPT}")"
fi
message="$(git -C "${remote}" log -1 --format=%B refs/heads/feature)"
if [ "${message}" != "Fix the build, which already failed at commit $(git -C "${feature_dir}" rev-parse --short "${broken_head}") before merging branch 'main'" ]; then
  fail "build that already failed: wrong message for the fix: ${message}"
fi

## The agent is told that the build already failed before the merges even
## when an earlier run merged, but did not push the merge, because the agent
## did not fix the build.  The first run fails without asking the agent, as
## above; the second merges main, and the agent changes nothing; the third
## builds that unpushed merge again.
setup_case build-already-failed-unpushed build
git -C "${main_dir}" reset -q --hard HEAD^
git -C "${main_dir}" push -q --force
echo "BROKEN" >> "${feature_dir}/other.txt"
git -C "${feature_dir}" commit -q -a -m "Break the build and push"
git -C "${feature_dir}" push -q
broken_head="$(git -C "${feature_dir}" rev-parse HEAD)"
feature_head="${broken_head}"
push_to STUB_BUILD=fix good --llm
check_not_pushed "unpushed merge after a build that already failed, first run"
echo "main" > "${main_dir}/main.txt"
git -C "${main_dir}" add main.txt
git -C "${main_dir}" commit -q -m "Add main.txt"
git -C "${main_dir}" push -q
push_to STUB_BUILD=none good --llm
check_not_pushed "unpushed merge after a build that already failed, second run"
if [ "$(git -C "${feature_dir}" rev-parse HEAD^1)" != "${broken_head}" ]; then
  fail "unpushed merge after a build that already failed: the second run left no merge of main: $(git -C "${feature_dir}" log --oneline -3)"
fi
push_to STUB_BUILD=fix good --llm
if [ "${push_status}" -ne 0 ]; then
  fail "unpushed merge after a build that already failed: git-push-to failed: ${push_output}"
fi
if ! grep -q "the build of branch feature already failed at commit ${broken_head}, which no merge had broken" "${STUB_PROMPT}"; then
  fail "unpushed merge after a build that already failed: the instructions do not say that the build already failed: $(cat "${STUB_PROMPT}")"
fi
message="$(git -C "${remote}" log -1 --format=%B refs/heads/feature)"
if [ "${message}" != "Fix the build, which already failed at commit $(git -C "${feature_dir}" rev-parse --short "${broken_head}") before merging branch 'main'" ]; then
  fail "unpushed merge after a build that already failed: wrong message for the fix: ${message}"
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
push_to STUB_BUILD=fix good --llm
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
push_to STUB_BUILD=fix good --no-llm
if [ "${push_status}" -eq 0 ] || [ "$(git -C "${fork}" rev-parse refs/heads/feature)" != "${fork_head}" ]; then
  fail "build with a push remote: the first run pushed: ${push_output}"
fi
git -C "${feature_dir}" push -q fork feature
git -C "${feature_dir}" update-ref refs/remotes/fork/feature "${fork_head}"
push_to STUB_BUILD=fix good --llm
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
push_to STUB_BUILD=fix good --llm
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
  push_to STUB_BUILD=fix good "${llm_option}"
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
push_to STUB_BUILD=fix good --llm
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
push_to STUB_BUILD=fix good --llm
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
push_to STUB_BUILD=fix good --llm
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
  push_to STUB_BUILD=fix good --llm
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
push_to STUB_BUILD=fix good --llm
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
push_to STUB_BUILD=fix good --llm
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
  push_to STUB_BUILD=fix good --llm
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
push_to STUB_BUILD=fix good --llm
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
push_to STUB_BUILD=fix good --llm
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
push_to STUB_BUILD=none good --llm
check_not_pushed "failed build before a rerun"
: > "${STUB_LOG}"
local_head="$(git -C "${feature_dir}" rev-parse HEAD)"
git clone -q -b feature "${remote}" "${case_dir}/other-clone"
echo "unrelated" > "${case_dir}/other-clone/third.txt"
git -C "${case_dir}/other-clone" add third.txt
git -C "${case_dir}/other-clone" commit -q -m "Change feature remotely"
git -C "${case_dir}/other-clone" push -q
feature_head="$(git -C "${remote}" rev-parse refs/heads/feature)"
push_to STUB_BUILD=fix good --llm
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
push_to STUB_BUILD=fix good --llm
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
push_to STUB_BUILD=fix good --llm
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
push_to STUB_BUILD=fix good --no-llm
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

## Run in a subdirectory, `git-pull-upstream` runs the agent that fails to fix
## the build at the top level of the working tree, so that AGENT-TODO.md
## gives a command that starts there.  Once a person fixes the build, a rerun
## in the subdirectory deletes the entry, and with it the file.
setup_pull_breaks pull-upstream-build-subdir
git -C "${feature_dir}" remote set-head origin main
mkdir "${feature_dir}/sub"
if pull_upstream_output="$(cd "${feature_dir}/sub" && STUB_BUILD=none PATH="${WORK_DIR}/test-bin:${PATH}" \
  MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT='' "${COMMANDS_DIR}/git-pull-upstream" --llm 2>&1)"; then
  fail "git-pull-upstream in a subdirectory, build not fixed: succeeded: ${pull_upstream_output}"
fi
session_id="$(sed -n -e '/^--session-id$/{n;p;}' "${STUB_ARGS}")"
session_dir="$(cd "${feature_dir}" && pwd -P)"
if ! grep -q -x -F "cd ${session_dir} && claude --resume ${session_id}" "${feature_dir}/AGENT-TODO.md"; then
  fail "git-pull-upstream in a subdirectory, build not fixed: AGENT-TODO.md lacks the command that starts at the top level: $(cat "${feature_dir}/AGENT-TODO.md" 2> /dev/null)"
fi
echo "fine" > "${feature_dir}/other.txt"
git -C "${feature_dir}" commit -q -a -m "Fix the build by hand"
if ! pull_upstream_output="$(cd "${feature_dir}/sub" && MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT='' \
  "${COMMANDS_DIR}/git-pull-upstream" --no-llm 2>&1)"; then
  fail "git-pull-upstream in a subdirectory, build fixed by hand: failed: ${pull_upstream_output}"
fi
if [ -e "${feature_dir}/AGENT-TODO.md" ]; then
  fail "git-pull-upstream in a subdirectory, build fixed by hand: AGENT-TODO.md was not deleted: $(cat "${feature_dir}/AGENT-TODO.md")"
fi
build=0

## An agent that is not installed is not asked to fix the build.  The merge
## has no conflicts, so that the build is reached, and its tree is not
## main's.  The test is skipped if a real agent is on ${no_agent_path}.
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
