#!/bin/sh

# Tests the `git-orphaned-branches` script.
#
# Usage:
#   tests/test-git-orphaned-branches
#
# The status code is 0 if all the tests pass, and nonzero otherwise.
#
# The test creates its own scratch git repositories under a temporary
# directory; it does not touch any repository outside that directory.

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
TOPLEVEL="$(CDPATH='' cd -- "${TESTS_DIR}/.." && pwd -P)"
GIT_ORPHANED_BRANCHES="${TOPLEVEL}/git-orphaned-branches"

. "${TESTS_DIR}/lib-git-test-env.sh"

if [ "$#" -ne 0 ]; then
  echo "Usage: ${SCRIPT_NAME}" >&2
  exit 1
fi

status=0

if ! work="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")" || [ -z "${work}" ]; then
  echo "${SCRIPT_NAME}: cannot create a temporary directory" >&2
  exit 1
fi

# Restores the permissions of the deliberately unlistable directory created
# below, so that `rm -rf` can remove it.
# shellcheck disable=SC2329 # Is called from traps.
cleanup() {
  chmod 755 "${work}/dot-project/p-branch-unlistable" 2> /dev/null
  rm -rf "${work}"
}
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'cleanup' EXIT
trap 'cleanup; trap - INT; kill -s INT "$$"' INT
trap 'cleanup; trap - TERM; kill -s TERM "$$"' TERM

if ! work="$(CDPATH='' cd -- "${work}" && pwd -P)" || [ -z "${work}" ]; then
  echo "${SCRIPT_NAME}: cannot resolve the temporary directory" >&2
  exit 1
fi

sanitize_git_env "${work}"

fail() {
  echo "${SCRIPT_NAME}: FAILED: $1" >&2
  exit 1
}

# Prints the absolute path of directory $1, with symbolic links resolved.
# `realpath` would be simpler, but POSIX added it only in 2024 and some
# systems still lack it, whereas `cd` and `pwd -P` are portable.
absolute_path() {
  (CDPATH='' cd -- "$1" && pwd -P)
}

###########################################################################
## Directories that contain nothing but a `.project` file.
###########################################################################

mkdir -p "${work}/dot-project"

# Contains nothing but a `.project` file.
mkdir -p "${work}/dot-project/p-branch-only-project"
touch "${work}/dot-project/p-branch-only-project/.project"

# Contains a `.project` file and a regular file.
mkdir -p "${work}/dot-project/p-branch-plus-file"
touch "${work}/dot-project/p-branch-plus-file/.project" "${work}/dot-project/p-branch-plus-file/other"

# Contains a `.project` file and a hidden file.
mkdir -p "${work}/dot-project/p-branch-plus-hidden"
touch "${work}/dot-project/p-branch-plus-hidden/.project" "${work}/dot-project/p-branch-plus-hidden/.other"

# Contains a `.project` file and a subdirectory.
mkdir -p "${work}/dot-project/p-branch-plus-subdir/sub"
touch "${work}/dot-project/p-branch-plus-subdir/.project"

# Contains a `.project` file and a symbolic link with no target.
mkdir -p "${work}/dot-project/p-branch-plus-dangling-symlink"
touch "${work}/dot-project/p-branch-plus-dangling-symlink/.project"
ln -s no-such-file "${work}/dot-project/p-branch-plus-dangling-symlink/dangling"

# Contains nothing.
mkdir -p "${work}/dot-project/p-branch-empty"

# Contains no `.project` file.
mkdir -p "${work}/dot-project/p-branch-no-project"
touch "${work}/dot-project/p-branch-no-project/other"

# Contains nothing but a `.project` file, but is not named `*-branch-*`.
mkdir -p "${work}/dot-project/p-plain-project"
touch "${work}/dot-project/p-plain-project/.project"

# A `*-branch-*` directory inside another one, which the walk has to descend
# into:  a branch directory can hold a clone of another branch.
mkdir -p "${work}/dot-project/p-branch-outer/q-branch-inner"
touch "${work}/dot-project/p-branch-outer/q-branch-inner/.project"

# A `*-branch-*` directory behind a symbolic link to a directory.  The walk
# does not follow such a link, which is what keeps a link to an ancestor from
# sending it around forever.
mkdir -p "${work}/linktarget/p-branch-behind-link"
touch "${work}/linktarget/p-branch-behind-link/.project"
ln -s ../linktarget "${work}/dot-project/link"

# Contains a `.project` file and a regular file, but cannot be listed:  it can
# be searched but not read.  Every glob in such a directory expands to nothing,
# which must not be mistaken for "contains nothing but a `.project` file".
# The superuser can read any directory, so skip this case when running as root.
unlistable=0
if [ "$(id -u)" -ne 0 ]; then
  unlistable=1
  mkdir -p "${work}/dot-project/p-branch-unlistable"
  touch "${work}/dot-project/p-branch-unlistable/.project" "${work}/dot-project/p-branch-unlistable/other"
  chmod 111 "${work}/dot-project/p-branch-unlistable"
fi

if ! output="$(cd "${work}/dot-project" && "${GIT_ORPHANED_BRANCHES}")"; then
  fail "git-orphaned-branches exited with a failure status"
fi

# Checks whether `git-orphaned-branches` listed a directory.
# Arguments: DIRECTORY-NAME  "listed" or "unlisted"
check() {
  if printf '%s\n' "${output}" | grep -q -x -F -- "${work}/dot-project/$1"; then
    actual="listed"
  else
    actual="unlisted"
  fi
  if [ "${actual}" != "$2" ]; then
    echo "FAIL: git-orphaned-branches left $1 ${actual} rather than $2"
    status=1
  fi
}

check "p-branch-only-project" "listed"
check "p-branch-plus-file" "unlisted"
check "p-branch-plus-hidden" "unlisted"
check "p-branch-plus-subdir" "unlisted"
check "p-branch-plus-dangling-symlink" "unlisted"
check "p-branch-empty" "unlisted"
check "p-branch-no-project" "unlisted"
check "p-plain-project" "unlisted"
check "p-branch-outer" "unlisted"
check "p-branch-outer/q-branch-inner" "listed"
if printf '%s\n' "${output}" | grep -q -F -- 'p-branch-behind-link'; then
  echo "FAIL: git-orphaned-branches followed a symbolic link to a directory"
  status=1
fi
if [ "${unlistable}" -eq 1 ]; then
  check "p-branch-unlistable" "unlisted"
fi

###########################################################################
## A directory whose name contains a newline.
###########################################################################

# A newline cannot be held in a variable by `nl="$(printf '\n')"`, because
# command substitution removes trailing newlines.
nl="$(printf '\nx')"
nl="${nl%x}"

mkdir -p "${work}/newline"
newline_dir="${work}/newline/p-branch-a${nl}b"
mkdir -p "${newline_dir}"
touch "${newline_dir}/.project"

# Compare with --print0, because the newline in the directory name makes the
# newline-separated output ambiguous.
printf '%s\0' "$(absolute_path "${newline_dir}")" > "${work}/newline.goal"
(cd "${work}/newline" && "${GIT_ORPHANED_BRANCHES}" --print0) > "${work}/newline.actual"
if ! cmp -s "${work}/newline.goal" "${work}/newline.actual"; then
  echo "FAIL: git-orphaned-branches output differs from ${work}/newline.goal"
  status=1
fi

###########################################################################
## Clones of branches that have been deleted in the remote repository.
###########################################################################

# Create a remote repository with branches "main" and "feat2".
git init -q --bare -b main "${work}/remote.git"
# Redirect stderr to suppress the "you appear to have cloned an empty repository" warning.
git clone -q "${work}/remote.git" "${work}/seed" 2> /dev/null
echo "hello" > "${work}/seed/file.txt"
git -C "${work}/seed" add file.txt
git -C "${work}/seed" commit -q -m "Initial commit"
git -C "${work}/seed" push -q origin main
git -C "${work}/seed" push -q origin main:refs/heads/feat2

# The orphan directory's name, and the name of its parent directory, contain a
# space; the parent's first space-separated component names a sibling
# directory that must not be deleted.
mkdir -p "${work}/scan/my"
mkdir -p "${work}/scan/my dir"
orphan="${work}/scan/my dir/my repo-branch-feat2"
git clone -q -b feat2 "${work}/remote.git" "${orphan}"

# Delete branch "feat2" in the remote, orphaning the clone.
git -C "${work}/seed" push -q origin --delete feat2

orphan_absolute="$(absolute_path "${orphan}")"

# Test 1: --print0 emits the directory names separated by NUL.
printf '%s\0' "${orphan_absolute}" > "${work}/print0.goal"
(cd "${work}/scan" && "${GIT_ORPHANED_BRANCHES}" --print0) > "${work}/print0.actual"
cmp -s "${work}/print0.goal" "${work}/print0.actual" \
  || fail "--print0 output differs from ${work}/print0.goal"
# `-0` is an alias for `--print0`, so it emits the very same bytes.
(cd "${work}/scan" && "${GIT_ORPHANED_BRANCHES}" -0) > "${work}/print0-alias.actual"
cmp -s "${work}/print0.goal" "${work}/print0-alias.actual" \
  || fail "-0 output differs from ${work}/print0.goal"

# Test 2: without --print0, the directory names are separated by newlines.
printf '%s\n' "${orphan_absolute}" > "${work}/print-newline.goal"
(cd "${work}/scan" && "${GIT_ORPHANED_BRANCHES}") > "${work}/print-newline.actual"
cmp -s "${work}/print-newline.goal" "${work}/print-newline.actual" \
  || fail "default output differs from ${work}/print-newline.goal"

# Test 3: the recommended cleanup command deletes the orphan and nothing else.
(cd "${work}/scan" && "${GIT_ORPHANED_BRANCHES}" --print0) | xargs -0 rm -rf
[ ! -e "${orphan}" ] || fail "cleanup did not delete ${orphan}"
[ -d "${work}/scan/my" ] || fail "cleanup deleted ${work}/scan/my"
[ -d "${work}/scan/my dir" ] || fail "cleanup deleted ${work}/scan/my dir"

###########################################################################
## Working trees whose `.git` is a file rather than a directory.
###########################################################################

# A linked worktree is a working tree, and `is-deleted-branch` answers about
# it correctly, so an orphaned one must be listed.  Before this was fixed,
# such a directory failed the `[ -d "$dir/.git" ]` test, was checked only for
# a lone `.project` file, and was silently ignored.
#
# The main working tree that hosts it must not be listed, even when its own
# branch was deleted as well:  removing it would remove the repository that
# the worktree's `.git` file points into, breaking a working tree that the
# user never named.
git -C "${work}/seed" push -q origin main:refs/heads/host
git -C "${work}/seed" push -q origin main:refs/heads/dependent
mkdir -p "${work}/worktrees"
host="${work}/worktrees/w-branch-host"
dependent="${work}/worktrees/w-branch-dependent"
git clone -q -b host "${work}/remote.git" "${host}"
git -C "${host}" worktree add -q "${dependent}" dependent
host_absolute="$(absolute_path "${host}")"
dependent_absolute="$(absolute_path "${dependent}")"
git -C "${work}/seed" push -q origin --delete host
git -C "${work}/seed" push -q origin --delete dependent

if ! output="$(cd "${work}/worktrees" && "${GIT_ORPHANED_BRANCHES}" \
  2> "${work}/worktrees.stderr")"; then
  fail "git-orphaned-branches exited with a failure status for a linked worktree"
fi
if ! printf '%s\n' "${output}" | grep -q -x -F -- "${dependent_absolute}"; then
  fail "git-orphaned-branches did not list the orphaned worktree ${dependent}"
fi
if printf '%s\n' "${output}" | grep -q -x -F -- "${host_absolute}"; then
  fail "git-orphaned-branches listed ${host}, which hosts a live worktree"
fi
if ! grep -q -F -- "${dependent_absolute}" "${work}/worktrees.stderr"; then
  fail "git-orphaned-branches did not say which worktree ${host} hosts"
fi

# A registration whose directory is gone protects nothing:  removing the host
# cannot break a working tree that does not exist.
rm -rf "${dependent}"
if ! output="$(cd "${work}/worktrees" && "${GIT_ORPHANED_BRANCHES}" 2> /dev/null)"; then
  fail "git-orphaned-branches exited with a failure status for a stale registration"
fi
if ! printf '%s\n' "${output}" | grep -q -x -F -- "${host_absolute}"; then
  fail "git-orphaned-branches did not list ${host} once its worktree was gone"
fi

# A submodule's working tree is a working tree too, and its `.git` is a file
# as well, so the same test decides it.
git init -q --bare -b main "${work}/sub-origin.git"
# Redirect stderr to suppress the "you appear to have cloned an empty
# repository" warning.
git clone -q "${work}/sub-origin.git" "${work}/sub-seed" 2> /dev/null
echo "submodule content" > "${work}/sub-seed/sub.txt"
git -C "${work}/sub-seed" add sub.txt
git -C "${work}/sub-seed" commit -q -m "Initial commit"
git -C "${work}/sub-seed" push -q origin main
git -C "${work}/sub-seed" push -q origin main:refs/heads/subfeat
mkdir -p "${work}/submodule"
superproject="${work}/submodule/super-branch-main"
git init -q -b main "${superproject}"
echo "superproject content" > "${superproject}/super.txt"
git -C "${superproject}" add super.txt
git -C "${superproject}" commit -q -m "Initial commit"
# git 2.38.1 and later refuse the "file" transport for a submodule unless
# `protocol.file.allow` permits it.
git -C "${superproject}" -c protocol.file.allow=always submodule add -q \
  -b subfeat "${work}/sub-origin.git" sub-branch-subfeat
git -C "${superproject}" commit -q -m "Add the submodule"
submodule_absolute="$(absolute_path "${superproject}/sub-branch-subfeat")"
git -C "${work}/sub-seed" push -q origin --delete subfeat

if ! output="$(cd "${work}/submodule" && "${GIT_ORPHANED_BRANCHES}")"; then
  fail "git-orphaned-branches exited with a failure status for a submodule"
fi
if ! printf '%s\n' "${output}" | grep -q -x -F -- "${submodule_absolute}"; then
  fail "git-orphaned-branches did not list the orphaned submodule working tree ${submodule_absolute}"
fi

if [ "${status}" = 0 ]; then
  echo "${SCRIPT_NAME}: OK"
fi
exit "${status}"
