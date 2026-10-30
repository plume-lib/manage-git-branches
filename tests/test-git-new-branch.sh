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

# The local name collision is detected before the working tree is copied.  The
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
    *) fail "the working tree was copied before the local branch localonly was detected: ${out}" ;;
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
# tree is copied, and with a diagnosis rather than a raw `git checkout`
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
# promises:  the `git pull` that brings the working tree up to date as well as
# the query that asks the remote about the branch name.  Their output is
# captured or discarded, so a prompt for an unknown host key or for the
# passphrase of a key would be invisible and would block forever.  The fake
# `ssh` records the arguments of each invocation and then fails, so both
# operations fail; neither failure is fatal, and what this checks is the
# options they passed.
# shellcheck source=common-test-functions.sh
. "${SCRIPT_DIR}/common-test-functions.sh"
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
# right one.  A linked worktree is the exception:  the worktree modes do not
# copy `.git`, so only `--copy` refuses one.

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

# `--copy` copies `.git`, so it refuses a linked worktree, whose copied `.git`
# file would name this worktree's git directory.
if out="$(cd "${linked}" && "${GIT_NEW_BRANCH}" --copy newname 2>&1)"; then
  fail "zero exit status for --copy in a linked worktree"
fi
case "${out}" in
  *"is a linked worktree"*"main working tree ${worktree_main}"*) ;;
  *) fail "unexpected message for --copy in a linked worktree: ${out}" ;;
esac
for leftover in "${worktree_parent}/worktree-branch-newname" \
  "${worktree_parent}/worktree-branch-newname-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "directory was created for --copy in a linked worktree: ${leftover}"
  fi
done
if [ "$(working_tree_state "${linked}")" != "${linked_before}" ]; then
  fail "the linked worktree's HEAD or index changed"
fi

# The worktree modes do not copy `.git`, so they accept a linked worktree.  The
# new worktree is a sibling, registered in the main repository rather than
# nested in this worktree, and it gets this worktree's index rather than the
# main working tree's:  a change staged here is staged there.
echo 'staged in the linked worktree' > "${linked}/file.txt"
git -C "${linked}" add file.txt
linked_before="$(working_tree_state "${linked}")"
if ! out="$(cd "${linked}" && "${GIT_NEW_BRANCH}" fromlinked 2>&1)"; then
  fail "nonzero exit status in a linked worktree: ${out}"
fi
fromlinked="${worktree_parent}/worktree-branch-fromlinked"
if ! git -C "${worktree_main}" worktree list --porcelain \
  | grep -q -x -F "worktree ${fromlinked}"; then
  fail "the worktree made from a linked worktree is not registered in the main repository"
fi
if [ "$(git -C "${fromlinked}" diff --cached --name-only)" != 'file.txt' ]; then
  fail "the worktree made from a linked worktree does not have its staged change"
fi
if [ "$(working_tree_state "${linked}")" != "${linked_before}" ]; then
  fail "the linked worktree's HEAD or index changed"
fi
if ! out="$(cd "${linked}" && "${GIT_NEW_BRANCH}" --clean cleanfromlinked 2>&1)"; then
  fail "nonzero exit status for --clean in a linked worktree: ${out}"
fi
if [ ! -f "${worktree_parent}/worktree-branch-cleanfromlinked/.git" ]; then
  fail "--clean in a linked worktree did not create a worktree"
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
# GIT_WORK_TREE in the environment name its repository, is refused too:  the
# command unsets the two variables, which a hook would otherwise pass to the
# git commands that it runs in the new directory, so it finds no repository.
# `env` sets the two variables for the command under test alone, rather than
# for this test, whose other cases must not see them.
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
  *"Cannot determine top-level directory"*) ;;
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

# Prints the state of the working tree $1 that `git status` reports, ignored
# files included, for comparing two working trees.
status_of() {
  git -C "$1" status --porcelain=v1 --ignored
}

# Fails unless no directory, temporary directory, worktree registration, or
# branch named $2 was left behind in the repository of the working tree $1,
# whose branch directories are siblings named REPO-branch-$2.  $3 says what
# was run.
check_nothing_left() {
  check_nothing_left_dir="$(dirname -- "$1")/$(basename -- "$1" \
    | sed 's/-branch-.*//')-branch-$2"
  for leftover in "${check_nothing_left_dir}" "${check_nothing_left_dir}-TMP"; do
    if [ -e "${leftover}" ]; then
      fail "$3 left ${leftover} behind"
    fi
  done
  if git -C "$1" worktree list --porcelain \
    | grep -q -x -F "worktree ${check_nothing_left_dir}"; then
    fail "$3 left a worktree registered at ${check_nothing_left_dir}"
  fi
  if git -C "$1" rev-parse --verify --quiet "refs/heads/$2" > /dev/null; then
    fail "$3 left the branch $2 behind"
  fi
}

modes_parent="${tmpdir}/modes"
mkdir -p "${modes_parent}" || exit 1
modes_parent="$(CDPATH='' cd -- "${modes_parent}" && pwd -P)" || exit 1
modes="${modes_parent}/modes-branch-main"
make_repo "${modes}" || exit 1

# Option parsing.  Each usage error creates nothing.
for options in '--clean --copy' '--copy --clean'; do
  # shellcheck disable=SC2086 # The options are separate words.
  if out="$(cd "${modes}" && "${GIT_NEW_BRANCH}" ${options} both 2>&1)"; then
    fail "zero exit status for ${options}"
  fi
  case "${out}" in
    *"--clean and --copy cannot be used together"*) ;;
    *) fail "unexpected message for ${options}: ${out}" ;;
  esac
  check_nothing_left "${modes}" both "${options}"
done
if out="$(cd "${modes}" && "${GIT_NEW_BRANCH}" --cleann typo 2>&1)"; then
  fail "zero exit status for an unrecognized option"
fi
case "${out}" in
  *"unrecognized option: --cleann"*) ;;
  *) fail "unexpected message for an unrecognized option: ${out}" ;;
esac
check_nothing_left "${modes}" typo "an unrecognized option"
check_nothing_left "${modes}" --cleann "an unrecognized option"
if (cd "${modes}" && "${GIT_NEW_BRANCH}" late --clean > /dev/null 2>&1); then
  fail "zero exit status for an option after the branch name"
fi
check_nothing_left "${modes}" late "an option after the branch name"
# Repeating an option is harmless.
if ! out="$(cd "${modes}" && "${GIT_NEW_BRANCH}" --clean --clean twice 2>&1)"; then
  fail "nonzero exit status for a repeated option: ${out}"
fi
# `--` lets a branch name that begins with "-" through to `git worktree add`,
# whose `git branch` reads it as an option and fails, as `git checkout -b`
# did.  That failure leaves nothing behind.
if out="$(cd "${modes}" && "${GIT_NEW_BRANCH}" -- -dash 2>&1)"; then
  fail "zero exit status for the branch -dash"
fi
case "${out}" in
  *"unrecognized option"*) fail "-- did not end the options: ${out}" ;;
esac
check_nothing_left "${modes}" -dash "a branch name that begins with -"

# A source that holds every kind of local change:  a staged change, an
# unstaged change, an uncommitted deletion of a tracked file, an untracked
# file, an untracked directory, an ignored file, and a dotfile.
printf 'ignored.txt\n' > "${modes}/.gitignore"
echo 'tracked' > "${modes}/deleted.txt"
echo 'tracked' > "${modes}/unstaged.txt"
git -C "${modes}" add .gitignore deleted.txt unstaged.txt
git -C "${modes}" commit -q -m 'More files'
echo 'staged' >> "${modes}/file.txt"
git -C "${modes}" add file.txt
echo 'unstaged' >> "${modes}/unstaged.txt"
rm "${modes}/deleted.txt"
echo 'untracked' > "${modes}/untracked.txt"
mkdir "${modes}/untracked-dir"
echo 'untracked' > "${modes}/untracked-dir/inner.txt"
echo 'ignored' > "${modes}/ignored.txt"
echo 'dotfile' > "${modes}/.dotfile"
modes_status="$(status_of "${modes}")"
modes_state="$(working_tree_state "${modes}")"
modes_common="$(git -C "${modes}" rev-parse --path-format=absolute --git-common-dir)"

# The default mode:  a worktree whose contents, and whose status, are the
# source's.
if ! out="$(cd "${modes}" && "${GIT_NEW_BRANCH}" inherit 2>&1)"; then
  fail "nonzero exit status for the default mode: ${out}"
fi
case "${out}" in
  *"contain the pathname"*) fail "the default mode warned about files that do not contain the source's pathname: ${out}" ;;
esac
inherit="${modes_parent}/modes-branch-inherit"
if [ "$(git -C "${inherit}" symbolic-ref HEAD)" != 'refs/heads/inherit' ]; then
  fail "the default mode did not check out the branch inherit"
fi
if [ "$(status_of "${inherit}")" != "${modes_status}" ]; then
  fail "the default mode's status differs from the source's: $(status_of "${inherit}")"
fi
if ! diff -r --exclude=.git "${modes}" "${inherit}" > /dev/null; then
  fail "the default mode's contents differ from the source's"
fi
# The objects are shared.
if [ ! -f "${inherit}/.git" ]; then
  fail "the default mode's .git is not a file"
fi
if [ "$(git -C "${inherit}" rev-parse --path-format=absolute --git-common-dir)" \
  != "${modes_common}" ]; then
  fail "the default mode does not share the source's repository"
fi
# Registered under its final name, with no "-TMP" in its administrative
# directory.
inherit_gitdir="$(git -C "${inherit}" rev-parse --absolute-git-dir)"
if [ "${inherit_gitdir}" != "${modes_common}/worktrees/modes-branch-inherit" ]; then
  fail "the default mode's administrative directory is ${inherit_gitdir}"
fi
if ! git -C "${modes}" worktree list --porcelain | grep -q -x -F "worktree ${inherit}"; then
  fail "the default mode's worktree is not registered"
fi
if git -C "${modes}" worktree list --porcelain | grep -q 'prunable'; then
  fail "a worktree is prunable: $(git -C "${modes}" worktree list --porcelain)"
fi

# `--clean`:  a worktree that holds a clean checkout, and nothing else.
if ! out="$(cd "${modes}" && "${GIT_NEW_BRANCH}" --clean fresh 2>&1)"; then
  fail "nonzero exit status for --clean: ${out}"
fi
fresh="${modes_parent}/modes-branch-fresh"
if [ "$(git -C "${fresh}" symbolic-ref HEAD)" != 'refs/heads/fresh' ]; then
  fail "--clean did not check out the branch fresh"
fi
if [ -n "$(status_of "${fresh}")" ]; then
  fail "--clean's working tree is not clean: $(status_of "${fresh}")"
fi
if [ "$(git -C "${fresh}" rev-parse --path-format=absolute --git-common-dir)" \
  != "${modes_common}" ]; then
  fail "--clean does not share the source's repository"
fi

# `--copy`:  an independent clone whose contents, and whose status, are the
# source's.
if ! out="$(cd "${modes}" && "${GIT_NEW_BRANCH}" --copy copied 2>&1)"; then
  fail "nonzero exit status for --copy: ${out}"
fi
copied="${modes_parent}/modes-branch-copied"
if [ ! -d "${copied}/.git" ]; then
  fail "--copy's .git is not a directory"
fi
if [ "$(git -C "${copied}" rev-parse --path-format=absolute --git-common-dir)" \
  = "${modes_common}" ]; then
  fail "--copy shares the source's repository"
fi
if git -C "${modes}" worktree list --porcelain | grep -q -x -F "worktree ${copied}"; then
  fail "--copy's directory is registered as a worktree"
fi
# The source has linked worktrees by now, made by git-new-branch.  Their
# registrations and their branches stay with it, so that the branches'
# commits do not make the copy look as if it held unpushed work; the source's
# own branch is kept.
for other in inherit fresh; do
  if git -C "${copied}" rev-parse --verify --quiet "refs/heads/${other}" > /dev/null; then
    fail "--copy holds the branch ${other} of another branch directory"
  fi
done
if ! git -C "${copied}" rev-parse --verify --quiet refs/heads/main > /dev/null; then
  fail "--copy lost the source's branch main"
fi
if [ "$(git -C "${copied}" worktree list --porcelain | grep -c '^worktree ')" -ne 1 ]; then
  fail "--copy holds the source's worktree registrations: $(git -C "${copied}" worktree list)"
fi
if [ "$(git -C "${copied}" symbolic-ref HEAD)" != 'refs/heads/copied' ]; then
  fail "--copy did not check out the branch copied"
fi
if [ "$(status_of "${copied}")" != "${modes_status}" ]; then
  fail "--copy's status differs from the source's: $(status_of "${copied}")"
fi
if ! diff -r --exclude=.git "${modes}" "${copied}" > /dev/null; then
  fail "--copy's contents differ from the source's"
fi

# No mode changes the source.
if [ "$(status_of "${modes}")" != "${modes_status}" ] \
  || [ "$(working_tree_state "${modes}")" != "${modes_state}" ]; then
  fail "the source's status, HEAD, or index changed"
fi

# A branch directory that was removed with `rm -rf` leaves its branch behind,
# and then its registration, so the name cannot be used again until both are
# gone.  The first is reported by this script, the second by git, whose
# message names the ways out; neither is cleared behind the user's back.
rm -rf "${fresh}"
if out="$(cd "${modes}" && "${GIT_NEW_BRANCH}" fresh 2>&1)"; then
  fail "zero exit status for the branch of a removed worktree"
fi
case "${out}" in
  *"branch fresh already exists"*) ;;
  *) fail "unexpected message for the branch of a removed worktree: ${out}" ;;
esac
git -C "${modes}" update-ref -d refs/heads/fresh
if out="$(cd "${modes}" && "${GIT_NEW_BRANCH}" fresh 2>&1)"; then
  fail "zero exit status for the path of a removed worktree"
fi
case "${out}" in
  *"missing but already registered worktree"*) ;;
  *) fail "unexpected message for the path of a removed worktree: ${out}" ;;
esac
if [ ! -d "${modes_common}/worktrees/modes-branch-fresh" ]; then
  fail "the registration of a removed worktree was removed"
fi
if git -C "${modes}" rev-parse --verify --quiet refs/heads/fresh > /dev/null; then
  fail "a failed git worktree add left the branch fresh behind"
fi
for leftover in "${fresh}" "${fresh}-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "a failed git worktree add left ${leftover} behind"
  fi
done

# A repository with no commit has nothing to branch from, in every mode.
unborn="${modes_parent}/unborn-branch-main"
git init -q -b main "${unborn}"
for mode in '' --clean --copy; do
  # shellcheck disable=SC2086 # An empty mode is no argument at all.
  if out="$(cd "${unborn}" && "${GIT_NEW_BRANCH}" ${mode} nothing 2>&1)"; then
    fail "zero exit status in a repository with no commit, mode [${mode}]"
  fi
  case "${out}" in
    *"has no commit, so there is nothing to branch from"*) ;;
    *) fail "unexpected message in a repository with no commit, mode [${mode}]: ${out}" ;;
  esac
  for leftover in "${modes_parent}/unborn-branch-nothing" \
    "${modes_parent}/unborn-branch-nothing-TMP"; do
    if [ -e "${leftover}" ]; then
      fail "${leftover} was created in a repository with no commit, mode [${mode}]"
    fi
  done
done

# Too old a git is refused before anything happens.
make_fake_git "${tmpdir}/oldgit" version 0 'git version 2.30.0'
if out="$(cd "${modes}" && PATH="${tmpdir}/oldgit:${PATH}" \
  "${GIT_NEW_BRANCH}" ancient 2>&1)"; then
  fail "zero exit status with git 2.30.0"
fi
case "${out}" in
  *"requires git 2.31 or later, but found git 2.30.0"*) ;;
  *) fail "unexpected message with git 2.30.0: ${out}" ;;
esac
check_nothing_left "${modes}" ancient "git 2.30.0"

# A sparse checkout:  the default mode gives the new worktree the index's
# skip-worktree bits and the patterns that they depend on, which only git 2.36
# and later copy, so an older git is refused.
sparse="${tmpdir}/sparse/sparse-branch-main"
make_repo "${sparse}" || exit 1
mkdir "${sparse}/in" "${sparse}/out"
echo 'in' > "${sparse}/in/in.txt"
echo 'out' > "${sparse}/out/out.txt"
git -C "${sparse}" add in out
git -C "${sparse}" commit -q -m 'Add directories'
git -C "${sparse}" sparse-checkout set in
make_fake_git "${tmpdir}/sparsegit" version 0 'git version 2.35.0'
if out="$(cd "${sparse}" && PATH="${tmpdir}/sparsegit:${PATH}" \
  "${GIT_NEW_BRANCH}" oldsparse 2>&1)"; then
  fail "zero exit status for a sparse checkout with git 2.35.0"
fi
case "${out}" in
  *"requires git 2.36 or later for a sparse checkout"*) ;;
  *) fail "unexpected message for a sparse checkout with git 2.35.0: ${out}" ;;
esac
check_nothing_left "${sparse}" oldsparse "a sparse checkout with git 2.35.0"
if ! out="$(cd "${sparse}" && "${GIT_NEW_BRANCH}" newsparse 2>&1)"; then
  fail "nonzero exit status for a sparse checkout: ${out}"
fi
newsparse="${tmpdir}/sparse/sparse-branch-newsparse"
if [ "$(git -C "${newsparse}" sparse-checkout list)" != 'in' ]; then
  fail "a sparse checkout: the new worktree's patterns are [$(git -C "${newsparse}" sparse-checkout list)]"
fi
if [ -n "$(status_of "${newsparse}")" ] || [ -e "${newsparse}/out" ]; then
  fail "a sparse checkout: the new worktree is not the same sparse checkout: $(status_of "${newsparse}")"
fi
# The same old git is accepted for a working tree that is not a sparse
# checkout.
if ! out="$(cd "${modes}" && PATH="${tmpdir}/sparsegit:${PATH}" \
  "${GIT_NEW_BRANCH}" notsparse 2>&1)"; then
  fail "nonzero exit status without a sparse checkout, with git 2.35.0: ${out}"
fi

# A repository with submodules.  `--clean` is refused, with a message that
# names `--copy`; `--copy` succeeds; and the default mode falls back to the
# copy, whose submodule has a git directory of its own.  `protocol.file.allow`
# lets `git pull` reach the submodule's local origin.
superproject_before="$(working_tree_state "${superproject}")"
if out="$(cd "${superproject}" && "${GIT_NEW_BRANCH}" --clean subclean 2>&1)"; then
  fail "zero exit status for --clean in a repository with submodules"
fi
case "${out}" in
  *"has submodules"*"--copy works here"*) ;;
  *) fail "unexpected message for --clean in a repository with submodules: ${out}" ;;
esac
check_nothing_left "${superproject}" subclean "--clean with submodules"
if ! out="$(cd "${superproject}" && "${GIT_NEW_BRANCH}" --copy subcopy 2>&1)"; then
  fail "nonzero exit status for --copy in a repository with submodules: ${out}"
fi
if ! out="$(cd "${superproject}" && "${GIT_NEW_BRANCH}" subdefault 2>&1)"; then
  fail "nonzero exit status in a repository with submodules: ${out}"
fi
case "${out}" in
  *"has submodules"*"full copy"*) ;;
  *) fail "the default mode did not say that it copies, with submodules: ${out}" ;;
esac
subdefault="${submodule_parent}/super-branch-subdefault"
if [ ! -d "${subdefault}/.git" ]; then
  fail "the default mode made a worktree in a repository with submodules"
fi
if ! git -C "${subdefault}" status > /dev/null 2>&1 \
  || ! git -C "${subdefault}/sub" status > /dev/null 2>&1; then
  fail "the copy of a repository with submodules is not usable"
fi
if [ "$(git -C "${subdefault}/sub" rev-parse --absolute-git-dir)" \
  = "$(git -C "${submodule}" rev-parse --absolute-git-dir)" ]; then
  fail "the copy of a repository with submodules shares the submodule's git directory"
fi
if [ "$(working_tree_state "${superproject}")" != "${superproject_before}" ]; then
  fail "the superproject's HEAD or index changed"
fi

# A pull that brings in the first submodule switches the default mode to the
# copy, and makes `--clean` refuse, as if the submodule had been there before
# the pull.
pullsub_origin="${submodule_parent}/pullsub-origin.git"
git init -q --bare -b main "${pullsub_origin}"
git clone -q "${pullsub_origin}" "${submodule_parent}/pullsub-seed" 2> /dev/null
echo 'seed' > "${submodule_parent}/pullsub-seed/seed.txt"
git -C "${submodule_parent}/pullsub-seed" add seed.txt
git -C "${submodule_parent}/pullsub-seed" commit -q -m 'Initial commit'
git -C "${submodule_parent}/pullsub-seed" push -q origin main
pullsub="${submodule_parent}/pullsub-branch-main"
git clone -q "${pullsub_origin}" "${pullsub}"
git -C "${submodule_parent}/pullsub-seed" -c protocol.file.allow=always \
  submodule add -q "${submodule_parent}/submodule-origin" sub
git -C "${submodule_parent}/pullsub-seed" commit -q -m 'Add a submodule'
git -C "${submodule_parent}/pullsub-seed" push -q origin main
if out="$(cd "${pullsub}" && "${GIT_NEW_BRANCH}" --clean pullsubclean 2>&1)"; then
  fail "zero exit status for --clean when the pull brings in a submodule"
fi
case "${out}" in
  *"has submodules"*"--copy works here"*) ;;
  *) fail "unexpected message for --clean when the pull brings in a submodule: ${out}" ;;
esac
check_nothing_left "${pullsub}" pullsubclean "--clean when the pull brings in a submodule"
git -C "${pullsub}" reset -q --hard HEAD~1
if ! out="$(cd "${pullsub}" && "${GIT_NEW_BRANCH}" pullsubdefault 2>&1)"; then
  fail "nonzero exit status when the pull brings in a submodule: ${out}"
fi
case "${out}" in
  *"has submodules"*"full copy"*) ;;
  *) fail "the default mode did not say that it copies, when the pull brings in a submodule: ${out}" ;;
esac
if [ ! -d "${submodule_parent}/pullsub-branch-pullsubdefault/.git" ]; then
  fail "the default mode made a worktree when the pull brought in a submodule"
fi

# A repository with submodules whose branch directories are worktrees:  the
# default mode falls back to the copy, which refuses a linked worktree, and
# the message says where to run the command instead.
git -C "${superproject}" worktree add -q -b sublinked "${submodule_parent}/super-branch-sublinked"
if out="$(cd "${submodule_parent}/super-branch-sublinked" \
  && "${GIT_NEW_BRANCH}" fromsublinked 2>&1)"; then
  fail "zero exit status in a linked worktree of a repository with submodules"
fi
case "${out}" in
  *"has submodules"*"is a linked worktree"*"main working tree ${superproject}"*) ;;
  *) fail "unexpected message in a linked worktree of a repository with submodules: ${out}" ;;
esac
check_nothing_left "${superproject}" fromsublinked \
  "a linked worktree of a repository with submodules"

# GIT_INDEX_FILE, which git exports to hooks, does not redirect the new
# worktree's checkout onto this working tree's index, which would discard its
# staged changes.
envindex="${tmpdir}/envindex-branch-main"
make_repo "${envindex}" || exit 1
echo 'staged' > "${envindex}/staged.txt"
git -C "${envindex}" add staged.txt
envindex_before="$(status_of "${envindex}")"
if ! out="$(cd "${envindex}" \
  && env GIT_INDEX_FILE="$(git rev-parse --absolute-git-dir)/index" \
    "${GIT_NEW_BRANCH}" --clean fromenvindex 2>&1)"; then
  fail "nonzero exit status with GIT_INDEX_FILE set: ${out}"
fi
if [ "$(status_of "${envindex}")" != "${envindex_before}" ]; then
  fail "GIT_INDEX_FILE: the staged changes of the source changed"
fi
if [ -n "$(status_of "${tmpdir}/envindex-branch-fromenvindex")" ]; then
  fail "GIT_INDEX_FILE: the --clean worktree is not clean"
fi

# Under core.splitIndex, the index that the default mode copies names a
# shared index file, which must be copied too.
split="${tmpdir}/split-branch-main"
make_repo "${split}" || exit 1
git -C "${split}" config core.splitIndex true
echo 'staged' > "${split}/staged.txt"
git -C "${split}" add staged.txt
if ! out="$(cd "${split}" && "${GIT_NEW_BRANCH}" fromsplit 2>&1)"; then
  fail "nonzero exit status under core.splitIndex: ${out}"
elif ! split_status="$(status_of "${tmpdir}/split-branch-fromsplit" 2>&1)"; then
  fail "core.splitIndex: git status fails in the new worktree: ${split_status}"
elif [ "${split_status}" != "$(status_of "${split}")" ]; then
  fail "core.splitIndex: the new worktree's status differs from the source's"
fi

# The default mode and `--copy` refuse while a merge is in progress, because
# the new directory would get the staged result without the merge.
# `--clean` carries no changes, so it is accepted.
merging="${tmpdir}/merging-branch-main"
make_repo "${merging}" || exit 1
git -C "${merging}" checkout -q localonly
echo 'other' > "${merging}/other.txt"
git -C "${merging}" add other.txt
git -C "${merging}" commit -q -m 'Other side'
git -C "${merging}" checkout -q main
git -C "${merging}" merge -q --no-commit --no-ff localonly > /dev/null 2>&1
if out="$(cd "${merging}" && "${GIT_NEW_BRANCH}" frommerging 2>&1)"; then
  fail "zero exit status while a merge is in progress"
fi
case "${out}" in
  *"a merge is in progress"*) ;;
  *) fail "unexpected message while a merge is in progress: ${out}" ;;
esac
check_nothing_left "${merging}" frommerging "a merge in progress"
if out="$(cd "${merging}" && "${GIT_NEW_BRANCH}" --copy frommerging 2>&1)"; then
  fail "zero exit status for --copy while a merge is in progress"
fi
check_nothing_left "${merging}" frommerging "--copy with a merge in progress"
if ! out="$(cd "${merging}" && "${GIT_NEW_BRANCH}" --clean frommerging 2>&1)"; then
  fail "nonzero exit status for --clean while a merge is in progress: ${out}"
fi

# A `.gitmodules` that names no submodule that the index holds does not make
# the default mode copy the repository.
stalemodules="${tmpdir}/stalemodules-branch-main"
make_repo "${stalemodules}" || exit 1
printf '[submodule "gone"]\n\tpath = gone\n\turl = ../gone\n' \
  > "${stalemodules}/.gitmodules"
git -C "${stalemodules}" add .gitmodules
git -C "${stalemodules}" commit -q -m 'Add a .gitmodules without submodules'
if ! out="$(cd "${stalemodules}" && "${GIT_NEW_BRANCH}" fromstale 2>&1)"; then
  fail "nonzero exit status with a .gitmodules but no submodule: ${out}"
elif [ ! -f "${tmpdir}/stalemodules-branch-fromstale/.git" ]; then
  fail "a .gitmodules but no submodule: the new directory is not a worktree"
fi

# An ignored linked worktree nested in the source, such as
# `.claude/worktrees/NAME`, keeps a `.git` file that names the source's
# repository, so a copy of it would share its HEAD and index.  Both copying
# modes leave it out, and say so; a nested clone, whose `.git` is a
# directory, is independent and is copied.
for mode in '' --copy; do
  nested="${tmpdir}/nested${mode}/nested-branch-main"
  make_repo "${nested}" || exit 1
  printf '.claude/\n' > "${nested}/.gitignore"
  git -C "${nested}" add .gitignore
  git -C "${nested}" commit -q -m 'Ignore .claude'
  git -C "${nested}" worktree add -q -b inner "${nested}/.claude/worktrees/inner"
  # A file that cannot be read makes any attempt to copy the nested worktree
  # fail, which shows that it is skipped rather than copied and removed.  Only
  # an unprivileged user is stopped by the permissions.
  echo 'secret' > "${nested}/.claude/worktrees/inner/unreadable.txt"
  if [ "$(id -u)" != 0 ]; then
    chmod 000 "${nested}/.claude/worktrees/inner/unreadable.txt"
  fi
  echo 'kept' > "${nested}/.claude/kept.txt"
  git clone -q "${nested}" "${nested}/.claude/clone"
  inner_before="$(working_tree_state "${nested}/.claude/worktrees/inner")"
  out="$(cd "${nested}" && "${GIT_NEW_BRANCH}" ${mode:+"${mode}"} outer 2>&1)"
  outer_status=$?
  chmod 644 "${nested}/.claude/worktrees/inner/unreadable.txt"
  if [ "${outer_status}" -ne 0 ]; then
    fail "nested worktree, mode '${mode}': nonzero exit status: ${out}"
    continue
  fi
  outer="${tmpdir}/nested${mode}/nested-branch-outer"
  case "${out}" in
    *"not copying .claude/worktrees/inner"*) ;;
    *) fail "nested worktree, mode '${mode}': unexpected message: ${out}" ;;
  esac
  if [ -e "${outer}/.claude/worktrees/inner" ]; then
    fail "nested worktree, mode '${mode}': the nested linked worktree was copied"
  fi
  if [ ! -f "${outer}/.claude/kept.txt" ]; then
    fail "nested worktree, mode '${mode}': the rest of .claude was not copied"
  fi
  if [ ! -d "${outer}/.claude/clone/.git" ]; then
    fail "nested worktree, mode '${mode}': the nested clone was not copied"
  fi
  if [ "$(working_tree_state "${nested}/.claude/worktrees/inner")" \
    != "${inner_before}" ]; then
    fail "nested worktree, mode '${mode}': the nested worktree's HEAD or index changed"
  fi
done

# A clone of an upstream repository is refused when a sibling directory holds a
# fork of it:  a clone whose remote "upstream" is the repository that the new
# branch would be pushed to.  The fork's "upstream" is a relative pathname,
# which is resolved in the fork.
fork_parent="${tmpdir}/forks"
mkdir "${fork_parent}"
fork_parent="$(CDPATH='' cd -- "${fork_parent}" && pwd -P)" || exit 1
git clone -q --bare "${repo}" "${tmpdir}/proj.git"
git clone -q --bare "${repo}" "${tmpdir}/proj-fork.git"
git clone -q "${tmpdir}/proj.git" "${fork_parent}/proj"
git clone -q "${tmpdir}/proj.git" "${fork_parent}/proj-branch-other"
git clone -q "${tmpdir}/proj-fork.git" "${fork_parent}/proj-fork-me"
git -C "${fork_parent}/proj-fork-me" remote add upstream ../../proj.git
for upstream_clone in proj proj-branch-other; do
  if out="$(cd "${fork_parent}/${upstream_clone}" && "${GIT_NEW_BRANCH}" --clean inupstream 2>&1)"; then
    fail "${upstream_clone}: zero exit status in a clone of an upstream repository"
  fi
  case "${out}" in
    *"git-new-branch: ERROR: the new branch would be pushed to origin"*"
  ${fork_parent}/proj-fork-me
"*"pass --allow-upstream"*) ;;
    *) fail "${upstream_clone}: unexpected message in a clone of an upstream repository: ${out}" ;;
  esac
  if [ -e "${fork_parent}/proj-branch-inupstream" ] \
    || git -C "${fork_parent}/${upstream_clone}" rev-parse --verify --quiet refs/heads/inupstream > /dev/null; then
    fail "${upstream_clone}: a branch was created in a clone of an upstream repository"
  fi
done

# `--allow-upstream` creates the branch in the clone of the upstream repository.
if ! out="$(cd "${fork_parent}/proj" && "${GIT_NEW_BRANCH}" --clean --allow-upstream allowed 2>&1)"; then
  fail "nonzero exit status with --allow-upstream: ${out}"
fi
if [ ! -d "${fork_parent}/proj-branch-allowed" ]; then
  fail "--allow-upstream did not create ${fork_parent}/proj-branch-allowed"
fi

# The fork itself is not refused:  it pushes to the fork, not to its upstream.
if ! out="$(cd "${fork_parent}/proj-fork-me" && "${GIT_NEW_BRANCH}" --clean infork 2>&1)"; then
  fail "nonzero exit status in a fork: ${out}"
fi
if [ ! -d "${fork_parent}/proj-fork-me-branch-infork" ]; then
  fail "the branch was not created in the fork"
fi

# A sibling fork that has no remote "upstream" says nothing about this clone,
# and neither does a sibling whose repository git cannot find.  The latter is
# the branch directory of a fork that has no main working tree here, so that it
# is examined.
nofork_parent="${tmpdir}/noforks"
mkdir "${nofork_parent}"
git clone -q "${tmpdir}/proj.git" "${nofork_parent}/proj"
git clone -q "${tmpdir}/proj-fork.git" "${nofork_parent}/proj-fork-me"
mkdir "${nofork_parent}/proj-fork-gone-branch-stale"
echo "gitdir: ${tmpdir}/no-such-gitdir" > "${nofork_parent}/proj-fork-gone-branch-stale/.git"
if ! out="$(cd "${nofork_parent}/proj" && "${GIT_NEW_BRANCH}" --clean nofork 2>&1)"; then
  fail "nonzero exit status beside a fork that has no remote upstream: ${out}"
fi
case "${out}" in
  *fatal:*) fail "diagnostic about a sibling whose repository git cannot find: ${out}" ;;
esac

# Two spellings of one repository's URL are the same repository.  The refusal
# precedes every query to a remote, so these URLs are never contacted.
url_parent="${tmpdir}/urls"
mkdir "${url_parent}"
git clone -q "${tmpdir}/proj.git" "${url_parent}/proj"
git -C "${url_parent}/proj" remote set-url origin git@example.invalid:Some-Org/proj.git
git clone -q "${tmpdir}/proj-fork.git" "${url_parent}/proj-fork-me"
git -C "${url_parent}/proj-fork-me" remote add upstream https://EXAMPLE.invalid/Some-Org/proj/
if out="$(cd "${url_parent}/proj" && "${GIT_NEW_BRANCH}" --clean spelled 2>&1)"; then
  fail "zero exit status for an upstream repository spelled differently by the fork"
fi
case "${out}" in
  *"git-new-branch: ERROR: the new branch would be pushed to origin (git@example.invalid:Some-Org/proj.git)"*) ;;
  *) fail "unexpected message for an upstream repository spelled differently by the fork: ${out}" ;;
esac

# GitHub ignores the case of a repository's path, so a fork's spelling of the
# upstream repository may differ in case.
github_parent="${tmpdir}/github"
mkdir "${github_parent}"
git clone -q "${tmpdir}/proj.git" "${github_parent}/proj"
git -C "${github_parent}/proj" remote set-url origin git@github.com:Some-Org/proj.git
git clone -q "${tmpdir}/proj-fork.git" "${github_parent}/proj-fork-me"
git -C "${github_parent}/proj-fork-me" remote add upstream https://github.com/some-org/Proj
if out="$(cd "${github_parent}/proj" && "${GIT_NEW_BRANCH}" --clean github 2>&1)"; then
  fail "zero exit status for a GitHub repository spelled in a different case by the fork"
fi

# A pathname that begins with "~" names one repository in every directory.
tilde_parent="${tmpdir}/tilde"
mkdir "${tilde_parent}"
git clone -q "${tmpdir}/proj.git" "${tilde_parent}/proj"
# shellcheck disable=SC2088 # Git, not the shell, interprets the "~".
git -C "${tilde_parent}/proj" remote set-url origin '~/no-such-dir/proj.git'
git clone -q "${tmpdir}/proj-fork.git" "${tilde_parent}/proj-fork-me"
# shellcheck disable=SC2088 # Git, not the shell, interprets the "~".
git -C "${tilde_parent}/proj-fork-me" remote add upstream '~/no-such-dir/proj.git'
if out="$(cd "${tilde_parent}/proj" && "${GIT_NEW_BRANCH}" --clean tilde 2>&1)"; then
  fail "zero exit status for an upstream repository named by a pathname that begins with ~"
fi
case "${out}" in
  *"git-new-branch: ERROR: the new branch would be pushed to origin (~/no-such-dir/proj.git)"*) ;;
  *) fail "unexpected message for an upstream repository named by a pathname that begins with ~: ${out}" ;;
esac

# A `file://` URL and a pathname that name one directory are one repository.
file_parent="${tmpdir}/fileurl"
mkdir "${file_parent}"
git clone -q "${tmpdir}/proj.git" "${file_parent}/proj"
git clone -q "${tmpdir}/proj-fork.git" "${file_parent}/proj-fork-me"
git -C "${file_parent}/proj-fork-me" remote add upstream "file://${tmpdir}/proj.git"
if out="$(cd "${file_parent}/proj" && "${GIT_NEW_BRANCH}" --clean fileurl 2>&1)"; then
  fail "zero exit status for an upstream repository named by a file:// URL in the fork: ${out}"
fi

# The URLs that `git push` uses say where the new branch would be pushed, not
# the remote's URL:  a `pushurl` or a `pushInsteadOf` rewrite that names the
# fork is not refused, and a `pushurl` that names the upstream repository is.
push_parent="${tmpdir}/pushurls"
mkdir "${push_parent}"
git clone -q "${tmpdir}/proj.git" "${push_parent}/proj"
git clone -q "${tmpdir}/proj-fork.git" "${push_parent}/proj-fork-me"
git -C "${push_parent}/proj-fork-me" remote add upstream "${tmpdir}/proj.git"
git -C "${push_parent}/proj" remote set-url --push origin "${tmpdir}/proj-fork.git"
if ! out="$(cd "${push_parent}/proj" && "${GIT_NEW_BRANCH}" --clean pushurl 2>&1)"; then
  fail "refused a clone whose pushurl names the fork: ${out}"
fi
git -C "${push_parent}/proj" config --unset remote.origin.pushurl
git -C "${push_parent}/proj" config "url.${tmpdir}/proj-fork.git.pushInsteadOf" "${tmpdir}/proj.git"
if ! out="$(cd "${push_parent}/proj" && "${GIT_NEW_BRANCH}" --clean pushinsteadof 2>&1)"; then
  fail "refused a clone whose pushInsteadOf names the fork: ${out}"
fi
git -C "${push_parent}/proj" config --remove-section "url.${tmpdir}/proj-fork.git"
git -C "${push_parent}/proj" remote set-url origin "${tmpdir}/proj-fork.git"
git -C "${push_parent}/proj" remote set-url --push origin "${tmpdir}/proj.git"
if out="$(cd "${push_parent}/proj" && "${GIT_NEW_BRANCH}" --clean pushtoupstream 2>&1)"; then
  fail "zero exit status for a clone whose pushurl names the upstream repository"
fi
case "${out}" in
  *"git-new-branch: ERROR: the new branch would be pushed to origin (${tmpdir}/proj.git)"*) ;;
  *) fail "unexpected message for a clone whose pushurl names the upstream repository: ${out}" ;;
esac

# A branch directory whose pushurl names the fork is not refused, and its new
# worktree is not registered in the main clone, which pushes to the upstream
# repository.
host_parent="${tmpdir}/host"
mkdir "${host_parent}"
host_parent="$(CDPATH='' cd -- "${host_parent}" && pwd -P)" || exit 1
git clone -q "${tmpdir}/proj.git" "${host_parent}/proj"
git clone -q "${tmpdir}/proj.git" "${host_parent}/proj-branch-other"
git -C "${host_parent}/proj-branch-other" remote set-url --push origin "${tmpdir}/proj-fork.git"
git clone -q "${tmpdir}/proj-fork.git" "${host_parent}/proj-fork-me"
git -C "${host_parent}/proj-fork-me" remote add upstream "${tmpdir}/proj.git"
if ! out="$(cd "${host_parent}/proj-branch-other" && "${GIT_NEW_BRANCH}" --clean inhost 2>&1)"; then
  fail "refused a branch directory whose pushurl names the fork: ${out}"
fi
inhost_common="$(git -C "${host_parent}/proj-branch-inhost" rev-parse --path-format=absolute --git-common-dir)"
if [ "${inhost_common}" != "${host_parent}/proj-branch-other/.git" ]; then
  fail "inhost is registered in ${inhost_common}, not in ${host_parent}/proj-branch-other/.git"
fi
if ! out="$(cd "${host_parent}/proj-branch-other" && "${GIT_NEW_BRANCH}" --copy inbranchdir 2>&1)"; then
  fail "refused a copy of a clone whose pushurl names the fork: ${out}"
fi

# If git's configuration sets `github.user`, only that user's fork counts, in
# any case:  another organization's fork of the upstream repository does not
# make this clone the wrong place for the branch.
user_parent="${tmpdir}/users"
mkdir "${user_parent}"
user_parent="$(CDPATH='' cd -- "${user_parent}" && pwd -P)" || exit 1
git clone -q "${tmpdir}/proj.git" "${user_parent}/proj"
git -C "${user_parent}/proj" config github.user Me
git clone -q "${tmpdir}/proj-fork.git" "${user_parent}/proj-fork-other"
git -C "${user_parent}/proj-fork-other" remote add upstream "${tmpdir}/proj.git"
if ! out="$(cd "${user_parent}/proj" && "${GIT_NEW_BRANCH}" --clean otherorg 2>&1)"; then
  fail "refused beside another organization's fork: ${out}"
fi
git clone -q "${tmpdir}/proj-fork.git" "${user_parent}/proj-fork-mE"
git -C "${user_parent}/proj-fork-mE" remote add upstream "${tmpdir}/proj.git"
if out="$(cd "${user_parent}/proj" && "${GIT_NEW_BRANCH}" --clean userorg 2>&1)"; then
  fail "zero exit status beside the fork of github.user"
fi
case "${out}" in
  *"of the fork in each of these directories:
  ${user_parent}/proj-fork-mE
git-new-branch: "*) ;;
  *) fail "unexpected message beside the fork of github.user: ${out}" ;;
esac

# When the fork has only a branch directory here, the refusal does not suggest
# running the command in it, which would start the new branch at that
# directory's branch, without saying so.
only_parent="${tmpdir}/onlybranch"
mkdir "${only_parent}"
only_parent="$(CDPATH='' cd -- "${only_parent}" && pwd -P)" || exit 1
git clone -q "${tmpdir}/proj.git" "${only_parent}/proj"
git clone -q "${tmpdir}/proj-fork.git" "${only_parent}/proj-fork-me-branch-feature"
git -C "${only_parent}/proj-fork-me-branch-feature" remote add upstream "${tmpdir}/proj.git"
if out="$(cd "${only_parent}/proj" && "${GIT_NEW_BRANCH}" --clean onlybranch 2>&1)"; then
  fail "zero exit status beside a fork that has only a branch directory"
fi
case "${out}" in
  *"the upstream repository of the fork in this branch directory:
  ${only_parent}/proj-fork-me-branch-feature
"*"such as a new one in ${only_parent}/proj-fork-me, or in ${only_parent}/proj-fork-me-branch-feature if the new branch should start at its current commit"*) ;;
  *) fail "unexpected message beside a fork that has only a branch directory: ${out}" ;;
esac

# The default mode and `--copy` warn about each untracked or ignored file that
# contains the source's pathname, such as a build output that refers to the
# source's files, or that is a symbolic link into the source; `--clean`
# copies no such file.  The pathname may end at a "/", a quotation mark, or a
# NUL, and may be the logical pathname through a symbolic link as well as the
# physical one.  A file that names a sibling directory whose name begins with
# the source's name does not contain the source's pathname.  A symbolic link
# to a FIFO does not make the scan block.  A file whose name says that its
# contents are compressed is not examined; this one is not compressed, so
# that examining it would name it.
stale_parent="${tmpdir}/stale"
mkdir -p "${stale_parent}" || exit 1
stale_parent="$(CDPATH='' cd -- "${stale_parent}" && pwd -P)" || exit 1
stale_link="${tmpdir}/stale-link"
ln -s "${stale_parent}" "${stale_link}" || exit 1
stale="${stale_parent}/stale-branch-main"
stale_logical="${stale_link}/stale-branch-main"
make_repo "${stale}" || exit 1
printf 'build/\n' > "${stale}/.gitignore"
git -C "${stale}" add .gitignore
git -C "${stale}" commit -q -m 'Ignore build output'
stale_top="$(git -C "${stale}" rev-parse --show-toplevel)"
mkdir "${stale}/build"
printf 'launcher\000%s/inst/libexec\000' "${stale_top}" > "${stale}/build/launcher"
printf 'prefix\000%s\000' "${stale_top}" > "${stale}/build/prefix.bin"
printf '#define PREFIX "%s"\n' "${stale_top}" > "${stale}/build/config.h"
printf 'SRCDIR = %s/src\n' "${stale_logical}" > "${stale}/build/Makefile"
ln -s "${stale_top}/build" "${stale}/build/current" || exit 1
printf '%s-other/file %s.bak/file\n' "${stale_top}" "${stale_top}" > "${stale}/sibling.txt"
printf '%s/lib\n' "${stale_top}" > "${stale}/build/library.jar"
mkfifo "${stale}/build/fifo" || exit 1
ln -s fifo "${stale}/build/fifo-link" || exit 1
for mode in '' --copy; do
  branch="stale${mode#--}"
  if ! out="$(cd "${stale_logical}" && "${GIT_NEW_BRANCH}" ${mode} "${branch}" 2>&1)"; then
    fail "nonzero exit status for ${mode:-the default mode} with build output: ${out}"
  fi
  case "${out}" in
    *"warning: these files in ${stale_parent}/stale-branch-${branch}, which git does not track, contain the pathname of ${stale_logical} (also ${stale_top}) or are symbolic links into it:"*) ;;
    *) fail "${mode:-the default mode} did not warn about build output that contains the source's pathname: ${out}" ;;
  esac
  for stale_file in build/launcher build/prefix.bin build/config.h build/Makefile build/current; do
    case "${out}" in
      *"  ${stale_file}
"*) ;;
      *) fail "${mode:-the default mode} did not name ${stale_file}: ${out}" ;;
    esac
  done
  case "${out}" in
    *"sibling.txt"* | *"fifo"*) fail "${mode:-the default mode} named a file that does not refer to the source: ${out}" ;;
    *"library.jar"*) fail "${mode:-the default mode} examined a file whose name says that it is compressed: ${out}" ;;
  esac
  case "${out}" in
    *"Or remove ${stale_parent}/stale-branch-${branch} with git-remove-branch-directory, and run \`git-new-branch --clean ${branch}\`"*) ;;
    *) fail "${mode:-the default mode} did not suggest --clean: ${out}" ;;
  esac
done
if ! out="$(cd "${stale}" && "${GIT_NEW_BRANCH}" --clean staleclean 2>&1)"; then
  fail "nonzero exit status for --clean with build output: ${out}"
fi
case "${out}" in
  *"contain the pathname"*) fail "--clean warned about build output that it does not copy: ${out}" ;;
esac

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
