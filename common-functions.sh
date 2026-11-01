# shellcheck shell=sh

# Functions that this package's commands share.  Other scripts source this
# file, rather than running it as a command, so it has no shebang line and is
# not executable.
#
# A script that sources this file must set ${SCRIPT_DIR} to the directory that
# contains this package's files, because `git_batch_ssh` runs a wrapper script
# from that directory and `check_conflict_resolution` runs an awk program
# from it.  It must also set ${SCRIPT_NAME} to its own name, which the
# diagnostics below use.

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
## Succeeds if git is version 2.MINOR or later.  Exits with status 1, after
## printing a diagnostic, if the version cannot be parsed.  It reads the
## version as `require_git` does, and only once.
git_at_least() {
  if [ -z "${require_git_version}" ]; then
    # Output is like "git version 2.44.0" or "git version 2.44.0.windows.1".
    require_git_version="$(git version)" || exit 1
    require_git_version="${require_git_version#git version }"
  fi
  require_git_major="${require_git_version%%.*}"
  require_git_minor="${require_git_version#*.}"
  require_git_minor="${require_git_minor%%.*}"
  case "${require_git_major}.${require_git_minor}" in
    *[!0-9.]* | .* | *.)
      echo "${SCRIPT_NAME}: cannot parse git version: ${require_git_version}" >&2
      exit 1
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
  copy_repository_head="$(git -C "$1" symbolic-ref --quiet HEAD)" \
    || copy_repository_head=''
  # `--bool` normalizes the value, and git prints the key in lower case.
  copy_repository_marked="$(git -C "$1" config --bool --get-regexp \
    '^branch\..*\.createdforbranchdirectory$' \
    | sed -n 's/^branch\.\(.*\)\.createdforbranchdirectory true$/\1/p')"
  printf '%s\n' "${copy_repository_marked}" \
    | while IFS= read -r copy_repository_branch; do
      case "${copy_repository_branch}" in
        '' | "${2-}" | "${copy_repository_head#refs/heads/}") continue ;;
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
  checked_out_branch=''
  # If the directory is not a working tree, or HEAD is detached, let a
  # subsequent command diagnose that, as `check_branch_exists` in
  # `git-push-to` does accurately.  `git rev-parse --abbrev-ref HEAD`, by
  # contrast, prints "HEAD" for a detached HEAD, which this function would
  # then report as a branch name.
  # Strip the known prefix ourselves, because `symbolic-ref --short` can return
  # "heads/BRANCH" when a tag and the branch have the same name.
  check_upstream_ref="$(git -C "$1" symbolic-ref --quiet HEAD 2> /dev/null)" || return 0
  checked_out_branch="${check_upstream_ref#refs/heads/}"
  check_upstream_remote="$(git -C "$1" config --get "branch.${checked_out_branch}.remote")"
  check_upstream_merge="$(git -C "$1" config --get-all "branch.${checked_out_branch}.merge")"
  if [ -n "${check_upstream_remote}" ] && [ -n "${check_upstream_merge}" ]; then
    return 0
  fi
  echo "${SCRIPT_NAME}: branch ${checked_out_branch} in $1 has no upstream branch, so it cannot be pulled or pushed" >&2
  return 1
}

## Usage: upstream_remote
## Prints the name of the remote of the current clone that is the upstream
## repository:  the remote named "upstream" if the clone has one, as a fork
## does, then "origin", then the clone's only remote if it has exactly one.
## Returns 1, after printing a diagnostic, if there is no such remote.
upstream_remote() {
  remote_dir='.'
  if ! remote_remotes="$(git remote)"; then
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
    if ! upstream_default_branch_git "${upstream_default_branch_batch}" \
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
    if ! upstream_default_branch_git "${upstream_default_branch_batch}" remote set-head "${upstream_default_branch_remote}" --auto > /dev/null \
      || ! upstream_default_branch_branch="$(git symbolic-ref --quiet "${upstream_default_branch_head}")"; then
      echo "${SCRIPT_NAME}: cannot determine the default branch of ${upstream_default_branch_remote}" >&2
      return 1
    fi
  fi
  printf '%s\n' "${upstream_default_branch_branch}"
}

## Usage: upstream_default_branch_git BATCH GIT-ARGUMENT...
## A helper for `upstream_default_branch`:  runs `git GIT-ARGUMENT...` in the
## current directory, under `git_batch_ssh` if BATCH is 1.
upstream_default_branch_git() {
  upstream_default_branch_git_batch="$1"
  shift
  if [ "${upstream_default_branch_git_batch}" -eq 1 ]; then
    git_batch_ssh . "$@"
  else
    git "$@"
  fi
}

## Usage: check_conflict_resolution FILE CONTAINS_SEPARATOR
## Checks the resolution of the conflicts in FILE against AUTO_MERGE, the git
## ref that names git's automatic merge, which contains the conflict markers:
## returns 0 if the text outside the conflict regions is unchanged and no
## conflict marker remains, and returns 1 otherwise.  Prints a diagnostic for
## each problem.  check-conflict-resolution.awk states exactly
## what is acceptable.  FILE is a pathname relative to the top level of the
## working tree, which must be the current directory.  CONTAINS_SEPARATOR is
## "yes" if HEAD's or MERGE_HEAD's version of FILE contains a line of 7 or
## more "=", such as "=======",
## which can then be content in the resolution, such as a Markdown heading's
## underline, rather than a conflict marker; and "no" otherwise.
##
## This compares content rather than the hunks of `git diff`, which can put a
## change on either of two identical lines, one inside a region and one
## outside it.
check_conflict_resolution() {
  if [ ! -f "$1" ]; then
    echo "${SCRIPT_NAME}: $1: the file was deleted" >&2
    return 1
  fi

  # This function passes FILE in AUTO_MERGE to the awk program
  # check-conflict-resolution.awk as MERGED, on standard input, and FILE in
  # the working tree as RESOLVED.  The "./" keeps awk from taking a
  # FILE such as "x=y" for a variable assignment.  `--filters` converts
  # AUTO_MERGE's file as a checkout would, such as to CRLF line endings, to
  # match the working tree.
  #
  # awk does not tell whether the last line of its input ends with a newline.
  # So `echo` appends a newline to AUTO_MERGE's file, whose last line as awk
  # reads it is then empty if and only if the file ends with a newline.
  # Whether the working tree's file ends with a newline is passed to the
  # checking program separately.
  check_conflict_ends_with_newline=yes
  if ! ends_with_newline < "$1"; then
    check_conflict_ends_with_newline=no
  fi

  {
    git cat-file --filters "AUTO_MERGE:$1"
    echo
  } | CCR_FILE="$1" CCR_SCRIPT_NAME="${SCRIPT_NAME}" \
    CCR_RESOLVED_ENDS_WITH_NEWLINE="${check_conflict_ends_with_newline}" \
    CCR_CONTAINS_SEPARATOR="$2" \
    awk -f "${SCRIPT_DIR}/check-conflict-resolution.awk" - "./$1"
}

## Usage: ends_with_newline
## Succeeds if standard input is empty or ends with a newline.
ends_with_newline() {
  # Command substitution removes a final newline, so the last character of
  # input that ends with one is empty.
  [ -z "$(tail -c 1)" ]
}

## Usage: resolve_merge_conflicts RESOLVER COMMIT SOURCE
## Resolves the conflicts of the merge of COMMIT that is in progress in the
## current directory, the top level of a working tree, and stages the result.
## Conflicts that `git rerere` has already resolved need no more work.  For
## any others, this function asks an AI agent, RESOLVER ("claude" or
## "codex"), to edit the conflicted files, or fails if RESOLVER is empty or
## cannot be run.  Either way, it checks every resolution with
## `check_conflict_resolution`.  SOURCE names COMMIT in diagnostics and in the
## agent's instructions.  Returns 1, after printing a diagnostic, on failure,
## and leaves the merge in progress.  The merge must have been made with
## `rerere.autoUpdate` false, so that the index lists every conflicted file as
## unmerged, including each one that rerere resolved.
##
## Only content conflicts are resolved, in which every conflicted file
## contains conflict markers.  For any other conflict, such as a file that one
## side modified and the other deleted, no check could tell whether the agent
## chose well.  Also refused are a file whose versions contain lines that look
## like conflict markers, and a working tree with changes other than the
## conflicted files, which would be committed with them.
resolve_merge_conflicts() {
  resolve_with="$1"
  resolve_commit="$2"
  resolve_source="$3"
  resolve_failed="${SCRIPT_NAME}: the merge of ${resolve_source} is still in progress in $(pwd)"

  # The checks compare the working tree with AUTO_MERGE, so an agent that
  # changed it would defeat them; `resolve_with_agent` checks that it did not.
  if ! resolve_auto_merge="$(git rev-parse --verify --quiet AUTO_MERGE)"; then
    echo "${SCRIPT_NAME}: no AUTO_MERGE, which git 2.42 and later write, in $(pwd)" >&2
    echo "${resolve_failed}" >&2
    return 1
  fi
  if ! resolve_head="$(git rev-parse --verify HEAD)" \
    || ! resolve_merge_head="$(git rev-parse --verify --quiet MERGE_HEAD)" \
    || [ "${resolve_merge_head}" != "$(git rev-parse --verify --quiet "${resolve_commit}^{commit}")" ]; then
    echo "${SCRIPT_NAME}: no merge of ${resolve_source} is in progress in $(pwd)" >&2
    return 1
  fi

  # The conflicted files, one per line.  `-z` keeps git from quoting a
  # pathname.  `tr` turns each NUL that ends a pathname into a newline, and
  # each newline within a pathname into the byte 001, by which such a
  # pathname is refused.
  resolve_files="$(git diff --name-only --diff-filter=U -z | tr '\n\000' '\001\n')"
  if [ -z "${resolve_files}" ]; then
    echo "${SCRIPT_NAME}: cannot list the conflicted files in $(pwd)" >&2
    echo "${resolve_failed}" >&2
    return 1
  fi
  case "${resolve_files}" in
    *"$(printf '\001')"*)
      echo "${SCRIPT_NAME}: a conflicted file has a newline in its name; resolve the conflicts by hand" >&2
      echo "${resolve_failed}" >&2
      return 1
      ;;
  esac
  # Any other change would be blamed on the agent below, or committed.
  resolve_other="$(resolve_other_changes)"
  if [ -n "${resolve_other}" ]; then
    printf '%s\n' "${resolve_other}" | sed -e "s/^/${SCRIPT_NAME}: changed, but not conflicted: /" >&2
    echo "${SCRIPT_NAME}: the working tree has changes that are not part of the merge; resolve the conflicts by hand" >&2
    echo "${resolve_failed}" >&2
    return 1
  fi

  # Checks each conflicted file, and lists each one that `git rerere` did not
  # resolve acceptably.
  #
  # `check_conflict_resolution` cannot tell a conflict marker from a line of
  # the file that looks like one, as in a test of merging, so such a file is
  # refused.  The sides are the versions of the file that the merge combined,
  # which the index holds as stages 1 (the merge base), 2 (HEAD), and 3
  # (MERGE_HEAD).  Each stage is under the conflicted pathname even if a side
  # has the file under another name, before or after a rename.  The merge
  # base matters too, because a merge with `merge.conflictStyle` "diff3" puts
  # its text in the conflict regions.  With several merge bases, stage 1 is
  # their merge, which can itself contain conflict markers; then the file is
  # refused.  A line of 7 or more "=", such as "=======", in HEAD's or
  # MERGE_HEAD's version is content, so `check_conflict_resolution` permits
  # such a line in the resolution.  (Git writes a separator of more than 7
  # "=" for a file whose attribute `conflict-marker-size` is larger.)
  #
  # For one stage, the awk program prints "marker" if a line looks like a
  # conflict marker, or else "separator" if a line consists of 7 or more "=".
  resolve_scan='/^(<<<<<<<|[|][|][|][|][|][|][|]|>>>>>>>)/ { marker = 1; exit }
    /^=======+\r?$/ { separator = 1 }
    END { if (marker) print "marker"; else if (separator) print "separator" }'
  # ${resolve_checks} has a line "separator FILE" for each conflicted file
  # in which a line of 7 or more "=" is permitted, and a line
  # "unresolved FILE" for each one that `git rerere` did not resolve
  # acceptably.
  if ! resolve_checks="$(printf '%s\n' "${resolve_files}" | {
    resolve_status=0
    while IFS= read -r resolve_file; do
      if ! git cat-file blob "AUTO_MERGE:${resolve_file}" 2> /dev/null | grep -q '^<<<<<<<'; then
        echo "${SCRIPT_NAME}: ${resolve_file} has a conflict other than a content conflict; resolve it by hand" >&2
        resolve_status=1
        continue
      fi
      resolve_contains_separator=no
      for resolve_stage in 1 2 3; do
        # The "(" before each pattern lets bash 3.2, which is /bin/sh on
        # macOS, parse a case statement inside a command substitution.
        case "$(git cat-file blob ":${resolve_stage}:${resolve_file}" 2> /dev/null \
          | awk "${resolve_scan}")" in
          (marker)
            echo "${SCRIPT_NAME}: ${resolve_file} contains lines that look like conflict markers; resolve its conflicts by hand" >&2
            resolve_status=1
            continue 2
            ;;
          (separator)
            if [ "${resolve_stage}" -ne 1 ]; then
              resolve_contains_separator=yes
            fi
            ;;
        esac
      done
      if [ "${resolve_contains_separator}" = yes ]; then
        printf 'separator %s\n' "${resolve_file}"
      fi
      if ! check_conflict_resolution "${resolve_file}" "${resolve_contains_separator}" 2> /dev/null; then
        printf 'unresolved %s\n' "${resolve_file}"
      fi
    done
    exit "${resolve_status}"
  })"; then
    echo "${resolve_failed}" >&2
    return 1
  fi
  # The files in which a line of 7 or more "=" is permitted, one per line;
  # `separator_permitted` reads it.
  resolve_separators="$(printf '%s\n' "${resolve_checks}" | sed -n -e 's/^separator //p')"
  # The files that `git rerere` did not resolve, one per line.
  resolve_unresolved="$(printf '%s\n' "${resolve_checks}" | sed -n -e 's/^unresolved //p')"

  if [ -z "${resolve_unresolved}" ]; then
    echo "${SCRIPT_NAME}: \`git rerere\` resolved the conflicts in $(pwd)" >&2
  elif [ -z "${resolve_with}" ] || ! agent_available "${resolve_with}"; then
    report_unresolved "${resolve_unresolved}"
    echo "${resolve_failed}" >&2
    return 1
  elif ! resolve_with_agent; then
    echo "${resolve_failed}" >&2
    return 1
  fi

  # `xargs -0` passes every pathname intact, even one that contains a blank
  # or a quotation mark.
  # GIT_LITERAL_PATHSPECS keeps git from interpreting glob characters in them.
  if ! git diff --name-only --diff-filter=U -z \
    | GIT_LITERAL_PATHSPECS=1 xargs -0 git add -- \
    || [ -n "$(git ls-files -u)" ]; then
    echo "${SCRIPT_NAME}: cannot stage the resolved files in $(pwd)" >&2
    echo "${resolve_failed}" >&2
    return 1
  fi
  return 0
}

## Usage: resolve_with_agent
## Asks the AI agent ${resolve_with} to resolve the conflicts in the files
## ${resolve_unresolved}, and checks its work.  Returns 1, after printing a
## diagnostic, if the agent fails or if its work is not acceptable.  Only
## `resolve_merge_conflicts` calls this function, which reads that function's
## variables.
##
## The agent may change only the files ${resolve_unresolved}.  Any other
## change is rejected:  to the index, to HEAD or MERGE_HEAD, to git's
## configuration or hooks, or to any other file of the working tree, whether
## tracked, untracked, or ignored.  A file that git does not track would not
## be committed, but a later build could use it.  A file that `git rerere`
## resolved must keep the resolution that rerere recorded.
resolve_with_agent() {
  # The index is compared by its contents.  The working tree, which can hold
  # many large files, such as build output, is compared by its pathnames and
  # by the time at which each file last changed (its "ctime").  Unlike a
  # file's modification time, an unprivileged process cannot set its ctime.
  # A file changed after the marker file was written, so the marker is in
  # the git directory, which neither agent can write.  A file system can
  # record times to the second, so the agent starts at least a second after
  # the marker is written, and a file that it changes has a later time.
  resolve_index="$(git ls-files --stage -z | cksum)"
  resolve_paths="$(working_tree_paths)"
  if ! resolve_marker="$(git rev-parse --path-format=absolute --git-path manage-git-branches-agent-start)" \
    || ! : > "${resolve_marker}"; then
    echo "${SCRIPT_NAME}: cannot write a file in the git directory of $(pwd)" >&2
    return 1
  fi
  sleep 1
  resolve_branch="$(git symbolic-ref --quiet --short HEAD)" || resolve_branch="HEAD"
  resolve_prompt="You are resolving merge conflicts in the git working tree $(pwd).
\`git merge\` of ${resolve_source} into branch ${resolve_branch} stopped with conflicts in these files:

$(printf '%s\n' "${resolve_unresolved}" | sed -e 's/^/  /')

Resolve every conflict by editing those files.  Rules:

* Edit only the conflict regions, each of which starts with a line \"<<<<<<<\" and ends with a line \">>>>>>>\".  A region holds the text of ${resolve_branch}; then, in the \"diff3\" conflict style, after a line \"|||||||\", the text of the merge base; then, after a line \"=======\", the text being merged in.  Remove every conflict marker line.  Do not change any other part of any file, even of a file that has conflicts:  git merged the rest cleanly.
* Do not resolve a file by taking one side wholesale.  Combine the intent of both sides.  To learn each side's intent, read the history, for example with \`git log --merge -p -- FILE\`, \`git diff HEAD...MERGE_HEAD -- FILE\` (the changes being merged in), and \`git diff MERGE_HEAD...HEAD -- FILE\` (the changes on ${resolve_branch}).
* Do not run any git command that changes the index, HEAD, or any other ref, such as \`git add\`, \`git commit\`, \`git checkout\`, \`git restore\`, \`git reset\`, \`git merge\`, \`git stash\`, or \`git rebase\`.  A script stages the files and commits the merge after you finish.
* Run commands in the current directory, which is the working tree, without \`cd\` or \`git -C\`.  A command in another form needs approval, which nobody is present to give.
* Do not build the project or run its tests; the script does that.
* Do not create another working copy, do not create any file, and do not change any file other than those listed above.
* The script rejects the resolution if any text outside the conflict regions changed, or if a conflict marker line remains.  \`git diff AUTO_MERGE\` shows your changes; AUTO_MERGE is git's automatic merge, which contains the conflict markers.
* If you cannot resolve a conflict with confidence, leave its conflict markers in place, and say why.

Finish with a brief summary of how you resolved each conflict."

  echo "${SCRIPT_NAME}: asking ${resolve_with} to resolve the conflicts in $(pwd)" >&2
  run_agent "${resolve_with}" "${resolve_prompt}"
  resolve_agent_status=$?
  resolve_changes="$(working_tree_changes "${resolve_paths}" "${resolve_marker}" "${resolve_unresolved}")"
  rm -f -- "${resolve_marker}"
  if [ "${resolve_agent_status}" -ne 0 ]; then
    return 1
  fi

  # Check the agent's work.
  if [ "$(git rev-parse --verify HEAD)" != "${resolve_head}" ] \
    || [ "$(git rev-parse --verify --quiet MERGE_HEAD)" != "${resolve_merge_head}" ] \
    || [ "$(git rev-parse --verify --quiet AUTO_MERGE)" != "${resolve_auto_merge}" ]; then
    echo "${SCRIPT_NAME}: ${resolve_with} changed HEAD, MERGE_HEAD, or AUTO_MERGE in $(pwd)" >&2
    return 1
  fi
  resolve_ok=1
  if [ "$(git ls-files --stage -z | cksum)" != "${resolve_index}" ]; then
    echo "${SCRIPT_NAME}: ${resolve_with} changed the index" >&2
    resolve_ok=0
  fi
  if [ -n "${resolve_changes}" ]; then
    printf '%s\n' "${resolve_changes}" | sed -e "s/^/${SCRIPT_NAME}: ${resolve_with} /" >&2
    resolve_ok=0
  fi
  # Every conflicted file is checked, including one that the agent did not
  # change, whose conflict markers remain.
  if ! printf '%s\n' "${resolve_files}" | {
    resolve_loop_ok=1
    while IFS= read -r resolve_file; do
      if ! check_conflict_resolution "${resolve_file}" "$(separator_permitted "${resolve_file}")"; then
        resolve_loop_ok=0
      fi
    done
    [ "${resolve_loop_ok}" -eq 1 ]
  }; then
    resolve_ok=0
  fi
  if [ "${resolve_ok}" -eq 0 ]; then
    echo "${SCRIPT_NAME}: ${resolve_with} did not resolve the conflicts acceptably" >&2
    return 1
  fi
  return 0
}

## Usage: working_tree_paths
## Prints the pathname of each file and directory of the working tree whose
## top level is the current directory, other than the contents of `.git`,
## one per line.  Each pathname begins with "./", as in "./src/main.c".  A
## pathname that contains a newline spans several lines.
working_tree_paths() {
  find . -path './.git/*' -prune -o -print
}

## Usage: working_tree_changes PATHS MARKER ALLOWED
## Compares the working tree whose top level is the current directory with
## PATHS, an earlier output of `working_tree_paths`.  Prints, one per line,
## "created a file: FILE" or "deleted a file: FILE" for each pathname that
## was added to or removed from PATHS, and "changed a file: FILE" for each
## other file, not a directory, whose status changed after MARKER, a file,
## was last modified.  A change to a file in ALLOWED, a list of pathnames
## relative to the top level such as "src/main.c", one per line, is not
## printed.  FILE is relative to the top level.
working_tree_changes() {
  {
    printf '%s\n' "$1" | sed -e 's/^/before /'
    working_tree_paths | sed -e 's/^/after /'
    find . -path './.git/*' -prune -o ! -type d -cnewer "$2" -print \
      | sed -e 's/^/changed /'
  } | WTC_ALLOWED="$3" awk '
    BEGIN {
      n = split(ENVIRON["WTC_ALLOWED"], allowed_list, "\n")
      for (i = 1; i <= n; i++) allowed["./" allowed_list[i]] = 1
    }
    # Each list can hold a pathname more than once, if a pathname that
    # contains a newline spans lines that are also pathnames, so the lists
    # are compared as multisets.
    /^before / { count[substr($0, 8)]--; next }
    /^after / { count[substr($0, 7)]++; next }
    /^changed / {
      file = substr($0, 9)
      if (!(file in allowed)) changed[file] = 1
    }
    function relative(file) { sub(/^\.\//, "", file); return file }
    END {
      for (file in count) {
        if (count[file] > 0) print "created a file: " relative(file)
        else if (count[file] < 0) print "deleted a file: " relative(file)
      }
      for (file in changed) {
        if (count[file] == 0) print "changed a file: " relative(file)
      }
    }' | LC_ALL=C sort
}

## Usage: report_unresolved FILES
## Says why each of FILES, a list of conflicted files one per line, is not
## acceptably resolved:  that it still has conflict markers, or else what
## `check_conflict_resolution` finds wrong with its resolution.
report_unresolved() {
  printf '%s\n' "$1" | while IFS= read -r report_unresolved_file; do
    if grep -q '^<<<<<<<' "${report_unresolved_file}" 2> /dev/null; then
      echo "${SCRIPT_NAME}: conflicted: ${report_unresolved_file}" >&2
    else
      check_conflict_resolution "${report_unresolved_file}" \
        "$(separator_permitted "${report_unresolved_file}")" || true
    fi
  done
}

## Usage: separator_permitted FILE
## Prints "yes" if a line of 7 or more "=" is permitted in the resolution of
## FILE, because FILE is in ${resolve_separators}, and "no" otherwise.
separator_permitted() {
  if printf '%s\n' "${resolve_separators}" | grep -F -x -q -- "$1"; then
    echo yes
  else
    echo no
  fi
}

## Usage: resolve_other_changes
## Prints, one per line, each file that differs from AUTO_MERGE in the working
## tree or in the index and is not in ${resolve_files}, the conflicted files.
resolve_other_changes() {
  {
    git diff --no-renames --name-only -z AUTO_MERGE
    git diff --cached --no-renames --name-only -z AUTO_MERGE
  } | tr '\000' '\n' | sort -u | grep -F -x -v -- "${resolve_files}"
}

## Usage: agent_available AGENT
## Succeeds if the command AGENT, "claude" or "codex", can be found.
## Otherwise prints a diagnostic and returns 1.
agent_available() {
  if command -v "$1" > /dev/null 2>&1; then
    return 0
  fi
  echo "${SCRIPT_NAME}: cannot run $1, which is not on the PATH" >&2
  return 1
}

## Usage: run_agent AGENT PROMPT
## Runs the AI agent AGENT, "claude" or "codex", in the current directory, with
## the instructions PROMPT.  The agent can read and edit the files of the
## working tree and read the repository, but nothing else; PROMPT can contain
## text from other people, such as conflicting changes, which might try to
## make the agent do more, such as copy a secret from another file into the
## resolution.  Returns 1, after printing a diagnostic, if the agent fails.
run_agent() {
  # Each agent's sandbox keeps it from changing git's configuration or hooks,
  # which name commands that git runs.  Check that anyway.
  if ! run_agent_git_state="$(git_control_state)"; then
    echo "${SCRIPT_NAME}: cannot read git's configuration in $(pwd)" >&2
    return 1
  fi
  # Each agent reads its instructions from standard input.
  #
  # Claude's restricted mode confines the file tools to the current
  # directory, and it ignores the settings files, whose rules, such as a
  # user's "Write(*)", would otherwise permit edits anywhere; a project's
  # settings file could come from the merged branch.  `--strict-mcp-config`
  # leaves out MCP servers, whose tools could act elsewhere.  Of the git
  # commands that Claude may run, which read the repository, `git diff`,
  # `git log`, and `git show` can write a file named by `--output`.  Claude
  # refuses a shell redirection of their output to a file outside the
  # working tree or in `.git`.  `git diff` can also read any file, as in
  # `git diff --no-index /dev/null ~/.ssh/id_rsa`;
  # "blockReadsOutsideWorkingDirectories" refuses a command that names a file
  # outside the working tree.
  #
  # Codex's permission profile, which overrides any `sandbox_mode` in the
  # user's configuration, lets the commands that Codex runs write only the
  # working tree, other than `.git`, and read only the working tree, the
  # repository, the system's programs and libraries (":minimal"), and Codex's
  # own installation, which its sandbox runs.
  case "$1" in
    claude)
      printf '%s\n' "$2" | claude -p --restricted --strict-mcp-config \
        --settings '{"permissions": {"blockReadsOutsideWorkingDirectories": true}}' \
        --tools 'Read,Edit,Write,Grep,Glob,Bash' --permission-mode acceptEdits \
        --allowedTools 'Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*),Bash(git ls-files:*),Bash(git merge-base:*)' \
        --disallowedTools 'Bash(git diff *--output*),Bash(git log *--output*),Bash(git show *--output*)'
      run_agent_status=$?
      ;;
    codex)
      if ! run_agent_repository="$(git rev-parse --path-format=absolute --git-common-dir)" \
        || ! run_agent_codex="$(codex_installation)"; then
        echo "${SCRIPT_NAME}: cannot find the files that codex needs to read" >&2
        return 1
      fi
      # Codex's sandbox protects some names in the working tree, even absent
      # ones, by creating an empty directory to mount over.  Each such
      # directory that did not exist before is removed afterwards.
      run_agent_absent=''
      for run_agent_name in .agents .aws .codex; do
        if [ ! -e "${run_agent_name}" ] && [ ! -L "${run_agent_name}" ]; then
          run_agent_absent="${run_agent_absent} ${run_agent_name}"
        fi
      done
      printf '%s\n' "$2" | codex exec -c 'default_permissions="resolve_conflicts"' \
        -c "permissions.resolve_conflicts.filesystem={\":minimal\" = \"read\", \":project_roots\" = {\".\" = \"write\"}, $(toml_string "${run_agent_repository}") = \"read\", $(toml_string "${run_agent_codex}") = \"read\"}" \
        -
      run_agent_status=$?
      for run_agent_name in ${run_agent_absent}; do
        if [ -d "${run_agent_name}" ] && [ ! -L "${run_agent_name}" ]; then
          # `rmdir` removes only an empty directory.
          rmdir -- "${run_agent_name}" 2> /dev/null || true
        fi
      done
      ;;
    *)
      echo "${SCRIPT_NAME}: unknown AI agent: $1" >&2
      return 1
      ;;
  esac
  if [ "$(git_control_state)" != "${run_agent_git_state}" ]; then
    echo "${SCRIPT_NAME}: $1 changed git's configuration, attributes, or hooks in $(pwd); check them before running git there" >&2
    return 1
  fi
  if [ "${run_agent_status}" -ne 0 ]; then
    echo "${SCRIPT_NAME}: $1 failed with status ${run_agent_status}" >&2
    return 1
  fi
  return 0
}

## Usage: codex_installation
## Prints the absolute pathname of the directory that contains Codex's
## programs:  the parent of the directory that contains the `codex` command
## on the PATH, after any symbolic links to that command are followed, such
## as "~/.codex/packages/standalone/releases/0.165.0-x86_64-unknown-linux-musl"
## for ".../bin/codex", or the `@openai/codex` package of an npm installation
## for ".../bin/codex.js".  Returns 1 if `codex` is not on the PATH.
codex_installation() {
  codex_installation_file="$(command -v codex)" || return 1
  codex_installation_links=0
  while [ -L "${codex_installation_file}" ]; do
    codex_installation_links=$((codex_installation_links + 1))
    if [ "${codex_installation_links}" -gt 40 ]; then return 1; fi
    codex_installation_link="$(readlink -- "${codex_installation_file}")" || return 1
    case "${codex_installation_link}" in
      /*) codex_installation_file="${codex_installation_link}" ;;
      *) codex_installation_file="$(dirname -- "${codex_installation_file}")/${codex_installation_link}" ;;
    esac
  done
  physical_path "$(dirname -- "${codex_installation_file}")/.."
}

## Usage: toml_string STRING
## Prints STRING as a TOML basic string, in quotation marks, such as
## "a\"b" for a"b.
toml_string() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

## Usage: git_control_state
## Prints a summary of what in the current repository names commands that git
## runs, or chooses among them:  git's configuration, including each file
## that it includes; the repository's `info/attributes` file; and its hooks.
## The summary changes if any of them changes.
git_control_state() {
  # The configuration's values, rather than its files, are summarized, so
  # that a change to a file that the configuration includes, such as through
  # "include.path", changes the summary.
  git_control_config="$(git config --list)" || return 1
  printf '%s\n' "${git_control_config}" | cksum
  git_control_attributes="$(git rev-parse --path-format=absolute --git-path info/attributes)" || return 1
  if [ -f "${git_control_attributes}" ]; then
    cksum < "${git_control_attributes}"
  else
    echo "no ${git_control_attributes}"
  fi
  git_control_hooks="$(git rev-parse --path-format=absolute --git-path hooks)" || return 1
  if [ -d "${git_control_hooks}" ]; then
    # `-L` follows a symbolic link, so that a change to the file that a hook
    # links to changes the summary.  Every other entry, such as a dangling
    # link, is listed by name.
    find -L "${git_control_hooks}" -type f -exec cksum {} + -o -print | sort
  fi
}

## The AI agent that the commands ask to resolve merge conflicts:  "claude",
## "codex", or empty for none.  `parse_llm_option` sets it.
llm_agent=claude
## The AI agent that "--llm" turns on.  `parse_llm_option` sets it.
llm_choice=claude
## The usage of the options that `parse_llm_option` recognizes.
# shellcheck disable=SC2034 # used by the commands that source this file
llm_options_usage='[--llm | --no-llm] [--claude | --codex]'

## Usage: parse_llm_option OPTION
## Returns 0, after setting ${llm_agent}, if OPTION chooses the AI agent:
## "--claude" and "--codex" choose it and turn it on, "--no-llm" turns it off,
## and "--llm" turns it on.  The agent that "--llm" turns on is the one that
## the last "--claude" or "--codex" chose, or Claude if neither was given.
## Returns 1 if OPTION is not one of those.
# shellcheck disable=SC2034 # llm_agent is used by the commands that source this file
parse_llm_option() {
  case "$1" in
    --llm) llm_agent="${llm_choice}" ;;
    --no-llm) llm_agent='' ;;
    --claude | --codex)
      llm_choice="${1#--}"
      llm_agent="${llm_choice}"
      ;;
    *) return 1 ;;
  esac
  return 0
}

## Usage: merge_build_push COMMIT DESCRIPTION SOURCE NOCOMPILE [RESOLVER]
## Merges COMMIT into the current branch, builds with `compile-project` unless
## NOCOMPILE is 1 or $MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT is set, and
## pushes the current branch if the build succeeds.  DESCRIPTION is what
## `git fmt-merge-msg` says that COMMIT is, such as "branch 'feature'" or
## "remote-tracking branch 'upstream/master'".  SOURCE names COMMIT in
## diagnostics.  If the merge has conflicts, `resolve_merge_conflicts`
## resolves them, asking RESOLVER, if it is given and not empty, about any
## that `git rerere` did not resolve.
## Returns 1, after printing a diagnostic, on failure.
## ${SCRIPT_DIR} must be set; see the top of this file.
merge_build_push() {
  # Let git compose the message, as it does for `git merge`, rather than
  # composing it by hand.  Git then writes the "into BRANCH" suffix, which it
  # omits on the default branch, and the commit summaries that `merge.log`
  # turns on.  Saying that COMMIT came from ".", the local repository, keeps
  # git from appending " of SOURCE" to the message.  `git fmt-merge-msg` also
  # writes comment lines, such as "# By AUTHOR", that `git merge` keeps in a
  # message given with `-m`, so they are removed.  The comment character is
  # set to "#" for both commands, because the summaries that `merge.log`
  # turns on begin with "* ", which `core.commentChar` might be.
  if ! merge_message="$(printf '%s\t\t%s of .\n' "$1" "$2" \
    | git -c core.commentChar='#' fmt-merge-msg)" \
    || ! merge_message="$(printf '%s\n' "${merge_message}" \
      | git -c core.commentChar='#' stripspace --strip-comments)"; then
    echo "${SCRIPT_NAME}: cannot compose a merge message for $3" >&2
    return 1
  fi

  # Merge rather than `git pull`, which rebases if `pull.rebase` is set.  A
  # rebase would rewrite the branch that this function is about to push.
  # `--no-edit` keeps a chain of merges from stopping at an editor.
  # `--no-log` prevents a second copy of the commit summaries:  `git merge`
  # appends them to a message given with `-m` when `merge.log` is set, and
  # ${merge_message} already contains the ones that `fmt-merge-msg` wrote.
  # `rerere.autoUpdate` false keeps each file that `git rerere` resolves
  # unmerged in the index, where `resolve_merge_conflicts` finds it.  The
  # merge uses the conflict style that the configuration gives:  rerere
  # replays a resolution only for a conflict region that encloses the same
  # text as when the resolution was recorded, and the style determines which
  # lines a region encloses.
  if ! git -c rerere.autoUpdate=false merge -q --no-edit --no-log \
    -m "${merge_message}" "$1"; then
    # A failed merge without MERGE_HEAD did not start, for example because it
    # would overwrite a modified file; there are no conflicts to resolve.
    # Otherwise, `resolve_merge_conflicts` says what is wrong, if anything.
    if ! git rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
      echo "${SCRIPT_NAME}: problem merging $3 into $(pwd)" >&2
      return 1
    fi
    # Git names the conflicted files relative to the top level of the working
    # tree, so `resolve_merge_conflicts` runs there, in a subshell that leaves
    # the current directory unchanged.
    if ! merge_top="$(git rev-parse --show-toplevel)" \
      || ! (cd "${merge_top}" && resolve_merge_conflicts "${5:-}" "$1" "$3"); then
      return 1
    fi
    # `-F` supplies the message, rather than MERGE_MSG, to which `git merge`
    # appended a list of the conflicts.
    if ! printf '%s\n' "${merge_message}" | git commit -q --cleanup=whitespace -F -; then
      echo "${SCRIPT_NAME}: cannot commit the merge of $3 in $(pwd)" >&2
      return 1
    fi
  fi

  if [ "$4" -eq 0 ] && [ -z "${MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT}" ]; then
    if ! "${SCRIPT_DIR}"/compile-project; then
      echo "${SCRIPT_NAME}: unable to build in $(pwd)" >&2
      return 1
    fi
  fi

  if ! git push --quiet; then
    echo "${SCRIPT_NAME}: problem pushing from $(pwd)" >&2
    return 1
  fi
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

## Usage: branch_dir_name BRANCH
## Prints BRANCH as it appears in the name of a branch directory, with each
## "/" replaced by "-".
branch_dir_name() {
  printf '%s\n' "$1" | sed -e 's:/:-:g'
}

## Usage: parse_clone_name NAME
## Sets ${clone_project} and ${clone_org} from NAME, the name of a clone,
## PROJECT-fork-ORG or PROJECT, without a -branch-BRANCH suffix.  ORG starts
## after the last "-fork-" in NAME, so PROJECT can contain "-fork-" but ORG
## cannot, nor can ORG start with "fork-"; see `check_slug_org`.  ${clone_org} is "-" for a NAME that has no
## "-fork-", as ORG "-" stands for PROJECT in a slug.
parse_clone_name() {
  case "$1" in
    *-fork-*)
      clone_project="${1%-fork-*}"
      clone_org="${1##*-fork-}"
      ;;
    *)
      # shellcheck disable=SC2034 # set for the caller
      clone_project="$1"
      # shellcheck disable=SC2034 # set for the caller
      clone_org='-'
      ;;
  esac
}

## Usage: parse_slug SLUG
## Sets ${slug_org}, ${slug_branch}, and ${slug_branch_dir} from the slug
## ORG:BRANCH or BRANCH.  Git forbids ":" in a branch name, so the first ":"
## ends ORG.  ${slug_org} is empty if the slug has no ORG.  ${slug_branch_dir}
## is BRANCH as it appears in a directory name; see `branch_dir_name`.
parse_slug() {
  case "$1" in
    *:*)
      slug_org="${1%%:*}"
      slug_branch="${1#*:}"
      ;;
    *)
      slug_org=''
      slug_branch="$1"
      ;;
  esac
  # shellcheck disable=SC2034 # set for the caller
  slug_branch_dir="$(branch_dir_name "${slug_branch}")"
}

## Usage: check_slug_org SLUG
## Returns 0 if the slug BRANCH has no ORG, or if the ORG of the slug
## ORG:BRANCH can name the clone of a fork, PROJECT-fork-ORG.  Otherwise
## prints an error on standard error and returns 1.  Sets the variables that
## `parse_slug` sets.
##
## A pathname cannot serve as ORG, so an ORG that is empty, contains "/", or
## starts with "." is not one.
##
## Every directory name that contains "-branch-" is read as that of a branch
## directory, PREFIX-branch-BRANCH, and some commands take PREFIX to end at
## the first "-branch-".  So if ORG is "branch", starts with "branch-", ends
## with "-branch", or contains "-branch-", then the name of the clone
## PROJECT-fork-ORG or of its branch directory PROJECT-fork-ORG-branch-BRANCH
## would be read as that of a branch directory of a different clone.  A
## directory name is read as PROJECT-fork-ORG with ORG starting after its last
## "-fork-", so if ORG starts with "fork-" or contains "-fork-", then
## PROJECT-fork-ORG would be read as the clone of a different fork.
check_slug_org() {
  parse_slug "$1"
  case "$1" in
    *:*)
      case "${slug_org}" in
        '' | */* | .*)
          echo "${SCRIPT_NAME}: ERROR: not a slug ORG:BRANCH: $1" >&2
          return 1
          ;;
      esac
      ;;
  esac
  # The hyphens added around ${slug_org} stand for those that surround ORG in
  # PROJECT-fork-ORG-branch-BRANCH.
  case "-${slug_org}-" in
    *-branch-*)
      echo "${SCRIPT_NAME}: ERROR: an ORG that is \"branch\", starts with \"branch-\", ends with \"-branch\", or contains \"-branch-\" cannot be used in a slug, because the name of its fork's clone, PROJECT-fork-ORG, or of a branch directory of that clone would be read as that of a branch directory of a different clone: $1" >&2
      return 1
      ;;
  esac
  case "-${slug_org}" in
    *-fork-*)
      echo "${SCRIPT_NAME}: ERROR: an ORG that starts with \"fork-\" or contains \"-fork-\" cannot be used in a slug, because the name of its fork's clone, PROJECT-fork-ORG, would be read as that of a different fork: $1" >&2
      return 1
      ;;
  esac
}

## Usage: main_working_tree [DIRECTORY]
## Prints the main working tree of the repository that holds DIRECTORY (by
## default, the current directory):  the working tree whose top level holds
## the repository's `.git` directory.  Prints nothing and returns 1 if there
## is none -- for a bare repository, a git directory outside its working tree
## (as a submodule's is), or a DIRECTORY outside any repository.
##
## The variables are prefixed with an abbreviation of this function's name,
## so that they cannot collide with a sourcing script's variables.
main_working_tree() {
  mwt_common="$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2> /dev/null)" \
    || return 1
  case "${mwt_common}" in
    */.git) printf '%s\n' "${mwt_common%/.git}" ;;
    *) return 1 ;;
  esac
}

## Usage: main_clone_for DIRECTORY
## DIRECTORY is the top level of a working tree.  Prints the main working tree
## in which a new worktree of DIRECTORY's repository should be registered, if
## that is not the one that `git worktree add` in DIRECTORY would register it
## in; prints nothing otherwise.
##
## `git worktree add` registers a new worktree in the repository of the main
## working tree, which holds the `.git` directory.  When that main working
## tree is itself a branch directory -- REPONAME-branch-OTHER, a clone made
## with `--copy` or by other means -- the new
## worktree depends on it, and that branch directory cannot be removed while
## the new worktree exists, even after OTHER's pull request lands.  So a
## sibling named REPONAME, which conventionally holds the clone that branch
## directories are made from, is a better home, if it is a main working tree
## that pushes where DIRECTORY's repository does:  if both would push a branch
## with no configuration to the same repositories, as `push_keys` judges them.
## Having a remote in common is not enough.  A clone of a fork has a remote
## "upstream" in common with a clone of the upstream repository, but a branch
## registered in the latter would be pushed to the upstream repository rather
## than to the fork.  If neither clone determines a remote for such a branch,
## though, neither says where the branch would be pushed, and having a remote
## in common, as `repository_key` judges it, is enough.
##
## A sparse checkout and per-worktree configuration are exceptions.
## `git worktree add` gives the new worktree the sparse-checkout patterns and
## per-worktree configuration of the worktree that it runs in, and without
## per-worktree configuration, `core.sparseCheckout` and the patterns apply to
## every worktree of a repository.  So if either repository has either one,
## moving the new worktree to the main clone would change how it is checked
## out, and this function prints nothing.
##
## The variables are prefixed with an abbreviation of this function's name,
## so that they cannot collide with a sourcing script's variables.
main_clone_for() {
  # A repository without a main working tree has no name that this naming
  # convention could describe.
  mcf_host="$(main_working_tree "$1")" || return 0
  mcf_name="$(basename -- "${mcf_host}")"
  case "${mcf_name}" in
    *-branch-*) ;;
    *) return 0 ;;
  esac
  mcf_main="$(dirname -- "${mcf_host}")/${mcf_name%%-branch-*}"
  # A symbolic link, such as REPONAME -> REPONAME-branch-master, may lead back
  # to a branch directory, so it does not count.
  if [ -L "${mcf_main}" ] || [ ! -d "${mcf_main}/.git" ] || [ -L "${mcf_main}/.git" ]; then
    return 0
  fi
  mcf_main="$(physical_path "${mcf_main}")" || return 0
  mcf_host="$(physical_path "${mcf_host}")" || return 0
  if [ "${mcf_main}" = "${mcf_host}" ]; then
    return 0
  fi
  for mcf_dir in "$1" "${mcf_main}"; do
    if [ "$(git -C "${mcf_dir}" config --bool core.sparseCheckout)" = 'true' ] \
      || [ "$(git -C "${mcf_dir}" config --bool extensions.worktreeConfig)" = 'true' ]; then
      return 0
    fi
  done
  mcf_keys="$(push_keys "${mcf_host}")"
  if [ "$(push_keys "${mcf_main}")" != "${mcf_keys}" ]; then
    return 0
  fi
  if [ -z "${mcf_keys}" ]; then
    mcf_keys="$(git -C "${mcf_host}" remote | while IFS= read -r mcf_remote; do
      repository_key "${mcf_host}" "${mcf_remote}"
    done | sort -u)"
    if [ -z "${mcf_keys}" ] \
      || ! git -C "${mcf_main}" remote | while IFS= read -r mcf_remote; do
        repository_key "${mcf_main}" "${mcf_remote}"
      done | grep -q -x -F -- "${mcf_keys}"; then
      return 0
    fi
  fi
  printf '%s\n' "${mcf_main}"
}

## Usage: note_worktree_host
## Says, on standard error, that the new worktree is registered in
## ${WORKTREE_HOST}, and names the branch directory that this frees:  the main
## working tree of the current repository, which is not the current working
## tree if that is a linked worktree.  ${WORKTREE_HOST} is set by
## `main_clone_for`, which finds it only if that main working tree exists.
note_worktree_host() {
  nwh_main="$(main_working_tree)" || return 0
  echo "${SCRIPT_NAME}: registering the new worktree in ${WORKTREE_HOST}, the main clone, rather than in ${nwh_main}, so that ${nwh_main} can be removed independently" >&2
}

## Usage: copy_objects_to REPOSITORY REFSPEC [INDEX]
## Fetches REFSPEC from the current repository into the repository of the
## working tree REPOSITORY, which brings along the history of the commit that
## REFSPEC names; with INDEX, also copies the blobs that the current working
## tree's index names, and REFSPEC must then be HEAD.  These are the objects
## that a worktree registered in
## REPOSITORY needs in order to hold that commit and that index.  On failure,
## prints a warning and returns 1.  A failure is not unusual:  git refuses,
## for example, to update a ref that REFSPEC names unless the update is a
## fast-forward.  A caller then registers the worktree in the current
## repository instead.
##
## A shallow current repository is refused before anything is fetched.  A
## fetch from it into a complete repository warns that it "rejected" the ref,
## exits with status 0 all the same, and leaves the commit in REPOSITORY
## without its parents, which a worktree there would then be based on.
##
## The fetch of HEAD brings every blob of HEAD's tree, so only an index entry
## that differs from HEAD, or a stage of a conflict, which `git diff-index`
## does not name, can be missing.  Asking about every index entry would cost
## one lookup per file of the repository.
##
## A staged blob that no commit holds is copied in one pack; it is then an
## unreachable object in REPOSITORY, which `git gc` nonetheless keeps, because
## the new worktree's index names it.  A gitlink names a commit in a submodule
## rather than an object of this repository, so it is skipped.
copy_objects_to() {
  if [ "$(git rev-parse --is-shallow-repository)" != 'false' ]; then
    echo "${SCRIPT_NAME}: warning: ${PWD} is a shallow clone, so $1 cannot fetch history from it" >&2
    return 1
  fi
  if ! git -C "$1" fetch -q --no-tags --no-write-fetch-head "${PWD}" "$2" < /dev/null; then
    echo "${SCRIPT_NAME}: warning: cannot fetch $2 from ${PWD} into $1" >&2
    return 1
  fi
  if [ "$#" -lt 3 ]; then
    return 0
  fi
  # Each line of `git diff-index` is ":OLD-MODE NEW-MODE OLD NEW STATUS\tPATH",
  # and NEW is all zeros for a deleted or unmerged path.
  if ! cot_changed="$(git diff-index --cached --no-renames HEAD)" \
    || ! cot_unmerged="$(git ls-files --unmerged)"; then
    echo "${SCRIPT_NAME}: warning: cannot determine which staged blobs $1 lacks" >&2
    return 1
  fi
  if ! cot_missing="$( {
    printf '%s\n' "${cot_changed}" | awk '$2 != "160000" && $4 !~ /^0+$/ { print $4 }'
    printf '%s\n' "${cot_unmerged}" | awk '$1 != "160000" { print $2 }'
  } | grep '.' | sort -u \
    | git -C "$1" cat-file --batch-check | awk '$2 == "missing" { print $1 }')"; then
    echo "${SCRIPT_NAME}: warning: cannot determine which staged blobs $1 lacks" >&2
    return 1
  fi
  if [ -z "${cot_missing}" ]; then
    return 0
  fi
  # A pipeline's status is that of its last command, so whether every blob
  # arrived is tested afterward.
  printf '%s\n' "${cot_missing}" | git pack-objects -q --stdout \
    | git -C "$1" index-pack --stdin > /dev/null
  if printf '%s\n' "${cot_missing}" | git -C "$1" cat-file --batch-check \
    | grep -q ' missing$'; then
    echo "${SCRIPT_NAME}: warning: cannot copy the staged blobs into $1" >&2
    return 1
  fi
}

## Usage: is_deleted_branch_tracking_refs DIRECTORY REMOTE REF
## Prints the remote-tracking refs that REMOTE's fetch refspecs, as the clone
## in DIRECTORY configures them, map REF to, one per line.  Prints nothing if
## no refspec maps REF, which is also what happens when REMOTE is a URL rather
## than the name of a configured remote:  fetching from a URL creates no
## remote-tracking ref.
##
## The variables below are prefixed with an abbreviation of this function's
## name, as `check_git_dir_is_directory`'s are, so that they cannot collide
## with a sourcing script's variables.  The pipeline that sets them also makes
## them a subshell's, in every shell that this package supports, but the
## prefix is what the guarantee rests on.
is_deleted_branch_tracking_refs() {
  git -C "$1" config --get-all "remote.$2.fetch" \
    | while IFS= read -r tracking_refs_refspec; do
      # A fetch refspec is [+]SOURCE:DESTINATION.  A "*" in SOURCE matches any
      # substring, and DESTINATION's "*" stands for what SOURCE's matched.
      # A refspec without a DESTINATION, such as the negative refspec
      # "^refs/heads/BRANCH", creates no remote-tracking ref.
      case "${tracking_refs_refspec}" in
        *:*) ;;
        *) continue ;;
      esac
      tracking_refs_refspec="${tracking_refs_refspec#+}"
      tracking_refs_source_pattern="${tracking_refs_refspec%%:*}"
      tracking_refs_destination="${tracking_refs_refspec#*:}"
      case "${tracking_refs_source_pattern}" in
        *'*'*)
          # A ref name cannot contain "*", "?", or "[", so the only pattern
          # character in SOURCE is the "*" that this case matched.
          tracking_refs_source_prefix="${tracking_refs_source_pattern%%'*'*}"
          tracking_refs_source_suffix="${tracking_refs_source_pattern#*'*'}"
          case "$3" in
            "${tracking_refs_source_prefix}"*"${tracking_refs_source_suffix}") ;;
            *) continue ;;
          esac
          tracking_refs_matched="${3#"${tracking_refs_source_prefix}"}"
          tracking_refs_matched="${tracking_refs_matched%"${tracking_refs_source_suffix}"}"
          case "${tracking_refs_destination}" in
            *'*'*)
              printf '%s%s%s\n' "${tracking_refs_destination%%'*'*}" \
                "${tracking_refs_matched}" "${tracking_refs_destination#*'*'}"
              ;;
            *) printf '%s\n' "${tracking_refs_destination}" ;;
          esac
          ;;
        *)
          if [ "$3" = "${tracking_refs_source_pattern}" ]; then
            printf '%s\n' "${tracking_refs_destination}"
          fi
          ;;
      esac
    done
}

## Usage: is_deleted_branch_was_pushed DIRECTORY REMOTE BRANCH BRANCH-REF COMMIT
## Returns 0 (true) if the clone in DIRECTORY shows that BRANCH, whose ref is
## BRANCH-REF and whose commit is COMMIT, was pushed to REMOTE.  The existence
## of a remote-tracking ref for the branch is not itself such a sign:  the ref
## may be a leftover from a different branch of the same name, which someone
## else pushed and deleted and which this clone never pruned.  A sign is a
## reflog entry that records a push.  So is a remote-tracking ref that is at
## the same commit as the branch:  even if that ref is a leftover, the branch
## holds no work that the remote lacks.
is_deleted_branch_was_pushed() {
  is_deleted_branch_was_pushed_candidates="$(
    is_deleted_branch_tracking_refs "$1" "$2" "refs/heads/$3"
  )"
  is_deleted_branch_was_pushed_result=1
  # A ref name cannot contain a newline.
  is_deleted_branch_was_pushed_saved_ifs="${IFS}"
  IFS='
'
  set -f
  for is_deleted_branch_was_pushed_ref in ${is_deleted_branch_was_pushed_candidates}; do
    if [ "${is_deleted_branch_was_pushed_ref}" = "$4" ]; then
      # A fetch refspec can map the branch to itself, as the "+refs/*:refs/*"
      # that `git remote add --mirror=fetch` sets does.  The branch is
      # trivially at its own commit and its reflog is not a record of a push,
      # so such a ref is no sign that the branch was pushed.
      continue
    fi
    is_deleted_branch_was_pushed_commit="$(git -C "$1" rev-parse --verify \
      --quiet "${is_deleted_branch_was_pushed_ref}")" || continue
    if [ "${is_deleted_branch_was_pushed_commit}" = "$5" ] \
      || git -C "$1" reflog show "${is_deleted_branch_was_pushed_ref}" 2> /dev/null \
      | grep -q ': update by push$'; then
      is_deleted_branch_was_pushed_result=0
      break
    fi
  done
  set +f
  IFS="${is_deleted_branch_was_pushed_saved_ifs}"
  return "${is_deleted_branch_was_pushed_result}"
}

## Usage: remote_location DIRECTORY REMOTE
## Prints the location of the repository that REMOTE names in DIRECTORY.
## REMOTE is a remote of the clone in DIRECTORY, or a URL or a pathname, which
## git accepts in place of a remote's name.  The location is that of the URL
## that REMOTE resolves to; see `url_location`.  `git ls-remote --get-url`
## resolves REMOTE, applying `url.*.insteadOf` rewriting as a query would.
##
## Prints nothing if git cannot resolve REMOTE, or if REMOTE resolves to a
## pathname that names no directory.  Git takes a name that is not a remote's
## to be a pathname, so this includes a misspelled remote name, unless
## DIRECTORY contains a directory of that name.
remote_location() {
  remote_location_url="$(git -C "$1" ls-remote --get-url "$2" 2> /dev/null)" \
    || return 0
  url_location "$1" "${remote_location_url}"
}

## Usage: url_location DIRECTORY URL
## Prints the location of the repository that URL, as git would use it in
## DIRECTORY, names.  The location is URL itself or, for a pathname, the
## physical path of the directory that it names.  A `file://` URL is a URL,
## because git reaches the repository through another transport than for its
## pathname.
##
## A pathname is resolved in DIRECTORY, as git resolves it, so two directories
## that both say "../upstream.git" do not name one repository.  A pathname
## that begins with "~" is not relative to DIRECTORY, and its location is the
## pathname itself.
##
## Prints nothing if URL is empty, or if it is a pathname that names no
## directory.
url_location() {
  url_location_url="$2"
  # Git reads a string as a URL if it has a scheme, and as an scp-style URL if
  # a colon precedes the first slash.  Anything else is a pathname.
  case "${url_location_url}" in
    '') return 0 ;;
    *://* | '~'*)
      printf '%s\n' "${url_location_url}"
      return 0
      ;;
    *:*)
      case "${url_location_url%%:*}" in
        */*) ;;
        *)
          printf '%s\n' "${url_location_url}"
          return 0
          ;;
      esac
      ;;
  esac
  case "${url_location_url}" in
    /*) url_location_path="${url_location_url}" ;;
    *) url_location_path="$1/${url_location_url}" ;;
  esac
  # Unlike the `physical_path` calls in `is_deleted_branch`, which explain the
  # failure that they let through, this one is expected to fail:  a remote that
  # names a pathname that no longer exists is an ordinary reason to have no
  # location.  Discard `cd`'s diagnostic, which would name the pathname with no
  # hint of what asked about it.
  physical_path "${url_location_path}" 2> /dev/null || true
}

## Usage: repository_key DIRECTORY REMOTE
## Prints a key for the repository that REMOTE names in DIRECTORY, as
## `url_key` does for the URL that `git ls-remote --get-url` resolves REMOTE
## to.  Prints nothing if REMOTE has no location (see `remote_location`).
repository_key() {
  repository_key_url="$(git -C "$1" ls-remote --get-url "$2" 2> /dev/null)" \
    || return 0
  url_key "$1" "${repository_key_url}"
}

## Usage: remote_urls DIRECTORY REMOTE [--push]
## Prints, one per line, the URLs that the clone in DIRECTORY fetches from, or
## with --push pushes to, for REMOTE, which is the name of a remote, a URL or a
## pathname (which git accepts in place of a remote's name), or empty.  A
## remote's push URLs are those that `remote.<name>.pushurl` and
## `url.<base>.pushInsteadOf` set, if they set any.  A URL or a pathname is
## rewritten by `url.<base>.insteadOf`, as `git ls-remote --get-url` rewrites
## it, but not by `url.<base>.pushInsteadOf`, although `git push` applies that
## too.
remote_urls() {
  if is_remote_name "$1" "$2"; then
    git -C "$1" remote get-url ${3:+"$3"} --all "$2" 2> /dev/null
  elif [ -n "$2" ]; then
    git -C "$1" ls-remote --get-url "$2" 2> /dev/null
  fi
}

## Usage: push_keys DIRECTORY
## Prints, one per line and sorted, the repository keys (see `url_key`) of the
## URLs that `git push` in DIRECTORY would push a branch with no configuration
## to; see `push_remote` and `remote_urls`.  Prints nothing if DIRECTORY
## determines no remote for such a branch.
push_keys() {
  push_keys_remote="$(push_remote "$1" '')"
  if [ -n "${push_keys_remote}" ]; then
    remote_urls "$1" "${push_keys_remote}" --push | url_keys "$1" | sort -u
  fi
}

## Usage: url_keys DIRECTORY
## Reads URLs, one per line, and prints the key (see `url_key`) of each that
## has one, as git would use it in DIRECTORY.
url_keys() {
  while IFS= read -r url_keys_url; do
    url_key "$1" "${url_keys_url}"
  done
}

## Usage: url_key DIRECTORY URL
## Prints a key for the repository that URL names in DIRECTORY, which is its
## location (see `url_location`) with each URL put in one form, so that two
## spellings of one repository's URL, such as `git@github.com:org/proj.git` and
## `https://github.com/org/proj`, have the same key.  The form is the host, in
## lower case, and the path, without a scheme, a user, or a trailing "/" or
## ".git".  A port is part of the host, except the default port of the scheme,
## which names the same repository as no port.  The path is in lower case too
## for a host that ignores the case of its paths, and only for such a host,
## because two paths that differ only in case might name different repositories.
## A physical path is its own key, and a `file://` URL has the key of its
## pathname.  Prints nothing if URL has no location.
url_key() {
  case "$2" in
    file:///*) url_key_location="$(url_location "$1" "${2#file://}")" ;;
    *) url_key_location="$(url_location "$1" "$2")" ;;
  esac
  case "${url_key_location}" in
    '') return 0 ;;
    # A physical path, or a pathname that is not relative to a directory.
    /* | '~'*)
      printf '%s\n' "${url_key_location}"
      return 0
      ;;
  esac
  # One process puts the URL in its form; the URL is one with a scheme or an
  # scp-style URL, `[user@]host:path`.
  printf '%s\n' "${url_key_location}" | awk '{
    url = $0
    scheme = ""
    if (match(url, /^[A-Za-z][A-Za-z0-9+.-]*:\/\//)) {
      scheme = tolower(substr(url, 1, RLENGTH - 3))
      url = substr(url, RLENGTH + 1)
    }
    sub(/^[^@\/]*@/, "", url)
    if (scheme == "") {
      split_at = index(url, ":")
      host = substr(url, 1, split_at - 1)
      path = "/" substr(url, split_at + 1)
    } else {
      split_at = index(url, "/")
      if (split_at == 0) {
        host = url
        path = ""
      } else {
        host = substr(url, 1, split_at - 1)
        path = substr(url, split_at)
      }
      if (match(host, /:[0-9]+$/)) {
        port = substr(host, RSTART + 1)
        if ((port == "22" && (scheme == "ssh" || scheme == "git+ssh" || scheme == "ssh+git")) \
          || (port == "9418" && scheme == "git") || (port == "80" && scheme == "http") \
          || (port == "443" && scheme == "https")) {
          host = substr(host, 1, RSTART - 1)
        }
      }
    }
    sub(/\/*$/, "", path)
    sub(/\.git$/, "", path)
    host = tolower(host)
    if (host == "github.com") {
      path = tolower(path)
    }
    print host path
  }'
}

## The answers that remotes have already given this file, so that one
## `git ls-remote --heads` answers for every directory that asks the same
## remote the same way.  In this package's workflow, every `REPO-branch-*`
## directory of one project is a clone of one upstream repository, so a scan
## of twenty of them asked twenty times what one query answers.
##
## The memory lasts as long as the process that sourced this file, which is
## one run of one command.  A scan therefore sees one snapshot of each remote,
## rather than a remote that may change under it as the scan proceeds.
##
## ${remote_heads_keys} holds one key per remembered answer, in the order the
## answers arrived; a key's line number is the index of the variable that
## holds that answer.  A shell has no associative array, and an answer holds
## newlines, so it cannot go in a list of its own.
remote_heads_keys=''
remote_heads_answers=0

## Usage: remote_heads_key DIRECTORY REMOTE
## Prints a key that two directories share exactly when one `git ls-remote`
## can answer for both of them.  Prints nothing if no such key applies, in
## which case the caller must ask its own question.
##
## Four things decide it.  One is the location that REMOTE resolves to (see
## `remote_location`), which is what determines whether two queries ask the
## same repository -- not whether the directories share a repository, and not
## what they call the remote.  Two spellings of one repository's URL, which
## `repository_key` equates, are different queries:  they reach the repository
## through different transports and credentials, which might be told
## different branches or might fail differently.
##
## Another is the SSH configuration, because `git_batch_ssh` takes
## `core.sshCommand` and `ssh.variant` from the directory it is given:  two
## directories that resolve one URL but reach it through different SSH
## commands are asking different questions, and must not share an answer.
##
## Another is `remote.<name>.uploadpack`, which names the program that git
## runs at the far end to list the refs.  Two directories that resolve one URL
## but run different programs there can both succeed and yet be told different
## branches -- the program is free to serve any repository at all -- so they
## too are asking different questions.  Git applies this setting only to a
## REMOTE that is the name of a remote, and a lookup for a REMOTE given as a
## URL or a pathname finds nothing, which is the same answer.
##
## The last is every other setting that can put something other than the named
## repository at the far end.  `remote.<name>.vcs` names a remote helper that
## answers in place of git's own transport; a proxy (`remote.<name>.proxy`,
## `http.proxy` and its per-URL forms, `core.gitProxy`) relays the query to
## whatever it likes; a credential helper (`credential.helper` and its per-URL
## forms) decides whose view of the refs comes back.  Each of these is
## `uploadpack` again:  two directories that resolve one URL but differ here
## can both succeed and be told different branches, so each belongs in the
## key.  The per-URL forms have names that this function cannot predict, and
## values that can repeat, so take the `http.*`, `credential.*` and
## `core.gitProxy` configuration whole rather than by name.
##
## A REMOTE that has no location, or a key that contains a newline (which the
## list of keys could not hold), yields no key at all:  a query that is not
## shared is always correct, merely slower.
remote_heads_key() {
  remote_heads_key_location="$(remote_location "$1" "$2")"
  if [ -z "${remote_heads_key_location}" ]; then
    return 0
  fi
  remote_heads_key_command="${GIT_SSH_COMMAND:-$(git -C "$1" config --get core.sshCommand || true)}"
  remote_heads_key_variant="${GIT_SSH_VARIANT:-$(git -C "$1" config --get ssh.variant || true)}"
  # A REMOTE that is a pathname or a URL can make a name that `git config`
  # rejects as malformed, which is no more than "this directory sets nothing
  # of the sort for this remote"; discard the diagnostic that says so.
  remote_heads_key_uploadpack="$(git -C "$1" config --get \
    "remote.$2.uploadpack" 2> /dev/null || true)"
  remote_heads_key_vcs="$(git -C "$1" config --get "remote.$2.vcs" \
    2> /dev/null || true)"
  remote_heads_key_proxy="$(git -C "$1" config --get "remote.$2.proxy" \
    2> /dev/null || true)"
  # The settings whose own names hold a URL, which no fixed list would find.
  # `git config` prints one per line; fold the newlines into tabs, because a
  # key is one line.  A directory that sets none of them prints nothing and
  # exits nonzero, which is not an error here.
  remote_heads_key_relays="$(git -C "$1" config --get-regexp \
    '^(http\.|credential\.|core\.gitproxy$)' 2> /dev/null | tr '\n' '\t')" \
    || remote_heads_key_relays=''
  remote_heads_key_key="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "${remote_heads_key_location}" "${remote_heads_key_command}" \
    "${remote_heads_key_variant}" "${remote_heads_key_uploadpack}" \
    "${remote_heads_key_vcs}" "${remote_heads_key_proxy}" \
    "${remote_heads_key_relays}")"
  case "${remote_heads_key_key}" in
    *'
'*) return 0 ;;
  esac
  printf '%s\n' "${remote_heads_key_key}"
}

## Usage: remote_heads DIRECTORY REMOTE KEY
## Asks REMOTE, in DIRECTORY, for its branches, and returns the status of
## `git ls-remote --heads`:  0 if the remote answered, nonzero if it could not
## be asked.  Sets ${remote_heads_output} to what the remote said, which is
## one "SHA<TAB>refname" line per branch.
##
## With a nonempty KEY, from `remote_heads_key`, an answer is remembered under
## that key and a later call with the same key returns it without asking
## again.  The result is one query per remote URL rather than one per
## directory.
##
## Only an answer is remembered; a failed query is made again by the next
## directory that asks.  A key names the settings that decide what is asked,
## not the directory, yet a query can still fail for a reason that belongs to
## the directory it ran in -- a clone that cannot be read, or a setting such
## as `protocol.*.allow` that forbids the query without changing what it would
## ask.  Remembering such a failure for the whole group would let one broken
## directory answer for its healthy siblings, which is how this scan reports
## nothing at all; remembering it until some fixed number of retries is spent
## only raises the number of broken directories that it takes to do so.  The
## price is that a remote that nothing can reach is asked once per directory,
## so such a group waits for one connection attempt per directory to time out
## rather than for one.  A scan that is slow when the network is down is
## better than a scan that is wrong when a directory is.
##
## The answer is returned in a variable rather than printed, because a caller
## that captured the output with `$(...)` would run this function in a
## subshell and lose what it remembered.
##
## `--heads`, rather than a pattern per branch:  one answer serves any number
## of questions, with no chunking and no command-line length limit.
remote_heads() {
  if [ -n "$3" ]; then
    remote_heads_index="$(printf '%s\n' "${remote_heads_keys}" \
      | grep -n -x -F -- "$3" | head -n 1)"
    remote_heads_index="${remote_heads_index%%:*}"
    if [ -n "${remote_heads_index}" ]; then
      eval "remote_heads_output=\${remote_heads_output_${remote_heads_index}}"
      return 0
    fi
  fi
  remote_heads_output="$(git_batch_ssh "$1" ls-remote --heads "$2" 2> /dev/null)"
  remote_heads_status="$?"
  if [ -n "$3" ] && [ "${remote_heads_status}" -eq 0 ]; then
    remote_heads_answers=$((remote_heads_answers + 1))
    remote_heads_keys="${remote_heads_keys}$3
"
    eval "remote_heads_output_${remote_heads_answers}=\${remote_heads_output}"
  fi
  return "${remote_heads_status}"
}

## Usage: only_dot_project DIRECTORY
## Returns 0 (true) if DIRECTORY holds nothing but Eclipse `.project` files:
## that is, if every entry of DIRECTORY is a `.project` file or is a directory
## that itself holds nothing but `.project` files.  A directory that holds
## nothing at all satisfies this, which is what lets an empty subdirectory --
## such as the `bin` that Eclipse makes for a project's build output -- count
## as nothing.
##
## This says only what is in DIRECTORY; the caller decides what that means.
## A directory that holds nothing satisfies this test only vacuously, so the
## variable `only_dot_project_found` is set to a nonempty value if at least
## one `.project` file was seen, and is left alone otherwise.  A caller that
## distinguishes a tree of `.project` files from a tree of nothing -- as
## `is_deleted_branch` does -- sets that variable to the empty string before
## the call and tests it after.  A shell function has no local variables, so
## the recursive calls below all set the one variable, and it therefore
## reports about the whole tree.
##
## A symbolic link is content, whether it names a directory, a file, or
## nothing:  it is neither skipped as a `.project` file nor descended into.
## Following one that names an ancestor would not terminate, and a link is
## something that the user put there.
##
## `find "$1" ! -name .project ! -type d` would be simpler, but `find`
## communicates through newline-separated text, which cannot represent a file
## name that contains a newline, whereas the globs and the positional
## parameters below can hold any file name.
##
## The entries that remain to be examined are held in the positional
## parameters, which a shell makes local to a function call, so the recursive
## call below gets its own and this call's are intact when it returns.  A
## `for` loop over a variable could not recurse, because a shell function has
## no local variables.
only_dot_project() {
  # In a directory that cannot be listed (but can be searched, such as one with
  # mode 711), every glob below expands to nothing, which is indistinguishable
  # from an empty directory.  Do not claim that such a directory holds nothing.
  if [ ! -r "$1" ]; then
    return 1
  fi
  set -- "$1"/* "$1"/.*
  while [ "$#" -gt 0 ]; do
    case "${1##*/}" in
      '.' | '..')
        shift
        continue
        ;;
      '.project')
        # Skip the Eclipse metadata itself.  A *directory* named `.project`
        # can hold anything, so leave it to the test below, which descends
        # into it like any other directory.
        if [ -f "$1" ] && [ ! -L "$1" ]; then
          only_dot_project_found=1
          shift
          continue
        fi
        ;;
    esac
    # When a pattern matches nothing, the shell leaves it unexpanded.  Such a
    # pathname names no entry, so it is not content.
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then
      shift
      continue
    fi
    if [ ! -d "$1" ] || [ -L "$1" ] || ! only_dot_project "$1"; then
      return 1
    fi
    shift
  done
  return 0
}

## Usage: is_deleted_branch DIRECTORY
## Tests whether DIRECTORY is on a branch that was deleted in its remote, and
## returns the status that the `is-deleted-branch` command documents:  0 if
## the branch was deleted in its remote or if DIRECTORY is the leftover of
## such a branch's directory, 1 if the branch still exists in its remote, 2 if
## DIRECTORY is not the top level of a working tree, and 3 if the question
## cannot be answered.  That command is a wrapper around this function, and
## its documentation is the documentation of this answer.
##
## The body lives here rather than in the command so that the other commands
## of this package can ask the question directly.
is_deleted_branch() {
  is_deleted_branch_dir="$1"

  # A path that does not exist -- or that exists but is not a directory -- is
  # certainly not a working tree.  Reject it here rather than leaving it to
  # `git -C`, for which the empty string is a documented no-op:
  # `git -C '' rev-parse` would answer about the current directory rather than
  # about the argument.
  # The `physical_path` call below also rejects the empty string, but only as
  # a side effect of `cd -- ''` failing; this test states the requirement
  # directly.
  if [ ! -d "${is_deleted_branch_dir}" ]; then
    return 2
  fi

  # A directory that holds nothing but Eclipse `.project` files is the
  # leftover of a branch directory whose working tree is gone:  what remains
  # is metadata, a `.project` file for each Eclipse project of the branch and
  # the directories that hold them, and none of the branch itself.  Such a
  # directory is as removable as one whose branch was deleted in its remote,
  # so answer 0 for it.
  #
  # Answer it before the tests below, which would call such a directory "not
  # the top level of a working tree" (status 2):  that is true, and it would
  # leave the caller's question -- may this directory be removed? -- unanswered
  # when it has an answer.  The tests below still decide every directory that
  # holds anything else, including a working tree, whose `.git` is not a
  # `.project` file and which `only_dot_project` therefore rejects at its
  # first entry.
  #
  # Require a `.project` file somewhere in the tree.  `only_dot_project` is
  # satisfied by a directory that holds nothing at all, and a tree of nothing
  # but empty directories is not evidence of an Eclipse project that a branch
  # directory once held.  The `.project` file need not be in DIRECTORY
  # itself:  a branch whose Eclipse projects were all below its top level,
  # such as a `java/lib` that Eclipse knew as a project, leaves its metadata
  # there and none at the top.
  only_dot_project_found=
  if only_dot_project "${is_deleted_branch_dir}" \
    && [ -n "${only_dot_project_found}" ]; then
    return 0
  fi

  # `git -C DIR rev-parse` succeeds for every directory within a working tree,
  # so also require that DIRECTORY is that working tree's top level.  A
  # subdirectory is not itself a working tree, and answering for the enclosing
  # one would answer a question that the caller did not ask.
  is_deleted_branch_toplevel="$(git -C "${is_deleted_branch_dir}" rev-parse \
    --show-toplevel 2> /dev/null)" || return 2
  if [ -z "${is_deleted_branch_toplevel}" ]; then
    # A bare repository has no working tree, so it is not on any branch.
    return 2
  fi
  # A pathname that cannot be canonicalized means that whether DIRECTORY is
  # the top level of a working tree cannot be determined.
  # (status 2 would assert that DIRECTORY is not the top level of a working
  # tree.)
  if ! is_deleted_branch_dir_real="$(physical_path "${is_deleted_branch_dir}")"; then
    echo "${SCRIPT_NAME}: cannot canonicalize: ${is_deleted_branch_dir}" >&2
    return 3
  fi
  if ! is_deleted_branch_top_real="$(physical_path "${is_deleted_branch_toplevel}")"; then
    echo "${SCRIPT_NAME}: cannot canonicalize: ${is_deleted_branch_toplevel}" >&2
    return 3
  fi
  if [ "${is_deleted_branch_dir_real}" != "${is_deleted_branch_top_real}" ]; then
    # Not the top level of a working tree, so it is not on any branch, deleted
    # or otherwise.
    return 2
  fi

  # A detached HEAD is not on a branch, so there is no remote branch to ask
  # about, and whether a branch was deleted cannot be determined.
  # Strip the known prefix ourselves, because `symbolic-ref --short` can return
  # "heads/BRANCH" when a tag and the branch have the same name.
  if ! is_deleted_branch_ref="$(git -C "${is_deleted_branch_dir}" symbolic-ref \
    --quiet HEAD 2> /dev/null)"; then
    return 3
  fi
  is_deleted_branch_branch="${is_deleted_branch_ref#refs/heads/}"

  # A branch with no commit does not yet exist even locally, so it was never
  # pushed and it was not deleted.  `git clone` of an empty repository leaves
  # HEAD on such a branch, and gives it upstream configuration that no push
  # ever justified.
  # `rev-parse --verify --quiet` exits 1 when the ref does not exist, which is
  # the case this tests for but would abort a caller that runs under `set -e`.
  is_deleted_branch_commit="$(git -C "${is_deleted_branch_dir}" rev-parse \
    --verify --quiet "${is_deleted_branch_ref}" || true)"
  if [ -z "${is_deleted_branch_commit}" ]; then
    return 3
  fi

  # The branch's upstream configuration:  a remote name and one or more refs
  # such as "refs/heads/BRANCH".
  # `git config --get` exits 1 when the key is not set, which a branch that has
  # no upstream configuration -- the common case that the comment below
  # describes -- is expected to be, but would abort a caller that runs under
  # `set -e`.
  is_deleted_branch_branch_remote="$(git -C "${is_deleted_branch_dir}" config \
    --get "branch.${is_deleted_branch_branch}.remote" || true)"
  is_deleted_branch_merge_refs="$(git -C "${is_deleted_branch_dir}" config \
    --get-all "branch.${is_deleted_branch_branch}.merge" || true)"

  # A branch exists in a remote because someone pushed it there, so ask the
  # remote that `git push` uses.  `push_remote` determines it; answering
  # "cannot tell" for a branch that was never pushed to the remote that
  # `remote.pushDefault` names is one reason for the order that it documents.
  is_deleted_branch_remote="$(push_remote "${is_deleted_branch_dir}" \
    "${is_deleted_branch_branch}")"
  if [ -z "${is_deleted_branch_remote}" ]; then
    # The clone has no remote, or it has several and none is named "origin",
    # so there is no remote branch to ask about.
    return 3
  fi

  # A branch has no upstream configuration until some command sets it, and
  # neither `git checkout -b BRANCH` (which `git-new-branch` runs) nor
  # `git push REMOTE BRANCH` sets it.  Such a branch can still exist in a
  # remote, under the name that `git push` gives it:  a branch of the same
  # name.  `branch.BRANCH.merge` names refs in `branch.BRANCH.remote`, so it
  # describes no other remote, and Git ignores it when `branch.BRANCH.remote`
  # is unset (`git pull` then reports "no tracking information").
  is_deleted_branch_configured=0
  is_deleted_branch_upstream_refs="refs/heads/${is_deleted_branch_branch}"
  if [ -n "${is_deleted_branch_merge_refs}" ] \
    && [ "${is_deleted_branch_remote}" = "${is_deleted_branch_branch_remote}" ]; then
    is_deleted_branch_configured=1
    is_deleted_branch_upstream_refs="${is_deleted_branch_merge_refs}"
  fi

  if [ "${is_deleted_branch_configured}" -eq 0 ] \
    && ! is_deleted_branch_was_pushed "${is_deleted_branch_dir}" \
      "${is_deleted_branch_remote}" "${is_deleted_branch_branch}" \
      "${is_deleted_branch_ref}" "${is_deleted_branch_commit}"; then
    # The branch has no upstream configuration and no sign of having been
    # pushed, so it was probably never pushed, and a branch that was never
    # pushed was not deleted.  Contacting the remote could not settle the
    # question:  a branch of this name in the remote might be someone else's,
    # and the absence of one is what a never-pushed branch and a deleted
    # branch both look like.  Answering without the network also keeps a scan
    # of many never-pushed branches, such as `git-orphaned-branches` performs,
    # from making one network request per branch.
    return 3
  fi

  # A ref name cannot contain a newline.  Preserve each configured merge value
  # as one argument so that ls-remote succeeds if any configured upstream ref
  # exists.
  is_deleted_branch_saved_ifs="${IFS}"
  IFS='
'
  set -f
  # shellcheck disable=SC2086
  set -- ${is_deleted_branch_upstream_refs}
  set +f
  IFS="${is_deleted_branch_saved_ifs}"

  # A `git ls-remote --heads` of the remote answers for every upstream ref
  # under refs/heads/, and one such query answers for every directory that
  # asks the same remote the same way -- which, in this package's workflow, is
  # every branch directory of one project.  `branch.BRANCH.merge` may name any
  # ref, and a ref outside refs/heads/ is not in that listing, so a directory
  # that configures one asks its own question below.
  is_deleted_branch_key=''
  is_deleted_branch_shared=1
  for is_deleted_branch_ref_arg in "$@"; do
    case "${is_deleted_branch_ref_arg}" in
      refs/heads/?*) ;;
      *) is_deleted_branch_shared=0 ;;
    esac
  done
  if [ "${is_deleted_branch_shared}" -eq 1 ]; then
    is_deleted_branch_key="$(remote_heads_key "${is_deleted_branch_dir}" \
      "${is_deleted_branch_remote}")"
  fi
  if [ -n "${is_deleted_branch_key}" ]; then
    if ! remote_heads "${is_deleted_branch_dir}" "${is_deleted_branch_remote}" \
      "${is_deleted_branch_key}"; then
      # The remote could not be contacted (say, the network is down), so it is
      # unknown whether the branch still exists there.
      echo "${SCRIPT_NAME}: cannot list branches of remote ${is_deleted_branch_remote} for ${is_deleted_branch_dir}" >&2
      return 3
    fi
    # Each line of the listing is "SHA<TAB>refname".
    is_deleted_branch_listed="$(printf '%s\n' "${remote_heads_output}" | cut -f 2)"
    for is_deleted_branch_ref_arg in "$@"; do
      if printf '%s\n' "${is_deleted_branch_listed}" \
        | grep -q -x -F -- "${is_deleted_branch_ref_arg}"; then
        # The branch still exists in the remote.
        return 1
      fi
    done
    # The branch was deleted in the remote.
    return 0
  fi

  # `git ls-remote --exit-code` exits with status 2 if no matching ref exists.
  # `git_batch_ssh` disables the interactive prompts that would otherwise
  # block this query forever.
  #
  # Ask in a condition rather than assigning `$?` after a standalone command,
  # which would abort a caller that runs under `set -e` -- and would do so in
  # the very case that this function exists to report, since a deleted branch
  # is what makes the command exit nonzero.
  if git_batch_ssh "${is_deleted_branch_dir}" ls-remote --exit-code \
    "${is_deleted_branch_remote}" "$@" > /dev/null 2>&1; then
    is_deleted_branch_status=0
  else
    is_deleted_branch_status="$?"
  fi
  case "${is_deleted_branch_status}" in
    0)
      # The branch still exists in the remote.
      return 1
      ;;
    2)
      # The branch was deleted in the remote.
      return 0
      ;;
    *)
      # The remote could not be contacted (say, the network is down), so it is
      # unknown whether the branch still exists there.
      echo "${SCRIPT_NAME}: cannot list branches of remote ${is_deleted_branch_remote} for ${is_deleted_branch_dir}" >&2
      return 3
      ;;
  esac
}
