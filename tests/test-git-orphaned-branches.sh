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

# Restores the permissions of the deliberately unlistable and unenterable
# directories created below, so that `rm -rf` can remove them.
# shellcheck disable=SC2329 # Is called from traps.
cleanup() {
  chmod 755 "${work}/dot-project/p-branch-unlistable" \
    "${work}/dot-project/p-branch-unenterable" \
    "${work}/dot-project/p-repo/r-branch-unenterable" 2> /dev/null
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
## Directories that contain nothing but Eclipse `.project` files.
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

# Contains a `.project` file and an empty subdirectory, such as the `bin` that
# Eclipse makes for a project's build output.
mkdir -p "${work}/dot-project/p-branch-plus-subdir/sub"
touch "${work}/dot-project/p-branch-plus-subdir/.project"

# The shape that Eclipse leaves when a branch directory's working tree is
# gone:  a `.project` file at the top level, one in each project directory
# below it, and an empty `bin` beside each of those.
mkdir -p "${work}/dot-project/p-branch-leftover/covered-class/bin" \
  "${work}/dot-project/p-branch-leftover/replacecall/bin"
touch "${work}/dot-project/p-branch-leftover/.project" \
  "${work}/dot-project/p-branch-leftover/covered-class/.project" \
  "${work}/dot-project/p-branch-leftover/replacecall/.project"

# Contains a `.project` file, and a file that is not one further down.
mkdir -p "${work}/dot-project/p-branch-deep-file/sub"
touch "${work}/dot-project/p-branch-deep-file/.project" \
  "${work}/dot-project/p-branch-deep-file/sub/other"

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
# into:  a branch directory can hold a clone of another branch.  The outer
# directory holds a file of its own, so that it is content rather than a
# leftover of `.project` files and the walk descends into it instead of
# reporting it.
mkdir -p "${work}/dot-project/p-branch-outer/q-branch-inner"
touch "${work}/dot-project/p-branch-outer/other" \
  "${work}/dot-project/p-branch-outer/q-branch-inner/.project"
# A `*-branch-*` directory that is not a leftover, inside the outer one.  The
# warning about the outer directory covers it.
mkdir -p "${work}/dot-project/p-branch-outer/q-branch-content"
touch "${work}/dot-project/p-branch-outer/q-branch-content/other"

# Contains no `.project` file of its own, but holds one further down, which is
# what a branch whose Eclipse projects were all below its top level leaves
# behind.  The whole tree is a leftover, so it is reported and the walk does
# not descend into it.
mkdir -p "${work}/dot-project/p-branch-nested-project/java/lib"
touch "${work}/dot-project/p-branch-nested-project/java/lib/.project"

# Contains nothing but empty directories, so it holds no `.project` file
# anywhere and is the leftover of nothing.
mkdir -p "${work}/dot-project/p-branch-empty-tree/sub/deeper"

# Contains nothing but Python build output.  A `*-branch-*` directory within
# its `.venv` is build output, so it is neither listed nor warned about.
mkdir -p "${work}/dot-project/p-branch-python/.venv/lib/x-branch-y" \
  "${work}/dot-project/p-branch-python/myproject.egg-info"
touch "${work}/dot-project/p-branch-python/.venv/lib/x-branch-y/other"

# Contains nothing but a `.venv` directory, but that holds a git clone, as
# `pip install -e git+URL#egg=NAME` makes in `.venv/src/`.  The clone can hold
# unpushed work, so the directory is not a leftover.
mkdir -p "${work}/dot-project/p-branch-python-checkout/.venv/src/mylib/.git"
touch "${work}/dot-project/p-branch-python-checkout/.venv/src/mylib/setup.py"
# A `*-branch-*` directory within a `.venv` that holds a checkout is examined
# like any other.  This one is the leftover of a clone, so it is warned about.
mkdir -p "${work}/dot-project/p-plain-python/.venv/src/mylib-branch-fix/.git"
touch "${work}/dot-project/p-plain-python/.venv/src/mylib-branch-fix/setup.py"

# The walk examines nothing below a directory named `.cache` or `.claude`.
# Each `*-branch-*` directory here would otherwise be warned about.
mkdir -p "${work}/dot-project/.cache/c-branch-cached" \
  "${work}/dot-project/sub/.claude/worktrees/c-branch-claude"
touch "${work}/dot-project/.cache/c-branch-cached/other" \
  "${work}/dot-project/sub/.claude/worktrees/c-branch-claude/other"

# A Claude Code configuration directory that is not named `.claude`, such as
# one that `CLAUDE_CONFIG_DIR` names, whose `projects` directory holds a
# directory named for each directory that Claude Code has run in.  The walk
# does not examine that `projects` directory.
mkdir -p "${work}/dot-project/.claude-alt/projects/-home-me-repo-branch-feature"
touch "${work}/dot-project/.claude-alt/history.jsonl" \
  "${work}/dot-project/.claude-alt/projects/-home-me-repo-branch-feature/a.jsonl"
# A `projects` directory whose parent holds no `history.jsonl` file is not
# part of a Claude Code configuration directory, so the walk examines it.
mkdir -p "${work}/dot-project/p-plain-projects/projects/-home-me-repo-branch-other"
touch "${work}/dot-project/p-plain-projects/projects/-home-me-repo-branch-other/a.jsonl"

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
  # Cannot be entered at all, as for a directory that only another user can
  # search.
  mkdir -p "${work}/dot-project/p-branch-unenterable"
  touch "${work}/dot-project/p-branch-unenterable/other"
  chmod 000 "${work}/dot-project/p-branch-unenterable"
fi

# What a failed `rm -rf` leaves of a branch directory whose `.git` directory
# holds files that another user owns:  part of the `.git` directory, with no
# `HEAD`.  Git cannot use it, but it is a leftover, not a working tree.
mkdir -p "${work}/dot-project/p-branch-git-leftover/.git/objects/ab"
touch "${work}/dot-project/p-branch-git-leftover/.git/objects/ab/cdef"

# A `*-branch-*` directory that is a subdirectory of a working tree and holds
# a tracked file is part of that working tree, not a leftover, so it is
# neither listed nor warned about.
git init -q -b main "${work}/dot-project/p-repo"
mkdir -p "${work}/dot-project/p-repo/r-branch-subdir"
touch "${work}/dot-project/p-repo/r-branch-subdir/other"
# Likewise for one that holds nothing but Python build output, such as a test
# fixture, if the working tree tracks a file in it.  If the working tree
# tracks none, it is a leftover, so it is listed.
mkdir -p "${work}/dot-project/p-repo/r-branch-tracked-python/pkg.egg-info" \
  "${work}/dot-project/p-repo/r-branch-untracked-python/.venv"
touch "${work}/dot-project/p-repo/r-branch-tracked-python/pkg.egg-info/PKG-INFO"
git -C "${work}/dot-project/p-repo" add r-branch-subdir/other \
  r-branch-tracked-python
git -C "${work}/dot-project/p-repo" commit -q -m 'Track a file'
# A `*-branch-*` directory in a working tree that tracks none of its files,
# empty or not, is not part of that working tree.  It is not listed, but it is
# warned about.
mkdir -p "${work}/dot-project/p-repo/r-branch-empty"
mkdir -p "${work}/dot-project/p-repo/r-branch-untracked"
touch "${work}/dot-project/p-repo/r-branch-untracked/other"
# So is one that the working tree ignores by name, as a repository of
# configuration files ignores the directory that holds clones.
printf 'r-branch-ignored/\n' > "${work}/dot-project/p-repo/.gitignore"
mkdir -p "${work}/dot-project/p-repo/r-branch-ignored"
touch "${work}/dot-project/p-repo/r-branch-ignored/other"
# A `*-branch-*` directory in a working tree that git can use, but that the
# user cannot enter, is warned about as such, and says nothing about the
# working tree.
if [ "${unlistable}" -eq 1 ]; then
  mkdir -p "${work}/dot-project/p-repo/r-branch-unenterable"
  touch "${work}/dot-project/p-repo/r-branch-unenterable/other"
  chmod 000 "${work}/dot-project/p-repo/r-branch-unenterable"
fi
# Neither is a `*-branch-*` directory in a `.git` directory, nor a bare
# repository:  git can use the repository in each, which has no working tree.
mkdir -p "${work}/dot-project/p-repo/.git/refs/heads/r-branch-ref"
touch "${work}/dot-project/p-repo/.git/refs/heads/r-branch-ref/other"
git init -q --bare -b main "${work}/dot-project/p-branch-bare.git"

# A linked worktree whose main working tree was moved.  Its `.git` file names
# a git directory that no longer exists, so git cannot use it, but it is a
# repository that can hold work rather than a leftover.
git init -q -b main "${work}/dot-project/p-main"
git -C "${work}/dot-project/p-main" commit -q --allow-empty -m 'Initial commit'
git -C "${work}/dot-project/p-main" worktree add -q -b feat \
  "${work}/dot-project/p-branch-broken-worktree"
# Another one, not named `*-branch-*`, that holds `*-branch-*` directories.
git -C "${work}/dot-project/p-main" worktree add -q -b feat2 \
  "${work}/dot-project/p-broken-plain"
mkdir -p "${work}/dot-project/p-broken-plain/a-branch-1" \
  "${work}/dot-project/p-broken-plain/b-branch-2"
mv "${work}/dot-project/p-main" "${work}/dot-project/p-main-moved"

if ! output="$(cd "${work}/dot-project" && "${GIT_ORPHANED_BRANCHES}" \
  2> "${work}/dot-project.stderr")"; then
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
check "p-branch-plus-subdir" "listed"
check "p-branch-leftover" "listed"
check "p-branch-deep-file" "unlisted"
check "p-branch-plus-dangling-symlink" "unlisted"
check "p-branch-empty" "unlisted"
check "p-branch-no-project" "unlisted"
check "p-plain-project" "unlisted"
check "p-branch-outer" "unlisted"
check "p-branch-outer/q-branch-inner" "listed"
check "p-branch-nested-project" "listed"
check "p-branch-empty-tree" "unlisted"
check "p-branch-python" "listed"
check "p-branch-python/.venv/lib/x-branch-y" "unlisted"
check "p-branch-python-checkout" "unlisted"
check "p-plain-python/.venv/src/mylib-branch-fix" "unlisted"
check "p-repo/r-branch-tracked-python" "unlisted"
check "p-repo/r-branch-untracked-python" "listed"
if printf '%s\n' "${output}" | grep -q -F -- 'p-branch-behind-link'; then
  echo "FAIL: git-orphaned-branches followed a symbolic link to a directory"
  status=1
fi
check "p-repo/r-branch-subdir" "unlisted"
check "p-repo/r-branch-empty" "unlisted"
check "p-repo/r-branch-untracked" "unlisted"
check "p-branch-git-leftover" "unlisted"
check "p-broken-plain/a-branch-1" "unlisted"
check "p-broken-plain/b-branch-2" "unlisted"
check "p-branch-outer/q-branch-content" "unlisted"
check "p-branch-broken-worktree" "unlisted"
if [ "${unlistable}" -eq 1 ]; then
  check "p-branch-unlistable" "unlisted"
  check "p-branch-unenterable" "unlisted"
fi

# Checks whether `git-orphaned-branches` warned that a directory is in no git
# working tree.
# Arguments: DIRECTORY-NAME  "warned" or "unwarned"
check_warned() {
  if grep -q -F -- "warning: not listing ${work}/dot-project/$1, which is not in a git working tree" \
    "${work}/dot-project.stderr"; then
    actual="warned"
  else
    actual="unwarned"
  fi
  if [ "${actual}" != "$2" ]; then
    echo "FAIL: git-orphaned-branches left $1 ${actual} rather than $2"
    status=1
  fi
}

# Each `*-branch-*` directory that is in no working tree and either holds
# more than `.project` files or holds no `.project` file at all, such as an
# empty directory, is warned about; each listed one is not.
check_warned "p-branch-only-project" "unwarned"
check_warned "p-branch-plus-file" "warned"
check_warned "p-branch-plus-hidden" "warned"
check_warned "p-branch-leftover" "unwarned"
check_warned "p-branch-deep-file" "warned"
check_warned "p-branch-plus-dangling-symlink" "warned"
check_warned "p-branch-empty" "warned"
check_warned "p-branch-no-project" "warned"
check_warned "p-plain-project" "unwarned"
check_warned "p-branch-outer" "warned"
check_warned "p-branch-outer/q-branch-inner" "unwarned"
check_warned "p-branch-outer/q-branch-content" "unwarned"
check_warned "p-branch-empty-tree" "warned"
check_warned "p-branch-python" "unwarned"
check_warned "p-branch-python/.venv/lib/x-branch-y" "unwarned"
check_warned "p-branch-python-checkout" "warned"
check_warned "p-plain-python/.venv/src/mylib-branch-fix" "warned"
check_warned "p-repo/r-branch-subdir" "unwarned"
check_warned "p-branch-git-leftover" "warned"
check_warned "p-repo/.git/refs/heads/r-branch-ref" "unwarned"
check_warned "p-branch-bare.git" "unwarned"
check_warned "p-branch-broken-worktree" "unwarned"
if grep -q -F -- '-home-me-repo-branch-feature' "${work}/dot-project.stderr" \
  || printf '%s\n' "${output}" | grep -q -F -- '-home-me-repo-branch-feature'; then
  echo "FAIL: git-orphaned-branches examined the projects directory of a Claude Code configuration directory"
  status=1
fi
check_warned "p-plain-projects/projects/-home-me-repo-branch-other" "warned"
if grep -q -e 'c-branch-cached' -e 'c-branch-claude' "${work}/dot-project.stderr" \
  || printf '%s\n' "${output}" | grep -q -e 'c-branch-cached' -e 'c-branch-claude'; then
  echo "FAIL: git-orphaned-branches examined a directory below .cache or .claude"
  status=1
fi
if [ "${unlistable}" -eq 1 ]; then
  check_warned "p-branch-unlistable" "warned"
  # A directory that the user cannot enter is warned about as such.
  for d in p-branch-unenterable p-repo/r-branch-unenterable; do
    check_warned "$d" "unwarned"
    if ! grep -q -x -F -- "git-orphaned-branches: warning: not listing ${work}/dot-project/$d, which you cannot enter" \
      "${work}/dot-project.stderr"; then
      echo "FAIL: git-orphaned-branches did not warn that the user cannot enter $d:"
      cat "${work}/dot-project.stderr"
      status=1
    fi
  done
fi
# A working tree that git can use is not called one that git cannot use.
if grep -q -F -- "git cannot use ${work}/dot-project/p-repo " "${work}/dot-project.stderr"; then
  echo "FAIL: git-orphaned-branches claimed that git cannot use p-repo:"
  cat "${work}/dot-project.stderr"
  status=1
fi
# Each `*-branch-*` directory in a working tree that tracks none of its files
# is warned about, whether or not the working tree ignores it.
for d in r-branch-empty r-branch-untracked r-branch-ignored; do
  if ! grep -q -x -F -- "git-orphaned-branches: warning: not listing ${work}/dot-project/p-repo/$d, which is in the git working tree ${work}/dot-project/p-repo but holds no file that it tracks" \
    "${work}/dot-project.stderr"; then
    echo "FAIL: git-orphaned-branches did not warn that p-repo tracks no file in $d:"
    cat "${work}/dot-project.stderr"
    status=1
  fi
done
# Neither directory of Python build output in a working tree is warned about:
# the one that holds a tracked file is part of the working tree, and the other
# is listed.
for d in r-branch-tracked-python r-branch-untracked-python; do
  if grep -q -F -- "${work}/dot-project/p-repo/$d" "${work}/dot-project.stderr"; then
    echo "FAIL: git-orphaned-branches warned about p-repo/$d:"
    cat "${work}/dot-project.stderr"
    status=1
  fi
done
# The directories in a working tree that git cannot use are covered by one
# warning, which names that working tree.
if [ "$(grep -c -F -- "warning: not listing directories in ${work}/dot-project/p-broken-plain, such as ${work}/dot-project/p-broken-plain/a-branch-1, because git cannot use ${work}/dot-project/p-broken-plain as a working tree although ${work}/dot-project/p-broken-plain/.git exists; " \
  "${work}/dot-project.stderr")" -ne 1 ] \
  || grep -q -F -- "b-branch-2" "${work}/dot-project.stderr"; then
  echo "FAIL: git-orphaned-branches did not warn exactly once about p-broken-plain:"
  cat "${work}/dot-project.stderr"
  status=1
fi
# What a failed `rm -rf` left of a `.git` directory is not a working tree.
if grep -q -F -- "p-branch-git-leftover, which git cannot use" "${work}/dot-project.stderr"; then
  echo "FAIL: git-orphaned-branches called the leftover p-branch-git-leftover a working tree:"
  cat "${work}/dot-project.stderr"
  status=1
fi
# A directory that is warned about is warned about once, and a directory
# within it not at all.
if [ "$(grep -c -F -- "warning: not listing ${work}/dot-project/p-branch-outer" \
  "${work}/dot-project.stderr")" -ne 1 ]; then
  echo "FAIL: git-orphaned-branches did not warn exactly once within p-branch-outer:"
  cat "${work}/dot-project.stderr"
  status=1
fi
# The linked worktree whose main working tree was moved is warned about as a
# working tree that git cannot use.
if ! grep -q -F -- "warning: not listing ${work}/dot-project/p-branch-broken-worktree, which git cannot use as a working tree although ${work}/dot-project/p-branch-broken-worktree/.git exists; " \
  "${work}/dot-project.stderr"; then
  echo "FAIL: git-orphaned-branches did not warn that git cannot use p-branch-broken-worktree:"
  cat "${work}/dot-project.stderr"
  status=1
fi
# Every file in the test's directories belongs to the user who runs it.
if grep -q -F -- 'files that you do not own' "${work}/dot-project.stderr"; then
  echo "FAIL: git-orphaned-branches claimed that a file that the user owns is another user's:"
  cat "${work}/dot-project.stderr"
  status=1
fi

###########################################################################
## A directory beyond which git does not search for a repository.
###########################################################################

# Git stops searching for a repository at a directory in
# `GIT_CEILING_DIRECTORIES`, as it does at a file system boundary.  A
# working tree above that directory is one that git can use, so the
# `*-branch-*` directory is warned about as being beyond where git searches
# for that working tree, not as being in one that git cannot use.
git init -q -b main "${work}/ceiling"
git -C "${work}/ceiling" commit -q --allow-empty -m 'Initial commit'
mkdir -p "${work}/ceiling/mount/c-branch-x"
touch "${work}/ceiling/mount/c-branch-x/other"
if ! output="$(cd "${work}/ceiling/mount" \
  && GIT_CEILING_DIRECTORIES="${work}/ceiling/mount" "${GIT_ORPHANED_BRANCHES}" \
    2> "${work}/ceiling.stderr")"; then
  fail "git-orphaned-branches exited with a failure status beyond a ceiling directory"
fi
if [ -n "${output}" ]; then
  fail "git-orphaned-branches printed [${output}] beyond a ceiling directory, expected no output"
fi
if ! grep -q -x -F -- "git-orphaned-branches: warning: not listing ${work}/ceiling/mount/c-branch-x, which is in the git working tree ${work}/ceiling but beyond where git searches for it" \
  "${work}/ceiling.stderr"; then
  echo "FAIL: git-orphaned-branches did not warn about c-branch-x as being beyond where git searches:"
  cat "${work}/ceiling.stderr"
  status=1
fi

###########################################################################
## A working tree that ignores every file that it does not track.
###########################################################################

# A repository of configuration files in a home directory often has a
# `.gitignore` of `*`.  Its ignoring a `*-branch-*` directory says nothing
# about whether the directory is a leftover, so the directory is warned about.
git init -q -b main "${work}/dotfiles"
printf '*\n' > "${work}/dotfiles/.gitignore"
git -C "${work}/dotfiles" add -f .gitignore
git -C "${work}/dotfiles" commit -q -m 'Ignore everything'
mkdir -p "${work}/dotfiles/d-branch-x"
touch "${work}/dotfiles/d-branch-x/other"
if ! output="$(cd "${work}/dotfiles" && "${GIT_ORPHANED_BRANCHES}" \
  2> "${work}/dotfiles.stderr")"; then
  fail "git-orphaned-branches exited with a failure status in a working tree that ignores everything"
fi
if [ -n "${output}" ]; then
  fail "git-orphaned-branches printed [${output}] in a working tree that ignores everything, expected no output"
fi
if ! grep -q -x -F -- "git-orphaned-branches: warning: not listing ${work}/dotfiles/d-branch-x, which is in the git working tree ${work}/dotfiles but holds no file that it tracks" \
  "${work}/dotfiles.stderr"; then
  echo "FAIL: git-orphaned-branches did not warn about d-branch-x in a working tree that ignores everything:"
  cat "${work}/dotfiles.stderr"
  status=1
fi

###########################################################################
## Directories named for a path in a `*-branch-*` working tree.
###########################################################################

# Gradle names the report of a test that it ran on a test directory for that
# directory's absolute path, with each `/` written as `-`.  In a working tree
# named `*-branch-*`, that name matches `*-branch-*` too, but only because of
# the working tree's own name, so the directory is not warned about.  A name
# that matches `*-branch-*` apart from the path that it embeds is warned about,
# and so is a name that embeds the path of a sibling of the working tree.
#
# Each run starts below the symbolic link `gradle-link`, so the names embed the
# path with symbolic links resolved (${gradle_flat}) or the path without them
# (${gradle_link_flat}).  The second run starts in a subdirectory of the
# working tree, so the working tree is an ancestor of the directory that the
# run starts in.
git init -q -b main "${work}/gradle/w-branch-x"
printf 'build/\n' > "${work}/gradle/w-branch-x/.gitignore"
git -C "${work}/gradle/w-branch-x" add .gitignore
git -C "${work}/gradle/w-branch-x" commit -q -m 'Ignore build output'
ln -s gradle "${work}/gradle-link"
gradle_flat="$(printf '%s' "${work}/gradle/w-branch-x" | tr / -)"
gradle_link_flat="$(printf '%s' "${work}/gradle-link/w-branch-x" | tr / -)"
gradle_reports="${work}/gradle/w-branch-x/build/reports/tests/test/MyTest"
for d in "[${gradle_flat}-tests-all]" "[${gradle_flat}-tests-al-5NAR8S06TVEBO" \
  "[${gradle_link_flat}-tests-al-link]" \
  "[${gradle_flat}-tests-z-branch-y]" "[${gradle_flat}yz-tests]"; do
  mkdir -p "${gradle_reports}/$d"
  touch "${gradle_reports}/$d/index.html"
done
# The test directory `branch-q` does not match `*-branch-*`, but the name of
# its report matches `*-branch-*` after the path of the working tree is
# removed.  So the report is not warned about only if the path of the deeper
# ancestor `branch-q` is removed first.
mkdir -p "${work}/gradle/w-branch-x/branch-q/build/reports/[${gradle_flat}-branch-q-tests]"
touch "${work}/gradle/w-branch-x/branch-q/build/reports/[${gradle_flat}-branch-q-tests]/index.html"
for start in w-branch-x w-branch-x/build; do
  if ! output="$(cd "${work}/gradle-link/${start}" && "${GIT_ORPHANED_BRANCHES}" \
    2> "${work}/gradle.stderr")"; then
    fail "git-orphaned-branches exited with a failure status in ${start} with Gradle test reports"
  fi
  if [ -n "${output}" ]; then
    fail "git-orphaned-branches printed [${output}] in ${start} with Gradle test reports, expected no output"
  fi
  if grep -q -e '-tests-al' -e '-branch-q-tests' "${work}/gradle.stderr"; then
    echo "FAIL: git-orphaned-branches in ${start} warned about a directory named for a path in its working tree:"
    cat "${work}/gradle.stderr"
    status=1
  fi
  for d in "[${gradle_flat}-tests-z-branch-y]" "[${gradle_flat}yz-tests]"; do
    if ! grep -q -x -F -- "git-orphaned-branches: warning: not listing ${gradle_reports}/$d, which is in the git working tree ${work}/gradle/w-branch-x but holds no file that it tracks" \
      "${work}/gradle.stderr"; then
      echo "FAIL: git-orphaned-branches in ${start} did not warn about $d, whose name matches \`*-branch-*\` apart from the path of an ancestor:"
      cat "${work}/gradle.stderr"
      status=1
    fi
  done
done

# A working tree none of whose ancestors is named `*-branch-*`, but whose
# flattened path matches `*-branch-*` across the boundary between `branch` and
# `repo`.
git init -q -b main "${work}/gradle/branch/repo"
printf 'build/\n' > "${work}/gradle/branch/repo/.gitignore"
git -C "${work}/gradle/branch/repo" add .gitignore
git -C "${work}/gradle/branch/repo" commit -q -m 'Ignore build output'
gradle_boundary_flat="$(printf '%s' "${work}/gradle/branch/repo" | tr / -)"
mkdir -p "${work}/gradle/branch/repo/build/reports/[${gradle_boundary_flat}-tests-all]"
touch "${work}/gradle/branch/repo/build/reports/[${gradle_boundary_flat}-tests-all]/index.html"
if ! output="$(cd "${work}/gradle/branch/repo" && "${GIT_ORPHANED_BRANCHES}" \
  2> "${work}/gradle-boundary.stderr")"; then
  fail "git-orphaned-branches exited with a failure status in branch/repo with Gradle test reports"
fi
if [ -n "${output}" ]; then
  fail "git-orphaned-branches printed [${output}] in branch/repo with Gradle test reports, expected no output"
fi
if [ -s "${work}/gradle-boundary.stderr" ]; then
  echo "FAIL: git-orphaned-branches warned in branch/repo, expected no warning:"
  cat "${work}/gradle-boundary.stderr"
  status=1
fi

###########################################################################
## Working trees that git cannot use, whatever git's diagnostic.
###########################################################################

# A `.git` directory that holds a `HEAD` but is not a valid git directory,
# which git skips while it searches for a repository, and a `.git` file that
# is not a valid gitfile.  Each is a working tree that git cannot use, not a
# directory that is in no working tree.
mkdir -p "${work}/unusable/invalid/.git" "${work}/unusable/invalid/i-branch-x" \
  "${work}/unusable/garbage/g-branch-x"
echo 'ref: refs/heads/main' > "${work}/unusable/invalid/.git/HEAD"
echo 'garbage' > "${work}/unusable/garbage/.git"
if ! output="$(cd "${work}/unusable" && "${GIT_ORPHANED_BRANCHES}" \
  2> "${work}/unusable.stderr")"; then
  fail "git-orphaned-branches exited with a failure status in working trees that git cannot use"
fi
if [ -n "${output}" ]; then
  fail "git-orphaned-branches printed [${output}] in working trees that git cannot use, expected no output"
fi
for d in invalid/i-branch-x garbage/g-branch-x; do
  if ! grep -q -x -F -- "git-orphaned-branches: warning: not listing directories in ${work}/unusable/${d%/*}, such as ${work}/unusable/$d, because git cannot use ${work}/unusable/${d%/*} as a working tree although ${work}/unusable/${d%/*}/.git exists; \`git -C ${work}/unusable/${d%/*} status\` says why" \
    "${work}/unusable.stderr"; then
    echo "FAIL: git-orphaned-branches did not warn that git cannot use ${d%/*}:"
    cat "${work}/unusable.stderr"
    status=1
  fi
done

# A repository that git refuses because another user owns it, with an
# invalid `.git` directory between it and the `*-branch-*` directory.  The
# warning names the repository that git refuses.  Only the superuser can give
# a repository to another user, so a knob of git's own test suite stands in
# for one.  Git versions that lack the knob, or that word the diagnostic
# differently, are not tested.
git init -q -b main "${work}/dubious"
mkdir -p "${work}/dubious/mid/.git" "${work}/dubious/mid/m-branch-x"
echo 'ref: refs/heads/main' > "${work}/dubious/mid/.git/HEAD"
case "$(GIT_TEST_ASSUME_DIFFERENT_OWNER=1 LC_ALL=C \
  git -C "${work}/dubious/mid/m-branch-x" rev-parse --git-dir 2>&1)" in
  *"dubious ownership in repository at '${work}/dubious'"*)
    if ! output="$(cd "${work}/dubious/mid" && GIT_TEST_ASSUME_DIFFERENT_OWNER=1 \
      "${GIT_ORPHANED_BRANCHES}" 2> "${work}/dubious.stderr")"; then
      fail "git-orphaned-branches exited with a failure status in a repository that git refuses"
    fi
    if [ -n "${output}" ]; then
      fail "git-orphaned-branches printed [${output}] in a repository that git refuses, expected no output"
    fi
    if ! grep -q -x -F -- "git-orphaned-branches: warning: not listing directories in ${work}/dubious, such as ${work}/dubious/mid/m-branch-x, because git cannot use ${work}/dubious as a working tree although ${work}/dubious/.git exists; \`git -C ${work}/dubious status\` says why" \
      "${work}/dubious.stderr"; then
      echo "FAIL: git-orphaned-branches did not warn that git refuses dubious:"
      cat "${work}/dubious.stderr"
      status=1
    fi
    ;;
esac

###########################################################################
## A directory that holds files that another user owns.
###########################################################################

# Only the superuser can give a file to another user, so a stub `id` stands
# in for one:  it prints a user id that owns no file, so that to
# `git-orphaned-branches`, every file is another user's, including the
# `*-branch-*` directory itself.
mkdir -p "${work}/foreign/f-branch-leftover" "${work}/stub-id"
touch "${work}/foreign/f-branch-leftover/other"
# A `.venv` whose files another user owns, as when a container running as
# root created them, is a leftover, so the directory that holds it is listed.
mkdir -p "${work}/foreign/f-branch-python/.venv/bin"
touch "${work}/foreign/f-branch-python/.venv/bin/python"
printf '#!/bin/sh\necho 2147483646\n' > "${work}/stub-id/id"
chmod +x "${work}/stub-id/id"
if ! output="$(cd "${work}/foreign" && PATH="${work}/stub-id:${PATH}" \
  "${GIT_ORPHANED_BRANCHES}" 2> "${work}/foreign.stderr")"; then
  fail "git-orphaned-branches exited with a failure status on files that another user owns"
fi
if [ "${output}" != "${work}/foreign/f-branch-python" ]; then
  fail "git-orphaned-branches printed [${output}] for files that another user owns, expected [${work}/foreign/f-branch-python]"
fi
if ! grep -q -x -F -- "git-orphaned-branches: warning: not listing ${work}/foreign/f-branch-leftover, which is not in a git working tree and which another user owns" \
  "${work}/foreign.stderr"; then
  echo "FAIL: git-orphaned-branches did not say that another user owns f-branch-leftover:"
  cat "${work}/foreign.stderr"
  status=1
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

# Test 3: the `--print0` pipeline deletes the orphan and nothing else.
(cd "${work}/scan" && "${GIT_ORPHANED_BRANCHES}" --print0) | xargs -0 rm -rf
[ ! -e "${orphan}" ] || fail "cleanup did not delete ${orphan}"
[ -d "${work}/scan/my" ] || fail "cleanup deleted ${work}/scan/my"
[ -d "${work}/scan/my dir" ] || fail "cleanup deleted ${work}/scan/my dir"

###########################################################################
## Working trees whose `.git` is a file rather than a directory.
###########################################################################

# A linked worktree is a working tree, and `is-deleted-branch` answers about
# it correctly, so an orphaned one must be listed.  A `[ -d "$dir/.git" ]`
# test would not recognize it as a working tree, would check it only for a
# lone `.project` file, and would silently ignore it.
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

# A locked registration whose directory is missing, such as one on removable
# media that is not mounted, still depends on the host.
git -C "${host}" worktree lock --reason 'removable media' "${dependent}"
if ! output="$(cd "${work}/worktrees" && "${GIT_ORPHANED_BRANCHES}" 2> /dev/null)"; then
  fail "git-orphaned-branches exited with a failure status for a locked registration"
fi
if printf '%s\n' "${output}" | grep -q -x -F -- "${host_absolute}"; then
  fail "git-orphaned-branches listed ${host}, which hosts a locked worktree"
fi
git -C "${host}" worktree unlock "${dependent}"

# A worktree that `git-new-branch` made, once its branch was pushed and then
# deleted in the remote, is listed; the clone that hosts it, whose branch
# still exists, is not.  `--remove` removes the worktree and deletes its
# branch, and leaves the host in place.
mkdir -p "${work}/gnb"
gnbhost="${work}/gnb/g-branch-main"
git clone -q -b main "${work}/remote.git" "${gnbhost}"
if ! (cd "${gnbhost}" && "${TOPLEVEL}/git-new-branch" gnbgone > /dev/null 2>&1); then
  fail "git-new-branch failed"
fi
gnbgone="${work}/gnb/g-branch-gnbgone"
git -C "${gnbgone}" push -q -u origin gnbgone
git -C "${work}/seed" push -q origin --delete gnbgone
if ! output="$(cd "${work}/gnb" && "${GIT_ORPHANED_BRANCHES}" 2> /dev/null)"; then
  fail "git-orphaned-branches exited with a failure status for a git-new-branch worktree"
fi
if ! printf '%s\n' "${output}" | grep -q -x -F -- "$(absolute_path "${gnbgone}")"; then
  fail "git-orphaned-branches did not list the orphaned worktree ${gnbgone}"
fi
if printf '%s\n' "${output}" | grep -q -x -F -- "$(absolute_path "${gnbhost}")"; then
  fail "git-orphaned-branches listed ${gnbhost}, whose branch still exists"
fi
if ! output="$(cd "${work}/gnb" && "${GIT_ORPHANED_BRANCHES}" --remove 2>&1)"; then
  fail "git-orphaned-branches --remove failed for a git-new-branch worktree: ${output}"
fi
if [ -e "${gnbgone}" ]; then
  fail "git-orphaned-branches --remove did not remove ${gnbgone}"
fi
if git -C "${gnbhost}" rev-parse --verify --quiet refs/heads/gnbgone > /dev/null; then
  fail "git-orphaned-branches --remove left the branch of ${gnbgone}"
fi
if ! git -C "${gnbhost}" status > /dev/null 2>&1; then
  fail "git-orphaned-branches --remove broke the host ${gnbhost}"
fi

# A clone whose name matches `*-branch-*` only because it embeds the path of
# an ancestor is still examined, because it is a working tree, so it is listed
# once its branch is deleted.
git -C "${work}/seed" push -q origin main:refs/heads/pathnamed
mkdir -p "${work}/pathnamed/w-branch-x"
pathnamed_flat="$(absolute_path "${work}/pathnamed/w-branch-x" | tr / -)"
pathnamed="${work}/pathnamed/w-branch-x/[${pathnamed_flat}-tests]"
git clone -q -b pathnamed "${work}/remote.git" "${pathnamed}"
git -C "${work}/seed" push -q origin --delete pathnamed
if ! output="$(cd "${work}/pathnamed" && "${GIT_ORPHANED_BRANCHES}" 2> /dev/null)"; then
  fail "git-orphaned-branches exited with a failure status for a clone named for an ancestor's path"
fi
if [ "${output}" != "$(absolute_path "${pathnamed}")" ]; then
  fail "git-orphaned-branches printed [${output}] for a clone named for an ancestor's path, expected ${pathnamed}"
fi

# A submodule's working tree is a working tree too, and its `.git` is a file
# as well, so the same test decides it.  Its branch can be deleted in the
# submodule's remote like any other, but the directory still must not be
# listed:  it is part of the superproject's working tree, which the user never
# named.
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

superproject_absolute="$(absolute_path "${superproject}")"

if ! output="$(cd "${work}/submodule" && "${GIT_ORPHANED_BRANCHES}" \
  2> "${work}/submodule.stderr")"; then
  fail "git-orphaned-branches exited with a failure status for a submodule"
fi
if printf '%s\n' "${output}" | grep -q -x -F -- "${submodule_absolute}"; then
  fail "git-orphaned-branches listed ${submodule_absolute}, which is part of a live working tree"
fi
if ! grep -q -F -- "${superproject_absolute}" "${work}/submodule.stderr"; then
  fail "git-orphaned-branches did not say which superproject ${submodule_absolute} belongs to"
fi
# The superproject itself is a clone of nothing, so `is-deleted-branch` cannot
# call its branch deleted; the submodule is the only candidate here.
if [ -n "${output}" ]; then
  fail "git-orphaned-branches listed something under a superproject: ${output}"
fi

###########################################################################
## One remote query per remote URL, rather than one per directory.
###########################################################################

# Count the queries with a git wrapper on PATH that logs its arguments and then
# runs the real git.  These tests' remotes are local pathnames that never
# reach SSH, so counting SSH invocations would count nothing.
# shellcheck source=common-test-functions.sh
. "${TESTS_DIR}/common-test-functions.sh"
make_counting_git "${work}/test-bin" "${work}/git-commands.log"

# Usage: scan_with_counted_queries DIRECTORY
# Runs `git-orphaned-branches` in DIRECTORY with the counting `git` on PATH.
# Sets ${scan_output} to what it listed and ${scan_queries} to the number of
# questions it asked a remote.  `ls-remote --get-url` only prints a URL from
# the local configuration, so it asks nothing and does not count.
scan_with_counted_queries() {
  : > "${GIT_COMMAND_LOG}"
  scan_output="$(PATH="${work}/test-bin:${PATH}" \
    sh -c 'cd "$1" && "$2"' sh "$1" "${GIT_ORPHANED_BRANCHES}" 2> /dev/null)"
  scan_queries="$(count_remote_queries)"
}

# Usage: check_scan EXPECTED-QUERIES DESCRIPTION DIRECTORY...
# Checks that the scan just run asked EXPECTED-QUERIES questions and listed
# exactly the given directories.
check_scan() {
  check_scan_expected_queries="$1"
  check_scan_description="$2"
  shift 2
  if [ "${scan_queries}" -ne "${check_scan_expected_queries}" ]; then
    fail "${check_scan_description}: asked ${scan_queries} question(s), not ${check_scan_expected_queries}"
  fi
  check_scan_expected="$(for check_scan_dir in "$@"; do
    absolute_path "${check_scan_dir}"
  done | sort)"
  check_scan_actual="$(printf '%s\n' "${scan_output}" | grep '.' | sort)"
  if [ "${check_scan_actual}" != "${check_scan_expected}" ]; then
    fail "${check_scan_description}: listed [${check_scan_actual}], expected [${check_scan_expected}]"
  fi
}

# A second remote, so that clones of different upstreams can be told from
# clones of one.
git init -q --bare -b main "${work}/remote2.git"
git -C "${work}/seed" remote add second "${work}/remote2.git"
git -C "${work}/seed" push -q second main
git -C "${work}/seed" tag live-tag
git -C "${work}/seed" push -q origin refs/tags/live-tag
for branch in q1 q2 q3 q5 q6 q7 q8 q9; do
  git -C "${work}/seed" push -q origin "main:refs/heads/${branch}"
done
git -C "${work}/seed" push -q second main:refs/heads/q4

# Three clones of one upstream: one query answers for all three.
mkdir -p "${work}/queries-one"
for branch in q1 q2 q3; do
  git clone -q -b "${branch}" "${work}/remote.git" \
    "${work}/queries-one/p-branch-${branch}"
  git -C "${work}/seed" push -q origin --delete "${branch}"
done
scan_with_counted_queries "${work}/queries-one"
check_scan 1 'three clones of one upstream' \
  "${work}/queries-one/p-branch-q1" "${work}/queries-one/p-branch-q2" \
  "${work}/queries-one/p-branch-q3"

# Clones of different upstreams are asked separately, because a URL is what
# says whether two directories are asking one repository.
mkdir -p "${work}/queries-two"
git clone -q -b q5 "${work}/remote.git" "${work}/queries-two/p-branch-q5"
git clone -q -b q4 "${work}/remote2.git" "${work}/queries-two/p-branch-q4"
git -C "${work}/seed" push -q origin --delete q5
git -C "${work}/seed" push -q second --delete q4
scan_with_counted_queries "${work}/queries-two"
check_scan 2 'clones of two upstreams' \
  "${work}/queries-two/p-branch-q4" "${work}/queries-two/p-branch-q5"

# A directory whose configured upstream ref is not under refs/heads/ asks its
# own question, because `ls-remote --heads` does not report such a ref.  It
# still gets the right answer:  its upstream tag exists, so its branch is not
# orphaned, while its neighbor's branch is.
mkdir -p "${work}/queries-fallback"
git clone -q -b q6 "${work}/remote.git" "${work}/queries-fallback/p-branch-q6"
git clone -q -b q7 "${work}/remote.git" "${work}/queries-fallback/p-branch-q7"
git -C "${work}/queries-fallback/p-branch-q7" config branch.q7.merge \
  refs/tags/live-tag
git -C "${work}/seed" push -q origin --delete q6
git -C "${work}/seed" push -q origin --delete q7
scan_with_counted_queries "${work}/queries-fallback"
check_scan 2 'a clone whose upstream ref is outside refs/heads/' \
  "${work}/queries-fallback/p-branch-q6"

# Two clones of one upstream that reach it through different SSH commands are
# asking different questions, and are asked separately.
mkdir -p "${work}/queries-ssh"
git clone -q -b q8 "${work}/remote.git" "${work}/queries-ssh/p-branch-q8"
git clone -q -b q9 "${work}/remote.git" "${work}/queries-ssh/p-branch-q9"
git -C "${work}/queries-ssh/p-branch-q9" config core.sshCommand 'ssh -v'
git -C "${work}/seed" push -q origin --delete q8
git -C "${work}/seed" push -q origin --delete q9
scan_with_counted_queries "${work}/queries-ssh"
check_scan 2 'two clones that configure SSH differently' \
  "${work}/queries-ssh/p-branch-q8" "${work}/queries-ssh/p-branch-q9"

# Two clones of one upstream that run different programs at the far end are
# asking different questions, and are asked separately.  Both queries succeed,
# so the retry below cannot correct a shared answer:  the second clone's
# `remote.origin.uploadpack` serves another repository entirely, where its
# branch still exists, and reusing the first clone's answer would report a
# live branch as orphaned.
mkdir -p "${work}/queries-uploadpack"
cat > "${work}/fake-upload-pack" << UPLOAD_PACK_END
#!/bin/sh
# Ignore the repository that git names, and serve the other one.
exec git upload-pack "${work}/remote2.git"
UPLOAD_PACK_END
chmod +x "${work}/fake-upload-pack"
for branch in qd qe; do
  git -C "${work}/seed" push -q origin "main:refs/heads/${branch}"
  git clone -q -b "${branch}" "${work}/remote.git" \
    "${work}/queries-uploadpack/p-branch-${branch}"
  git -C "${work}/seed" push -q origin --delete "${branch}"
done
# The branch that the other repository still has.
git -C "${work}/seed" push -q second main:refs/heads/qe
git -C "${work}/queries-uploadpack/p-branch-qe" config \
  remote.origin.uploadpack "${work}/fake-upload-pack"
scan_with_counted_queries "${work}/queries-uploadpack"
check_scan 2 'two clones that configure upload-pack differently' \
  "${work}/queries-uploadpack/p-branch-qd"

# Two clones of one upstream that reach it through different transports are
# asking different questions, and are asked separately.  Both queries succeed,
# so nothing later can correct a shared answer:  the second clone's
# `remote.origin.vcs` names a remote helper that answers in place of git's own
# transport, and reusing the first clone's answer would report a live branch
# as orphaned.
mkdir -p "${work}/queries-vcs"
cat > "${work}/test-bin/git-remote-fakevcs" << HELPER_END
#!/bin/sh
# Ignore the URL that git names, and serve a fixed list of refs.  Reading the
# list from a file, rather than asking a repository for it, keeps this
# helper's own work out of the query count.
while IFS= read -r fake_helper_command; do
  case "\${fake_helper_command}" in
    capabilities) printf 'fetch\n\n' ;;
    list) cat "${work}/fake-helper-refs"; printf '\n' ;;
    *) exit 0 ;;
  esac
done
HELPER_END
chmod +x "${work}/test-bin/git-remote-fakevcs"
for branch in qf qg; do
  git -C "${work}/seed" push -q origin "main:refs/heads/${branch}"
  git clone -q -b "${branch}" "${work}/remote.git" \
    "${work}/queries-vcs/p-branch-${branch}"
  git -C "${work}/seed" push -q origin --delete "${branch}"
done
# The branch that the remote helper still reports, in the format that a helper
# answers `list` with:  "SHA<SPACE>refname".
printf '%s refs/heads/qg\n' "$(git -C "${work}/seed" rev-parse HEAD)" \
  > "${work}/fake-helper-refs"
git -C "${work}/queries-vcs/p-branch-qg" config remote.origin.vcs fakevcs
scan_with_counted_queries "${work}/queries-vcs"
check_scan 2 'two clones that configure a remote helper differently' \
  "${work}/queries-vcs/p-branch-qf"

# A directory whose own configuration breaks its query does not answer for the
# rest of its group.  A key names a URL, not a directory, so a failure that
# belongs to one directory would otherwise be remembered for all of them, and
# a scan that should have listed the healthy directories would list nothing.
# `protocol.file.allow` forbids the query that this directory would make,
# which fails it without changing what it would ask -- that is, without
# changing the key -- and it is set on the directory that is scanned first,
# which is the one that would poison the others.
mkdir -p "${work}/queries-broken"
for branch in qa qb qc; do
  git -C "${work}/seed" push -q origin "main:refs/heads/${branch}"
  git clone -q -b "${branch}" "${work}/remote.git" \
    "${work}/queries-broken/p-branch-${branch}"
  git -C "${work}/seed" push -q origin --delete "${branch}"
done
git -C "${work}/queries-broken/p-branch-qa" config protocol.file.allow never
# One failed query, then one that succeeds and answers for the rest.
scan_with_counted_queries "${work}/queries-broken"
check_scan 2 'a directory whose own configuration breaks its query' \
  "${work}/queries-broken/p-branch-qb" "${work}/queries-broken/p-branch-qc"

# The same, with two broken directories:  a healthy directory is asked its own
# question no matter how many of its siblings failed before it.  A budget of
# retries, rather than a failure that is simply never remembered, would spend
# itself on the second broken directory and report nothing at all.
mkdir -p "${work}/queries-broken-two"
for branch in qh qi qj; do
  git -C "${work}/seed" push -q origin "main:refs/heads/${branch}"
  git clone -q -b "${branch}" "${work}/remote.git" \
    "${work}/queries-broken-two/p-branch-${branch}"
  git -C "${work}/seed" push -q origin --delete "${branch}"
done
git -C "${work}/queries-broken-two/p-branch-qh" config protocol.file.allow never
git -C "${work}/queries-broken-two/p-branch-qi" config protocol.file.allow never
# Two failed queries, then one that succeeds.
scan_with_counted_queries "${work}/queries-broken-two"
check_scan 3 'two directories whose own configuration breaks their queries' \
  "${work}/queries-broken-two/p-branch-qj"

###########################################################################
## $GIT_DIR and $GIT_WORK_TREE in the environment.
###########################################################################

# Git exports them to hooks and to the commands run by `git rebase --exec`,
# `git bisect run`, and `git submodule foreach`, and they take precedence over
# `git -C`.  Left set, they made every directory of the scan answer for the
# one repository that they name:  an orphaned clone was classified by that
# repository instead of by itself, so the scan listed nothing and `--remove`
# removed nothing.  The scan must give the same answer as it does with them
# unset.
git -C "${work}/seed" push -q origin main:refs/heads/envfeat
mkdir -p "${work}/env-scan"
envorphan="${work}/env-scan/myrepo-branch-envfeat"
git clone -q -b envfeat "${work}/remote.git" "${envorphan}"
git -C "${work}/seed" push -q origin --delete envfeat
# An unrelated repository, on a branch that still exists in the remote, for
# the environment to name.
git clone -q "${work}/remote.git" "${work}/env-other"

printf '%s\n' "$(absolute_path "${envorphan}")" > "${work}/env.goal"
(cd "${work}/env-scan" \
  && GIT_DIR="${work}/env-other/.git" GIT_WORK_TREE="${work}/env-other" \
    "${GIT_ORPHANED_BRANCHES}") > "${work}/env.actual"
cmp -s "${work}/env.goal" "${work}/env.actual" \
  || fail "the scan with GIT_DIR set differs from ${work}/env.goal: [$(cat "${work}/env.actual")]"

###########################################################################
## --remove
###########################################################################

# `--remove` removes each directory that it would otherwise list, by running
# `git-remove-branch-directory`, and prints nothing on standard output.  That
# script refuses a directory that holds work, so `--remove` can leave one
# behind; it says why, and the exit status says that not everything was
# removed.
git -C "${work}/seed" push -q origin main:refs/heads/r1
git -C "${work}/seed" push -q origin main:refs/heads/r2
git -C "${work}/seed" push -q origin main:refs/heads/r3
mkdir -p "${work}/removal"
git clone -q -b r1 "${work}/remote.git" "${work}/removal/c-branch-r1"
git clone -q -b r2 "${work}/remote.git" "${work}/removal/c-branch-r2"
git clone -q -b r3 "${work}/remote.git" "${work}/removal/c-branch-r3"
mkdir -p "${work}/removal/c-branch-project"
touch "${work}/removal/c-branch-project/.project"
echo "an uncommitted change" >> "${work}/removal/c-branch-r2/file.txt"
git -C "${work}/seed" push -q origin --delete r1
git -C "${work}/seed" push -q origin --delete r2

removal_stderr="${work}/removal-stderr"
if (cd "${work}/removal" && "${GIT_ORPHANED_BRANCHES}" --remove \
  > "${work}/removal.out" 2> "${removal_stderr}"); then
  fail "--remove exited with status 0 although a removal was refused"
fi
if [ -s "${work}/removal.out" ]; then
  fail "--remove printed [$(cat "${work}/removal.out")], expected no output"
fi
if [ -e "${work}/removal/c-branch-r1" ]; then
  fail "--remove did not remove ${work}/removal/c-branch-r1"
fi
if [ -e "${work}/removal/c-branch-project" ]; then
  fail "--remove did not remove ${work}/removal/c-branch-project"
fi
if [ ! -d "${work}/removal/c-branch-r2" ]; then
  fail "--remove removed a directory that holds uncommitted changes"
fi
if [ ! -d "${work}/removal/c-branch-r3" ]; then
  fail "--remove removed a directory whose branch still exists"
fi
if ! grep -q -F -- 'uncommitted changes' "${removal_stderr}"; then
  fail "--remove did not say why it left a directory behind: $(cat "${removal_stderr}")"
fi

# None of the force flags is passed through, so a second run refuses again.
if (cd "${work}/removal" && "${GIT_ORPHANED_BRANCHES}" --remove > /dev/null 2>&1); then
  fail "--remove exited with status 0 although a removal was refused again"
fi
if [ ! -d "${work}/removal/c-branch-r2" ]; then
  fail "--remove removed a directory that holds uncommitted changes"
fi

# `--print0` says how to separate the directories that are printed, and
# `--remove` prints none, so the two together still print nothing, and
# `--remove` does its work as it does alone.
git -C "${work}/seed" push -q origin main:refs/heads/r4
mkdir -p "${work}/removal0"
git clone -q -b r4 "${work}/remote.git" "${work}/removal0/c-branch-r4"
git -C "${work}/seed" push -q origin --delete r4
if ! (cd "${work}/removal0" && "${GIT_ORPHANED_BRANCHES}" --remove --print0) \
  > "${work}/removal0.actual"; then
  fail "--remove --print0 exited with a failure status although the removal succeeded"
fi
if [ -s "${work}/removal0.actual" ]; then
  fail "--remove --print0 printed [$(cat "${work}/removal0.actual")], expected no output"
fi
if [ -e "${work}/removal0/c-branch-r4" ]; then
  fail "--remove --print0 did not remove ${work}/removal0/c-branch-r4"
fi

# A reported directory can contain another, which is why the scan descends
# into one.  The inner directory is removed first, through its own checks, and
# the outer one after it.  Removing the outer one first would `rm -rf` the
# inner clone without ever asking whether it held work, and would then fail on
# an inner directory that no longer existed.
git -C "${work}/seed" push -q origin main:refs/heads/n1
git -C "${work}/seed" push -q origin main:refs/heads/n2
mkdir -p "${work}/nested"
git clone -q -b n1 "${work}/remote.git" "${work}/nested/c-branch-outer"
git clone -q -b n2 "${work}/remote.git" \
  "${work}/nested/c-branch-outer/c-branch-inner"
git -C "${work}/seed" push -q origin --delete n1
git -C "${work}/seed" push -q origin --delete n2
if ! (cd "${work}/nested" && "${GIT_ORPHANED_BRANCHES}" --remove \
  > "${work}/nested.out" 2> "${removal_stderr}"); then
  fail "--remove exited with a failure status although both nested directories were removable: $(cat "${removal_stderr}")"
fi
if [ -s "${work}/nested.out" ]; then
  fail "--remove printed [$(cat "${work}/nested.out")], expected no output"
fi
if [ -e "${work}/nested/c-branch-outer" ]; then
  fail "--remove did not remove ${work}/nested/c-branch-outer"
fi

# When the inner directory is kept, the outer one is kept as well:  removing
# it would destroy what the inner directory's checks just refused to destroy.
git -C "${work}/seed" push -q origin main:refs/heads/n3
git -C "${work}/seed" push -q origin main:refs/heads/n4
mkdir -p "${work}/nested-kept"
git clone -q -b n3 "${work}/remote.git" "${work}/nested-kept/c-branch-outer"
git clone -q -b n4 "${work}/remote.git" \
  "${work}/nested-kept/c-branch-outer/c-branch-inner"
echo "an uncommitted change" \
  >> "${work}/nested-kept/c-branch-outer/c-branch-inner/file.txt"
git -C "${work}/seed" push -q origin --delete n3
git -C "${work}/seed" push -q origin --delete n4
if (cd "${work}/nested-kept" && "${GIT_ORPHANED_BRANCHES}" --remove \
  > "${work}/nested-kept.out" 2> "${removal_stderr}"); then
  fail "--remove exited with status 0 although a nested removal was refused"
fi
if [ ! -d "${work}/nested-kept/c-branch-outer/c-branch-inner" ]; then
  fail "--remove removed a nested directory that holds uncommitted changes"
fi
if [ ! -d "${work}/nested-kept/c-branch-outer" ]; then
  fail "--remove removed a directory that contains one that was not removed"
fi
if [ -s "${work}/nested-kept.out" ]; then
  fail "--remove printed [$(cat "${work}/nested-kept.out")], expected no output"
fi
if ! grep -q -F -- 'contains a directory that was not removed' \
  "${removal_stderr}"; then
  fail "--remove did not say why it kept the outer directory: $(cat "${removal_stderr}")"
fi

# A scan that finds nothing removes nothing and exits with status 0.
mkdir -p "${work}/removal-empty/unrelated-directory"
if ! output="$(cd "${work}/removal-empty" && "${GIT_ORPHANED_BRANCHES}" --remove)"; then
  fail "--remove exited with a failure status although it found nothing"
fi
if [ -n "${output}" ]; then
  fail "--remove printed [${output}], expected no output"
fi
if [ ! -d "${work}/removal-empty/unrelated-directory" ]; then
  fail "--remove removed a directory that it does not list"
fi

# Too old a git is refused before anything happens.
make_fake_git "${work}/oldgit" version 0 'git version 2.30.0'
mkdir -p "${work}/oldgit-scan"
if output="$(cd "${work}/oldgit-scan" && PATH="${work}/oldgit:${PATH}" \
  "${GIT_ORPHANED_BRANCHES}" 2>&1)"; then
  fail "git-orphaned-branches exited with status 0 with git 2.30.0"
fi
case "${output}" in
  *"requires git 2.31 or later, but found git 2.30.0"*) ;;
  *) fail "unexpected message with git 2.30.0: ${output}" ;;
esac

if [ "${status}" = 0 ]; then
  echo "${SCRIPT_NAME}: OK"
fi
exit "${status}"
