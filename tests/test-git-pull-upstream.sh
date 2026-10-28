#!/bin/sh

# Tests `git-pull-upstream`.
#
# Usage:
#   tests/test-git-pull-upstream.sh
#
# The status code is 0 if all tests pass and 1 otherwise.
#
# The tests use local "remote" repositories, so they do not access the network.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"
COMMANDS_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)" || exit 1
GIT_PULL_UPSTREAM="${COMMANDS_DIR}/git-pull-upstream"

. "${SCRIPT_DIR}/lib-git-test-env.sh"
# shellcheck source=common-test-functions.sh
. "${SCRIPT_DIR}/common-test-functions.sh"

failures=0

# Prints a message and records a test failure.
fail() {
  echo "${SCRIPT_NAME}: FAIL: $1" >&2
  failures=$((failures + 1))
}

# Usage: pull_upstream DIRECTORY [ARGS]
# Runs `git-pull-upstream ARGS` in DIRECTORY, writing its standard error to
# ${testdir}/errors.
pull_upstream() {
  (cd "$1" && shift && "${GIT_PULL_UPSTREAM}" "$@") > /dev/null 2> "${testdir}/errors"
}

# Usage: pushed_head
# Prints the commit that branch "feature" has in the fork's remote repository.
pushed_head() {
  git -C "${fork_remote}" rev-parse refs/heads/feature
}

testdir="$(mktemp -d)"
trap 'rm -rf "${testdir}"' EXIT
trap 'rm -rf "${testdir}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${testdir}"; trap - TERM; kill -s TERM "$$"' TERM

sanitize_git_env "${testdir}"

# The canonical repository, whose default branch is not named "main", and a
# fork of it, with a branch "feature" that has an upstream branch.  The
# Makefile builds successfully unless the file "broken" exists.
canonical="${testdir}/canonical.git"
git init -q --bare -b trunk "${canonical}"
canonical_work="${testdir}/canonical-work"
git clone -q "${canonical}" "${canonical_work}" 2> /dev/null
printf 'all:\n\ttest ! -e broken\n' > "${canonical_work}/Makefile"
git -C "${canonical_work}" add Makefile
commit_file "${canonical_work}" a.txt 'a1'
git -C "${canonical_work}" push -q origin trunk
fork_remote="${testdir}/fork.git"
git clone -q --bare "${canonical}" "${fork_remote}"

fork="${testdir}/fork"
git clone -q "${fork_remote}" "${fork}"
git -C "${fork}" remote add upstream "${canonical}"
git -C "${fork}" switch -q -c feature
mkdir "${fork}/subdir"
commit_file "${fork}" subdir/b.txt 'b1'
git -C "${fork}" push -q -u origin feature

# The fork's branch already contains the default branch of `upstream`.
before="$(git -C "${fork}" rev-parse HEAD)"
if ! pull_upstream "${fork}"; then
  fail "up to date: failed: $(cat "${testdir}/errors")"
elif [ "$(git -C "${fork}" rev-parse HEAD)" != "${before}" ]; then
  fail "up to date: changed HEAD"
fi

# A new commit in `upstream` is merged and pushed, even when this command is
# run in a subdirectory.
commit_file "${canonical_work}" a.txt 'a2'
git -C "${canonical_work}" push -q origin trunk
if ! pull_upstream "${fork}/subdir"; then
  fail "merge: failed: $(cat "${testdir}/errors")"
else
  subject="$(git -C "${fork}" log -1 --format=%s)"
  if [ "${subject}" != "Merge remote-tracking branch 'upstream/trunk' into feature" ]; then
    fail "merge: wrong merge message: ${subject}"
  fi
  if [ "$(cat "${fork}/a.txt")" != 'a2' ]; then
    fail "merge: did not merge a.txt"
  fi
  if [ "$(pushed_head)" != "$(git -C "${fork}" rev-parse HEAD)" ]; then
    fail "merge: did not push"
  fi
fi

# With `merge.log` set, the merge message has the commit summaries that
# `git merge` writes, but not the comment lines, such as "# By AUTHOR", that
# `git fmt-merge-msg` adds when someone other than the user wrote a commit.
printf 'a3\n' > "${canonical_work}/a.txt"
git -C "${canonical_work}" add a.txt
git -C "${canonical_work}" commit -q -m 'Change a.txt again' \
  --author='Another Author <another@example.com>'
git -C "${canonical_work}" push -q origin trunk
git -C "${fork}" config merge.log true
if ! pull_upstream "${fork}"; then
  fail "merge.log: failed: $(cat "${testdir}/errors")"
else
  message="$(git -C "${fork}" log -1 --format=%B)"
  case "${message}" in
    *'
#'*) fail "merge.log: the merge message has comment lines: ${message}" ;;
  esac
  case "${message}" in
    *"* upstream/trunk:"*) ;;
    *) fail "merge.log: the merge message lacks the commit summaries: ${message}" ;;
  esac
fi
git -C "${fork}" config --unset merge.log

# The current branch is pulled from its own upstream branch first.
other="${testdir}/other"
git clone -q -b feature "${fork_remote}" "${other}"
commit_file "${other}" c.txt 'c1'
git -C "${other}" push -q origin feature
commit_file "${canonical_work}" a.txt 'a3'
git -C "${canonical_work}" push -q origin trunk
if ! pull_upstream "${fork}"; then
  fail "pull first: failed: $(cat "${testdir}/errors")"
elif [ ! -e "${fork}/c.txt" ] || [ "$(cat "${fork}/a.txt")" != 'a3' ]; then
  fail "pull first: did not pull and merge"
fi

# A merge that does not build is not pushed, unless `--nocompile` is given.
pushed_before="$(pushed_head)"
commit_file "${canonical_work}" broken 'x'
git -C "${canonical_work}" push -q origin trunk
if pull_upstream "${fork}"; then
  fail "build failure: succeeded"
elif [ "$(pushed_head)" != "${pushed_before}" ]; then
  fail "build failure: pushed"
fi

# The merge that was not pushed survives the pull of a new commit on the
# branch, even when `pull.rebase` is set, and the pull's own merge does not
# stop at an editor.  `GIT_MERGE_AUTOEDIT` makes git start the editor even
# though no terminal is attached, and the editor `false` makes the merge fail.
unpushed_merge="$(git -C "${fork}" rev-parse HEAD)"
git -C "${other}" pull -q --no-rebase
commit_file "${other}" c.txt 'c2'
git -C "${other}" push -q origin feature
git -C "${fork}" config pull.rebase true
if ! GIT_MERGE_AUTOEDIT=yes GIT_EDITOR=false pull_upstream "${fork}" --nocompile; then
  fail "--nocompile: failed: $(cat "${testdir}/errors")"
elif [ "$(pushed_head)" != "$(git -C "${fork}" rev-parse HEAD)" ]; then
  fail "--nocompile: did not push"
elif ! git -C "${fork}" merge-base --is-ancestor "${unpushed_merge}" HEAD; then
  fail "--nocompile: lost the merge that was not pushed"
elif [ "$(cat "${fork}/c.txt")" != 'c2' ]; then
  fail "--nocompile: did not pull c.txt"
fi
git -C "${fork}" config --unset pull.rebase

# A conflicting merge fails and is not pushed.
commit_file "${fork}" a.txt 'fork'
git -C "${fork}" push -q
pushed_before="$(pushed_head)"
commit_file "${canonical_work}" a.txt 'canonical'
git -C "${canonical_work}" push -q origin trunk
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "conflict: succeeded"
elif [ "$(pushed_head)" != "${pushed_before}" ]; then
  fail "conflict: pushed"
fi
git -C "${fork}" merge --abort

# Usage: expect_merge DESCRIPTION REMOTE FILE
# Commits FILE to the default branch of ${fork_remote}, runs this command in
# ${fork}, and checks that it merges REMOTE's default branch and pushes.
expect_merge() {
  git -C "${other}" fetch -q origin
  git -C "${other}" switch -q trunk
  git -C "${other}" merge -q --ff-only origin/trunk
  commit_file "${other}" "$3" "$3"
  git -C "${other}" push -q origin trunk
  if ! MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
    fail "$1: failed: $(cat "${testdir}/errors")"
    return
  fi
  expect_merge_subject="$(git -C "${fork}" log -1 --format=%s)"
  if [ "${expect_merge_subject}" != "Merge remote-tracking branch '$2/trunk' into feature" ]; then
    fail "$1: wrong merge message: ${expect_merge_subject}"
  elif [ ! -e "${fork}/$3" ]; then
    fail "$1: did not merge $3"
  elif [ "$(pushed_head)" != "$(git -C "${fork}" rev-parse HEAD)" ]; then
    fail "$1: did not push"
  fi
}

# Without an `upstream` remote, `origin` is the upstream repository.
git -C "${fork}" remote remove upstream
expect_merge 'origin' origin d.txt

# Without `upstream` or `origin`, the clone's only remote is the upstream
# repository.
git -C "${fork}" remote rename origin github
expect_merge 'sole remote' github e.txt

# A branch that pushes to the upstream repository's default branch is not
# pushed, even when it has commits that are not pushed.
git -C "${fork}" switch -q trunk
git -C "${fork}" merge -q --ff-only github/trunk
commit_file "${fork}" f.txt 'f'
trunk_before="$(git -C "${fork_remote}" rev-parse refs/heads/trunk)"
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "push to upstream default branch: succeeded"
elif [ "$(git -C "${fork_remote}" rev-parse refs/heads/trunk)" != "${trunk_before}" ]; then
  fail "push to upstream default branch: pushed"
elif ! grep -q 'does not push it' "${testdir}/errors"; then
  fail "push to upstream default branch: wrong message: $(cat "${testdir}/errors")"
fi
git -C "${fork}" switch -q feature

# A clone that has no remote named "upstream" or "origin", and more than one
# remote, fails before the pull changes the current branch.
git -C "${fork}" remote add mirror "${fork_remote}"
git -C "${other}" switch -q feature
git -C "${other}" pull -q --no-rebase
commit_file "${other}" g.txt 'g'
git -C "${other}" push -q origin feature
before="$(git -C "${fork}" rev-parse HEAD)"
if pull_upstream "${fork}"; then
  fail "two remotes: succeeded"
elif [ "$(git -C "${fork}" rev-parse HEAD)" != "${before}" ]; then
  fail "two remotes: changed HEAD"
fi
git -C "${fork}" remote remove mirror

# A branch that cannot be pushed is not merged.  When `push.default` is
# "simple", a branch whose name differs from its upstream branch's cannot be
# pushed to that remote.
git -C "${other}" switch -q trunk
git -C "${other}" pull -q --no-rebase
commit_file "${other}" h.txt 'h'
git -C "${other}" push -q origin trunk
git -C "${fork}" switch -q -c renamed --track github/feature
git -C "${fork}" config push.default simple
commit_file "${fork}" renamed.txt 'r'
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "cannot push: succeeded"
elif [ -e "${fork}/h.txt" ]; then
  fail "cannot push: merged"
elif ! grep -q 'cannot be pushed' "${testdir}/errors"; then
  fail "cannot push: wrong message: $(cat "${testdir}/errors")"
fi
git -C "${fork}" switch -q feature

# In a fork, a branch that pushes to the remote "upstream" is not pushed, even
# to a branch other than the default branch.  The refusal comes before the
# pull, so the branch's upstream branch's new commit is not pulled.
git -C "${fork}" remote add upstream "${canonical}"
git -C "${fork}" fetch -q upstream
git -C "${fork}" switch -q -c topic upstream/trunk
git -C "${fork}" config push.default current
commit_file "${fork}" topic.txt 't'
commit_file "${canonical_work}" i.txt 'i'
git -C "${canonical_work}" push -q origin trunk
before="$(git -C "${fork}" rev-parse HEAD)"
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "push to upstream: succeeded"
elif git -C "${canonical}" rev-parse --verify --quiet refs/heads/topic > /dev/null; then
  fail "push to upstream: pushed"
elif [ "$(git -C "${fork}" rev-parse HEAD)" != "${before}" ]; then
  fail "push to upstream: pulled"
elif ! grep -q 'does not push it' "${testdir}/errors"; then
  fail "push to upstream: wrong message: $(cat "${testdir}/errors")"
fi
git -C "${fork}" config --unset push.default
git -C "${fork}" switch -q feature

# A `git push` that might push other branches too is refused, before the pull.
# The current branch's upstream branch has a new commit, which must not be
# pulled.
git -C "${other}" switch -q feature
git -C "${other}" pull -q --no-rebase
commit_file "${other}" j.txt 'j'
git -C "${other}" push -q origin feature
before="$(git -C "${fork}" rev-parse HEAD)"
git -C "${fork}" config push.default matching
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "push.default=matching: succeeded"
elif [ "$(git -C "${fork}" rev-parse HEAD)" != "${before}" ]; then
  fail "push.default=matching: pulled"
elif ! grep -q 'push.default is "matching"' "${testdir}/errors"; then
  fail "push.default=matching: wrong message: $(cat "${testdir}/errors")"
fi
git -C "${fork}" config --unset push.default
git -C "${fork}" config remote.github.mirror true
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "remote.github.mirror: succeeded"
elif [ "$(git -C "${fork}" rev-parse HEAD)" != "${before}" ]; then
  fail "remote.github.mirror: pulled"
elif ! grep -q 'remote.github.mirror is set' "${testdir}/errors"; then
  fail "remote.github.mirror: wrong message: $(cat "${testdir}/errors")"
fi
git -C "${fork}" config --unset remote.github.mirror
git -C "${fork}" config remote.github.push 'refs/heads/*:refs/heads/*'
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "remote.github.push: succeeded"
elif [ "$(git -C "${fork}" rev-parse HEAD)" != "${before}" ]; then
  fail "remote.github.push: pulled"
elif ! grep -q 'remote.github.push is set' "${testdir}/errors"; then
  fail "remote.github.push: wrong message: $(cat "${testdir}/errors")"
fi
git -C "${fork}" config --unset remote.github.push

# In a triangular workflow, a branch that matches the branch it pulls from but
# not the branch it pushes to is pushed, even though there is nothing to merge.
# The branch pulls from `github/feature` and pushes to `push/feature`, which
# lacks the branch's latest commit.
git -C "${fork}" pull -q --no-rebase --no-edit
git -C "${fork}" fetch -q upstream
# `-X ours` resolves the conflict in a.txt that an earlier test made.
git -C "${fork}" merge -q --no-edit -X ours upstream/trunk > /dev/null
push_remote="${testdir}/push.git"
git clone -q --bare "${fork_remote}" "${push_remote}"
git -C "${fork}" remote add push "${push_remote}"
git -C "${fork}" config branch.feature.pushRemote push
git -C "${fork}" config push.default current
git -C "${fork}" fetch -q push
commit_file "${fork}" k.txt 'k'
git -C "${fork}" push -q github feature
git -C "${fork}" fetch -q github
if ! MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "triangular: failed: $(cat "${testdir}/errors")"
elif [ "$(git -C "${push_remote}" rev-parse refs/heads/feature)" != "$(git -C "${fork}" rev-parse HEAD)" ]; then
  fail "triangular: did not push"
fi
git -C "${fork}" config --unset push.default
git -C "${fork}" config --unset branch.feature.pushRemote
git -C "${fork}" remote remove push

# A branch that has no upstream branch fails with a diagnostic that says so.
git -C "${fork}" switch -q -c no-upstream
if pull_upstream "${fork}"; then
  fail "no upstream branch: succeeded"
elif ! grep -q 'has no upstream branch' "${testdir}/errors"; then
  fail "no upstream branch: wrong message: $(cat "${testdir}/errors")"
fi
git -C "${fork}" switch -q feature

# An extra argument is rejected.
if pull_upstream "${fork}" extra; then
  fail "extra argument: succeeded"
fi

if [ "${failures}" -ne 0 ]; then
  echo "${SCRIPT_NAME}: ${failures} failure(s)" >&2
  exit 1
fi
