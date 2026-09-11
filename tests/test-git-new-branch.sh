#!/bin/sh

# Tests for the `git-new-branch` script.
#
# Usage:
#   tests/test-git-new-branch.sh
#
# The exit status is 0 if all tests pass, 1 otherwise.
#
# These tests exercise only cases that require no network access.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
GIT_NEW_BRANCH="${SCRIPT_DIR}/../git-new-branch"

. "${SCRIPT_DIR}/lib-git-test-env.sh"

status=0

fail() {
  echo "FAIL: $*" >&2
  status=1
}

tmpdir="$(mktemp -d)"
trap 'chmod -R u+rwx "${tmpdir}" 2> /dev/null; rm -rf "${tmpdir}"' EXIT INT TERM

sanitize_git_env "${tmpdir}"

# Creates, in "$1", a repository that has no remote, with a branch "localonly"
# in addition to the initial branch.
make_repo() {
  mkdir -p "$1" || return 1
  (
    cd "$1" || exit 1
    git init -q -b main .
    echo "hello" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"
    git branch localonly
  )
}

repo="${tmpdir}/myrepo-branch-main"
make_repo "${repo}" || exit 1

# A branch name that is already in use locally is an error, reported by
# `git-new-branch` itself rather than as a raw `git checkout` failure.
if out="$(cd "${repo}" && "${GIT_NEW_BRANCH}" localonly 2>&1)"; then
  fail "zero exit status for the existing local branch localonly"
fi
case "${out}" in
  *"git-new-branch: ERROR: branch localonly already exists"*) ;;
  *) fail "unexpected message for the existing local branch localonly: ${out}" ;;
esac
for leftover in "${tmpdir}/myrepo-branch-localonly" "${tmpdir}/myrepo-branch-localonly-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "directory was created for the existing local branch localonly: ${leftover}"
  fi
done

# The local name collision is detected before the working copy is copied.  The
# copy is made unable to succeed, by making a subdirectory unreadable; if
# `git-new-branch` attempts the copy, it reports the copy failure instead.
# Only an unprivileged user is stopped by the permissions.
if [ "$(id -u)" != 0 ]; then
  unreadable_repo="${tmpdir}/unreadable-branch-main"
  make_repo "${unreadable_repo}" || exit 1
  mkdir "${unreadable_repo}/subdir"
  chmod 000 "${unreadable_repo}/subdir"
  if out="$(cd "${unreadable_repo}" && "${GIT_NEW_BRANCH}" localonly 2>&1)"; then
    fail "zero exit status for the existing local branch localonly"
  fi
  case "${out}" in
    *"git-new-branch: ERROR: branch localonly already exists"*) ;;
    *) fail "the working copy was copied before the local branch localonly was detected: ${out}" ;;
  esac
  chmod 700 "${unreadable_repo}/subdir"
fi

# A branch name that is not in use creates the branch and its directory.
if ! out="$(cd "${repo}" && "${GIT_NEW_BRANCH}" brandnew 2>&1)"; then
  fail "nonzero exit status for the new branch brandnew: ${out}"
fi
newdir="${tmpdir}/myrepo-branch-brandnew"
if [ ! -d "${newdir}" ]; then
  fail "directory was not created: ${newdir}"
else
  checkedout="$(git -C "${newdir}" rev-parse --abbrev-ref HEAD)"
  if [ "${checkedout}" != "brandnew" ]; then
    fail "checked out ${checkedout} rather than brandnew in ${newdir}"
  fi
fi
if [ -e "${newdir}-TMP" ]; then
  fail "temporary directory was left behind: ${newdir}-TMP"
fi

# A branch name that is in use on the remote is an error, even when the clone
# has no remote-tracking branch for it and so must ask the remote itself.
clone="${tmpdir}/myclone-branch-main"
git clone -q "${repo}" "${clone}"
# Restrict the fetch refspec before deleting the remote-tracking branch, so
# that the `git pull` in `git-new-branch` does not recreate it.
git -C "${clone}" config remote.origin.fetch "+refs/heads/main:refs/remotes/origin/main"
git -C "${clone}" update-ref -d refs/remotes/origin/localonly
if out="$(cd "${clone}" && "${GIT_NEW_BRANCH}" localonly 2>&1)"; then
  fail "zero exit status for the branch localonly that exists on the remote"
fi
case "${out}" in
  *"already exists"*) ;;
  *) fail "unexpected message for the branch localonly that exists on the remote: ${out}" ;;
esac
if [ -e "${tmpdir}/myclone-branch-localonly" ]; then
  fail "directory was created for the branch localonly that exists on the remote"
fi

# A name that a remote-tracking branch already uses is a collision even when no
# remote can be determined for the current branch.  A clone with several
# remotes, none named "origin", determines none for a branch that has no
# `branch.BRANCH.remote` -- which is the state that `git-new-branch` itself
# leaves a new branch in, because `git checkout -b` writes no such setting --
# and the remote-tracking branches that the clone does have are then the only
# evidence of a collision.
tworemotes="${tmpdir}/tworemotes-branch-main"
git clone -q -o upstream "${repo}" "${tworemotes}"
git init -q --bare -b main "${tmpdir}/newfork.git"
git -C "${tworemotes}" remote add fork "${tmpdir}/newfork.git"
git -C "${tworemotes}" config --unset branch.main.remote
git -C "${tworemotes}" config --unset branch.main.merge
if out="$(cd "${tworemotes}" && "${GIT_NEW_BRANCH}" localonly 2>&1)"; then
  fail "zero exit status for the branch localonly that a remote-tracking branch uses"
fi
case "${out}" in
  *"already exists"*) ;;
  *) fail "unexpected message for the branch localonly of a remote-tracking branch: ${out}" ;;
esac
for leftover in "${tmpdir}/tworemotes-branch-localonly" "${tmpdir}/tworemotes-branch-localonly-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "directory was created for the branch localonly of a remote-tracking branch: ${leftover}"
  fi
done

# When a remote can be determined, only that remote's branches collide:  a
# branch of some other remote is not where this branch would be pushed, so it
# is not a collision.  This clone pushes to "upstream", and only "fork" has a
# branch named "onlyfork".
git -C "${tworemotes}" config branch.main.remote upstream
git -C "${tworemotes}" config branch.main.merge refs/heads/main
git -C "${tworemotes}" push -q fork "refs/remotes/upstream/localonly:refs/heads/onlyfork"
git -C "${tworemotes}" fetch -q fork
if ! out="$(cd "${tworemotes}" && "${GIT_NEW_BRANCH}" onlyfork 2>&1)"; then
  fail "nonzero exit status for a name that only another remote uses: ${out}"
fi
if [ ! -d "${tmpdir}/tworemotes-branch-onlyfork" ]; then
  fail "directory was not created: ${tmpdir}/tworemotes-branch-onlyfork"
fi

# `HEAD` is not the name of a branch, even though a clone has a symbolic ref
# `refs/remotes/origin/HEAD` that resolves.  It is rejected before the working
# copy is copied, and with a diagnosis rather than a raw `git checkout`
# failure.
if out="$(cd "${clone}" && "${GIT_NEW_BRANCH}" HEAD 2>&1)"; then
  fail "zero exit status for HEAD"
fi
case "${out}" in
  *"git-new-branch: ERROR: HEAD is not the name of a branch."*) ;;
  *) fail "unexpected message for HEAD: ${out}" ;;
esac
for leftover in "${tmpdir}/myclone-branch-HEAD" "${tmpdir}/myclone-branch-HEAD-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "directory was created for HEAD: ${leftover}"
  fi
done

# Every remote operation disables SSH's own interactive prompts, as the README
# promises:  the `git pull` that brings the working copy up to date as well as
# the query that asks the remote about the branch name.  Their output is
# captured or discarded, so a prompt for an unknown host key or for the
# passphrase of a key would be invisible and would block forever.  The fake
# `ssh` records the arguments of each invocation and then fails, so both
# operations fail; neither failure is fatal, and what this checks is the
# options they passed.
# shellcheck source=common-functions.sh
. "${SCRIPT_DIR}/common-functions.sh"
sshclone="${tmpdir}/sshclone-branch-main"
git clone -q "${repo}" "${sshclone}"
use_fake_ssh "${sshclone}" "${tmpdir}/ssh-arguments"
if ! out="$(cd "${sshclone}" && "${GIT_NEW_BRANCH}" sshnew 2>&1)"; then
  fail "nonzero exit status when the remote is unreachable: ${out}"
fi
if [ ! -d "${tmpdir}/sshclone-branch-sshnew" ]; then
  fail "directory was not created when the remote is unreachable"
fi
ssh_invocations="$(grep -c '.' "${tmpdir}/ssh-arguments" || true)"
if [ "${ssh_invocations}" -lt 2 ]; then
  fail "expected the pull and the query to invoke ssh, got ${ssh_invocations} invocation(s)"
fi
if grep -v -- '-o BatchMode=yes' "${tmpdir}/ssh-arguments" | grep -q '.'; then
  fail "an ssh invocation did not disable SSH's prompts: $(cat "${tmpdir}/ssh-arguments")"
fi

# A working tree that does not hold its own `.git` directory is refused
# before anything else happens.  Copying such a working tree produces a
# directory that names the *same* git directory, so the two share one HEAD and
# one index, and the `git checkout` that follows moves the source's HEAD and
# rewrites the source's index -- data loss in a working tree that the user did
# not name.  The cases have different remedies, so each message names the
# right one.

submodule_parent="${tmpdir}/submodule"
mkdir -p "${submodule_parent}" || exit 1
# Canonicalize the pathname, because the messages below name the directory as
# the command resolves it.  On macOS, `mktemp -d` returns a pathname under a
# symbolic link.
submodule_parent="$(CDPATH='' cd -- "${submodule_parent}" && pwd -P)" || exit 1
make_submodule_superproject "${submodule_parent}" || exit 1
superproject="${submodule_parent}/super-branch-main"
submodule="${superproject}/sub"
submodule_before="$(working_tree_state "${submodule}")"
if out="$(cd "${submodule}" && "${GIT_NEW_BRANCH}" newname 2>&1)"; then
  fail "zero exit status in the working tree of a submodule"
fi
case "${out}" in
  *"is the working tree of a submodule"*"superproject ${superproject}"*) ;;
  *) fail "unexpected message in the working tree of a submodule: ${out}" ;;
esac
for leftover in "${superproject}/sub-branch-newname" \
  "${superproject}/sub-branch-newname-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "directory was created in the working tree of a submodule: ${leftover}"
  fi
done
if [ "$(working_tree_state "${submodule}")" != "${submodule_before}" ]; then
  fail "the submodule's HEAD or index changed"
fi

worktree_parent="${tmpdir}/worktree"
mkdir -p "${worktree_parent}" || exit 1
worktree_parent="$(CDPATH='' cd -- "${worktree_parent}" && pwd -P)" || exit 1
make_linked_worktree "${worktree_parent}" || exit 1
worktree_main="${worktree_parent}/worktree-branch-main"
linked="${worktree_parent}/worktree-branch-linked"
linked_before="$(working_tree_state "${linked}")"
if out="$(cd "${linked}" && "${GIT_NEW_BRANCH}" newname 2>&1)"; then
  fail "zero exit status in a linked worktree"
fi
case "${out}" in
  *"is a linked worktree"*"main working tree ${worktree_main}"*) ;;
  *) fail "unexpected message in a linked worktree: ${out}" ;;
esac
for leftover in "${worktree_parent}/worktree-branch-newname" \
  "${worktree_parent}/worktree-branch-newname-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "directory was created in a linked worktree: ${leftover}"
  fi
done
if [ "$(working_tree_state "${linked}")" != "${linked_before}" ]; then
  fail "the linked worktree's HEAD or index changed"
fi

# A working tree whose git directory lies outside it is a main working tree,
# not a linked worktree:  the diagnostic must not send the user to another
# working tree, nor name the git directory as one.
separate_parent="${tmpdir}/separate"
mkdir -p "${separate_parent}" || exit 1
separate_parent="$(CDPATH='' cd -- "${separate_parent}" && pwd -P)" || exit 1
make_separate_git_dir_worktree "${separate_parent}" || exit 1
separate="${separate_parent}/separate-branch-main"
separate_before="$(working_tree_state "${separate}")"
if out="$(cd "${separate}" && "${GIT_NEW_BRANCH}" newname 2>&1)"; then
  fail "zero exit status in a working tree whose git directory lies outside it"
fi
case "${out}" in
  *"is a linked worktree"* | *"main working tree"*)
    fail "a working tree whose git directory lies outside it was called a linked worktree: ${out}" ;;
  *"names the git directory ${separate_parent}/separate-git-dir"*) ;;
  *) fail "unexpected message in a working tree whose git directory lies outside it: ${out}" ;;
esac
for leftover in "${separate_parent}/separate-branch-newname" \
  "${separate_parent}/separate-branch-newname-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "directory was created in a working tree whose git directory lies outside it: ${leftover}"
  fi
done
if [ "$(working_tree_state "${separate}")" != "${separate_before}" ]; then
  fail "the HEAD or index changed in a working tree whose git directory lies outside it"
fi

# A working tree whose `.git` is a symbolic link to a directory is refused as
# well.  `test -d` follows the link, but `cp -Rp` copies the link itself, so
# the copy's `.git` names the same git directory that this one's does.
symlink_parent="${tmpdir}/symlink"
mkdir -p "${symlink_parent}" || exit 1
symlink_parent="$(CDPATH='' cd -- "${symlink_parent}" && pwd -P)" || exit 1
make_symlinked_git_dir_worktree "${symlink_parent}" || exit 1
symlinked="${symlink_parent}/symlink-branch-main"
symlinked_before="$(working_tree_state "${symlinked}")"
if out="$(cd "${symlinked}" && "${GIT_NEW_BRANCH}" newname 2>&1)"; then
  fail "zero exit status in a working tree whose .git is a symbolic link"
fi
case "${out}" in
  *"is a symbolic link that names ../symlink-git-dir"*) ;;
  *) fail "unexpected message in a working tree whose .git is a symbolic link: ${out}" ;;
esac
for leftover in "${symlink_parent}/symlink-branch-newname" \
  "${symlink_parent}/symlink-branch-newname-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "directory was created in a working tree whose .git is a symbolic link: ${leftover}"
  fi
done
if [ "$(working_tree_state "${symlinked}")" != "${symlinked_before}" ]; then
  fail "the HEAD or index changed in a working tree whose .git is a symbolic link"
fi

# A working tree that holds no `.git` at all, because GIT_DIR and
# GIT_WORK_TREE in the environment name its repository, is refused too.  The
# copy would hold no repository, and the environment would still name this
# working tree's git directory, so the checkout would move this working
# tree's HEAD.  `env` sets the two variables for the command under test
# alone, rather than for this test, whose other cases must not see them.
envdir_parent="${tmpdir}/envgitdir"
mkdir -p "${envdir_parent}" || exit 1
envdir_parent="$(CDPATH='' cd -- "${envdir_parent}" && pwd -P)" || exit 1
make_env_git_dir_worktree "${envdir_parent}" || exit 1
envtree="${envdir_parent}/env-branch-main"
envgitdir="${envdir_parent}/env-git-dir"
envtree_before="$(working_tree_state "${envtree}" "${envgitdir}")"
if out="$(cd "${envtree}" \
  && env GIT_DIR="${envgitdir}" GIT_WORK_TREE="${envtree}" \
    "${GIT_NEW_BRANCH}" newname 2>&1)"; then
  fail "zero exit status in a working tree that has no .git"
fi
case "${out}" in
  *"${envtree} has no .git"*) ;;
  *) fail "unexpected message in a working tree that has no .git: ${out}" ;;
esac
for leftover in "${envdir_parent}/env-branch-newname" \
  "${envdir_parent}/env-branch-newname-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "directory was created in a working tree that has no .git: ${leftover}"
  fi
done
envtree_after="$(working_tree_state "${envtree}" "${envgitdir}")"
if [ "${envtree_after}" != "${envtree_before}" ]; then
  fail "the HEAD or index changed in a working tree that has no .git"
fi

# The wrong number of arguments is an error.
if (cd "${repo}" && "${GIT_NEW_BRANCH}" > /dev/null 2>&1); then
  fail "zero exit status when given no argument"
fi
if (cd "${repo}" && "${GIT_NEW_BRANCH}" a b > /dev/null 2>&1); then
  fail "zero exit status when given two arguments"
fi

if [ "${status}" = 0 ]; then
  echo "test-git-new-branch.sh: all tests passed"
fi
exit "${status}"
