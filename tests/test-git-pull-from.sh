#!/bin/sh

# Tests that `git-pull-from` accepts the `--nocompile` argument, just as
# `git-push-to` does, that the merge commit it creates names the other
# repository by a relative pathname, and that it diagnoses the current
# directory and OTHER-REPO-DIR itself when either is not the top level of a
# working tree, including when either is a linked worktree whose repository is
# gone.
#
# Usage:
#   tests/test-git-pull-from
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"
REPO_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"

. "${SCRIPT_DIR}/lib-git-test-env.sh"

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $1" >&2
  exit 1
}

# Creates a clone of ${remote} at the given directory, configured for merging.
make_clone() {
  git clone -q "${remote}" "$1"
  git -C "$1" config pull.rebase false
}

workdir="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
trap 'rm -rf "${workdir}"' EXIT
trap 'rm -rf "${workdir}"; exit 130' INT
trap 'rm -rf "${workdir}"; exit 143' TERM

sanitize_git_env "${workdir}"

remote="${workdir}/remote.git"
git init -q --bare -b main "${remote}"

# The Makefile that `compile-project` would run.  Its recipe creates a marker
# file, so the test can detect whether `compile-project` ran.
make_clone "${workdir}/from"
printf 'all:\n\ttouch compile-project-ran\n' > "${workdir}/from/Makefile"
git -C "${workdir}/from" add Makefile
git -C "${workdir}/from" commit -q -m "initial commit"
git -C "${workdir}/from" push -q -u origin main

make_clone "${workdir}/to"

# A commit that only "to" has, so that pulling "from" into it creates a merge
# commit, whose message the assertions below inspect.
date > "${workdir}/to/to-change.txt"
git -C "${workdir}/to" add to-change.txt
git -C "${workdir}/to" commit -q -m "a change in the destination"

date > "${workdir}/from/change.txt"
git -C "${workdir}/from" add change.txt
git -C "${workdir}/from" commit -q -m "a change"

if ! (cd "${workdir}/to" && "${REPO_DIR}/git-pull-from" --nocompile "${workdir}/from"); then
  fail "git-pull-from --nocompile failed"
fi
if [ ! -f "${workdir}/to/change.txt" ]; then
  fail "git-pull-from --nocompile did not merge the change"
fi
if [ -f "${workdir}/to/compile-project-ran" ]; then
  fail "git-pull-from --nocompile ran compile-project"
fi
if [ "$(git -C "${remote}" rev-parse main)" != "$(git -C "${workdir}/to" rev-parse HEAD)" ]; then
  fail "git-pull-from --nocompile did not push"
fi

# The merge commit message names the branch and no directory at all, just as
# it does for a merge within a single clone.  In particular it contains no
# absolute pathname, which would record this machine's directory layout in
# history that is shared with everyone else.
subject="$(git -C "${workdir}/to" log -1 --format=%s)"
if [ "${subject}" != "Merge branch 'main'" ]; then
  fail "unexpected merge commit message: ${subject}"
fi

# `git-push-to` fetches the other repository by a pathname relative to this
# one.  FETCH_HEAD is where git records the pathname that it fetched from.
fetch_head="$(cat "${workdir}/to/.git/FETCH_HEAD")"
case "${fetch_head}" in
  *"${workdir}"*) fail "git-push-to fetched from an absolute pathname: ${fetch_head}" ;;
esac
case "${fetch_head}" in
  *../from*) ;;
  *) fail "git-push-to did not fetch from ../from: ${fetch_head}" ;;
esac

# `git-pull-from` requires the current directory to be the top level of a
# working tree.  A subdirectory of a working tree is in a git repository, so
# the diagnostic must not say merely that this is not a working tree.
mkdir -p "${workdir}/to/subdir"
if output="$(cd "${workdir}/to/subdir" \
  && "${REPO_DIR}/git-pull-from" --nocompile "${workdir}/from" 2>&1)"; then
  fail "git-pull-from succeeded in a subdirectory of a working tree"
fi
case "${output}" in
  *"not the top level of a git working tree"*) ;;
  *) fail "git-pull-from did not say that the directory is not a top level: ${output}" ;;
esac
case "${output}" in
  *"its top level is: "*) ;;
  *) fail "git-pull-from did not name the top level to run in: ${output}" ;;
esac

# The same requirement holds outside a working tree altogether.
if output="$(cd "${workdir}" \
  && "${REPO_DIR}/git-pull-from" --nocompile "${workdir}/from" 2>&1)"; then
  fail "git-pull-from succeeded outside a working tree"
fi
case "${output}" in
  *"not the top level of a git working tree"*) ;;
  *) fail "git-pull-from did not reject a directory outside a working tree: ${output}" ;;
esac

# OTHER-REPO-DIR must be the top level of a working tree too.
mkdir -p "${workdir}/from/subdir"
if output="$(cd "${workdir}/to" \
  && "${REPO_DIR}/git-pull-from" --nocompile "${workdir}/from/subdir" 2>&1)"; then
  fail "git-pull-from accepted a subdirectory as OTHER-REPO-DIR"
fi
case "${output}" in
  *"git-pull-from: not the top level of a git working tree: "*"/from/subdir"*) ;;
  *) fail "git-pull-from did not reject OTHER-REPO-DIR: ${output}" ;;
esac
# The diagnostic is about this command's argument, so it names this command.
case "${output}" in
  *git-push-to*) fail "git-pull-from left the diagnostic to git-push-to: ${output}" ;;
esac
if output="$(cd "${workdir}/to" \
  && "${REPO_DIR}/git-pull-from" --nocompile "${workdir}/no-such-directory" 2>&1)"; then
  fail "git-pull-from accepted a nonexistent OTHER-REPO-DIR"
fi
case "${output}" in
  *"no such directory"*) ;;
  *) fail "git-pull-from did not reject a nonexistent OTHER-REPO-DIR: ${output}" ;;
esac

# `git-pull-from` compares physical pathnames, so it accepts a clone that is
# reached through a symbolic link, both as the current directory and as
# OTHER-REPO-DIR.  (`git rev-parse --show-toplevel` resolves symbolic links,
# so comparing the pathnames as given would reject these.)
ln -s "${workdir}/to" "${workdir}/to-link"
ln -s "${workdir}/from" "${workdir}/from-link"
date > "${workdir}/from/another-change.txt"
git -C "${workdir}/from" add another-change.txt
git -C "${workdir}/from" commit -q -m "another change"
if ! output="$(cd "${workdir}/to-link" \
  && "${REPO_DIR}/git-pull-from" --nocompile "${workdir}/from-link" 2>&1)"; then
  fail "git-pull-from failed when the clones were named through symbolic links: ${output}"
fi
if [ ! -f "${workdir}/to/another-change.txt" ]; then
  fail "git-pull-from did not merge the change when the clones were named through symbolic links"
fi

# A directory that cannot be entered might or might not be a clone, so say
# that it cannot be canonicalized rather than that it is not a clone.
# Only an unprivileged user is stopped by the permissions.
if [ "$(id -u)" != 0 ]; then
  # Leave the directory empty, so that the cleanup trap can remove it.
  mkdir "${workdir}/unenterable"
  chmod 000 "${workdir}/unenterable"
  if output="$(cd "${workdir}/to" \
    && "${REPO_DIR}/git-pull-from" --nocompile "${workdir}/unenterable" 2>&1)"; then
    fail "git-pull-from accepted a directory that cannot be entered"
  fi
  chmod 700 "${workdir}/unenterable"
  case "${output}" in
    *"cannot canonicalize"*) ;;
    *) fail "git-pull-from did not report a directory that cannot be entered: ${output}" ;;
  esac
fi

# A linked worktree whose main working tree was deleted still holds its files,
# but git refuses every command in it.  The diagnostic says why, and names the
# missing repository, both for the current directory and for OTHER-REPO-DIR.
make_clone "${workdir}/doomed"
git -C "${workdir}/doomed" worktree add -q -b orphan "${workdir}/orphan"
mv "${workdir}/doomed" "${workdir}/doomed-moved"
if output="$(cd "${workdir}/orphan" \
  && "${REPO_DIR}/git-pull-from" --nocompile "${workdir}/from" 2>&1)"; then
  fail "git-pull-from succeeded in a worktree whose repository is gone"
fi
case "${output}" in
  *"broken git working tree"*"${workdir}/orphan"*) ;;
  *) fail "git-pull-from did not report the broken worktree: ${output}" ;;
esac
case "${output}" in
  *"its repository does not exist; it was moved or deleted: ${workdir}/doomed/.git"*) ;;
  *) fail "git-pull-from did not name the missing repository: ${output}" ;;
esac
if output="$(cd "${workdir}/to" \
  && "${REPO_DIR}/git-pull-from" --nocompile "${workdir}/orphan" 2>&1)"; then
  fail "git-pull-from accepted a worktree whose repository is gone as OTHER-REPO-DIR"
fi
case "${output}" in
  *"git-pull-from: broken git working tree"*"${workdir}/orphan"*) ;;
  *) fail "git-pull-from did not report the broken OTHER-REPO-DIR: ${output}" ;;
esac
# In a subdirectory of a broken worktree, the diagnostic names the worktree.
mkdir "${workdir}/orphan/subdir"
if output="$(cd "${workdir}/orphan/subdir" \
  && "${REPO_DIR}/git-pull-from" --nocompile "${workdir}/from" 2>&1)"; then
  fail "git-pull-from succeeded in a subdirectory of a worktree whose repository is gone"
fi
# The diagnostic names the worktree by its physical pathname.
orphan_physical="$(CDPATH='' cd -- "${workdir}/orphan" && pwd -P)"
case "${output}" in
  *"within a broken one: ${workdir}/orphan/subdir"*"the broken working tree is: ${orphan_physical}"*) ;;
  *) fail "git-pull-from did not report the enclosing broken worktree: ${output}" ;;
esac
# `git-push-to` gives the same diagnostic for its own arguments.
if output="$("${REPO_DIR}/git-push-to" --no-llm "${workdir}/orphan" "${workdir}/to" 2>&1)"; then
  fail "git-push-to accepted a worktree whose repository is gone"
fi
case "${output}" in
  *"git-push-to: broken git working tree"*"${workdir}/orphan"*) ;;
  *) fail "git-push-to did not report the broken worktree: ${output}" ;;
esac

# A repository that exists but no longer registers the worktree, as after
# `git worktree prune`, is reported as such.
mv "${workdir}/doomed-moved" "${workdir}/doomed"
rm -rf "${workdir}/doomed/.git/worktrees/orphan"
if output="$(cd "${workdir}/to" \
  && "${REPO_DIR}/git-pull-from" --nocompile "${workdir}/orphan" 2>&1)"; then
  fail "git-pull-from accepted a worktree that its repository does not register"
fi
case "${output}" in
  *"its repository exists but no longer registers this worktree: ${workdir}/doomed/.git"*) ;;
  *) fail "git-pull-from did not report the unregistered worktree: ${output}" ;;
esac

echo "${SCRIPT_NAME}: OK"
