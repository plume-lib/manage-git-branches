#!/bin/sh

# Tests the `git-remove-branch-directory` script.
#
# Usage:
#   tests/test-git-remove-branch-directory.sh
#
# The exit status is 0 if all tests pass, 1 otherwise.
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.  Every removal that it checks is of a directory
# under that temporary directory.

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(CDPATH='' cd -- "${TESTS_DIR}/.." && pwd -P)" || exit 1
COMMAND="${COMMANDS_DIR}/git-remove-branch-directory"

# shellcheck source=lib-git-test-env.sh
. "${TESTS_DIR}/lib-git-test-env.sh"
# shellcheck source=common-functions.sh
. "${TESTS_DIR}/common-functions.sh"

status=0

fail() {
  echo "${SCRIPT_NAME}: FAIL: $*" >&2
  status=1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${work}"' EXIT
trap 'rm -rf "${work}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${work}"; trap - TERM; kill -s TERM "$$"' TERM

work="$(CDPATH='' cd -- "${work}" && pwd -P)"
sanitize_git_env "${work}"

## Usage: run_command DESCRIPTION EXPECTED-STATUS ARGUMENT...
## Runs the command under test, checks its exit status, and sets ${out} to
## everything that it printed.
run_command() {
  run_command_description="$1"
  run_command_expected="$2"
  shift 2
  out="$("${COMMAND}" "$@" 2>&1)"
  run_command_status="$?"
  if [ "${run_command_status}" -ne "${run_command_expected}" ]; then
    fail "${run_command_description}: exit status ${run_command_status}, expected ${run_command_expected}: ${out}"
  fi
}

## Usage: check_gone DESCRIPTION DIRECTORY
check_gone() {
  if [ -e "$2" ]; then
    fail "$1: $2 was not removed"
  fi
}

## Usage: check_present DESCRIPTION DIRECTORY
check_present() {
  if [ ! -e "$2" ]; then
    fail "$1: $2 was removed"
  fi
}

## Usage: check_message DESCRIPTION TEXT
## Checks that the last command's output contains TEXT.
check_message() {
  if ! printf '%s\n' "${out}" | grep -q -F -- "$2"; then
    fail "$1: the output does not contain [$2]: ${out}"
  fi
}

## Create a remote with one commit on "main" and a branch for each test to
## clone.
remote="${work}/myrepo.git"
git init -q --bare -b main "${remote}"
# Redirect stderr to suppress the "you appear to have cloned an empty
# repository" warning.
git clone -q "${remote}" "${work}/seed" 2> /dev/null
echo "first line" > "${work}/seed/file.txt"
git -C "${work}/seed" add file.txt
git -C "${work}/seed" commit -q -m "Initial commit"
git -C "${work}/seed" push -q -u origin main
for branch in clean dirty unpushed both several1 several2 host inside \
  stashed detached localtag corrupt stale envgitdir indexfile wthost; do
  git -C "${work}/seed" push -q origin "main:refs/heads/${branch}"
done

## Usage: make_clone BRANCH
## Clones BRANCH into ${work}/myrepo-branch-BRANCH and prints the directory.
make_clone() {
  git clone -q -b "$1" "${remote}" "${work}/myrepo-branch-$1"
  printf '%s\n' "${work}/myrepo-branch-$1"
}

## Usage: add_unpushed_commit DIRECTORY
## Puts a commit that no remote-tracking ref and no tag holds on a branch that
## DIRECTORY does not have checked out, and leaves the working tree clean.
## That is the case the check exists to catch:  a clone whose unpushed work is
## on a branch nobody has looked at in a long time.
add_unpushed_commit() {
  echo "unpushed work" > "$1/unpushed.txt"
  git -C "$1" add unpushed.txt
  git -C "$1" commit -q -m "An unpushed commit"
  git -C "$1" update-ref refs/heads/side HEAD
  git -C "$1" reset -q --hard HEAD~1
}

###########################################################################
## What is removed.
###########################################################################

# A clone that holds nothing at risk.
clean="$(make_clone clean)"
run_command 'a clone with nothing at risk' 0 "${clean}"
check_gone 'a clone with nothing at risk' "${clean}"

# A directory that is no repository at all, which is the `.project`-only
# directory that `git-orphaned-branches` also reports.
project="${work}/myrepo-branch-project"
mkdir -p "${project}"
touch "${project}/.project"
run_command 'a directory that is no repository' 0 "${project}"
check_gone 'a directory that is no repository' "${project}"

# Several directories in one invocation, since a caller passes a whole list.
several1="$(make_clone several1)"
several2="$(make_clone several2)"
run_command 'several directories' 0 "${several1}" "${several2}"
check_gone 'several directories' "${several1}"
check_gone 'several directories' "${several2}"

###########################################################################
## Uncommitted changes to tracked files.
###########################################################################

dirty="$(make_clone dirty)"
echo "an uncommitted change" >> "${dirty}/file.txt"
run_command 'uncommitted changes' 1 "${dirty}"
check_present 'uncommitted changes' "${dirty}"
check_message 'uncommitted changes' \
  "refusing to remove ${dirty}: 1 tracked file(s) have uncommitted changes; re-run with --force-uncommitted"

# An untracked file is not a reason to refuse:  a branch directory is full of
# build output, and refusing on account of it would refuse nearly every
# directory.
touch "${dirty}/untracked-build-output"
run_command 'uncommitted changes, ignoring untracked files' 1 "${dirty}"
check_message 'uncommitted changes, ignoring untracked files' \
  "1 tracked file(s) have uncommitted changes"

# The narrow flag waives this check, and says what it overrode.
run_command 'uncommitted changes waived' 0 --force-uncommitted "${dirty}"
check_gone 'uncommitted changes waived' "${dirty}"
check_message 'uncommitted changes waived' \
  "--force-uncommitted: deleting 1 tracked file(s) with uncommitted changes"

# A directory within a working tree is not a branch directory, but `rm -rf`
# would take its tracked files with it, so the same check applies to it.
inside="$(make_clone inside)"
mkdir -p "${inside}/subdir"
echo "tracked" > "${inside}/subdir/tracked.txt"
git -C "${inside}" add subdir/tracked.txt
git -C "${inside}" commit -q -m "Add a subdirectory"
echo "modified" >> "${inside}/subdir/tracked.txt"
run_command 'a subdirectory with uncommitted changes' 1 "${inside}/subdir"
check_present 'a subdirectory with uncommitted changes' "${inside}/subdir"
run_command 'a subdirectory with uncommitted changes, waived' 0 \
  --force-uncommitted "${inside}/subdir"
check_gone 'a subdirectory with uncommitted changes, waived' "${inside}/subdir"

###########################################################################
## Commits that no remote-tracking ref and no tag holds.
###########################################################################

unpushed="$(make_clone unpushed)"
add_unpushed_commit "${unpushed}"
run_command 'unpushed commits' 1 "${unpushed}"
check_present 'unpushed commits' "${unpushed}"
check_message 'unpushed commits' \
  "refusing to remove ${unpushed}: 1 commit(s) are on no remote-tracking ref or tag; re-run with --force-unpushed"

# Each flag waives exactly one check.
run_command 'unpushed commits, with the other flag' 1 \
  --force-uncommitted "${unpushed}"
check_present 'unpushed commits, with the other flag' "${unpushed}"
run_command 'unpushed commits waived' 0 --force-unpushed "${unpushed}"
check_gone 'unpushed commits waived' "${unpushed}"
check_message 'unpushed commits waived' \
  "--force-unpushed: deleting 1 commit(s) that are on no remote-tracking ref or tag"

# A directory that fails both checks needs both waivers, which is what
# `--force` is.
both="$(make_clone both)"
add_unpushed_commit "${both}"
echo "an uncommitted change" >> "${both}/file.txt"
run_command 'both checks' 1 "${both}"
check_message 'both checks' "--force-uncommitted"
check_message 'both checks' "--force-unpushed"
run_command 'both checks, one waiver' 1 --force-uncommitted "${both}"
check_present 'both checks, one waiver' "${both}"
run_command 'both checks, the other waiver' 1 --force-unpushed "${both}"
check_present 'both checks, the other waiver' "${both}"
run_command 'both checks, --force' 0 --force "${both}"
check_gone 'both checks, --force' "${both}"

###########################################################################
## Work that no branch names.
###########################################################################

# Stashing leaves the working tree clean, so the uncommitted-changes check
# sees nothing, and a stash entry is on no branch, so a check that asked only
# about `refs/heads` would see nothing either:  the clone would be removed and
# the only copy of the work would go with it.
stashed="$(make_clone stashed)"
echo "work in progress" >> "${stashed}/file.txt"
git -C "${stashed}" stash -q
run_command 'a stash entry' 1 "${stashed}"
check_present 'a stash entry' "${stashed}"
check_message 'a stash entry' \
  "are on no remote-tracking ref or tag; re-run with --force-unpushed"
run_command 'a stash entry waived' 0 --force-unpushed "${stashed}"
check_gone 'a stash entry waived' "${stashed}"

# A commit made on a detached HEAD is on no branch either.
detached="$(make_clone detached)"
git -C "${detached}" checkout -q --detach
echo "work on no branch" >> "${detached}/file.txt"
git -C "${detached}" commit -q -a -m "A commit on a detached HEAD"
run_command 'a commit on a detached HEAD' 1 "${detached}"
check_present 'a commit on a detached HEAD' "${detached}"
check_message 'a commit on a detached HEAD' \
  "are on no remote-tracking ref or tag; re-run with --force-unpushed"
run_command 'a commit on a detached HEAD, waived' 0 --force-unpushed \
  "${detached}"
check_gone 'a commit on a detached HEAD, waived' "${detached}"

###########################################################################
## Commits that only a tag names.
###########################################################################

# A tag that the remote holds names a commit that no branch's history
# contains, as an old release tag can.  A clone fetches such a tag into
# `refs/tags`, where git keeps no remote-tracking ref for it, so a check that
# did not count tags would count its commit as unpushed work and refuse a
# clone that holds nothing of the user's at all -- and no push could clear the
# refusal, since the commit is in the remote already.
#
# This needs a remote of its own.  Pushing the tag to ${remote} would put it
# in every later clone, where it names the history of `main` as well and so
# would answer for commits that the tests above and below want asked about.
tagremote="${work}/tagrepo.git"
git init -q --bare -b main "${tagremote}"
git clone -q "${tagremote}" "${work}/tagseed" 2> /dev/null
echo "first line" > "${work}/tagseed/file.txt"
git -C "${work}/tagseed" add file.txt
git -C "${work}/tagseed" commit -q -m "Initial commit"
git -C "${work}/tagseed" push -q -u origin main
git -C "${work}/tagseed" checkout -q --detach
echo "a line that only a tag names" >> "${work}/tagseed/file.txt"
git -C "${work}/tagseed" commit -q -a -m "A commit that only a tag names"
git -C "${work}/tagseed" tag fetched-tag
git -C "${work}/tagseed" push -q origin fetched-tag

tagged="${work}/tagrepo-branch-tagged"
git clone -q -b main "${tagremote}" "${tagged}"
# Guard the premise:  the clone really did fetch the tag, and the commit that
# the tag names really is on no remote-tracking ref of the clone.
if [ "$(git -C "${tagged}" rev-list --count --all --not --remotes)" -eq 0 ]; then
  fail 'a fetched tag: the clone has no commit outside its remote-tracking refs'
fi
run_command 'a fetched tag' 0 "${tagged}"
check_gone 'a fetched tag' "${tagged}"

# The cost of counting a tag:  a commit that a tag made here alone names is
# not caught.  Nothing local tells such a tag from a fetched one -- git
# records no remote for either -- so this is the same case as the one above,
# seen from the other side.  It loses little, because a commit is nearly
# always on a branch, HEAD, or the stash as well, and each of those still
# counts; the commit below is on none of them only because HEAD was moved off
# it deliberately.
localtag="$(make_clone localtag)"
git -C "${localtag}" checkout -q --detach
echo "work that only a local tag names" >> "${localtag}/file.txt"
git -C "${localtag}" commit -q -a -m "A commit that only a local tag names"
git -C "${localtag}" tag a-local-tag HEAD
git -C "${localtag}" checkout -q localtag
run_command 'a tag made locally' 0 "${localtag}"
check_gone 'a tag made locally' "${localtag}"

###########################################################################
## A check that cannot run.
###########################################################################

# `git status` fails on a corrupt index, and its empty output then says
# nothing about the working tree.  Reading that as "no modified files" would
# delete the modified file that it could not report.
corrupt="$(make_clone corrupt)"
echo "an uncommitted change" >> "${corrupt}/file.txt"
echo "not an index" > "${corrupt}/.git/index"
run_command 'a corrupt index' 1 "${corrupt}"
check_present 'a corrupt index' "${corrupt}"
check_message 'a corrupt index' \
  "cannot tell whether it holds uncommitted changes"

# Not even `--force` waives it:  each force flag waives a loss that this
# command has measured and named, and this one it could not measure.
run_command 'a corrupt index, with --force' 1 --force "${corrupt}"
check_present 'a corrupt index, with --force' "${corrupt}"

# For a directory within a working tree this is the only check there is, so
# failing open there removed tracked files with nothing asked at all.
mkdir -p "${corrupt}/subdir"
run_command 'a corrupt index, within a working tree' 1 --force \
  "${corrupt}/subdir"
check_present 'a corrupt index, within a working tree' "${corrupt}/subdir"
check_message 'a corrupt index, within a working tree' \
  "cannot tell whether it holds uncommitted changes"

###########################################################################
## The refusals that cannot be waived.
###########################################################################

# The current directory, and an ancestor of it.
mkdir -p "${work}/cwd/below"
if out="$( (CDPATH='' cd -- "${work}/cwd/below" && "${COMMAND}" --force .) 2>&1)"; then
  fail 'the current directory was removed'
fi
check_present 'the current directory' "${work}/cwd/below"
check_message 'the current directory' "current directory or an ancestor"
if out="$( (CDPATH='' cd -- "${work}/cwd/below" \
  && "${COMMAND}" --force "${work}/cwd") 2>&1)"; then
  fail 'an ancestor of the current directory was removed'
fi
check_present 'an ancestor of the current directory' "${work}/cwd"
check_message 'an ancestor of the current directory' \
  "current directory or an ancestor"

# A working tree that hosts a linked worktree, whose repository the worktree
# depends on.
host="$(make_clone host)"
git -C "${host}" worktree add -q "${work}/myrepo-branch-linked" -b linked
run_command 'a working tree that hosts a worktree' 1 --force "${host}"
check_present 'a working tree that hosts a worktree' "${host}"
check_message 'a working tree that hosts a worktree' \
  "holds the repository of 1 linked worktree(s)"

# A registration whose directory is gone is not a linked worktree that
# removing this directory would break:  nothing depends on the repository any
# longer, and `git worktree prune` would drop the registration.  Counting it
# refused a directory that `git-orphaned-branches` lists, with a refusal that
# no flag can waive.
stale="$(make_clone stale)"
git -C "${stale}" worktree add -q "${work}/myrepo-branch-stale-linked" \
  -b stale-linked
rm -rf "${work}/myrepo-branch-stale-linked"
run_command 'a stale worktree registration' 0 "${stale}"
check_gone 'a stale worktree registration' "${stale}"

# A submodule's working tree, whose `.git` is a file as well, is not a
# linked worktree, and is refused and left intact.
mkdir -p "${work}/submodule"
make_submodule_superproject "${work}/submodule"
submodule_before="$(working_tree_state "${work}/submodule/super-branch-main/sub")"
run_command "a submodule's working tree" 1 --force \
  "${work}/submodule/super-branch-main/sub"
check_present "a submodule's working tree" \
  "${work}/submodule/super-branch-main/sub"
check_message "a submodule's working tree" "it is not a linked worktree"
if [ "$(working_tree_state "${work}/submodule/super-branch-main/sub")" \
  != "${submodule_before}" ]; then
  fail "a submodule's working tree: its HEAD or index changed"
fi

###########################################################################
## Linked worktrees.
###########################################################################

## Usage: check_unregistered DESCRIPTION HOST DIRECTORY BRANCH
## Checks that the repository of the working tree HOST registers no worktree
## at DIRECTORY, keeps no administrative directory for it, and has no branch
## BRANCH and no configuration for it, and that HOST itself is intact.
## DIRECTORY is where the worktree was added.
check_unregistered() {
  if git -C "$2" worktree list --porcelain | grep -q -x -F "worktree $3"; then
    fail "$1: $3 is still registered"
  fi
  # The administrative directory is named after the directory that the
  # worktree was added at.
  if [ -e "$(git -C "$2" rev-parse --path-format=absolute \
    --git-common-dir)/worktrees/$(basename -- "$3")" ]; then
    fail "$1: an administrative directory is left in $2"
  fi
  if git -C "$2" rev-parse --verify --quiet "refs/heads/$4" > /dev/null; then
    fail "$1: the branch $4 is left in $2"
  fi
  # A new branch of the same name would inherit this configuration, such as
  # an upstream that was deleted in its remote.
  if git -C "$2" config --get-regexp "^branch\\.$4\\." > /dev/null; then
    fail "$1: the configuration of the branch $4 is left in $2"
  fi
  if ! git -C "$2" status > /dev/null 2>&1; then
    fail "$1: $2 is no longer a working tree"
  fi
}

# A linked worktree is removed, along with its registration and its branch,
# and the branch name can then be used again.  Its HEAD is where the remote
# has it, so nothing is lost.  It holds modified and untracked build output,
# which `git worktree remove` would refuse without git's own `--force`.
wthost="$(make_clone wthost)"
git -C "${wthost}" worktree add -q -b wtgone "${work}/myrepo-branch-wtgone"
git -C "${wthost}" config branch.wtgone.remote origin
git -C "${wthost}" config branch.wtgone.merge refs/heads/wtgone
echo 'build output' > "${work}/myrepo-branch-wtgone/output.o"
run_command 'a linked worktree' 0 "${work}/myrepo-branch-wtgone"
check_gone 'a linked worktree' "${work}/myrepo-branch-wtgone"
check_unregistered 'a linked worktree' "${wthost}" \
  "${work}/myrepo-branch-wtgone" wtgone
if ! (cd "${wthost}" && "${COMMANDS_DIR}/git-new-branch" wtgone > /dev/null 2>&1); then
  fail "git-new-branch could not reuse the name of a removed worktree's branch"
fi

# The unpushed check of a linked worktree asks about its own branch alone.
# It refuses for an unpushed commit on that branch, and not for one on another
# branch of the repository, which the removal does not touch.
git -C "${wthost}" worktree add -q -b wtmine "${work}/myrepo-branch-wtmine"
echo 'mine' > "${work}/myrepo-branch-wtmine/mine.txt"
git -C "${work}/myrepo-branch-wtmine" add mine.txt
git -C "${work}/myrepo-branch-wtmine" commit -q -m 'An unpushed commit on wtmine'
git -C "${wthost}" worktree add -q -b wtother "${work}/myrepo-branch-wtother"
add_unpushed_commit "${wthost}"
run_command 'a linked worktree with an unpushed commit' 1 \
  "${work}/myrepo-branch-wtmine"
check_present 'a linked worktree with an unpushed commit' \
  "${work}/myrepo-branch-wtmine"
check_message 'a linked worktree with an unpushed commit' \
  "1 commit(s) are on no other branch, remote-tracking ref, or tag; re-run with --force-unpushed"
if ! git -C "${wthost}" rev-parse --verify --quiet refs/heads/wtmine > /dev/null; then
  fail "a linked worktree with an unpushed commit: its branch was deleted"
fi
run_command "another branch's unpushed commit" 0 "${work}/myrepo-branch-wtother"
check_gone "another branch's unpushed commit" "${work}/myrepo-branch-wtother"
run_command 'a linked worktree with an unpushed commit, waived' 0 \
  --force-unpushed "${work}/myrepo-branch-wtmine"
check_gone 'a linked worktree with an unpushed commit, waived' \
  "${work}/myrepo-branch-wtmine"
check_message 'a linked worktree with an unpushed commit, waived' \
  "git fsck --lost-found"
if git -C "${wthost}" rev-parse --verify --quiet refs/heads/wtmine > /dev/null; then
  fail "a linked worktree with an unpushed commit, waived: its branch is left"
fi

# Uncommitted changes in a linked worktree are refused, as in a clone.
git -C "${wthost}" worktree add -q -b wtdirty "${work}/myrepo-branch-wtdirty"
echo 'modified' >> "${work}/myrepo-branch-wtdirty/file.txt"
run_command 'a linked worktree with uncommitted changes' 1 \
  "${work}/myrepo-branch-wtdirty"
check_present 'a linked worktree with uncommitted changes' \
  "${work}/myrepo-branch-wtdirty"
check_message 'a linked worktree with uncommitted changes' "--force-uncommitted"
run_command 'a linked worktree with uncommitted changes, waived' 0 \
  --force-uncommitted "${work}/myrepo-branch-wtdirty"
check_gone 'a linked worktree with uncommitted changes, waived' \
  "${work}/myrepo-branch-wtdirty"

# A locked linked worktree is refused, even with `--force`, and its lock
# reason is reported.  `git worktree remove --force` refuses it too, and the
# fallback must not then remove it anyway.
git -C "${wthost}" worktree add -q -b wtlocked "${work}/myrepo-branch-wtlocked"
git -C "${wthost}" worktree lock --reason 'on a USB drive' \
  "${work}/myrepo-branch-wtlocked"
run_command 'a locked linked worktree' 1 --force "${work}/myrepo-branch-wtlocked"
check_present 'a locked linked worktree' "${work}/myrepo-branch-wtlocked"
check_message 'a locked linked worktree' "it is locked (on a USB drive)"
if ! git -C "${wthost}" rev-parse --verify --quiet refs/heads/wtlocked > /dev/null; then
  fail "a locked linked worktree: its branch was deleted"
fi
git -C "${wthost}" worktree unlock "${work}/myrepo-branch-wtlocked"
run_command 'an unlocked linked worktree' 0 "${work}/myrepo-branch-wtlocked"
check_unregistered 'an unlocked linked worktree' "${wthost}" \
  "${work}/myrepo-branch-wtlocked" wtlocked

# A linked worktree that was moved with `mv`, and not repaired, is no longer
# where its registration says.  `git worktree remove` cannot remove it, so the
# directory and its own administrative directory are removed instead.
git -C "${wthost}" worktree add -q -b wtmoved "${work}/myrepo-branch-wtmoved"
mv "${work}/myrepo-branch-wtmoved" "${work}/myrepo-branch-wtmoved-elsewhere"
run_command 'a moved linked worktree' 0 "${work}/myrepo-branch-wtmoved-elsewhere"
check_gone 'a moved linked worktree' "${work}/myrepo-branch-wtmoved-elsewhere"
check_unregistered 'a moved linked worktree' "${wthost}" \
  "${work}/myrepo-branch-wtmoved" wtmoved

# A linked worktree that is already gone, removed with `rm -rf`, leaves its
# registration and its branch, which are cleaned up given the repository.  A
# worktree elsewhere in the repository that was moved with `mv`, and not
# repaired, is left alone, which is what distinguishes this from
# `git worktree prune`.
git -C "${wthost}" worktree add -q -b wtrmrf "${work}/myrepo-branch-wtrmrf"
git -C "${wthost}" config branch.wtrmrf.remote origin
git -C "${wthost}" config branch.wtrmrf.merge refs/heads/wtrmrf
rm -rf "${work}/myrepo-branch-wtrmrf"
git -C "${wthost}" worktree add -q -b wtbystander "${work}/myrepo-branch-wtbystander"
mv "${work}/myrepo-branch-wtbystander" "${work}/myrepo-branch-wtbystander-moved"
run_command 'a removed linked worktree, from the repository' 0 \
  --repository "${wthost}" "${work}/myrepo-branch-wtrmrf"
check_unregistered 'a removed linked worktree' "${wthost}" \
  "${work}/myrepo-branch-wtrmrf" wtrmrf
if git -C "${wthost}" worktree list --porcelain | grep -q -x -F \
  "worktree ${work}/myrepo-branch-wtrmrf"; then
  fail "a removed linked worktree: it is still registered"
fi
if git -C "${wthost}" rev-parse --verify --quiet refs/heads/wtrmrf > /dev/null; then
  fail "a removed linked worktree: its branch is left"
fi
if ! (cd "${wthost}" && "${COMMANDS_DIR}/git-new-branch" wtrmrf > /dev/null 2>&1); then
  fail "git-new-branch could not reuse the name of a removed worktree"
fi
if ! git -C "${wthost}" worktree repair "${work}/myrepo-branch-wtbystander-moved" \
  > /dev/null 2>&1 \
  || ! git -C "${work}/myrepo-branch-wtbystander-moved" status > /dev/null 2>&1; then
  fail "cleaning up after a removed linked worktree disturbed a moved one"
fi

# With `worktree.useRelativePaths`, the administrative directory names its
# worktree with a relative path, which must still be matched to the missing
# directory.  `--relative-paths` needs git 2.48, so skip this test otherwise.
if git -C "${wthost}" worktree add -q --relative-paths -b wtrelative \
  "${work}/myrepo-branch-wtrelative" 2> /dev/null; then
  case "$(cat -- "$(git -C "${work}/myrepo-branch-wtrelative" rev-parse \
    --absolute-git-dir)/gitdir")" in
    /*) fail "a removed linked worktree with relative paths: its gitdir file is absolute" ;;
  esac
  rm -rf "${work}/myrepo-branch-wtrelative"
  run_command 'a removed linked worktree with relative paths' 0 \
    --repository "${wthost}" "${work}/myrepo-branch-wtrelative"
  check_unregistered 'a removed linked worktree with relative paths' \
    "${wthost}" "${work}/myrepo-branch-wtrelative" wtrelative
fi

# The repository defaults to the current directory, when that is a working
# tree.
git -C "${wthost}" worktree add -q -b wtrmrf2 "${work}/myrepo-branch-wtrmrf2"
rm -rf "${work}/myrepo-branch-wtrmrf2"
out="$(cd "${wthost}" && "${COMMAND}" "${work}/myrepo-branch-wtrmrf2" 2>&1)" \
  || fail "a removed linked worktree, from the current directory: ${out}"
if git -C "${wthost}" rev-parse --verify --quiet refs/heads/wtrmrf2 > /dev/null; then
  fail "a removed linked worktree, from the current directory: its branch is left"
fi

# A removed linked worktree whose branch holds unpushed work is refused, so
# that the branch survives.
git -C "${wthost}" worktree add -q -b wtrmrfwork "${work}/myrepo-branch-wtrmrfwork"
git -C "${work}/myrepo-branch-wtrmrfwork" commit -q --allow-empty -m 'Unpushed'
rm -rf "${work}/myrepo-branch-wtrmrfwork"
run_command 'a removed linked worktree with an unpushed commit' 1 \
  --repository "${wthost}" "${work}/myrepo-branch-wtrmrfwork"
check_message 'a removed linked worktree with an unpushed commit' \
  "--force-unpushed"
if ! git -C "${wthost}" rev-parse --verify --quiet refs/heads/wtrmrfwork > /dev/null; then
  fail "a removed linked worktree with an unpushed commit: its branch was deleted"
fi

# A locked linked worktree whose directory is gone may be on removable media
# that is not mounted, so it is refused, even with `--force`.
git -C "${wthost}" worktree add -q -b wtrmrflocked "${work}/myrepo-branch-wtrmrflocked"
git -C "${wthost}" worktree lock --reason 'on a USB drive' \
  "${work}/myrepo-branch-wtrmrflocked"
mv "${work}/myrepo-branch-wtrmrflocked" "${work}/myrepo-branch-wtrmrflocked-unmounted"
run_command 'a removed locked linked worktree' 1 --force \
  --repository "${wthost}" "${work}/myrepo-branch-wtrmrflocked"
check_message 'a removed locked linked worktree' "it is locked (on a USB drive)"
if ! git -C "${wthost}" rev-parse --verify --quiet refs/heads/wtrmrflocked > /dev/null; then
  fail "a removed locked linked worktree: its branch was deleted"
fi
mv "${work}/myrepo-branch-wtrmrflocked-unmounted" "${work}/myrepo-branch-wtrmrflocked"
if ! git -C "${work}/myrepo-branch-wtrmrflocked" status > /dev/null 2>&1; then
  fail "a removed locked linked worktree: it is no longer a working tree once remounted"
fi

# A path that does not exist and that no repository registers is an error,
# whether or not a repository is given, so that a mistyped name fails.
run_command 'a path that no worktree is registered at' 1 \
  --repository "${wthost}" "${work}/never-a-worktree"
check_message 'a path that no worktree is registered at' \
  "no worktree registered there"
out="$(cd "${wthost}" && "${COMMAND}" "${work}/never-a-worktree" 2>&1)" \
  && fail "a path that no worktree is registered at, from a working tree: exit status 0: ${out}"

# $GIT_DIR and $GIT_WORK_TREE in the environment (as when running under a git
# hook, or `git rebase --exec`) take precedence over `git -C`, so leaving them
# set would make every check ask about the repository that they name rather
# than about the directory that `rm -rf` is about to take.  A directory with
# uncommitted changes and unpushed commits would be removed with nothing
# asked, because the clean repository named by the environment would answer
# for it.
envtarget="$(make_clone envgitdir)"
add_unpushed_commit "${envtarget}"
echo "a modification" >> "${envtarget}/file.txt"
envother="${work}/env-other"
git clone -q "${remote}" "${envother}"
out="$(GIT_DIR="${envother}/.git" GIT_WORK_TREE="${envother}" \
  "${COMMAND}" "${envtarget}" 2>&1)"
envstatus="$?"
if [ "${envstatus}" -ne 1 ]; then
  fail "a target with GIT_DIR set: exit status ${envstatus}, expected 1: ${out}"
fi
check_present 'a target with GIT_DIR set' "${envtarget}"
check_message 'a target with GIT_DIR set' "uncommitted changes"
check_message 'a target with GIT_DIR set' "on no remote-tracking ref or tag"

# $GIT_INDEX_FILE names the index alone, and the uncommitted-changes check is
# the one that reads an index.  A modified tracked file is caught through a
# foreign index anyway, because it differs from whatever that index holds, but
# work that exists only in the index is not:  a file created and staged and
# never committed is absent from the foreign index, so it is untracked there,
# and `--untracked-files=no` says nothing about it.  The directory would be
# removed, silently and with exit status 0.
indextarget="$(make_clone indexfile)"
echo "work that exists only in the index" > "${indextarget}/staged.txt"
git -C "${indextarget}" add staged.txt
indexother="${work}/index-other"
git clone -q "${remote}" "${indexother}"
out="$(GIT_INDEX_FILE="${indexother}/.git/index" "${COMMAND}" "${indextarget}" 2>&1)"
indexstatus="$?"
if [ "${indexstatus}" -ne 1 ]; then
  fail "a target with GIT_INDEX_FILE set: exit status ${indexstatus}, expected 1: ${out}"
fi
check_present 'a target with GIT_INDEX_FILE set' "${indextarget}"
check_message 'a target with GIT_INDEX_FILE set' "uncommitted changes"

###########################################################################
## Bare repositories.
###########################################################################

# A bare repository holds no working tree, so the uncommitted check has
# nothing to ask about, but its objects are its own and `rm -rf` takes every
# one of them.  Classified with the directories that are no repository at
# all, which are checked for nothing, a bare repository that holds the only
# copy of its commits would be removed and nothing would be said.
bareonly="${work}/myrepo-branch-bareonly.git"
git clone -q --bare "${remote}" "${bareonly}"
run_command 'a bare repository whose commits are nowhere else' 1 "${bareonly}"
check_present 'a bare repository whose commits are nowhere else' "${bareonly}"
check_message 'a bare repository whose commits are nowhere else' \
  "on no remote-tracking ref or tag"

# The same refusal is waived by the same flag as a clone's.
run_command 'a forced bare repository' 0 --force-unpushed "${bareonly}"
check_gone 'a forced bare repository' "${bareonly}"
check_message 'a forced bare repository' "--force-unpushed"

# A bare repository whose every commit is on a remote-tracking ref has
# nothing to lose, so it is removed.
barepushed="${work}/myrepo-branch-barepushed.git"
git init -q --bare -b main "${barepushed}"
git -C "${barepushed}" remote add origin "${remote}"
git -C "${barepushed}" fetch -q origin
run_command 'a bare repository whose commits are on a remote' 0 "${barepushed}"
check_gone 'a bare repository whose commits are on a remote' "${barepushed}"

# A directory inside a bare repository is asked the same question:  removing
# it loses those commits as surely as removing the repository directory does.
bareinside="${work}/myrepo-branch-bareinside.git"
git clone -q --bare "${remote}" "${bareinside}"
run_command 'a directory inside a bare repository' 1 "${bareinside}/objects"
check_present 'a directory inside a bare repository' "${bareinside}/objects"
check_message 'a directory inside a bare repository' "on no remote-tracking ref or tag"

###########################################################################
## Arguments.
###########################################################################

run_command 'no argument' 1
check_message 'no argument' "no directory to remove"

# A path that does not exist, with no repository to consult about it.  The
# command runs in ${work}, which is not a working tree.
out="$(cd "${work}" && "${COMMAND}" "${work}/no-such-directory" 2>&1)" \
  && fail "a path that does not exist: exit status 0: ${out}"
check_message 'a path that does not exist' "no such directory"
check_message 'a path that does not exist' "--repository"

touch "${work}/a-file"
run_command 'a path that is not a directory' 1 "${work}/a-file"
check_present 'a path that is not a directory' "${work}/a-file"
check_message 'a path that is not a directory' "not a directory"

run_command 'an unrecognized option' 1 --no-such-option "${work}"
check_message 'an unrecognized option' "unrecognized option"

# A refusal for one directory does not stop the others, and the exit status
# says that not everything was removed.
git -C "${work}/seed" push -q origin main:refs/heads/after-refusal
after="$(make_clone after-refusal)"
run_command 'a refusal among removals' 1 "${work}/a-file" "${after}"
check_gone 'a refusal among removals' "${after}"

if [ "${status}" = 0 ]; then
  echo "${SCRIPT_NAME}: OK"
fi
exit "${status}"
