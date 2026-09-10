#!/bin/sh

# Tests `remote_is_usable`, `push_remote`, and `fetch_remote` in
# remote-functions.sh, which decide which remote this package's commands ask
# about a branch.  A wrong answer is not visible in the commands' output:  it
# makes them ask some other repository, which can report that a branch that
# still exists was deleted.  Also tests `conflict_abort_command` and
# `conflict_continue_command`, which the same file provides for the same
# commands:  they name the commands that end or resume the operation that a
# failed pull left in progress, and a wrong name is a command that the user
# runs and that fails.
#
# Usage:
#   tests/test-remote-functions.sh
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(dirname -- "${TESTS_DIR}")"

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

# `remote-functions.sh` expects ${SCRIPT_DIR} to be the directory that holds
# this package's files.  The functions that this test calls do not use it, but
# set it anyway, so that the file is sourced the way its comment requires.
# shellcheck disable=SC2034
SCRIPT_DIR="${COMMANDS_DIR}"
# shellcheck source=../remote-functions.sh
. "${COMMANDS_DIR}/remote-functions.sh"

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

## Usage: check_usable REMOTES NAME EXPECTED
## Checks that `remote_is_usable`, for the clone in ${WORK_DIR}, answers
## EXPECTED for NAME, which is "yes" or "no".  A relative pathname is resolved
## in ${WORK_DIR}.
check_usable() {
  if remote_is_usable "${WORK_DIR}" "$1" "$2"; then
    check_usable_actual='yes'
  else
    check_usable_actual='no'
  fi
  if [ "${check_usable_actual}" != "$3" ]; then
    fail "remote_is_usable [$1] [$2] answered ${check_usable_actual}, not $3"
  fi
}

REMOTES='origin
upstream'

# A name that the clone has.
check_usable "${REMOTES}" 'origin' 'yes'
check_usable "${REMOTES}" 'upstream' 'yes'

# No name at all, and a name that only some other clone has.  The latter is
# what `remote.pushDefault` in ~/.gitconfig amounts to in a clone that has no
# such remote.
check_usable "${REMOTES}" '' 'no'
check_usable "${REMOTES}" 'fork' 'no'

# A URL, which git accepts wherever it accepts a remote's name.  A string that
# contains ":" is an scp-style or a scheme-style URL, and "~" begins a pathname
# in the shell syntax that git accepts for a local repository.
check_usable "${REMOTES}" 'git@example.com:owner/other.git' 'yes'
check_usable "${REMOTES}" 'https://example.com/owner/other.git' 'yes'
# Assemble the tilde, which does not expand inside quotes anyway, so that the
# test says what it means rather than looking like an unexpanded "~".
TILDE='~'
check_usable "${REMOTES}" "${TILDE}/other.git" 'yes'
check_usable "${REMOTES}" "${TILDE}other" 'yes'

# A pathname, which git also accepts wherever it accepts a remote's name.
# `git push --set-upstream ../other.git BRANCH` writes such a value into
# `branch.BRANCH.remote`.  Only a pathname that names a repository is usable:
# git accepts "/" in the name of a remote, so a slash does not by itself tell a
# pathname from the name of a remote that this clone lacks.  A pathname may
# name a bare repository or a working tree.
git init -q --bare -b main "${WORK_DIR}/mirrors/other.git"
git init -q -b main "${WORK_DIR}/working-tree"
check_usable "${REMOTES}" 'mirrors/other.git' 'yes'
check_usable "${REMOTES}" './working-tree' 'yes'
check_usable "${REMOTES}" 'mirrors/nosuch.git' 'no'
check_usable "${REMOTES}" '/srv/git/nosuch-49b1c0.git' 'no'

# A name with no "/" in it is the name of a remote, so a repository of that
# name within the working tree does not make it usable, even though git would
# resolve the name as a relative pathname in a clone that has no such remote.
# A nested repository is commonplace -- a submodule, or a vendored clone -- and
# it is not the fork that `remote.pushDefault = working-tree` names, so pushing
# a branch into it is the failure that this function exists to prevent.  A
# value that is meant as a pathname says so with a "/", as "./working-tree"
# above does.
check_usable "${REMOTES}" 'working-tree' 'no'

# A file or a directory that is not a repository does not make a name usable.
# A working tree commonly contains a directory whose name is also a common
# name for a remote:  if an `upstream/` directory made `upstream` usable, then
# `remote.pushDefault = upstream` in ~/.gitconfig would send every query about
# the branch to something that is not a repository, and git answers such a
# query with "does not appear to be a git repository" -- exactly the failure
# that this function exists to prevent.  The clone in this check has only the
# remote "origin", so the name itself does not make "upstream" usable.
mkdir -p "${WORK_DIR}/upstream"
: > "${WORK_DIR}/plain-file"
check_usable 'origin' 'upstream' 'no'
check_usable "${REMOTES}" 'plain-file' 'no'

# A directory within a working tree is not the repository that contains it,
# even though a git command run there would find that repository.
mkdir -p "${WORK_DIR}/working-tree/subdir"
check_usable "${REMOTES}" 'working-tree/subdir' 'no'

# A remote that only some other clone has, whose name contains "/".  This is
# what `remote.pushDefault = team/fork` in ~/.gitconfig amounts to here, and
# `git remote add team/fork URL` shows that such a name is one that a remote
# can have.  Reporting it as usable would send every query to a repository
# that does not exist, which silently disables the check that made the query.
check_usable "${REMOTES}" 'team/fork' 'no'

# `push_remote` reports the pathname that the branch is pushed to, rather than
# falling back to "origin".  Falling back would make `is-deleted-branch` ask
# the wrong repository about the branch, which can report that a branch that
# still exists there was deleted.
git init -q -b main "${WORK_DIR}/clone"
echo "first line" > "${WORK_DIR}/clone/file.txt"
git -C "${WORK_DIR}/clone" add file.txt
git -C "${WORK_DIR}/clone" commit -q -m "Initial commit"
git -C "${WORK_DIR}/clone" remote add origin "${WORK_DIR}/origin.git"
git init -q --bare -b main "${WORK_DIR}/origin.git"
git -C "${WORK_DIR}/clone" config branch.main.remote '../mirrors/other.git'

remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != '../mirrors/other.git' ]; then
  fail "push_remote reported [${remote}] for a branch pushed to ../mirrors/other.git"
fi

# The pathname really is where git pushes the branch, so reporting it is right.
git -C "${WORK_DIR}/clone" push -q '../mirrors/other.git' main
if ! git -C "${WORK_DIR}/mirrors/other.git" rev-parse --verify --quiet main > /dev/null; then
  fail 'git did not push to the pathname that push_remote reported'
fi

# A name that no remote has still yields "origin", the remote that git itself
# falls back to, whether or not the name contains "/".  Reporting the name
# itself would make every query about the branch fail, and a failed query is
# not an answer:  `is-deleted-branch` would report "cannot tell" for a branch
# that "origin" can be asked about.
git -C "${WORK_DIR}/clone" config branch.main.remote 'fork'
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'origin' ]; then
  fail "push_remote reported [${remote}] for a branch whose remote this clone does not have"
fi
git -C "${WORK_DIR}/clone" config branch.main.remote 'team/fork'
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'origin' ]; then
  fail "push_remote reported [${remote}] for a branch whose remote is a name containing a slash"
fi

# A directory in the working tree does not make the name of a remote that the
# clone lacks look like a pathname.  `remote.pushDefault = fork` in
# ~/.gitconfig names a remote that only some other clone has; if a `fork/`
# directory in the working tree made that name usable, every query about the
# branch would go to something that is not a repository, and the check that
# made the query would silently stop working.
git -C "${WORK_DIR}/clone" config --unset branch.main.remote
git -C "${WORK_DIR}/clone" config remote.pushDefault 'fork'
mkdir -p "${WORK_DIR}/clone/fork"
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'origin' ]; then
  fail "push_remote reported [${remote}] for a name that only a working-tree directory matches"
fi

# A repository nested in the working tree does not make such a name usable
# either.  A submodule, or a vendored clone, in a directory named "upstream" is
# commonplace, and `remote.pushDefault = upstream` in ~/.gitconfig names the
# fork that some other clone has:  pushing the branch into the nested
# repository is the same failure as pushing to a name that no repository has.
git init -q --bare -b main "${WORK_DIR}/clone/upstream"
git -C "${WORK_DIR}/clone" config remote.pushDefault 'upstream'
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'origin' ]; then
  fail "push_remote reported [${remote}] for a name that only a nested repository matches"
fi

# A pathname that does name a repository is still reported, even when it lies
# within the working tree, where the directories in the checks above lie.
git init -q --bare -b main "${WORK_DIR}/clone/fork/repository.git"
git -C "${WORK_DIR}/clone" config remote.pushDefault 'fork/repository.git'
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'fork/repository.git' ]; then
  fail "push_remote reported [${remote}] for a branch pushed to fork/repository.git"
fi

# `branch.BRANCH.pushRemote` outranks `branch.BRANCH.remote`, as `git push`
# itself does:  a branch that is fetched from one remote and pushed to another
# is pushed to the one that the pushRemote names.
git -C "${WORK_DIR}/clone" config branch.main.pushRemote '../mirrors/other.git'
git -C "${WORK_DIR}/clone" config branch.main.remote 'origin'
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != '../mirrors/other.git' ]; then
  fail "push_remote reported [${remote}] for a branch whose pushRemote is ../mirrors/other.git"
fi

# An empty branch, which means that HEAD is detached, uses only the
# configuration that is not about a particular branch:  the branch settings
# above are the ones of some other branch, which say nothing about this push.
remote="$(push_remote "${WORK_DIR}/clone" '')"
if [ "${remote}" != 'fork/repository.git' ]; then
  fail "push_remote reported [${remote}] for an empty branch"
fi
git -C "${WORK_DIR}/clone" config --unset branch.main.pushRemote
git -C "${WORK_DIR}/clone" config --unset branch.main.remote

# `fetch_remote` reports the remote that the branch is fetched from, which is
# not always the one that `push_remote` reports.  In the fork workflow the
# clone pushes to a fork -- `remote.pushDefault` or `branch.BRANCH.pushRemote`
# names it -- and fetches the project's branches from another remote, so a
# question about what the project has must go to the latter.  Asking the fork
# would report that a branch of the project does not exist.
git init -q --bare -b main "${WORK_DIR}/fork.git"
git -C "${WORK_DIR}/clone" remote add fork "${WORK_DIR}/fork.git"
git -C "${WORK_DIR}/clone" config remote.pushDefault 'fork'
remote="$(fetch_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'origin' ]; then
  fail "fetch_remote reported [${remote}] for a clone whose remote.pushDefault is fork"
fi
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'fork' ]; then
  fail "push_remote reported [${remote}] for a clone whose remote.pushDefault is fork"
fi
git -C "${WORK_DIR}/clone" config --unset remote.pushDefault
git -C "${WORK_DIR}/clone" config branch.main.pushRemote 'fork'
remote="$(fetch_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'origin' ]; then
  fail "fetch_remote reported [${remote}] for a branch whose pushRemote is fork"
fi

# `branch.BRANCH.remote` does say where the branch is fetched from, so
# `fetch_remote` reports it even though a pushRemote outranks it for a push.
git -C "${WORK_DIR}/clone" config branch.main.remote 'fork'
remote="$(fetch_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'fork' ]; then
  fail "fetch_remote reported [${remote}] for a branch whose remote is fork"
fi
git -C "${WORK_DIR}/clone" config --unset branch.main.remote
git -C "${WORK_DIR}/clone" config --unset branch.main.pushRemote

# A clone whose sole remote is not named "origin" fetches from that one.
git -C "${WORK_DIR}/clone" remote remove fork
git -C "${WORK_DIR}/clone" remote rename origin elsewhere
remote="$(fetch_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'elsewhere' ]; then
  fail "fetch_remote reported [${remote}] for a clone whose sole remote is elsewhere"
fi
# The same clone pushes to that remote, because it is the only one it has.
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'elsewhere' ]; then
  fail "push_remote reported [${remote}] for a clone whose sole remote is elsewhere"
fi

# `conflict_abort_command` names the command that ends the operation in
# progress, and `conflict_continue_command` the command that resumes it:  each
# operation rejects every other one's `--abort` and `--continue`.

## Usage: check_conflict_commands SITUATION ABORT CONTINUE
## Fails the test unless the two functions report ABORT and CONTINUE for the
## state that the clone is currently in, which SITUATION names.
check_conflict_commands() {
  check_conflict_commands_abort="$(conflict_abort_command "${WORK_DIR}/clone")"
  if [ "${check_conflict_commands_abort}" != "$2" ]; then
    fail "conflict_abort_command reported [${check_conflict_commands_abort}] rather than [$2] $1"
  fi
  check_conflict_commands_continue="$(conflict_continue_command "${WORK_DIR}/clone")"
  if [ "${check_conflict_commands_continue}" != "$3" ]; then
    fail "conflict_continue_command reported [${check_conflict_commands_continue}] rather than [$3] $1"
  fi
}

# With no operation in progress, every `--abort` fails, and resolving the
# conflicts finishes nothing, so there is no `--continue` to advise.
check_conflict_commands 'with no operation in progress' 'git reset --merge' ''
mkdir -p "${WORK_DIR}/clone/.git/rebase-merge"
check_conflict_commands 'during a rebase' 'git rebase --abort' 'git rebase --continue'
rmdir "${WORK_DIR}/clone/.git/rebase-merge"
mkdir -p "${WORK_DIR}/clone/.git/rebase-apply"
check_conflict_commands 'during a patch-applying rebase' \
  'git rebase --abort' 'git rebase --continue'
# `git am` uses the same directory as a patch-applying rebase, and only it
# creates `applying` there.  Advising `git rebase --abort` during a `git am`
# gives the user a command that exits 128 with "It looks like 'git am' is in
# progress.  Cannot rebase."
touch "${WORK_DIR}/clone/.git/rebase-apply/applying"
check_conflict_commands 'during a git am' 'git am --abort' 'git am --continue'
rm -rf "${WORK_DIR}/clone/.git/rebase-apply"
touch "${WORK_DIR}/clone/.git/MERGE_HEAD"
check_conflict_commands 'during a merge' 'git merge --abort' 'git merge --continue'
rm -f "${WORK_DIR}/clone/.git/MERGE_HEAD"
touch "${WORK_DIR}/clone/.git/CHERRY_PICK_HEAD"
check_conflict_commands 'during a cherry-pick' \
  'git cherry-pick --abort' 'git cherry-pick --continue'
# A rebase that stops at a conflict can leave `CHERRY_PICK_HEAD` as well, and
# `git cherry-pick --abort` is not what leaves that state, so the rebase
# directory outranks the pseudo-ref.
mkdir -p "${WORK_DIR}/clone/.git/rebase-merge"
check_conflict_commands 'during a rebase that left CHERRY_PICK_HEAD' \
  'git rebase --abort' 'git rebase --continue'
rmdir "${WORK_DIR}/clone/.git/rebase-merge"
rm -f "${WORK_DIR}/clone/.git/CHERRY_PICK_HEAD"
touch "${WORK_DIR}/clone/.git/REVERT_HEAD"
check_conflict_commands 'during a revert' 'git revert --abort' 'git revert --continue'
rm -f "${WORK_DIR}/clone/.git/REVERT_HEAD"

echo "${SCRIPT_NAME}: OK"
