#!/bin/sh

# Tests the functions in common-functions.sh.
#
# Usage:
#   tests/test-common-functions.sh
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(CDPATH='' cd -- "${TESTS_DIR}/.." && pwd -P)" || exit 1

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
# Resolve symbolic links, as git does in the pathnames that
# `git worktree list` prints:  on macOS, $TMPDIR is below /var, a symbolic
# link to /private/var.
WORK_DIR="$(CDPATH='' cd -- "${WORK_DIR}" && pwd -P)" || exit 1
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${WORK_DIR}"' EXIT
trap 'rm -rf "${WORK_DIR}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${WORK_DIR}"; trap - TERM; kill -s TERM "$$"' TERM

# shellcheck source=lib-git-test-env.sh
. "${TESTS_DIR}/lib-git-test-env.sh"

sanitize_git_env "${WORK_DIR}"

# `common-functions.sh` expects ${SCRIPT_DIR} to be the directory that holds
# this package's files.  The functions that this test calls do not use it, but
# set it anyway, so that the file is sourced the way its comment requires.
# shellcheck disable=SC2034
SCRIPT_DIR="${COMMANDS_DIR}"
# shellcheck source=../common-functions.sh
. "${COMMANDS_DIR}/common-functions.sh"

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

# `is_remote_name` distinguishes the two kinds of value that `push_remote`
# reports, so that a caller fetches into a remote-tracking namespace only where
# the remote has one.
if ! is_remote_name "${WORK_DIR}/clone" 'origin'; then
  fail 'is_remote_name said that "origin" is not a remote of the clone'
fi
if is_remote_name "${WORK_DIR}/clone" '../mirrors/other.git'; then
  fail 'is_remote_name said that a pathname is a remote of the clone'
fi
if is_remote_name "${WORK_DIR}/clone" 'fork'; then
  fail 'is_remote_name said that a name the clone lacks is a remote of it'
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

## Usage: check_url_key URL EXPECTED
## Checks that `url_key`, in ${WORK_DIR}, prints EXPECTED for URL.
check_url_key() {
  check_url_key_actual="$(url_key "${WORK_DIR}" "$1")"
  if [ "${check_url_key_actual}" != "$2" ]; then
    fail "url_key [$1] printed [${check_url_key_actual}], not [$2]"
  fi
}

# Spellings of one repository's URL have one key.
check_url_key 'git@github.com:Org/Proj.git' 'github.com/org/proj'
check_url_key 'https://GitHub.com/org/proj/' 'github.com/org/proj'
# A scheme's default port is the same as no port.
check_url_key 'ssh://git@github.com:22/org/proj.git' 'github.com/org/proj'
check_url_key 'https://github.com:443/org/proj' 'github.com/org/proj'
# Any other port is part of the key, so a server on another port is a different
# repository.  An scp-style path that begins with digits is not a port.
check_url_key 'https://example.com:8443/org/proj' 'example.com:8443/org/proj'
check_url_key 'https://example.com/org/proj' 'example.com/org/proj'
check_url_key 'example.com:8443/org/proj' 'example.com/8443/org/proj'
# Only a host that ignores the case of its paths has its path in lower case.
check_url_key 'https://example.com/Org/Proj' 'example.com/Org/Proj'

# A `file://` URL and the pathname of one directory are one repository, but
# they reach it through different transports, so one answer to
# `git ls-remote` does not serve both.
git init -q --bare "${WORK_DIR}/heads.git"
for heads_dir in heads-by-url heads-by-path; do
  git init -q "${WORK_DIR}/${heads_dir}"
done
git -C "${WORK_DIR}/heads-by-url" remote add origin "file://${WORK_DIR}/heads.git"
git -C "${WORK_DIR}/heads-by-path" remote add origin "${WORK_DIR}/heads.git"
by_url="$(repository_key "${WORK_DIR}/heads-by-url" origin)"
if [ -z "${by_url}" ] || [ "${by_url}" != "$(repository_key "${WORK_DIR}/heads-by-path" origin)" ]; then
  fail "repository_key does not equate a file:// URL with its pathname"
fi
by_url="$(remote_heads_key "${WORK_DIR}/heads-by-url" origin)"
if [ -z "${by_url}" ] || [ "${by_url}" = "$(remote_heads_key "${WORK_DIR}/heads-by-path" origin)" ]; then
  fail "remote_heads_key [${by_url}] does not distinguish a file:// URL from its pathname"
fi

## Usage: check_is_deleted_branch DIRECTORY EXPECTED DESCRIPTION
## Checks that `is_deleted_branch DIRECTORY` returns status EXPECTED.
check_is_deleted_branch() {
  check_is_deleted_branch_status=0
  is_deleted_branch "$1" || check_is_deleted_branch_status="$?"
  if [ "${check_is_deleted_branch_status}" -ne "$2" ]; then
    fail "is_deleted_branch on $3 returned ${check_is_deleted_branch_status}, not $2"
  fi
}

# `is_deleted_branch` is the body of the `is-deleted-branch` command, which is
# a wrapper around it.  tests/test-is-deleted-branch.sh exercises the answers
# in depth through the command; what this checks is that the function answers
# the same way when a script sources it and calls it directly, which is how
# the other commands of this package use it.
git init -q --bare -b main "${WORK_DIR}/idb-remote.git"
# Redirect stderr to suppress the "you appear to have cloned an empty
# repository" warning.
git clone -q "${WORK_DIR}/idb-remote.git" "${WORK_DIR}/idb-seed" 2> /dev/null
echo 'content' > "${WORK_DIR}/idb-seed/file.txt"
git -C "${WORK_DIR}/idb-seed" add file.txt
git -C "${WORK_DIR}/idb-seed" commit -q -m 'Initial commit'
git -C "${WORK_DIR}/idb-seed" push -q -u origin main
git -C "${WORK_DIR}/idb-seed" push -q origin main:refs/heads/doomed
git clone -q -b doomed "${WORK_DIR}/idb-remote.git" "${WORK_DIR}/idb-dead"
git clone -q -b main "${WORK_DIR}/idb-remote.git" "${WORK_DIR}/idb-live"
git -C "${WORK_DIR}/idb-seed" push -q origin --delete doomed
check_is_deleted_branch "${WORK_DIR}/idb-dead" 0 'a branch deleted in its remote'
check_is_deleted_branch "${WORK_DIR}/idb-live" 1 'a branch that still exists'
mkdir -p "${WORK_DIR}/idb-plain-directory"
check_is_deleted_branch "${WORK_DIR}/idb-plain-directory" 2 'no working tree'

# `check_is_deleted_branch` calls the function on the left of `||`, which
# suppresses `set -e` for the whole of the function's body.  A caller that acts
# on the answer instead -- the commands of this package run under `set -e` --
# gets no such suppression, so check that the function survives one.  Do it in
# a separate script, because a failure here kills the shell that runs it.
#
# The branch is pushed without `-u`, so it has no upstream configuration and
# the `git config --get` queries fail, and it is then deleted in the remote, so
# the `ls-remote` query fails too.  Both failures are answers rather than
# errors, and the function must return 0 rather than let them abort the caller.
git clone -q -b main "${WORK_DIR}/idb-remote.git" "${WORK_DIR}/idb-errexit"
git -C "${WORK_DIR}/idb-errexit" checkout -q -b unconfigured
git -C "${WORK_DIR}/idb-errexit" push -q origin unconfigured
# Delete it from another clone, so that this one keeps the remote-tracking ref
# that shows that the branch was pushed.
git -C "${WORK_DIR}/idb-seed" push -q origin --delete unconfigured
cat > "${WORK_DIR}/errexit-caller.sh" << 'EOF'
#!/bin/sh
set -e
SCRIPT_NAME='errexit-caller.sh'
SCRIPT_DIR="$2"
# shellcheck source=/dev/null
. "$2/common-functions.sh"
is_deleted_branch "$1"
echo 'survived'
EOF
errexit_output="$(sh "${WORK_DIR}/errexit-caller.sh" "${WORK_DIR}/idb-errexit" \
  "${COMMANDS_DIR}" 2>&1)" \
  || fail "is_deleted_branch aborted a caller that runs under set -e: [${errexit_output}]"
if [ "${errexit_output}" != 'survived' ]; then
  fail "is_deleted_branch under set -e printed [${errexit_output}], not [survived]"
fi

# `require_git` accepts the git that runs this test for a requirement that it
# meets, and refuses one that it does not, naming the version that it found.
# It exits rather than returning, so run it in a subshell.
if ! require_git_output="$( (require_git 0) 2>&1)"; then
  fail "require_git 0 refused git: [${require_git_output}]"
fi
if require_git_output="$( (require_git 9999 'for a test') 2>&1)"; then
  fail "require_git 9999 accepted git"
fi
case "${require_git_output}" in
  *"requires git 2.9999 or later for a test, but found git $(git version | sed 's/^git version //')") ;;
  *) fail "unexpected message from require_git 9999: [${require_git_output}]" ;;
esac
# A git that reports an old version, or one that cannot be parsed.  The
# subshells change PATH for `require_git` alone, which is the point.
. "${TESTS_DIR}/common-test-functions.sh"
make_fake_git "${WORK_DIR}/oldgit" version 0 'git version 2.30.9'
# shellcheck disable=SC2030
if require_git_output="$( (PATH="${WORK_DIR}/oldgit:${PATH}" && require_git 31) 2>&1)"; then
  fail "require_git 31 accepted git 2.30.9"
fi
case "${require_git_output}" in
  *"requires git 2.31 or later, but found git 2.30.9") ;;
  *) fail "unexpected message from require_git 31 for git 2.30.9: [${require_git_output}]" ;;
esac
make_fake_git "${WORK_DIR}/oddgit" version 0 'git version unknown'
# shellcheck disable=SC2031
if require_git_output="$( (PATH="${WORK_DIR}/oddgit:${PATH}" && require_git 31) 2>&1)"; then
  fail "require_git 31 accepted an unparsable version"
fi
case "${require_git_output}" in
  *"cannot parse git version: unknown") ;;
  *) fail "unexpected message for an unparsable version: [${require_git_output}]" ;;
esac

# `undo_worktree_add` removes a worktree, its registration, and its branch,
# and leaves everything else of the repository alone.
uwa_main="${WORK_DIR}/uwa-branch-main"
git init -q -b main "${uwa_main}"
echo 'content' > "${uwa_main}/file.txt"
git -C "${uwa_main}" add file.txt
git -C "${uwa_main}" commit -q -m 'Initial commit'
uwa_commit="$(git -C "${uwa_main}" rev-parse HEAD)"
git -C "${uwa_main}" worktree add -q -b doomed "${WORK_DIR}/uwa-branch-doomed"
git -C "${uwa_main}" config branch.doomed.remote origin
git -C "${uwa_main}" config branch.doomed.merge refs/heads/doomed
uwa_gitdir="$(git -C "${WORK_DIR}/uwa-branch-doomed" rev-parse --absolute-git-dir)"
# A half-built worktree has modifications, which `git worktree remove` would
# refuse without `--force`.
echo 'modified' > "${WORK_DIR}/uwa-branch-doomed/file.txt"
# A moved worktree elsewhere in the repository, which `git worktree prune`
# would destroy, must survive.
git -C "${uwa_main}" worktree add -q -b moved "${WORK_DIR}/uwa-branch-moved"
mv "${WORK_DIR}/uwa-branch-moved" "${WORK_DIR}/uwa-branch-moved-elsewhere"
undo_worktree_add "${uwa_main}" "${WORK_DIR}/uwa-branch-doomed" "${uwa_gitdir}" \
  doomed "${uwa_commit}"
if [ -e "${WORK_DIR}/uwa-branch-doomed" ] || [ -e "${uwa_gitdir}" ]; then
  fail "undo_worktree_add left the worktree or its administrative directory"
fi
if git -C "${uwa_main}" rev-parse --verify --quiet refs/heads/doomed > /dev/null; then
  fail "undo_worktree_add left the branch doomed"
fi
if git -C "${uwa_main}" config --get-regexp '^branch\.doomed\.' > /dev/null; then
  fail "undo_worktree_add left the configuration of the branch doomed"
fi
if ! git -C "${uwa_main}" worktree list --porcelain | grep -q -x -F \
  "worktree ${WORK_DIR}/uwa-branch-moved"; then
  fail "undo_worktree_add removed the registration of a moved worktree"
fi
git -C "${uwa_main}" worktree repair "${WORK_DIR}/uwa-branch-moved-elsewhere" > /dev/null 2>&1

# Interrupted between the renames that put a worktree in place, the caller has
# no directory at the registered path, only the administrative directory that
# it learned.  That is removed, and the registration with it, without
# disturbing the registration of a path that is missing for another reason.
git -C "${uwa_main}" worktree add -q --no-checkout -b halfway "${WORK_DIR}/uwa-branch-halfway"
uwa_gitdir="$(git -C "${WORK_DIR}/uwa-branch-halfway" rev-parse --absolute-git-dir)"
rm -rf "${WORK_DIR}/uwa-branch-halfway"
git -C "${uwa_main}" worktree add -q -b stale "${WORK_DIR}/uwa-branch-stale"
rm -rf "${WORK_DIR}/uwa-branch-stale"
undo_worktree_add "${uwa_main}" "${WORK_DIR}/uwa-branch-halfway" "${uwa_gitdir}" \
  halfway "${uwa_commit}"
if [ -e "${uwa_gitdir}" ]; then
  fail "undo_worktree_add left the administrative directory of a missing worktree"
fi
if git -C "${uwa_main}" worktree list --porcelain | grep -q -x -F \
  "worktree ${WORK_DIR}/uwa-branch-halfway"; then
  fail "undo_worktree_add left the registration of a missing worktree"
fi

# A `git worktree add` that failed has nothing at the path, and the caller
# learned no administrative directory.  A registration of that path that is
# not the caller's -- a stale one, which is what made the add fail -- is left
# alone, but the branch that the add created before it failed is deleted.
git -C "${uwa_main}" branch stalebranch
uwa_stale_gitdir="$(git -C "${uwa_main}" rev-parse --path-format=absolute \
  --git-common-dir)/worktrees/uwa-branch-stale"
undo_worktree_add "${uwa_main}" "${WORK_DIR}/uwa-branch-stale" '' \
  stalebranch "${uwa_commit}"
if [ ! -d "${uwa_stale_gitdir}" ]; then
  fail "undo_worktree_add removed a stale registration that was not its own"
fi
if git -C "${uwa_main}" rev-parse --verify --quiet refs/heads/stalebranch > /dev/null; then
  fail "undo_worktree_add left the branch stalebranch"
fi

# A branch that is no longer at the commit that the caller created it at was
# moved by something else, and is left alone.
git -C "${uwa_main}" commit -q --allow-empty -m 'Second commit'
git -C "${uwa_main}" branch movedbranch
git -C "${uwa_main}" config branch.movedbranch.merge refs/heads/movedbranch
undo_worktree_add "${uwa_main}" "${WORK_DIR}/uwa-branch-nothing" '' \
  movedbranch "${uwa_commit}"
if ! git -C "${uwa_main}" rev-parse --verify --quiet refs/heads/movedbranch > /dev/null; then
  fail "undo_worktree_add deleted a branch that is not at the given commit"
fi
if ! git -C "${uwa_main}" config --get branch.movedbranch.merge > /dev/null; then
  fail "undo_worktree_add removed the configuration of a branch that it left"
fi

## Tests of check_conflict_resolution.  Each case makes AUTO_MERGE a tree
## whose file f.txt has given contents, with conflict markers, and writes the
## resolution to f.txt in the working tree.
git init -q "${WORK_DIR}/ccr"

## Usage: check_resolution_files EXPECTED DESCRIPTION
## Makes AUTO_MERGE a tree whose file f.txt is ${WORK_DIR}/ccr-auto, and checks
## that `check_conflict_resolution` accepts (EXPECTED "accept") or rejects
## (EXPECTED "reject") the resolution in ${WORK_DIR}/ccr/f.txt.  It passes
## ${ccr_contains_separator} as the argument that says whether a side of the
## merge contains a line "=======".
ccr_contains_separator=no
check_resolution_files() {
  check_resolution_blob="$(git -C "${WORK_DIR}/ccr" hash-object --no-filters -w "${WORK_DIR}/ccr-auto")"
  check_resolution_tree="$(printf '100644 blob %s\tf.txt\n' "${check_resolution_blob}" \
    | git -C "${WORK_DIR}/ccr" mktree)"
  git -C "${WORK_DIR}/ccr" update-ref AUTO_MERGE "${check_resolution_tree}"
  if (cd "${WORK_DIR}/ccr" && check_conflict_resolution f.txt "${ccr_contains_separator}" 2> /dev/null); then
    check_resolution_actual=accept
  else
    check_resolution_actual=reject
  fi
  if [ "${check_resolution_actual}" != "$1" ]; then
    fail "check_conflict_resolution: $2: expected $1, got ${check_resolution_actual}"
  fi
}

## Usage: check_resolution EXPECTED DESCRIPTION AUTO_MERGE_LINES -- RESOLUTION_LINES
## Like `check_resolution_files`, but takes the files' lines as arguments.
check_resolution() {
  check_resolution_expected="$1"
  check_resolution_description="$2"
  shift 2
  : > "${WORK_DIR}/ccr-auto"
  while [ "$1" != "--" ]; do
    printf '%s\n' "$1" >> "${WORK_DIR}/ccr-auto"
    shift
  done
  shift
  : > "${WORK_DIR}/ccr/f.txt"
  for check_resolution_line; do
    printf '%s\n' "${check_resolution_line}" >> "${WORK_DIR}/ccr/f.txt"
  done
  check_resolution_files "${check_resolution_expected}" "${check_resolution_description}"
}

check_resolution accept "both sides kept" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d -- a b c d
# `git diff -U0` puts the deletion of the blank line on the one after the
# region, outside it.
check_resolution accept "blank lines at the end of the region and after it" \
  a '<<<<<<< HEAD' b '' '=======' c '' '>>>>>>> other' '' d -- a b '' c '' d
check_resolution reject "a separator remains" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d -- a b '=======' c d
ccr_contains_separator=yes
check_resolution accept "a heading underline that looks like a separator, when a side contains one" \
  intro '<<<<<<< HEAD' 'Title A' '=======' '=======' 'Title B' '=======' '>>>>>>> other' text \
  -- intro 'Title B' '=======' text
ccr_contains_separator=no
check_resolution accept "diff3 style" \
  a '<<<<<<< HEAD' b '||||||| base' x '=======' c '>>>>>>> other' d -- a bc d
check_resolution accept "two regions" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' m '<<<<<<< HEAD' e '=======' f '>>>>>>> other' z \
  -- a b m e f z
check_resolution accept "two adjacent regions" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' '<<<<<<< HEAD' e '=======' f '>>>>>>> other' z \
  -- a b f z
check_resolution accept "a resolution that repeats the text between regions" \
  a '<<<<<<< HEAD' m '=======' c '>>>>>>> other' m '<<<<<<< HEAD' e '=======' f '>>>>>>> other' z \
  -- a m m f z
check_resolution reject "the text before the region changed" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d -- A b c d
check_resolution reject "the text after the region changed" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d -- a b c
check_resolution reject "the text between regions changed" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' m '<<<<<<< HEAD' e '=======' f '>>>>>>> other' z \
  -- a b M e f z
check_resolution reject "nothing resolved" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d -- a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d
check_resolution reject "a marker remains" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d -- a b c '>>>>>>> other' d
check_resolution reject "no conflict markers in AUTO_MERGE" \
  a b c -- a b c

## Usage: check_resolution_raw EXPECTED DESCRIPTION AUTO_MERGE_TEXT RESOLUTION_TEXT
## Like `check_resolution_files`, but takes the files' contents as printf
## formats, so that a test can omit the final newline or use CRLF line endings.
check_resolution_raw() {
  # shellcheck disable=SC2059 # The contents are formats.
  printf "$3" > "${WORK_DIR}/ccr-auto"
  # shellcheck disable=SC2059 # The contents are formats.
  printf "$4" > "${WORK_DIR}/ccr/f.txt"
  check_resolution_files "$1" "$2"
}

check_resolution_raw accept "no final newline" \
  '<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\nc' 'aA\nb\nc'
check_resolution_raw reject "no final newline, and the last line changed" \
  '<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\nc' 'aA\nb\nC'
check_resolution_raw reject "the final newline was added" \
  '<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\nc' 'aA\nb\nc\n'
check_resolution_raw reject "the final newline was removed" \
  '<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\nc\n' 'aA\nb\nc'
check_resolution_raw accept "no final newline after a region at the end" \
  'x\n<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\n' 'x\naA'
# A checkout converts the repository's LF line endings to CRLF.
printf '* text eol=crlf\n' > "${WORK_DIR}/ccr/.gitattributes"
check_resolution_raw accept "CRLF line endings in the working tree" \
  'x\n<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\n' 'x\r\naA\r\nb\r\n'
check_resolution_raw reject "CRLF line endings, and a clean line changed" \
  'x\n<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\n' 'x\r\naA\r\nB\r\n'
check_resolution_raw reject "CRLF line endings, and a marker without a label remains" \
  'x\n<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\n' 'x\r\naA\r\n>>>>>>>\r\nb\r\n'
check_resolution_raw reject "CRLF line endings, and a separator remains" \
  'x\n<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\n' 'x\r\na\r\n=======\r\nA\r\nb\r\n'
rm "${WORK_DIR}/ccr/.gitattributes"

## Tests of merge_description.
git init -q -b main "${WORK_DIR}/md"

## Usage: check_merge_description SUBJECT EXPECTED
## Checks that `merge_description` prints EXPECTED for a commit whose subject
## is SUBJECT.  In EXPECTED, "HASH" stands for the commit's abbreviated hash.
check_merge_description() {
  git -C "${WORK_DIR}/md" commit -q --allow-empty -m "$1"
  md_hash="$(git -C "${WORK_DIR}/md" rev-parse --short HEAD)"
  md_expected="$(printf '%s\n' "$2" | sed -e "s/HASH/${md_hash}/")"
  md_actual="$(cd "${WORK_DIR}/md" && merge_description HEAD)"
  if [ "${md_actual}" != "${md_expected}" ]; then
    fail "merge_description for [$1] printed [${md_actual}], not [${md_expected}]"
  fi
}

check_merge_description "Merge branch 'main' into feature" "branch 'main'"
check_merge_description "Merge remote-tracking branch 'upstream/master'" \
  "remote-tracking branch 'upstream/master'"
check_merge_description "Merge branch 'feature' of ../my repo into feature" \
  "branch 'feature' of ../my repo"
check_merge_description "Merge branch 'a' into b into c" "branch 'a' into b"
check_merge_description "Combine the branches" "commit HASH"
check_merge_description "Merge " "commit HASH"

echo "${SCRIPT_NAME}: OK"
