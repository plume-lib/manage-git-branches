# shellcheck shell=sh

# Functions that this package's commands share.  Other scripts source this
# file, rather than running it as a command, so it has no shebang line and is
# not executable.  This file defines the functions that the others build on,
# and it sources the files that define the rest:
#  * agent-functions.sh:  running AI agents, and recording their sessions in
#    the file AGENT-TODO.md.
#  * clone-functions.sh:  clones, forks, branch directories, and the GitHub
#    repositories of pull requests.
#  * deleted-branch-functions.sh:  whether a branch was deleted in its remote.
#  * merge-build-push-functions.sh:  merge messages, and merging, building, and
#    pushing a branch.
#  * merge-conflict-functions.sh:  resolving the conflicts of a merge.
#  * merge-functions.sh:  pulling, merges in progress, and commits.
#
# A script that sources this file must set ${SCRIPT_DIR} to the directory that
# contains this package's files, because this file sources the files above
# from that directory, `git_batch_ssh` runs a wrapper script from it, and
# `check_conflict_resolution` runs an awk program from it.  It must also set
# ${SCRIPT_NAME} to its own name, which the functions' diagnostics use.

# shellcheck source=agent-functions.sh
. "${SCRIPT_DIR}/agent-functions.sh"
# shellcheck source=clone-functions.sh
. "${SCRIPT_DIR}/clone-functions.sh"
# shellcheck source=deleted-branch-functions.sh
. "${SCRIPT_DIR}/deleted-branch-functions.sh"
# shellcheck source=merge-build-push-functions.sh
. "${SCRIPT_DIR}/merge-build-push-functions.sh"
# shellcheck source=merge-conflict-functions.sh
. "${SCRIPT_DIR}/merge-conflict-functions.sh"
# shellcheck source=merge-functions.sh
. "${SCRIPT_DIR}/merge-functions.sh"

## Usage: unset_git_location_variables
## Unsets $GIT_DIR, $GIT_WORK_TREE, $GIT_INDEX_FILE, $GIT_COMMON_DIR, and
## $GIT_OBJECT_DIRECTORY.  Git exports the first three to hooks and to the
## commands run by `git rebase --exec`, `git bisect run`, and
## `git submodule foreach`, and it exports $GIT_OBJECT_DIRECTORY to the hooks
## that run while a push is received.  They take precedence over the location
## of a working tree, including the `-C` argument of `git`, so a command that
## runs git in a directory other than the caller's must unset them before it
## runs git at all.
unset_git_location_variables() {
  unset GIT_DIR
  unset GIT_WORK_TREE
  unset GIT_INDEX_FILE
  unset GIT_COMMON_DIR
  unset GIT_OBJECT_DIRECTORY
}

## Usage: require_git MINOR [WHY]
## Exits with status 1, after printing a diagnostic, unless git is version
## 2.MINOR or later.  WHY, if given, says why that version is needed.
##
## The version is parsed rather than probed for:  one mechanism gives every
## command one message, and the message can say which version it found.  A
## probe would also need care, because `git rev-parse` prints an option that it
## does not recognize, and exits 0, rather than failing.
##
## The version is read once, by the first call, so that a command that states
## several requirements runs `git version` only once.
require_git_version=''
require_git() {
  if ! git_at_least "$1"; then
    echo "${SCRIPT_NAME}: requires git 2.$1 or later${2:+ $2}, but found git ${require_git_version}" >&2
    exit 1
  fi
}

## Usage: git_at_least MINOR
## Succeeds if git is version 2.MINOR or later.  Fails, after printing a
## diagnostic, if the version cannot be read or parsed, so that the caller
## falls back as it would for an older git.  It reads the version as
## `require_git` does, and only once.
git_at_least() {
  if [ -z "${require_git_version}" ]; then
    # Output is like "git version 2.44.0" or "git version 2.44.0.windows.1".
    require_git_version="$(git version)" || return 1
    require_git_version="${require_git_version#git version }"
  fi
  require_git_major="${require_git_version%%.*}"
  require_git_minor="${require_git_version#*.}"
  require_git_minor="${require_git_minor%%.*}"
  case "${require_git_major}.${require_git_minor}" in
    *[!0-9.]* | .* | *.)
      echo "${SCRIPT_NAME}: cannot parse git version: ${require_git_version}" >&2
      return 1
      ;;
  esac
  [ "${require_git_major}" -gt 2 ] \
    || { [ "${require_git_major}" -eq 2 ] && [ "${require_git_minor}" -ge "$1" ]; }
}

## Usage: undo_worktree_add REPOSITORY WORKTREE GITDIR BRANCH COMMIT
## Undoes a `git worktree add` that the calling command ran, or began to run,
## in the repository of the working tree REPOSITORY:  removes the directory
## WORKTREE, its administrative directory GITDIR, and the branch BRANCH.  It is
## for a command's cleanup after a failure or a signal, so it prints nothing,
## reads nothing from standard input, and returns 0.
##
## GITDIR is the worktree's administrative directory, from
## `git -C WORKTREE rev-parse --absolute-git-dir`, or empty if the caller never
## learned it.  BRANCH is empty if the caller did not create a branch.
## COMMIT is the commit that the caller created BRANCH at, and the branch is
## deleted only if it is still there, so that a branch that something else
## created or moved is left alone; an empty COMMIT deletes BRANCH wherever it
## is.
##
## `git worktree remove --force` is the removal when WORKTREE holds a `.git`,
## which only the caller's `git worktree add` can have put there, since the
## caller made sure that WORKTREE did not exist.  `--force` is needed because a
## half-built worktree has modifications by construction.  The test matters:
## given a path that is registered but missing, `git worktree remove --force`
## succeeds and drops the registration, which is no business of this function
## if the registration was not this command's -- a stale one, say, that made
## the `git worktree add` fail.
##
## When that does not apply or does not work, remove WORKTREE and GITDIR
## directly.  Never `git worktree prune`, which drops every registration whose
## directory is missing, including that of a worktree that the user moved with
## `mv` and has not repaired; that worktree cannot be repaired afterward.
undo_worktree_add() {
  if [ -e "$2/.git" ] \
    && git -C "$1" worktree remove --force "$2" < /dev/null > /dev/null 2>&1; then
    :
  else
    rm -rf -- "$2" || true
    if [ -n "$3" ]; then
      rm -rf -- "$3" || true
    fi
  fi
  # A branch that is not there, or is not at COMMIT, is left alone, without
  # aborting a caller that runs under `set -e`.  Deleting the branch also
  # removes its configuration, as `git branch --delete` would.
  if [ -n "$4" ] \
    && git -C "$1" update-ref -d "refs/heads/$4" ${5:+"$5"} \
      < /dev/null > /dev/null 2>&1; then
    git -C "$1" config --remove-section "branch.$4" \
      < /dev/null > /dev/null 2>&1 || true
  fi
}

## Usage: trap_branch_cleanup
## For `git-new-branch` and `git-checkout-branch`.  Installs traps that, when
## the command exits or is killed by a signal, undo whatever partial work these
## variables record.  It sets each of them to empty, and the command sets each
## one just before it creates what the variable names, and empties it once
## that is complete:
##  * TMPDIR_TO_CLEAN, a temporary directory.  It is left empty otherwise, so
##    the traps never remove a pre-existing directory that the command did not
##    create.
##  * WORKTREE_TO_CLEAN, BRANCH_TO_CLEAN, and BRANCH_COMMIT_TO_CLEAN, the new
##    worktree, and the branch that the add creates and its commit; see
##    `add_worktree`.
##  * WORKTREE_GITDIR_TO_CLEAN, the new worktree's administrative directory,
##    which the command records as soon as the add succeeds, if it learns it.
## The command must also set TOPLEVEL, the top level of its working tree,
## before it sets WORKTREE_TO_CLEAN.  If the command sets WORKTREE_HOST, the
## worktree was added in that repository rather than in TOPLEVEL's; see
## `add_worktree`.
##
## A POSIX shell such as dash does not run an EXIT trap when the shell is
## killed by a signal, so trap the signals too.  Each signal handler restores
## the default disposition and re-sends the signal to this shell, so that the
## caller still sees the exit status that the signal produces.
trap_branch_cleanup() {
  branch_cleanup_startdir="${PWD}"
  TMPDIR_TO_CLEAN=""
  WORKTREE_TO_CLEAN=""
  WORKTREE_GITDIR_TO_CLEAN=""
  BRANCH_TO_CLEAN=""
  BRANCH_COMMIT_TO_CLEAN=""
  WORKTREE_HOST=""
  trap branch_cleanup EXIT
  trap 'branch_cleanup; trap - HUP EXIT; kill -s HUP "$$"' HUP
  trap 'branch_cleanup; trap - INT EXIT; kill -s INT "$$"' INT
  trap 'branch_cleanup; trap - TERM EXIT; kill -s TERM "$$"' TERM
}

## Usage: branch_cleanup
## The traps that `trap_branch_cleanup` installs run this.
branch_cleanup() {
  cd -- "${branch_cleanup_startdir}" 2> /dev/null || true
  if [ -n "${TMPDIR_TO_CLEAN}" ]; then rm -rf -- "${TMPDIR_TO_CLEAN}"; fi
  # The starting directory may no longer resolve, so name the repository
  # explicitly.
  if [ -n "${WORKTREE_TO_CLEAN}" ]; then
    undo_worktree_add "${WORKTREE_HOST:-${TOPLEVEL}}" "${WORKTREE_TO_CLEAN}" \
      "${WORKTREE_GITDIR_TO_CLEAN}" "${BRANCH_TO_CLEAN}" \
      "${BRANCH_COMMIT_TO_CLEAN}"
  fi
}

## Usage: make_temp_dir
## Creates a new temporary directory, sets ${temp_dir} to its absolute
## pathname, and installs traps that remove the directory when this shell
## exits or is killed by SIGHUP, SIGINT, or SIGTERM.  The traps replace any
## earlier traps for those conditions.  Exits with status 1, after printing a
## diagnostic, if the directory cannot be created.  As in
## `trap_branch_cleanup`, each signal handler restores the default disposition
## and re-sends the signal to this shell, so that the caller sees that this
## shell was killed by the signal.
make_temp_dir() {
  if ! temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME}.XXXXXX")" \
    || [ -z "${temp_dir}" ]; then
    echo "${SCRIPT_NAME}: cannot create a temporary directory" >&2
    exit 1
  fi
  # mktemp returns a relative pathname if ${TMPDIR} is relative.
  case "${temp_dir}" in
    /*) ;;
    *) temp_dir="$(pwd)/${temp_dir}" ;;
  esac
  trap 'rm -rf -- "${temp_dir}"' EXIT
  trap 'rm -rf -- "${temp_dir}"; trap - HUP EXIT; kill -s HUP "$$"' HUP
  trap 'rm -rf -- "${temp_dir}"; trap - INT EXIT; kill -s INT "$$"' INT
  trap 'rm -rf -- "${temp_dir}"; trap - TERM EXIT; kill -s TERM "$$"' TERM
}

## Usage: review_notice MESSAGE
## Prints MESSAGE, which names something that an AI agent or a hook did that a
## person should review, as a diagnostic, and appends it to the summary (see
## `append_summary`), prefixed by the current directory, as in
## "in /home/me/myrepo-branch-feature: claude also changed: README.md".
review_notice() {
  printf '%s\n' "${SCRIPT_NAME}: $1" >&2
  append_summary "in $(pwd): $1"
}

## Usage: append_merge_note_summary NOTE
## Appends to the summary (see `append_summary`) NOTE, a paragraph that
## `merge_in_progress_note` printed, as one line, without its last line, which
## says what to do, as in "The merge of commit 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b
## is in progress in /home/me/myrepo-branch-feature.  No conflicted file
## remains."
append_merge_note_summary() {
  if [ -n "$1" ]; then
    append_summary "$(printf '%s\n' "$1" | sed -e '$d' \
      | awk 'NR > 1 { printf "  " } { printf "%s", $0 } END { print "" }')"
  fi
}

## Usage: append_summary LINE
## Appends LINE, followed by a newline, to the file named by ${summary_file}, if
## that variable is set and not empty.  The summary lists what a person should
## look at after a run:  each change by an AI agent to review, each change by a
## hook to a file that a commit would not otherwise change, each file that
## changed after a hook's changes were staged (see `commit_staged_again`),
## each merge left in progress and each agent session that can be continued
## (which `report_merge_in_progress` and `report_agent_session` also note in
## AGENT-TODO.md), and the step that failed.  `git-push-to --summary` sets
## ${summary_file}.  A failure to write the summary goes unreported, because
## the same information is printed as a diagnostic.
append_summary() {
  if [ -n "${summary_file:-}" ]; then
    printf '%s\n' "$1" >> "${summary_file}" 2> /dev/null || true
  fi
}

## Usage: add_worktree WORKTREE BRANCH [START-POINT [OPTION...]]
## Runs `git worktree add` in the current repository, or in the repository of
## the working tree WORKTREE_HOST if that variable is non-empty, with the
## OPTIONs, to make
## a new worktree at the absolute pathname WORKTREE.  With START-POINT, it
## creates the branch BRANCH there; without, it checks out the existing BRANCH.
## START-POINT is passed to git as given, so that git sets up an upstream for
## it as it would for `git branch`.  Exits with status 1, after printing a
## diagnostic, if the add fails; git's own message says why.
##
## It records, for the traps of `trap_branch_cleanup`, WORKTREE and, if it
## creates BRANCH, BRANCH and the commit that START-POINT names.  A BRANCH
## that it creates gets `branch.BRANCH.createdForBranchDirectory`, so that
## `git-remove-branch-directory` deletes it along with the worktree.  BRANCH is
## recorded only if it does not exist just before the add, so that the traps
## never delete a branch that this command did not create;
## `git worktree add -b` creates the branch before it tests the path, and
## leaves it behind when the test fails.
##
## The worktree is added at its final path, never at a temporary one:  a
## worktree that is later moved with `mv` keeps a registration that names its
## old path, and one that is moved with `git worktree move` keeps an
## administrative directory named after its old path forever.
##
## When a branch directory was removed with `rm -rf`, the add fails because
## the path is still registered, and git's message names the ways out.  This
## function never runs `git worktree prune` to smooth that over, because prune
## also deletes the registration of a worktree that the user moved with `mv`,
## which cannot be repaired afterward.
##
## WORKTREE must not exist; if it does, this function exits with status 1.
## It tests for WORKTREE itself, even when the caller already has, so that
## nothing slow -- a remote query or a copy -- runs between the test and the
## recording of WORKTREE.  Otherwise a directory that another process created
## in between would make the add fail, and the traps would then remove that
## directory, which this command did not create.
add_worktree() {
  add_worktree_dir="$1"
  add_worktree_repo="${WORKTREE_HOST:-.}"
  add_worktree_branch="$2"
  if [ -e "${add_worktree_dir}" ] || [ -L "${add_worktree_dir}" ]; then
    echo "${SCRIPT_NAME}: ERROR: directory exists: ${add_worktree_dir}" >&2
    exit 1
  fi
  if [ "$#" -lt 3 ]; then
    WORKTREE_TO_CLEAN="${add_worktree_dir}"
    # WORKTREE is absolute, so it cannot be mistaken for an option.
    if ! git -C "${add_worktree_repo}" worktree add -q "${add_worktree_dir}" "${add_worktree_branch}"; then
      echo "${SCRIPT_NAME}: ERROR: cannot create the worktree ${add_worktree_dir}" >&2
      exit 1
    fi
    return 0
  fi
  add_worktree_start="$3"
  shift 3
  if ! BRANCH_COMMIT_TO_CLEAN="$(git -C "${add_worktree_repo}" rev-parse --verify \
    "${add_worktree_start}^{commit}")"; then
    echo "${SCRIPT_NAME}: ERROR: cannot resolve ${add_worktree_start}" >&2
    exit 1
  fi
  if ! git -C "${add_worktree_repo}" rev-parse --verify --quiet "refs/heads/${add_worktree_branch}" > /dev/null; then
    BRANCH_TO_CLEAN="${add_worktree_branch}"
  fi
  WORKTREE_TO_CLEAN="${add_worktree_dir}"
  if ! git -C "${add_worktree_repo}" worktree add "$@" -q -b "${add_worktree_branch}" \
    "${add_worktree_dir}" "${add_worktree_start}"; then
    echo "${SCRIPT_NAME}: ERROR: cannot create the worktree ${add_worktree_dir}" >&2
    exit 1
  fi
  # `git-remove-branch-directory` deletes a branch only if this mark says
  # that this package created it for its worktree.  Without the mark, the
  # branch merely outlives its worktree.
  if ! git -C "${add_worktree_repo}" config "branch.${add_worktree_branch}.createdForBranchDirectory" true; then
    echo "${SCRIPT_NAME}: warning: cannot mark the branch ${add_worktree_branch}, so git-remove-branch-directory will keep it" >&2
  fi
}

## Usage: has_gitlinks [TREE-ISH]
## Succeeds if TREE-ISH, or the index of the current working tree if TREE-ISH
## is omitted, contains a submodule, which git records as a gitlink, an entry
## of mode 160000.  This is the question that matters for making a worktree,
## rather than whether `.gitmodules` exists:  that file can outlive the last
## submodule, and the working tree that this command runs in can hold
## submodules that the branch to be checked out does not, or the reverse.
##
## A TREE-ISH or index without `.gitmodules` is answered without listing all
## of it, which in a large repository is slow:  a gitlink without that file
## is a submodule that `git submodule` cannot set up, and nearly every tree
## without the file has no gitlink.  `:.gitmodules` names the index's entry.
has_gitlinks() {
  if [ "$#" -eq 0 ]; then
    git cat-file -e :.gitmodules 2> /dev/null \
      && git ls-files --stage | grep -q '^160000 '
  else
    git cat-file -e "$1:.gitmodules" 2> /dev/null \
      && git ls-tree -r "$1" | grep -q '^160000 '
  fi
}

## Usage: note_copy_for_submodules WHAT
## Says that WHAT has submodules, so that the new directory is a full copy of
## the current one rather than a worktree, because git does not support a
## submodule in more than one worktree.  `git-new-branch` and
## `git-checkout-branch` print this note before `check_git_dir_is_directory`
## decides whether the current directory can be copied, so that a refusal
## follows the reason for the copy.
note_copy_for_submodules() {
  echo "${SCRIPT_NAME}: $1 has submodules, which a worktree cannot hold, so the new directory is a full copy of this one, as with --copy." >&2
}

## Usage: copy_repository DESTINATION [BRANCH]
## Copies the current directory, the top level of a working tree whose `.git`
## is a directory, to DESTINATION, which must not exist, so that DESTINATION
## is an independent clone.  BRANCH is the branch that the caller will check
## out in the copy, if it is an existing one.  Exits on failure.
##
## `.git/worktrees` is not copied.  It holds the registrations of this
## repository's linked worktrees, which belong to this repository alone:  in
## the copy they would make git refuse to check out those worktrees'
## branches, let `git worktree remove` run from the copy delete those
## worktrees, and make git-remove-branch-directory refuse to remove the copy.
## `git worktree prune` would not remove them, because the worktrees exist.
## It is left out rather than copied and removed, because each worktree's
## administrative directory holds that worktree's index and the repositories
## of its submodules, which can be large.
##
## The branches that `add_worktree` created for those worktrees, which
## `branch.NAME.createdForBranchDirectory` marks, except BRANCH and the
## branch that HEAD names.  They belong to the other branch directories, and
## their commits remain in this repository; in the copy, their unpushed
## commits would make git-remove-branch-directory refuse to remove the copy.
## So they are deleted from the copy.
copy_repository() {
  if ! mkdir -- "$1"; then
    echo "${SCRIPT_NAME}: ERROR: cannot create $1" >&2
    exit 1
  fi
  copy_working_tree "$1" .git/worktrees
  copy_repository_head="$(current_branch "$1")" || copy_repository_head=''
  # `--bool` normalizes the value, and git prints the key in lower case.
  copy_repository_marked="$(git -C "$1" config --bool --get-regexp \
    '^branch\..*\.createdforbranchdirectory$' \
    | sed -n 's/^branch\.\(.*\)\.createdforbranchdirectory true$/\1/p')"
  printf '%s\n' "${copy_repository_marked}" \
    | while IFS= read -r copy_repository_branch; do
      case "${copy_repository_branch}" in
        '' | "${2-}" | "${copy_repository_head}") continue ;;
      esac
      if ! git -C "$1" update-ref -d "refs/heads/${copy_repository_branch}" \
        || ! git -C "$1" config --remove-section "branch.${copy_repository_branch}"; then
        echo "${SCRIPT_NAME}: ERROR: cannot delete the branch ${copy_repository_branch} from $1" >&2
        exit 1
      fi
    done || exit 1
}

## Usage: copy_working_tree DESTINATION [OMIT]
## Copies the contents of the current directory, the top level of a working
## tree, into the existing directory DESTINATION, except the entry OMIT, a
## pathname relative to the current directory, and each worktree of this
## repository that is nested in the current directory.  Says on standard error
## which nested worktrees it leaves out.  Exits on failure.
##
## A worktree's `.git` is a file that names its administrative directory, and
## a copy would keep that file unchanged, so the copy of a nested worktree
## would name the *same* administrative directory as the original:  a commit
## or a checkout in the copy would move the original's HEAD and rewrite its
## index.  It is left out of the copy rather than copied and removed, because
## a nested worktree, such as one in `.claude/worktrees/NAME`, holds a working
## tree of its own, build output included, which can be large.
copy_working_tree() {
  if ! copy_working_tree_top="$(physical_path .)" \
    || ! copy_working_tree_nested="$(nested_worktrees "${copy_working_tree_top}")"; then
    echo "${SCRIPT_NAME}: ERROR: cannot list the worktrees of $(pwd)" >&2
    exit 1
  fi
  copy_working_tree_omit="${2-}"
  if [ -n "${copy_working_tree_nested}" ]; then
    printf '%s\n' "${copy_working_tree_nested}" | while IFS= read -r copy_working_tree_rel; do
      if [ -e "${copy_working_tree_rel}" ] || [ -L "${copy_working_tree_rel}" ]; then
        echo "${SCRIPT_NAME}: not copying ${copy_working_tree_rel}, which is a worktree of its own" >&2
      fi
    done
    copy_working_tree_omit="${copy_working_tree_omit:+${copy_working_tree_omit}
}${copy_working_tree_nested}"
  fi
  if ! copy_tree_into . "$1" '' "${copy_working_tree_omit}"; then
    echo "${SCRIPT_NAME}: ERROR: cannot copy $(pwd) to $1" >&2
    exit 1
  fi
}

## Usage: copy_tree_into SOURCE DESTINATION PREFIX OMIT
## Copies each entry of the directory SOURCE into the existing directory
## DESTINATION, except those named in OMIT, a list of pathnames relative to
## the top of the copy, one per line; PREFIX is SOURCE's pathname relative to
## that top, empty or ending in "/".  Returns 1, after a diagnostic from `cp`
## or `mkdir`, on failure.
##
## An entry that is neither omitted nor an ancestor of an omitted one is copied
## whole, by `cp -Rp`, which copies a symbolic link as a link.  An ancestor of
## an omitted entry is created with `mkdir` and filled by recursion; its
## modification time is copied, but `mkdir` gives it the default permissions.
## The body is a subshell, so that the recursion's variables are its own.
##
## The globs begin with SOURCE, which is "." or begins with "./", so that an
## entry whose name begins with "-" cannot be read as an option; between them
## they name every entry, and "." and ".." are skipped by name.  A pattern
## that matches nothing is left unexpanded, and names no entry; testing `-L`
## as well as `-e` keeps a dangling symbolic link, which is an entry.
copy_tree_into() (
  for entry in "$1"/* "$1"/.*; do
    name="${entry##*/}"
    case "${name}" in '.' | '..') continue ;; esac
    if [ ! -e "${entry}" ] && [ ! -L "${entry}" ]; then continue; fi
    rel="$3${name}"
    # The shell splits OMIT on newlines, with globbing off so that no line is
    # expanded; the patterns are quoted, so that a line is matched literally.
    # This forks nothing, which matters because it runs for every entry.
    relation=''
    saved_ifs="${IFS}"
    IFS='
'
    set -f
    for omitted in $4; do
      case "${omitted}" in
        "${rel}")
          relation='omitted'
          break
          ;;
        "${rel}"/*) relation='ancestor' ;;
      esac
    done
    set +f
    IFS="${saved_ifs}"
    case "${relation}" in
      omitted) continue ;;
      ancestor)
        if [ -d "${entry}" ] && [ ! -L "${entry}" ]; then
          mkdir -- "$2/${name}" || exit 1
          copy_tree_into "${entry}" "$2/${name}" "${rel}/" "$4" || exit 1
          touch -r "${entry}" -- "$2/${name}" || exit 1
          continue
        fi
        ;;
    esac
    \cp -Rp -- "${entry}" "$2/" || exit 1
  done
)

## Usage: nested_worktrees DIRECTORY
## Prints, one per line, the pathname relative to DIRECTORY of each registered
## worktree of the repository that contains DIRECTORY, whether its directory
## exists or not, that lies strictly within DIRECTORY.  DIRECTORY must be a
## physical pathname, as `physical_path` prints, because git registers a
## worktree under one.  Returns 1 if git cannot list the worktrees.
##
## Asking git, rather than searching DIRECTORY for nested `.git` files, costs
## nothing in a directory full of build output.  It finds the worktrees of
## this repository only, which is where a nested one comes from:  a tool such
## as Claude Code adds a worktree in an ignored directory such as
## `.claude/worktrees/NAME`.  A pathname that contains a newline cannot be
## represented in `git worktree list --porcelain`, and one that does is
## pathological.
nested_worktrees() {
  nested_worktrees_list="$(git -C "$1" worktree list --porcelain)" || return 1
  printf '%s\n' "${nested_worktrees_list}" | sed -n 's/^worktree //p' \
    | while IFS= read -r nested_worktrees_dir; do
      case "${nested_worktrees_dir}" in
        "$1"/*) printf '%s\n' "${nested_worktrees_dir#"$1"/}" ;;
      esac
    done
}

## Usage: check_git_dir_is_directory DIRECTORY [ACCEPT]
## Tests whether DIRECTORY, the top level of a working tree, holds its own
## repository:  that is, whether DIRECTORY/.git is a directory and is not a
## symbolic link to one.  Returns 0 if it is.  Otherwise prints a diagnostic
## that says where to run the command instead, and returns 1.  If ACCEPT is
## "linked-worktree", a linked worktree is accepted as well, by a caller that
## does not copy `.git`.
##
## `git-new-branch --copy`, and both branch commands when the new directory
## would hold submodules, copy the top level with `cp -Rp`, which copies
## `.git` along with everything else.  That is the design when `.git` is a
## directory:  the copy is an independent clone.  When
## `.git` is a *file* that names a git directory elsewhere, the copy names the
## **same** git directory as the original -- a relative `gitdir:` resolves to
## the same place from a sibling directory, and an absolute one names it
## outright -- so the two working trees share one HEAD and one index, and the
## `git checkout` that follows moves the *source's* HEAD and rewrites the
## *source's* index.  That is data loss in a working tree that the user did
## not name, so refuse before anything else happens.
##
## Three kinds of working tree have such a `.git`:  a submodule's; a linked
## worktree made by `git worktree add`; and the working tree of a repository
## made with `--separate-git-dir`, which is a main working tree whose git
## directory merely lies elsewhere.  Their remedies differ, so the diagnostic
## says which one this is.
##
## `git rev-parse --show-superproject-working-tree` recognizes a submodule:
## it prints a path in a submodule's working tree and nothing in the other
## two.  `--git-dir` and `--git-common-dir` then tell the other two apart:
## they differ in a linked worktree, whose git directory is a subdirectory of
## the repository that the main working tree holds, and they are equal when
## the whole git directory is what lies elsewhere, because a git directory
## that has no `commondir` file is its own common directory.  That equal case
## prints one path twice, and the unequal case names two different
## directories, so comparing the two as strings is enough.  A query that
## fails leaves the distinction unavailable; the diagnostic then says only
## that the git directory lies elsewhere, which is the part that is certain.
##
## `git worktree list` names the main working tree, and is worth consulting
## only for a linked worktree:  the other kinds have no other working tree to
## send the user to.  Even then its first entry is not always a working tree.
## Git takes the main working tree to be the parent of the git directory, so
## for a repository made with `--separate-git-dir` it prints the git directory
## itself, which is no place to run this command.  An entry counts only if it
## has a `.git` of its own, and naming it is a convenience in any case; the
## advice stands without it.
##
## The test is "`.git` is not a directory" rather than a comparison of git
## directories.  `--git-dir` differs from `--git-common-dir` in a linked
## worktree but not in a submodule, whose two are equal, so that comparison
## would miss the submodule.
##
## A `.git` that is a *symbolic link* to a directory answers `-d`, which
## follows links, but it is no safer than a `.git` file:  `cp -Rp` copies the
## link itself rather than what it names, so the copy's `.git` names the same
## git directory that the original's does -- a relative target such as
## `../gitdir` resolves to the same place from the sibling copy, and an
## absolute one names it outright.  So the test is `-d` *and* not `-L`.  A
## link whose target lies inside the working tree would in fact give the copy
## a git directory of its own, but nobody relocates a git directory to a place
## that travels with the working tree; refusing that unlikely case costs a
## message, and letting it through would cost a HEAD and an index.
##
## A top level that holds no `.git` at all is not the innocent case it looks
## like.  Git found the repository some other way -- GIT_DIR and
## GIT_WORK_TREE in the environment, or `core.worktree` in a git directory
## elsewhere -- and that way names one git directory no matter which working
## tree a command runs in.  The copy therefore holds no repository, while the
## `git checkout` that follows still finds the original's git directory and
## moves the original's HEAD.  So an absent `.git` is refused rather than
## waved through.
check_git_dir_is_directory() {
  if [ -d "$1/.git" ] && [ ! -L "$1/.git" ]; then
    return 0
  fi
  # Before `-e`, which follows links and so answers "no" for a dangling one.
  if [ -L "$1/.git" ]; then
    # An empty answer -- from a system that has no `readlink`, or from a link
    # that this process cannot read -- leaves the target out of the message,
    # which the remedy does not depend on.
    check_git_dir_target="$(readlink -- "$1/.git" 2> /dev/null)"
    if [ -n "${check_git_dir_target}" ]; then
      check_git_dir_target=" that names ${check_git_dir_target}"
    fi
    echo "${SCRIPT_NAME}: ERROR: $1 has a .git that is a symbolic link${check_git_dir_target}, rather than a directory." >&2
    echo "${SCRIPT_NAME}: A copy of it would share this working tree's git directory, so the checkout would move this working tree's HEAD and rewrite its index." >&2
    echo "${SCRIPT_NAME}: Run ${SCRIPT_NAME} in a clone whose .git is a directory instead." >&2
    return 1
  fi
  if [ ! -e "$1/.git" ]; then
    echo "${SCRIPT_NAME}: ERROR: $1 has no .git, so its git directory is named by configuration elsewhere, such as core.worktree." >&2
    echo "${SCRIPT_NAME}: A copy of it would hold no repository, and the checkout would move this working tree's HEAD and rewrite its index." >&2
    echo "${SCRIPT_NAME}: Run ${SCRIPT_NAME} in a working tree that holds its own .git directory." >&2
    return 1
  fi
  check_git_dir_known=1
  check_git_dir_superproject="$(git -C "$1" rev-parse \
    --show-superproject-working-tree 2> /dev/null)" || check_git_dir_known=
  if [ -n "${check_git_dir_superproject}" ]; then
    echo "${SCRIPT_NAME}: ERROR: $1 is the working tree of a submodule, whose .git is a file rather than a directory." >&2
    echo "${SCRIPT_NAME}: A copy of it would share this working tree's git directory, so the checkout would move this working tree's HEAD and rewrite its index." >&2
    echo "${SCRIPT_NAME}: Run ${SCRIPT_NAME} in the superproject ${check_git_dir_superproject} instead, whose branches are the ones worth branching." >&2
    return 1
  fi
  check_git_dir_gitdir="$(git -C "$1" rev-parse --git-dir 2> /dev/null)"
  check_git_dir_common="$(git -C "$1" rev-parse --git-common-dir 2> /dev/null)"
  if [ -z "${check_git_dir_gitdir}" ] || [ -z "${check_git_dir_common}" ] \
    || [ -z "${check_git_dir_known}" ]; then
    echo "${SCRIPT_NAME}: ERROR: $1 has a .git that is a file rather than a directory, so its git directory lies elsewhere." >&2
    echo "${SCRIPT_NAME}: A copy of it would share this working tree's git directory, so the checkout would move this working tree's HEAD and rewrite its index." >&2
    echo "${SCRIPT_NAME}: Run ${SCRIPT_NAME} in a working tree whose .git is a directory instead." >&2
    return 1
  fi
  if [ "${check_git_dir_gitdir}" = "${check_git_dir_common}" ]; then
    echo "${SCRIPT_NAME}: ERROR: $1 is a working tree whose .git is a file that names the git directory ${check_git_dir_gitdir}, rather than a directory." >&2
    echo "${SCRIPT_NAME}: A copy of it would share this working tree's git directory, so the checkout would move this working tree's HEAD and rewrite its index." >&2
    echo "${SCRIPT_NAME}: Run ${SCRIPT_NAME} in a clone whose .git is a directory instead." >&2
    return 1
  fi
  if [ "${2-}" = 'linked-worktree' ]; then
    return 0
  fi
  echo "${SCRIPT_NAME}: ERROR: $1 is a linked worktree, whose .git is a file rather than a directory." >&2
  echo "${SCRIPT_NAME}: A copy of it would share this worktree's git directory, so the checkout would move this worktree's HEAD and rewrite its index." >&2
  # The main working tree is the first entry that `git worktree list` prints.
  check_git_dir_main="$(git -C "$1" worktree list --porcelain 2> /dev/null \
    | sed -n '1s/^worktree //p')"
  if [ -n "${check_git_dir_main}" ] && [ -e "${check_git_dir_main}/.git" ]; then
    echo "${SCRIPT_NAME}: Run ${SCRIPT_NAME} in the main working tree ${check_git_dir_main} instead." >&2
  else
    echo "${SCRIPT_NAME}: Run ${SCRIPT_NAME} in the main working tree instead." >&2
  fi
  return 1
}

## Usage: remote_is_usable DIRECTORY REMOTES NAME
## Tests whether NAME names a remote that a git command run in DIRECTORY can
## contact.  REMOTES is the output of `git remote` in the clone in question:
## the names of its remotes, one per line.
##
## Configuration can name a remote that a clone does not have.
## `remote.pushDefault` in particular is a default for every branch of every
## clone, commonly set once in ~/.gitconfig to name a fork; in a clone that has
## no such remote, it names a remote that only some other clone has.  A query
## about such a name fails, which would silently disable a check, and a
## diagnostic that names it hides the actual problem.  So `push_remote` skips
## such a name and considers the next possibility.
##
## Git accepts a URL or a pathname wherever it accepts a remote's name, and
## permits one as the value of `branch.BRANCH.remote` or `remote.pushDefault`
## -- `git push --set-upstream ../other.git BRANCH` writes one there -- so
## those count as usable as well.  A string that contains ":" is an scp-style
## or a scheme-style URL, and "~" begins a pathname in the shell syntax that
## git accepts for a local repository.  A string that contains "/" is a
## pathname only if it names a repository:  git does accept "/" in the name of
## a remote (`git remote add team/fork URL` succeeds), so a slash does not by
## itself distinguish a pathname from the name of a remote that this clone
## lacks, and only the file system does.  A relative pathname is resolved in
## DIRECTORY, where git resolves the ones it is given.
##
## Merely existing is not enough.  A file or a directory of that name is
## commonplace -- a working tree that contains a directory named "upstream"
## would make `remote.pushDefault = upstream` look usable in a clone whose
## only remote is "origin" -- and a query to such a "remote" fails in exactly
## the way that this function exists to prevent.  A bundle file does not count
## either:  git can fetch from one, but this package's callers push to the
## remote they choose, or advise the user to.
##
## A string that contains no "/" is not a pathname at all here, even when a
## repository of that name lies in DIRECTORY.  Git would resolve such a name
## as a relative pathname, having no remote of that name, but a repository
## nested in a working tree is commonplace -- a submodule, or a vendored
## clone, in a directory named "upstream" or "fork" -- and it is not the fork
## that `remote.pushDefault` names.  Pushing a branch into the submodule is
## the same class of failure as pushing to a name that no repository has, so
## such a name is skipped like any other name that this clone lacks.  A value
## that is meant as a relative pathname says so with a "/", as "./upstream"
## and "../other.git" do.
remote_is_usable() {
  if [ -z "$3" ]; then
    return 1
  fi
  if printf '%s\n' "$2" | grep -q -x -F -- "$3"; then
    return 0
  fi
  case "$3" in
    *:* | '~'*) return 0 ;;
    /*) remote_is_usable_path="$3" ;;
    */*) remote_is_usable_path="$1/$3" ;;
    # A name with no "/" in it is the name of a remote, not a pathname.
    *) return 1 ;;
  esac
  # `git rev-parse --resolve-git-dir` tests the one directory it is given,
  # rather than searching the parent directories as most git commands do, so a
  # plain directory within a working tree does not pass as the repository that
  # contains it.  A pathname may name a working tree, whose repository is its
  # ".git" (a directory, or a file that names one elsewhere), or a bare
  # repository, which is itself the repository.
  if git rev-parse --resolve-git-dir "${remote_is_usable_path}/.git" > /dev/null 2>&1 \
    || git rev-parse --resolve-git-dir "${remote_is_usable_path}" > /dev/null 2>&1; then
    return 0
  fi
  return 1
}

## Usage: is_remote_name DIRECTORY NAME
## Tests whether NAME is the name of a remote of the clone in DIRECTORY, as
## opposed to the URL or the pathname of a repository, which git accepts
## wherever it accepts a remote's name and which `push_remote` and
## `fetch_remote` therefore report when that is what the configuration says.
##
## Only a named remote has a remote-tracking namespace:  `git fetch URL`
## records no remote-tracking branch, so a caller that fetches into that
## namespace has to know which kind of value it has.
is_remote_name() {
  git -C "$1" remote | grep -q -x -F -- "$2"
}

## Usage: remote_consider NAME
## A helper for `push_remote`, `fetch_remote`, and `upstream_remote`:
## sets ${remote_result} to NAME if ${remote_result} is not set yet and NAME is
## a remote that the clone in ${remote_dir} can contact.
remote_consider() {
  if [ -z "${remote_result}" ] \
    && remote_is_usable "${remote_dir}" "${remote_remotes}" "$1"; then
    remote_result="$1"
  fi
}

## Usage: remote_consider_sole
## A helper for `push_remote`, `fetch_remote`, and `upstream_remote`:
## sets ${remote_result} to the sole remote of the clone in ${remote_dir}, if
## ${remote_result} is not set yet and that clone has exactly one remote.
## Such a clone has no remote named "origin", because
## `remote_consider origin` would have accepted it, but its one remote is the
## only remote that any branch of it could come from or go to.
remote_consider_sole() {
  if [ -z "${remote_result}" ] \
    && [ "$(printf '%s\n' "${remote_remotes}" | grep -c '.')" -eq 1 ]; then
    remote_result="${remote_remotes}"
  fi
}

## Usage: push_remote DIRECTORY BRANCH
## Prints the name of the remote that `git push` in DIRECTORY would use for
## BRANCH, or nothing if the clone in DIRECTORY determines no remote for it.
## BRANCH may be empty, which means that no branch is checked out (HEAD is
## detached), so only the clone's branch-independent configuration applies.
##
## The order is `branch.BRANCH.pushRemote`, then `branch.BRANCH.remote`, then
## `remote.pushDefault`, then "origin", then the clone's only remote if it has
## exactly one.  A value that names a remote the clone cannot contact does not
## count; see `remote_is_usable`.
##
## Consult `branch.BRANCH.remote` before `remote.pushDefault`, unlike
## `git push`.  Both `branch.BRANCH.pushRemote` and `branch.BRANCH.remote` say
## something about this branch, whereas `remote.pushDefault` is a default for
## every branch of every clone, commonly set once in ~/.gitconfig to name a
## fork.  Letting that default outrank this branch's own upstream would discard
## what this clone records about the branch.
push_remote() {
  remote_dir="$1"
  remote_branch="$2"
  remote_remotes="$(git -C "${remote_dir}" remote)"
  remote_result=''
  if [ -n "${remote_branch}" ]; then
    remote_consider \
      "$(git -C "${remote_dir}" config --get "branch.${remote_branch}.pushRemote")"
    remote_consider \
      "$(git -C "${remote_dir}" config --get "branch.${remote_branch}.remote")"
  fi
  remote_consider "$(git -C "${remote_dir}" config --get remote.pushDefault)"
  # Git uses the remote named "origin" when no configuration names a remote.
  remote_consider 'origin'
  remote_consider_sole
  printf '%s\n' "${remote_result}"
}

## Usage: fetch_remote DIRECTORY BRANCH
## Prints the name of the remote that `git fetch` in DIRECTORY would use for
## BRANCH, or nothing if the clone in DIRECTORY determines no remote for it.
## BRANCH may be empty, which means that no branch is checked out (HEAD is
## detached), so only the clone's branch-independent configuration applies.
##
## The order is `branch.BRANCH.remote`, then "origin", then the clone's only
## remote if it has exactly one.  A value that names a remote the clone cannot
## contact does not count; see `remote_is_usable`.
##
## This is not `push_remote`, and a command that reads from a remote must not
## use that one.  `branch.BRANCH.pushRemote` and `remote.pushDefault` say
## where a branch is pushed and say nothing about where the clone's branches
## come from; in the fork workflow they name the user's fork, while the
## project's branches are fetched from a different remote.  Asking the fork
## whether some branch of the project exists gets the wrong answer.
fetch_remote() {
  remote_dir="$1"
  remote_branch="$2"
  remote_remotes="$(git -C "${remote_dir}" remote)"
  remote_result=''
  if [ -n "${remote_branch}" ]; then
    remote_consider \
      "$(git -C "${remote_dir}" config --get "branch.${remote_branch}.remote")"
  fi
  # Git uses the remote named "origin" when no configuration names a remote.
  remote_consider 'origin'
  remote_consider_sole
  printf '%s\n' "${remote_result}"
}

## Usage: current_branch [DIRECTORY]
## Prints the name of the branch that is checked out in DIRECTORY, or in the
## current directory, such as "main".  Returns 1, printing nothing, if HEAD is
## detached or the directory is not in a git repository.  It prints the
## branch's own name even when another ref, such as a tag "main", has the same
## short name; `git symbolic-ref --short HEAD` would then print "heads/main".
current_branch() {
  current_branch_ref="$(git -C "${1:-.}" symbolic-ref --quiet HEAD 2> /dev/null)" \
    || return 1
  printf '%s\n' "${current_branch_ref#refs/heads/}"
}

## Usage: check_upstream DIRECTORY
## Tests whether the working tree DIRECTORY has an upstream branch, which
## `git pull` and `git push` require.  If it does not, prints an explanation
## and returns 1.
##
## Also sets ${checked_out_branch} to the name of the branch that the
## directory has checked out, or to the empty string if HEAD is detached or
## the directory is not a working tree.  It is the local branch, not the
## upstream branch that this function is named for; the two can differ.  A
## caller that fetches into or merges into that branch, as `git-push-to` does,
## can use this name rather than determine it again.
check_upstream() {
  # If the directory is not a working tree, or HEAD is detached, let a
  # subsequent command diagnose that, as `check_branch_exists` in
  # `git-push-to` does accurately.  `git rev-parse --abbrev-ref HEAD`, by
  # contrast, prints "HEAD" for a detached HEAD, which this function would
  # then report as a branch name.
  checked_out_branch="$(current_branch "$1")" || return 0
  check_upstream_remote="$(git -C "$1" config --get "branch.${checked_out_branch}.remote")"
  check_upstream_merge="$(git -C "$1" config --get-all "branch.${checked_out_branch}.merge")"
  if [ -n "${check_upstream_remote}" ] && [ -n "${check_upstream_merge}" ]; then
    return 0
  fi
  echo "${SCRIPT_NAME}: branch ${checked_out_branch} in $1 has no upstream branch, so it cannot be pulled or pushed" >&2
  return 1
}

## Usage: upstream_remote [DIRECTORY]
## Prints the name of the remote of the clone in DIRECTORY (by default, the
## current directory) that is the upstream repository:  the remote named
## "upstream" if the clone has one, as a fork does, then "origin", then the
## clone's only remote if it has exactly one.  Returns 1, after printing a
## diagnostic, if there is no such remote.
upstream_remote() {
  remote_dir="${1:-.}"
  if ! remote_remotes="$(git -C "${remote_dir}" remote)"; then
    return 1
  fi
  remote_result=''
  remote_consider 'upstream'
  remote_consider 'origin'
  remote_consider_sole
  if [ -z "${remote_result}" ]; then
    echo "${SCRIPT_NAME}: no remote named \"upstream\" or \"origin\", and not exactly one remote" >&2
    return 1
  fi
  printf '%s\n' "${remote_result}"
}

## Usage: upstream_default_branch REMOTE FETCH [BATCH]
## Prints the full name of the remote-tracking branch for the default branch of
## the remote REMOTE, such as `refs/remotes/upstream/master`.  If FETCH is 1,
## fetches REMOTE first and updates `REMOTE/HEAD` to name the remote's default
## branch, which replaces a `REMOTE/HEAD` that was set by hand.  Otherwise,
## sets `REMOTE/HEAD` with `git remote set-head REMOTE --auto` only if it does
## not exist or names a branch that does not exist.  Returns 1, after printing
## a diagnostic, on failure.
##
## If BATCH is 1, the git commands that contact REMOTE run under
## `git_batch_ssh`, so that they fail rather than prompt.
upstream_default_branch() {
  upstream_default_branch_remote="$1"
  upstream_default_branch_batch="${3:-0}"
  # `REMOTE/HEAD` does not exist after `git remote add`.  After the remote
  # renames its default branch, `REMOTE/HEAD` still names the old branch.  A
  # fetch without `--prune` keeps that remote-tracking branch, frozen at its
  # last commit, so only asking the remote reveals the rename.  A fetch with
  # `--prune` deletes it, so that `REMOTE/HEAD` names a branch that does not
  # exist.
  #
  # With `remote.REMOTE.followRemoteHEAD` set to "always", git 2.48 and later
  # update `REMOTE/HEAD` during the fetch, over the same connection.  An
  # earlier git ignores that setting, so after fetching it needs
  # `git remote set-head --auto`, which connects to the remote again.
  upstream_default_branch_head="refs/remotes/${upstream_default_branch_remote}/HEAD"
  upstream_default_branch_ask=0
  if [ "$2" -eq 1 ]; then
    if ! git_maybe_batch "${upstream_default_branch_batch}" \
      -c "remote.${upstream_default_branch_remote}.followRemoteHEAD=always" \
      fetch --quiet "${upstream_default_branch_remote}"; then
      echo "${SCRIPT_NAME}: problem fetching ${upstream_default_branch_remote}" >&2
      return 1
    fi
    if ! git_at_least 48; then
      upstream_default_branch_ask=1
    fi
  fi
  if [ "${upstream_default_branch_ask}" -eq 1 ] \
    || ! upstream_default_branch_branch="$(git symbolic-ref --quiet "${upstream_default_branch_head}")" \
    || ! git rev-parse --verify --quiet "${upstream_default_branch_branch}" > /dev/null; then
    if ! git_maybe_batch "${upstream_default_branch_batch}" remote set-head "${upstream_default_branch_remote}" --auto > /dev/null \
      || ! upstream_default_branch_branch="$(git symbolic-ref --quiet "${upstream_default_branch_head}")"; then
      echo "${SCRIPT_NAME}: cannot determine the default branch of ${upstream_default_branch_remote}" >&2
      return 1
    fi
  fi
  printf '%s\n' "${upstream_default_branch_branch}"
}

## Usage: git_maybe_batch BATCH GIT-ARGUMENT...
## Runs `git GIT-ARGUMENT...` in the current directory, under `git_batch_ssh`
## if BATCH is 1, so that a command that contacts a remote fails rather than
## prompts.
git_maybe_batch() {
  git_maybe_batch_flag="$1"
  shift
  if [ "${git_maybe_batch_flag}" -eq 1 ]; then
    git_batch_ssh . "$@"
  else
    git "$@"
  fi
}

## Usage: find_upstream_ref FETCH [BATCH]
## Sets ${upstream_ref} to the full name of the ref for the default branch of
## the upstream repository of the clone in the current directory, such as
## `refs/remotes/upstream/master`.  Sets ${upstream_source} to the name of the
## remote that the ref belongs to, such as "upstream", or to the URL that the
## ref was fetched from.  Sets ${upstream_is_parent} to 1 if the upstream
## repository is another repository than the remote that `upstream_remote`
## chooses, such as a fork's upstream repository, as described below, and to
## 0 otherwise.  Sets ${upstream_slug} to the GitHub slug, such as
## "ORG/PROJ", of the upstream repository, or to the empty string if it is
## not on GitHub.
##
## The upstream repository is the remote that `upstream_remote` chooses,
## unless that remote is not named "upstream" and one of these names another
## repository:
##  * The setting `remote.REMOTE.gh-resolved` of some remote REMOTE, which
##    names the repository that `gh` uses by default (see `gh_resolved`):
##    either a GitHub repository, such as ORG/PROJ, or REMOTE itself.
##  * Otherwise, `fork_upstream`, if the chosen remote is a GitHub
##    repository, such as ME/PROJ, whose upstream repository is another, such
##    as ORG/PROJ.
## A GitHub repository ORG/PROJ is the clone's remote whose URL names
## ORG/PROJ, if there is one.  Otherwise, if the chosen remote is a GitHub
## repository, it is the repository at the URL that has the same form as the
## chosen remote's, such as "git@github.com:ORG/PROJ.git" for
## "git@github.com:ME/PROJ.git".  The default branch at such a URL is fetched
## into the ref `refs/fork-upstream/ORG/PROJ`, in lower case, rather than into
## a remote-tracking branch, and without the URL's tags, so the clone gains no
## remote and no tag.  Otherwise, the upstream repository is the chosen
## remote.
##
## FETCH and BATCH are as for `upstream_default_branch`.  If FETCH is 0,
## such a URL is not fetched, and the ref that an earlier call fetched it into
## is used.  If the URL cannot be fetched, or FETCH is 0 and no earlier call
## fetched it, prints a diagnostic and uses the remote that `upstream_remote`
## chooses.  Returns 1, after printing a diagnostic, on failure.
find_upstream_ref() {
  find_parent_ref "$1" "${2:-0}"
  case "$?" in
    0) return 0 ;;
    2 | 3) upstream_ref="$(upstream_default_branch "${upstream_source}" "$1" "${2:-0}")" ;;
    *) return 1 ;;
  esac
}

## Usage: find_parent_ref FETCH [BATCH]
## Sets the variables that `find_upstream_ref` sets, and returns 0, if the
## upstream repository is another repository than the remote that
## `upstream_remote` chooses, as `find_upstream_ref` describes.  Otherwise,
## sets ${upstream_source} to the remote that `upstream_remote` chooses and
## ${upstream_is_parent} to 0, without fetching that remote, and returns:
##  * 2 if the upstream repository is that remote.
##  * 3, after printing a diagnostic, if the upstream repository might be
##    another one but its default branch is not available:  GitHub cannot be
##    asked which repository it is, or its URL cannot be fetched, or FETCH is
##    0 and no earlier call fetched it.
## FETCH and BATCH are as for `find_upstream_ref`.  Returns 1, after printing
## a diagnostic, on any other failure.
# shellcheck disable=SC2034 # set for the caller
find_parent_ref() {
  upstream_is_parent=0
  upstream_slug=''
  if ! upstream_source="$(upstream_remote)"; then
    return 1
  fi
  # A remote named "upstream" is the upstream repository by the clone's own
  # configuration, even if it is a fork.
  if [ "${upstream_source}" != upstream ]; then
    # `git remote get-url` applies `url.BASE.insteadOf`, which can map a
    # GitHub URL to a mirror or a local copy, so the configured URL might be
    # the one that names GitHub.  It can also map a shortcut, such as
    # "gh:ME/PROJ", to a GitHub URL, so the rewritten URL might be.
    fur_url="$(git config --get "remote.${upstream_source}.url")"
    fur_fork="$(github_slug "${fur_url}")"
    if [ -z "${fur_fork}" ]; then
      fur_url="$(git remote get-url "${upstream_source}")"
      fur_fork="$(github_slug "${fur_url}")"
    fi
    upstream_slug="${fur_fork}"
    fur_parent=''
    if gh_resolved .; then
      if [ "${gh_resolved_value}" = base ]; then
        if [ "${gh_resolved_remote}" != "${upstream_source}" ]; then
          upstream_ref="$(upstream_default_branch "${gh_resolved_remote}" "$1" "${2:-0}")" || return 1
          upstream_source="${gh_resolved_remote}"
          upstream_slug="$(remote_slug "${gh_resolved_remote}")"
          upstream_is_parent=1
          return 0
        fi
      else
        fur_parent="${gh_resolved_value}"
      fi
    elif [ -n "${fur_fork}" ]; then
      if ! fork_upstream "${fur_fork}" "$1"; then
        return 3
      fi
      fur_parent="${fork_upstream_repo}"
    fi
    if [ -n "${fur_parent}" ] \
      && fur_parent_lower="$(lowercase "${fur_parent}")" \
      && [ "${fur_parent_lower}" != "$(lowercase "${fur_fork}")" ]; then
      # GitHub ignores the case of a repository's name, so a remote's URL
      # might spell it differently than ${fur_parent} does.
      fur_remote="$(github_remote_slugs \
        | awk -v slug="${fur_parent_lower}" 'tolower($2) == slug { print $1; exit }')"
      if [ -n "${fur_remote}" ]; then
        upstream_ref="$(upstream_default_branch "${fur_remote}" "$1" "${2:-0}")" || return 1
        upstream_source="${fur_remote}"
        upstream_slug="${fur_parent}"
        upstream_is_parent=1
        return 0
      fi
      if [ -n "${fur_fork}" ]; then
        # `github_slug` recognized ${fur_url}, so it has an owner.
        split_repository_url "${fur_url}"
        case "${repo_url_repo}" in
          *.git) fur_suffix='.git' ;;
          *) fur_suffix='' ;;
        esac
        fur_parent_url="${repo_url_prefix}${fur_parent}${fur_suffix}"
        fur_ref="refs/fork-upstream/${fur_parent_lower}"
        if [ "$1" -eq 1 ]; then
          # Without `--no-tags`, the fetch would also create a local tag for
          # each of the URL's tags that points into the fetched history.
          if git_maybe_batch "${2:-0}" \
            fetch --quiet --no-tags "${fur_parent_url}" "+HEAD:${fur_ref}"; then
            upstream_ref="${fur_ref}"
            upstream_source="${fur_parent_url}"
            upstream_slug="${fur_parent}"
            upstream_is_parent=1
            return 0
          fi
          echo "${SCRIPT_NAME}: cannot fetch ${fur_parent_url}, the upstream repository of ${fur_fork}; using ${upstream_source} instead" >&2
          return 3
        elif git rev-parse --verify --quiet "${fur_ref}" > /dev/null; then
          upstream_ref="${fur_ref}"
          upstream_source="${fur_parent_url}"
          upstream_slug="${fur_parent}"
          upstream_is_parent=1
          return 0
        else
          echo "${SCRIPT_NAME}: ${fur_parent_url}, the upstream repository of ${fur_fork}, has not been fetched; using ${upstream_source} instead" >&2
          return 3
        fi
      fi
    fi
  else
    upstream_slug="$(remote_slug upstream)"
  fi
  return 2
}

## Usage: remote_slug REMOTE
## Prints the GitHub slug, such as "ORG/PROJ", of the repository that the
## remote REMOTE of the clone in the current directory names:  the one that
## its configured URL names, or, if that is not a GitHub URL, the one that the
## URL names as `url.BASE.insteadOf` rewrites it.  Prints nothing if neither
## is a GitHub URL.
remote_slug() {
  remote_slug_value="$(github_slug "$(git config --get "remote.$1.url")")"
  if [ -z "${remote_slug_value}" ]; then
    remote_slug_value="$(github_slug "$(git remote get-url "$1" 2> /dev/null)")"
  fi
  if [ -n "${remote_slug_value}" ]; then
    printf '%s\n' "${remote_slug_value}"
  fi
}

## Usage: fork_upstream FORK FETCH
## Sets ${fork_upstream_repo} to the GitHub slug, such as "ORG/PROJ", of the
## upstream repository of FORK, a GitHub repository's slug such as "ME/PROJ"
## (see `github_upstream`), or to the empty string if FORK is its own
## upstream repository or if the upstream repository is unknown.
##
## The answer is recorded in the git configuration variable
## `github-fork.FORK.upstream` of the clone in the current directory, with
## FORK in lower case, such as `github-fork.me/proj.upstream`, as a GitHub
## slug or as "none".  If that variable is set, by an earlier call or by hand
## to override this function's choice, uses its value.  Otherwise, if FETCH
## is 1, asks GitHub and records the answer.  GitHub is not asked if `gh` is
## not installed or has no token for github.com, as when no user has logged
## in with `gh auth login`.  Returns 1, after printing a diagnostic and
## recording nothing, if asking GitHub fails.
fork_upstream() {
  fork_upstream_repo=''
  fork_upstream_key="github-fork.$(lowercase "$1").upstream"
  if fork_upstream_value="$(git config --get "${fork_upstream_key}")"; then
    if [ "${fork_upstream_value}" != none ]; then
      fork_upstream_repo="${fork_upstream_value}"
    fi
    return 0
  fi
  if [ "$2" -ne 1 ] || ! gh_usable; then
    return 0
  fi
  if ! github_upstream "$1"; then
    echo "${SCRIPT_NAME}: to treat $1 as its own upstream repository without asking GitHub again, run:  git config ${fork_upstream_key} none" >&2
    return 1
  fi
  if [ "$(lowercase "${github_upstream_repo}")" = "$(lowercase "$1")" ]; then
    git config "${fork_upstream_key}" none
  else
    git config "${fork_upstream_key}" "${github_upstream_repo}"
    fork_upstream_repo="${github_upstream_repo}"
  fi
}

## Usage: gh_usable
## Returns 0 if `gh` is installed and has a token for github.com, and 1
## otherwise, as when no user has logged in with `gh auth login`.
gh_usable() {
  command -v gh > /dev/null 2>&1 \
    && gh auth token --hostname github.com > /dev/null 2>&1
}

## Usage: github_upstream REPO
## Sets ${github_upstream_repo} to the GitHub slug, such as "ORG/PROJ", of the
## upstream repository of REPO, a GitHub repository's slug such as
## "ME/PROJ", and sets ${github_upstream_default} to the name of REPO's
## default branch, such as "main", or to "-" if REPO has none, as an empty
## repository does.
##
## A fork that a user owns, such as ME/PROJ, holds pull requests for its
## parent, such as ORG/PROJ, which is its upstream repository.  A repository
## that is not a fork is its own upstream repository.  So is a fork that an
## organization owns, such as typetools/jdk (a fork of openjdk/jdk):  it is a
## downstream fork that carries its own changes, and its pull requests target
## it, not its parent.
##
## Asks GitHub with `gh`, which must be installed, unless an earlier call in
## the same process asked about REPO.  Returns 1, after printing a
## diagnostic, if GitHub cannot be asked.
github_upstream() {
  github_upstream_answer="$(printf '%s\n' "${github_upstream_cache}" \
    | awk -v repo="$1" '$1 == repo { print $2 " " $3; exit }')"
  if [ -z "${github_upstream_answer}" ]; then
    # The repository is named with its host, so that `gh` does not ask the
    # host that ${GH_HOST} names instead.
    github_upstream_answer="$(gh_query "cannot ask GitHub about $1" \
      gh repo view "github.com/$1" \
      --json owner,name,isInOrganization,parent,defaultBranchRef \
      --jq '"\(if .parent and (.isInOrganization | not) then "\(.parent.owner.login)/\(.parent.name)" else "\(.owner.login)/\(.name)" end) \(.defaultBranchRef.name // "-")"')" \
      || return 1
    case "${github_upstream_answer}" in
      ?*' '?*) ;;
      *)
        echo "${SCRIPT_NAME}: cannot ask GitHub about $1: unexpected answer [${github_upstream_answer}]" >&2
        return 1
        ;;
    esac
    github_upstream_cache="${github_upstream_cache}
$1 ${github_upstream_answer}"
  fi
  github_upstream_repo="${github_upstream_answer%% *}"
  # shellcheck disable=SC2034 # set for the caller
  github_upstream_default="${github_upstream_answer#* }"
}

## The answers that `github_upstream` has received.  Each line is
## "REPO UPSTREAM DEFAULT", as `github_upstream` describes them, so that every
## branch of a project, which asks about the same repository, asks GitHub
## only once.
github_upstream_cache=''

## Usage: gh_resolved DIRECTORY
## Sets ${gh_resolved_remote} to the name of a remote REMOTE of the clone in
## DIRECTORY that has the setting `remote.REMOTE.gh-resolved`, which
## `gh repo set-default` writes to name the repository that `gh` uses by
## default, and sets ${gh_resolved_value} to that setting:  either a GitHub
## slug, such as "ORG/REPO", or "base" for REMOTE itself.  If several remotes
## have the setting, uses the first that git lists.  Returns 1, after setting
## both to the empty string, if no remote has that setting.
gh_resolved() {
  # A remote's name contains no whitespace.
  gh_resolved_value="$(git -C "$1" config --get-regexp '^remote\..*\.gh-resolved$' | head -n 1)"
  gh_resolved_remote="${gh_resolved_value%% *}"
  gh_resolved_remote="${gh_resolved_remote#remote.}"
  gh_resolved_remote="${gh_resolved_remote%.gh-resolved}"
  gh_resolved_value="${gh_resolved_value#* }"
  [ -n "${gh_resolved_value}" ]
}

## Usage: shell_word STRING
## Prints STRING as a word that a POSIX shell reads as STRING:  unchanged if
## it consists only of characters that the shell does not interpret, as in
## "/home/me/myrepo", and otherwise in single quotes, as in
## "'/home/me/my repo'".
shell_word() {
  case "$1" in
    "" | *[!A-Za-z0-9_./:@%+=,-]*)
      printf "'%s'\n" "$(printf '%s' "$1" | sed -e "s/'/'\\\\''/g")"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

## Usage: run_with_time_limit SECONDS COMMAND [ARGUMENT...]
## Runs COMMAND with the ARGUMENTs and returns its exit status.  If COMMAND
## runs for more than SECONDS, sends it SIGTERM, and then SIGKILL if it is
## still running 10 seconds later.  SECONDS 0 means no limit.
##
## COMMAND runs in the foreground, so that an interrupt from the terminal,
## such as Ctrl-C, reaches it.  A shell starts a watchdog process, which
## knows the shell's process id, and then replaces itself with COMMAND.  The
## watchdog exits within a second after COMMAND does.
run_with_time_limit() {
  if [ "$1" -eq 0 ]; then
    shift
    "$@"
    return
  fi
  sh -c '
    limit="$1"
    shift
    command_pid=$$
    (
      elapsed=0
      while kill -0 "${command_pid}" 2> /dev/null; do
        if [ "${elapsed}" -ge "${limit}" ]; then
          kill -s TERM "${command_pid}" 2> /dev/null
          grace=0
          while [ "${grace}" -lt 10 ] && kill -0 "${command_pid}" 2> /dev/null; do
            sleep 1
            grace=$((grace + 1))
          done
          kill -s KILL "${command_pid}" 2> /dev/null
          exit 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
      done
    ) < /dev/null > /dev/null 2>&1 &
    exec "$@"' run_with_time_limit "$@"
}

## Usage: print_nul_lines COMMAND...
## Runs COMMAND, which writes items that each end with a NUL, as
## `git ls-files -z` writes pathnames, and prints the items one per line.  A
## newline within an item becomes the byte 001, so that an item such as a
## pathname that contains a newline is not split.  Returns the exit status of
## COMMAND.
print_nul_lines() {
  # A pipeline's status is that of its last command, so fd 3 carries the
  # status of COMMAND out of the command substitution, and fd 4 is the
  # function's standard output.
  {
    print_nul_lines_status="$({ {
      "$@" 3>&- 4>&-
      echo "$?" >&3
    } | tr '\n\000' '\001\n' >&4 3>&-; } 3>&1)"
  } 4>&1
  [ "${print_nul_lines_status}" = 0 ]
}

## Usage: untracked_files
## Prints, one per line, the files of the working tree that git does not track
## and does not ignore.  Returns the exit status of `git ls-files`.
untracked_files() {
  # As for `rwa_tracked` in `resolve_with_agent`, `-z` keeps git from
  # quoting a pathname.
  print_nul_lines git ls-files -z --others --exclude-standard
}

## Usage: ignored_files
## Prints, one per line, the files of the working tree that git ignores, with
## each directory that git ignores entirely as a single line.  A file that is
## created in such a directory does not change the output, but listing every
## file of a directory of build output would be slow.  So a caller checks
## only the names of ignored files, not their contents.
ignored_files() {
  git -c core.quotePath=false ls-files --others --ignored --exclude-standard --directory
}

## Usage: ssh_variant_of PROGRAM
## Prints the SSH variant that the command name PROGRAM denotes, or nothing if
## PROGRAM is not a command name that this file recognizes.
ssh_variant_of() {
  case "$(basename -- "$1")" in
    ssh | ssh.exe) echo 'ssh' ;;
    plink | plink.exe) echo 'plink' ;;
    putty | putty.exe) echo 'putty' ;;
  esac
}

## Usage: git_batch_ssh DIRECTORY GIT-ARGUMENT...
## Runs `git -C DIRECTORY GIT-ARGUMENT...` with every interactive prompt
## disabled, and returns its exit status.  DIRECTORY's clone also supplies the
## configuration (`core.sshCommand` and `ssh.variant`) that determines which
## SSH command git runs.
##
## A prompt would block forever when the caller runs from another script or
## from a CI job, or discards the command's standard error:  nobody sees the
## prompt, so nobody answers it.  `GIT_TERMINAL_PROMPT=0` makes an
## authentication failure an error rather than a prompt, but it does not
## suppress the prompts that SSH itself issues, such as the ones for an unknown
## host key or an encrypted key, so also pass SSH the option that disables
## those.  Git accepts several SSH implementations, and only OpenSSH accepts
## `-o`; Plink and Putty accept `-batch`.  When no variant is specified,
## recognize the standard command names and otherwise leave git's own variant
## detection in charge.
git_batch_ssh() {
  git_batch_ssh_dir="$1"
  shift

  if [ -z "${GIT_SSH_COMMAND:-}" ]; then
    unset GIT_SSH_COMMAND
  fi
  # `git config --get` exits 1 when the key is not set, which is not a
  # failure here but would abort a caller that runs under `set -e`.
  git_batch_ssh_command="${GIT_SSH_COMMAND:-$(git -C "${git_batch_ssh_dir}" config --get core.sshCommand || true)}"
  git_batch_ssh_variant="${GIT_SSH_VARIANT:-$(git -C "${git_batch_ssh_dir}" config --get ssh.variant || true)}"

  # The variant that ${git_batch_ssh_option} belongs to.
  git_batch_ssh_resolved_variant=''
  case "${git_batch_ssh_variant}" in
    ssh | plink | putty)
      git_batch_ssh_resolved_variant="${git_batch_ssh_variant}"
      ;;
    '' | auto)
      if [ -z "${git_batch_ssh_command}" ]; then
        if [ -z "${GIT_SSH:-}" ]; then
          # Git runs "ssh" when neither variable nor configuration names a
          # command.
          git_batch_ssh_resolved_variant='ssh'
        else
          # GIT_SSH is an executable path rather than a shell command.
          git_batch_ssh_resolved_variant="$(ssh_variant_of "${GIT_SSH}")"
        fi
      else
        # An SSH command is a shell command line, whose first word names the
        # program to run.
        git_batch_ssh_resolved_variant="$(ssh_variant_of "${git_batch_ssh_command%% *}")"
      fi
      ;;
  esac

  # The option that disables interactive prompts for the selected SSH
  # implementation.  OpenSSH's `-o BatchMode=yes` turns an authentication or
  # host-key prompt into a failure.  Plink's and Putty's `-batch` option
  # rejects any prompt that would require user input.
  git_batch_ssh_option=''
  case "${git_batch_ssh_resolved_variant}" in
    ssh)
      git_batch_ssh_option='-o BatchMode=yes'
      ;;
    plink | putty)
      git_batch_ssh_option='-batch'
      ;;
  esac

  if [ -z "${git_batch_ssh_option}" ]; then
    GIT_TERMINAL_PROMPT=0 git -C "${git_batch_ssh_dir}" "$@"
  elif [ -n "${git_batch_ssh_command}" ]; then
    GIT_TERMINAL_PROMPT=0 \
      GIT_SSH_COMMAND="${git_batch_ssh_command} ${git_batch_ssh_option}" \
      git -C "${git_batch_ssh_dir}" "$@"
  elif [ -n "${GIT_SSH:-}" ]; then
    # GIT_SSH is an executable path rather than a shell command.  A wrapper
    # adds the option without changing the way the path is parsed.
    # Git guesses the variant from the basename of GIT_SSH, and the wrapper's
    # basename is not one that git recognizes.  Without GIT_SSH_VARIANT, git
    # would guess the "simple" variant, which cannot pass a port or an address
    # family to SSH.
    MANAGE_GIT_BRANCHES_GIT_SSH="${GIT_SSH}"
    MANAGE_GIT_BRANCHES_SSH_BATCH_OPTION="${git_batch_ssh_option}"
    export MANAGE_GIT_BRANCHES_GIT_SSH MANAGE_GIT_BRANCHES_SSH_BATCH_OPTION
    GIT_TERMINAL_PROMPT=0 GIT_SSH="${SCRIPT_DIR}/git-ssh-batch-wrapper" \
      GIT_SSH_VARIANT="${git_batch_ssh_resolved_variant}" \
      git -C "${git_batch_ssh_dir}" "$@"
  else
    GIT_TERMINAL_PROMPT=0 \
      GIT_SSH_COMMAND="ssh ${git_batch_ssh_option}" \
      git -C "${git_batch_ssh_dir}" "$@"
  fi
}

## Usage: git_batch_ssh_capture DIRECTORY GIT-ARGUMENT...
## Runs `git_batch_ssh DIRECTORY GIT-ARGUMENT...` and returns its exit status.
## Sets ${git_batch_ssh_capture_output} to the command's standard output and
## ${git_batch_ssh_capture_error} to its standard error, such as "Host key
## verification failed.", each without trailing newlines.
##
## Standard error passes through a temporary file, because a command
## substitution captures only standard output.  If no temporary file can be
## created, the command still runs, its standard error is discarded, and
## ${git_batch_ssh_capture_error} says so instead.
##
## The results are returned in variables rather than printed, because one
## printed stream could not hold both of them distinguishably.
git_batch_ssh_capture() {
  git_batch_ssh_capture_file="$(mktemp "${TMPDIR:-/tmp}/${SCRIPT_NAME}-git.XXXXXX" \
    2> /dev/null)" || git_batch_ssh_capture_file=''
  if git_batch_ssh_capture_output="$(git_batch_ssh "$@" \
    2> "${git_batch_ssh_capture_file:-/dev/null}")"; then
    git_batch_ssh_capture_status=0
  else
    git_batch_ssh_capture_status="$?"
  fi
  if [ -n "${git_batch_ssh_capture_file}" ]; then
    git_batch_ssh_capture_error="$(cat -- "${git_batch_ssh_capture_file}")"
    rm -f -- "${git_batch_ssh_capture_file}"
  else
    git_batch_ssh_capture_error="(git's error output is unavailable, because no temporary file could be created in ${TMPDIR:-/tmp} to hold it)"
  fi
  return "${git_batch_ssh_capture_status}"
}

## Usage: physical_path DIRECTORY
## Prints the absolute pathname of DIRECTORY, with symbolic links resolved.
## Prints nothing and returns nonzero if DIRECTORY cannot be entered.
##
## `realpath` would be simpler, but POSIX added it only in 2024 and some
## systems still lack it; of those that have it, not every one accepts `--` to
## end the options, which a pathname that starts with `-` needs.  `cd` and
## `pwd -P` are portable.
##
## Several commands of this package define an `absolute_path` of their own.
## This is the one that the functions in this file call, so that a command's
## own definition -- `git-push-to`'s, which discards `cd`'s diagnostic --
## cannot change what a shared function does.
physical_path() {
  (CDPATH='' cd -- "$1" && pwd -P)
}
