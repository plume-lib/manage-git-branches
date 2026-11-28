#!/bin/sh

# Tests which changes `git-push-to` accepts from an AI agent that resolves a
# merge's conflicts:  commits, changes to other files, to hooks, and to git's
# configuration, and conflict markers that remain, including in criss-cross
# merges.  Also tests an agent that runs too long.
#
# `lib-push-to-llm.sh` describes the stub agents that stand in for `claude`
# and `codex`.
#
# Usage:
#   tests/test-push-to-llm-agent-changes.sh

TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib-push-to-llm.sh
. "${TESTS_DIR}/lib-push-to-llm.sh"

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
  *"claude created a file: scratch.txt"*) ;;
  *) fail "agent that creates a file: wrong diagnostic: ${push_output}" ;;
esac

## A change to a tracked file that has no conflicts, or its deletion, is
## committed with the merge, and reported.
for tracked_mode in change-tracked delete-tracked; do
  setup_case "${tracked_mode}"
  echo "other" > "${feature_dir}/other.txt"
  git -C "${feature_dir}" add other.txt
  git -C "${feature_dir}" commit -q -m "Add other.txt"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  push_to "${tracked_mode}" --llm
  check_resolved claude "${tracked_mode}"
  case "${tracked_mode}:$(git -C "${remote}" show refs/heads/feature:other.txt 2> /dev/null)" in
    change-tracked:"$(printf '%s\n' other agent)" | delete-tracked:) ;;
    *) fail "${tracked_mode}: wrong other.txt: $(git -C "${remote}" show refs/heads/feature:other.txt 2>&1)" ;;
  esac
  case "${push_output}" in
    *"claude also changed: other.txt"*) ;;
    *) fail "${tracked_mode}: wrong diagnostic: ${push_output}" ;;
  esac
done

## A conflict marker in another file that the agent changed is rejected, but
## not a line like one that the file already contained.  A new file that
## contains one is rejected anyway.
for markers_mode in copy-markers create-markers; do
  setup_case "${markers_mode}"
  echo "other" > "${feature_dir}/other.txt"
  git -C "${feature_dir}" add other.txt
  git -C "${feature_dir}" commit -q -m "Add other.txt"
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  push_to "${markers_mode}" --llm
  check_not_resolved "${markers_mode}"
  case "${markers_mode}:${push_output}" in
    copy-markers:*"other.txt: line "*" is a conflict marker"*"did not resolve the conflicts acceptably"*) ;;
    create-markers:*"created a file: copy.txt"*"did not resolve the conflicts acceptably"*) ;;
    *) fail "${markers_mode}: wrong diagnostic: ${push_output}" ;;
  esac
done
setup_case existing-markers
printf '%s\n' '<<<<<<< example' '=======' '>>>>>>> example' > "${feature_dir}/other.txt"
git -C "${feature_dir}" add other.txt
git -C "${feature_dir}" commit -q -m "Add other.txt"
git -C "${feature_dir}" push -q
feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
push_to change-tracked --llm
check_resolved claude "existing-markers"

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

## A change to a tracked file whose name git quotes is committed.  The name
## is in a variable because checkbashisms misparses a quotation mark inside
## single quotes in a command substitution.
quoted_name='q"x.txt'
setup_case change-quoted-tracked
echo "quoted" > "${feature_dir}/${quoted_name}"
git -C "${feature_dir}" add -- "${quoted_name}"
git -C "${feature_dir}" commit -q -m "Add ${quoted_name}"
git -C "${feature_dir}" push -q
feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
push_to change-quoted-tracked --llm
check_resolved claude "change-quoted-tracked"
quoted_content="$(git -C "${remote}" show "refs/heads/feature:${quoted_name}")"
if [ "${quoted_content}" != "$(printf '%s\n' quoted agent)" ]; then
  fail "change-quoted-tracked: wrong ${quoted_name}: ${quoted_content}"
fi

## A file that git ignored until the agent changed .gitignore is not
## committed, though the change to .gitignore is.
setup_case unignore
echo "secret.txt" > "${feature_dir}/.gitignore"
git -C "${feature_dir}" add .gitignore
git -C "${feature_dir}" commit -q -m "Add .gitignore"
git -C "${feature_dir}" push -q
feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
echo "secret" > "${feature_dir}/secret.txt"
push_to unignore --llm
check_resolved claude "unignore"
if git -C "${remote}" cat-file -e refs/heads/feature:secret.txt 2> /dev/null; then
  fail "unignore: the formerly ignored file was committed"
fi
if [ -n "$(git -C "${remote}" show refs/heads/feature:.gitignore)" ]; then
  fail "unignore: the change to .gitignore was not committed"
fi

## An agent that changes a hook in the working tree is rejected, because the
## commit would run the hook.
setup_case change-hook
mkdir "${feature_dir}/.githooks"
printf '%s\n' '#!/bin/sh' 'exit 0' > "${feature_dir}/.githooks/pre-commit"
chmod +x "${feature_dir}/.githooks/pre-commit"
git -C "${feature_dir}" add .githooks/pre-commit
git -C "${feature_dir}" commit -q -m "Add a hook"
git -C "${feature_dir}" push -q
feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
git -C "${feature_dir}" config core.hooksPath .githooks
push_to change-hook --llm
check_not_resolved "change-hook"
case "${push_output}" in
  *"changed a file: .githooks/pre-commit"*) ;;
  *) fail "change-hook: wrong diagnostic: ${push_output}" ;;
esac

## An agent that repoints a hooks directory that is a tracked symbolic link
## is rejected:  git resolves the link, so the hooks that git runs changed.
setup_case relink-hooks
for hooks_dir in tools-hooks other-hooks; do
  mkdir "${feature_dir}/${hooks_dir}"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "${feature_dir}/${hooks_dir}/pre-commit"
  chmod +x "${feature_dir}/${hooks_dir}/pre-commit"
done
ln -s tools-hooks "${feature_dir}/.githooks"
git -C "${feature_dir}" add .githooks tools-hooks other-hooks
git -C "${feature_dir}" commit -q -m "Add hooks"
git -C "${feature_dir}" push -q
feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
git -C "${feature_dir}" config core.hooksPath .githooks
push_to relink-hooks --llm
check_not_pushed "relink-hooks"
case "${push_output}" in
  *"changed git's configuration, attributes, or hooks"*) ;;
  *) fail "relink-hooks: wrong diagnostic: ${push_output}" ;;
esac

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

## Usage: setup_criss_cross [SHARED [MARKER]]
## Makes the merge of main into feature, in the case that `setup_case` just
## created, a criss-cross merge whose merge bases are the heads of main and
## feature before the criss-cross merges:  main merges feature, and feature
## merges main's earlier head, each resolving the conflict in file.txt in
## its own way.  Git's merge of the two merge bases conflicts in file.txt,
## so the merge base that git makes of them contains conflict markers.  If
## SHARED is not empty, each merge resolves the conflict as the line SHARED
## followed by a line of its own, so that both sides delete the first marker
## of git's conflict in the same way.  If MARKER is given, feature first
## appends the line MARKER to file.txt, and both merges remove it, so that
## only a merge base's version of file.txt contains it.  Sets
## ${feature_head}.
setup_criss_cross() {
  if [ -n "${2-}" ]; then
    printf '%s\n' "$2" >> "${feature_dir}/file.txt"
    git -C "${feature_dir}" commit -q -a -m "Add a line"
    git -C "${feature_dir}" push -q
  fi
  scc_main_head="$(git -C "${main_dir}" rev-parse HEAD)"
  git -C "${main_dir}" fetch -q origin
  git -C "${main_dir}" merge -q origin/feature > /dev/null 2>&1 || true
  write_file "${main_dir}/file.txt" ONE two three four five six ${1:+"$1"} SEVEN-both-main eight nine
  git -C "${main_dir}" commit -q -a --no-edit
  git -C "${main_dir}" push -q
  git -C "${feature_dir}" fetch -q origin
  git -C "${feature_dir}" merge -q "${scc_main_head}" > /dev/null 2>&1 || true
  write_file "${feature_dir}/file.txt" ONE two three four five six ${1:+"$1"} SEVEN-both-feature eight nine
  git -C "${feature_dir}" commit -q -a --no-edit
  git -C "${feature_dir}" push -q
  feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
  if [ "$(git -C "${feature_dir}" merge-base --all HEAD origin/main | grep -c .)" -ne 2 ]; then
    fail "setup_criss_cross: the merge does not have two merge bases"
  fi
}

## Usage: check_no_outside_notice DESCRIPTION
## Checks that git-push-to did not report that the agent changed text
## outside the conflict regions.
check_no_outside_notice() {
  case "${push_output}" in
    *"changed text outside the conflict regions"*)
      fail "$1: a false notice of a change outside the conflict regions: ${push_output}"
      ;;
  esac
}

## A criss-cross merge is resolved by the agent, although the merge base that
## git makes contains conflict markers, which git wrote.
setup_case criss-cross
git -C "${feature_dir}" config merge.conflictStyle diff3
setup_criss_cross
push_to good --llm
check_resolved claude "criss-cross" \
  ONE two three four five six SEVEN-both-feature SEVEN-both-main eight nine
check_no_outside_notice "criss-cross"

## A criss-cross merge in which both sides delete the first of git's conflict
## markers in the merge base in the same way, so that the merge base's text in
## the conflict region contains the rest of git's markers, unbalanced, is
## resolved by the agent in each conflict style.
for criss_cross_style in diff3 zdiff3 merge; do
  setup_case "criss-cross-shared-${criss_cross_style}"
  git -C "${feature_dir}" config merge.conflictStyle "${criss_cross_style}"
  setup_criss_cross SEVEN-main
  push_to good --llm
  check_resolved claude "criss-cross-shared-${criss_cross_style}" \
    ONE two three four five six SEVEN-main SEVEN-both-feature SEVEN-both-main eight nine
  check_no_outside_notice "criss-cross-shared-${criss_cross_style}"
done

## `git rerere` resolves such a criss-cross merge, and the check of its
## resolution accepts it.
setup_case criss-cross-rerere
git -C "${feature_dir}" config merge.conflictStyle diff3
git -C "${feature_dir}" config rerere.enabled true
setup_criss_cross SEVEN-main
push_to none --llm
: > "${STUB_LOG}"
git -C "${feature_dir}" worktree add -q --detach "${case_dir}/other" "${feature_head}"
git -C "${case_dir}/other" merge -q "$(git -C "${feature_dir}" rev-parse MERGE_HEAD)" > /dev/null 2>&1 || true
write_file "${case_dir}/other/file.txt" \
  ONE two three four five six SEVEN-main SEVEN-both-feature SEVEN-both-main eight nine
git -C "${case_dir}/other" add file.txt
git -C "${case_dir}/other" commit -q --no-edit > /dev/null 2>&1
push_to good --no-llm
check_resolved "" "criss-cross-rerere" \
  ONE two three four five six SEVEN-main SEVEN-both-feature SEVEN-both-main eight nine

## A criss-cross merge is refused if a merge base's own version of a
## conflicted file contains a line that looks like a conflict marker.
setup_case criss-cross-marker
git -C "${feature_dir}" config merge.conflictStyle diff3
setup_criss_cross '' '>>>>>>> fixture'
push_to good --llm
check_not_resolved "criss-cross-marker"
case "${push_output}" in
  *"file.txt contains lines that look like conflict markers"*) ;;
  *) fail "criss-cross-marker: wrong diagnostic: ${push_output}" ;;
esac
if [ -s "${STUB_LOG}" ]; then
  fail "criss-cross-marker: an agent ran: $(cat "${STUB_LOG}")"
fi

## A criss-cross merge is refused if the merge bases' own merge base contains
## a line that looks like a conflict marker, which the merge base that git
## makes contains although neither merge base does.  The merge bases' merge
## base ends with that line, and each merge base replaces it with a line of
## its own.
setup_case criss-cross-deep-marker
git -C "${feature_dir}" config merge.conflictStyle diff3
printf '%s\n' '>>>>>>> fixture' >> "${feature_dir}/file.txt"
git -C "${feature_dir}" commit -q -a -m "Add a line"
git -C "${feature_dir}" push -q
git -C "${main_dir}" fetch -q origin
git -C "${main_dir}" merge -q origin/feature > /dev/null 2>&1 || true
write_file "${main_dir}/file.txt" ONE two three four five six SEVEN-main eight nine '>>>>>>> fixture'
git -C "${main_dir}" commit -q -a --no-edit
git -C "${main_dir}" push -q
git -C "${feature_dir}" fetch -q origin
git -C "${feature_dir}" merge -q --ff-only origin/main
write_file "${main_dir}/file.txt" ONE two three four five six SEVEN-main eight nine end-main
git -C "${main_dir}" commit -q -a -m "End main"
git -C "${main_dir}" push -q
write_file "${feature_dir}/file.txt" ONE two three four five six SEVEN-main eight nine end-feature
git -C "${feature_dir}" commit -q -a -m "End feature"
git -C "${feature_dir}" push -q
criss_cross_main_head="$(git -C "${main_dir}" rev-parse HEAD)"
git -C "${main_dir}" fetch -q origin
git -C "${main_dir}" merge -q origin/feature > /dev/null 2>&1 || true
write_file "${main_dir}/file.txt" ONE two three four five six SEVEN-main eight nine end-both-main
git -C "${main_dir}" commit -q -a --no-edit
git -C "${main_dir}" push -q
git -C "${feature_dir}" fetch -q origin
git -C "${feature_dir}" merge -q "${criss_cross_main_head}" > /dev/null 2>&1 || true
write_file "${feature_dir}/file.txt" ONE two three four five six SEVEN-main eight nine end-both-feature
git -C "${feature_dir}" commit -q -a --no-edit
git -C "${feature_dir}" push -q
feature_head="$(git -C "${feature_dir}" rev-parse HEAD)"
if [ "$(git -C "${feature_dir}" merge-base --all HEAD origin/main | grep -c .)" -ne 2 ]; then
  fail "criss-cross-deep-marker: the merge does not have two merge bases"
fi
push_to good --llm
check_not_resolved "criss-cross-deep-marker"
case "${push_output}" in
  *"file.txt contains lines that look like conflict markers"*) ;;
  *) fail "criss-cross-deep-marker: wrong diagnostic: ${push_output}" ;;
esac
if [ -s "${STUB_LOG}" ]; then
  fail "criss-cross-deep-marker: an agent ran: $(cat "${STUB_LOG}")"
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

## Git writes the conflict markers at the length that the attributes before
## the merge give, so a merge that sets the attribute `conflict-marker-size`
## does not change the length of the markers in AUTO_MERGE.
setup_case marker-size-from-merge
echo 'file.txt conflict-marker-size=10' > "${main_dir}/.gitattributes"
git -C "${main_dir}" add .gitattributes
git -C "${main_dir}" commit -q -m "Lengthen the conflict markers"
git -C "${main_dir}" push -q
push_to good --llm
check_resolved claude "a merge that sets the attribute conflict-marker-size"
check_no_outside_notice "a merge that sets the attribute conflict-marker-size"

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

## Another process can add or remove the configuration of a branch other than
## the current one while the agent runs, as by creating a worktree for a new
## branch or deleting a branch:  linked worktrees share one configuration
## file.  Such a change is not the agent's.
setup_case new-branch
push_to new-branch --llm
check_resolved claude "branch created while the agent runs"
setup_case delete-branch
git -C "${feature_dir}" branch old
git -C "${feature_dir}" config branch.old.remote origin
push_to delete-branch --llm
check_resolved claude "branch deleted while the agent runs"

## An agent that changes the configuration of a branch that exists is
## rejected.
setup_case branch-config
push_to branch-config --llm
check_not_resolved "agent that changes a branch's configuration"
case "${push_output}" in
  *"changed git's configuration, attributes, or hooks"*) ;;
  *) fail "agent that changes a branch's configuration: wrong diagnostic: ${push_output}" ;;
esac

## Another process can set the upstream of a branch other than the current
## one while the agent runs, as by pushing it with `git push -u`.  Such a
## change is not the agent's.
setup_case push-upstream
git -C "${feature_dir}" branch other
push_to push-upstream --llm
check_resolved claude "upstream of another branch set while the agent runs"

## An agent that sets the remote of another branch to a value that names no
## configured remote, or that changes the upstream of the current branch, is
## rejected.
setup_case upstream-url
git -C "${feature_dir}" branch other
push_to upstream-url --llm
check_not_resolved "agent that sets another branch's remote to a URL"
case "${push_output}" in
  *"changed git's configuration, attributes, or hooks"*) ;;
  *) fail "agent that sets another branch's remote to a URL: wrong diagnostic: ${push_output}" ;;
esac
setup_case current-upstream
push_to current-upstream --llm
check_not_resolved "agent that changes the current branch's upstream"
case "${push_output}" in
  *"changed git's configuration, attributes, or hooks"*) ;;
  *) fail "agent that changes the current branch's upstream: wrong diagnostic: ${push_output}" ;;
esac

## A tag with the name of the current branch does not make the current branch
## look like another branch, whose upstream another process can set.
setup_case current-upstream-tag
git -C "${feature_dir}" tag feature
push_to current-upstream --llm
check_not_resolved "agent that changes the current branch's upstream, with a tag of its name"
case "${push_output}" in
  *"changed git's configuration, attributes, or hooks"*) ;;
  *) fail "agent that changes the current branch's upstream, with a tag of its name: wrong diagnostic: ${push_output}" ;;
esac

## An agent that changes the current branch's upstream is rejected even if it
## then makes another branch current.
setup_case switch-upstream
git -C "${feature_dir}" branch other
push_to switch-upstream --llm
check_not_resolved "agent that changes the current branch's upstream, then switches branches"
case "${push_output}" in
  *"changed git's configuration, attributes, or hooks"*) ;;
  *) fail "agent that changes the current branch's upstream, then switches branches: wrong diagnostic: ${push_output}" ;;
esac

## An agent that deletes a branch and sets its configuration is rejected:  the
## configuration takes effect if the branch is created again.
setup_case deleted-branch-config
git -C "${feature_dir}" branch old
push_to deleted-branch-config --llm
check_not_resolved "agent that sets the configuration of a branch that it deletes"
case "${push_output}" in
  *"changed git's configuration, attributes, or hooks"*) ;;
  *) fail "agent that sets the configuration of a branch that it deletes: wrong diagnostic: ${push_output}" ;;
esac

## An agent that changes the upstream that another branch already has is
## rejected:  the change takes effect at once in a working tree of that
## branch.
setup_case other-upstream
git -C "${feature_dir}" branch other
git -C "${feature_dir}" config branch.other.remote origin
git -C "${feature_dir}" config branch.other.merge refs/heads/other
push_to other-upstream --llm
check_not_resolved "agent that changes another branch's upstream"
case "${push_output}" in
  *"changed git's configuration, attributes, or hooks"*) ;;
  *) fail "agent that changes another branch's upstream: wrong diagnostic: ${push_output}" ;;
esac

## Usage: make_many_branches
## Creates, in ${feature_dir}, so many branches that their names exceed the
## size limit of an environment variable, about 128 KiB on Linux.
make_many_branches() {
  make_many_branches_name="many-branches-$(printf '%080d' 0)"
  make_many_branches_i=0
  while [ "${make_many_branches_i}" -lt 2000 ]; do
    printf 'create refs/heads/%s-%d HEAD\n' "${make_many_branches_name}" "${make_many_branches_i}"
    make_many_branches_i=$((make_many_branches_i + 1))
  done | git -C "${feature_dir}" update-ref --stdin
}

## A repository can have so many branches that their names exceed the size
## limit of an environment variable.  An agent that leaves git's
## configuration alone is accepted there, and one that changes it is
## rejected.
setup_case good-many-branches
make_many_branches
push_to good --llm
check_resolved claude "many branches"
setup_case config-many-branches
make_many_branches
push_to config --llm
check_not_resolved "agent that changes git's configuration, with many branches"
case "${push_output}" in
  *"changed git's configuration, attributes, or hooks"*) ;;
  *) fail "agent that changes git's configuration, with many branches: wrong diagnostic: ${push_output}" ;;
esac

## An agent that changes a line of a value that looks like an entry for a
## branch that does not exist is rejected.
setup_case multiline-config
git -C "${feature_dir}" config core.pager "$(printf 'less\nbranch.gone.remote=origin')"
push_to multiline-config --llm
check_not_resolved "agent that changes a line of a multi-line value"
case "${push_output}" in
  *"changed git's configuration, attributes, or hooks"*) ;;
  *) fail "agent that changes a line of a multi-line value: wrong diagnostic: ${push_output}" ;;
esac

echo "${SCRIPT_NAME}: all tests passed"
