# shellcheck shell=sh

# Functions that parse the names of clones, branch directories, and slugs; that
# find and create clones and forks; and that determine the GitHub repositories
# that a branch is pushed to and that its pull requests target.
#
# `common-functions.sh` sources this file.  A script uses these functions by
# sourcing that file, which says what the script must set first.

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

## Usage: enter_slug_clone SLUG [--clone | --clone-for-new-branch]
## SLUG is a slug ORG:BRANCH, such as "mernst:feature"; it contains ":".
## Changes the current directory to the clone that SLUG names:  the sibling
## clone PROJECT-fork-ORG of the project that the current directory belongs
## to, or the clone PROJECT itself if ORG is "-".  If there is no clone
## PROJECT-fork-ORG and ORG owns the project's upstream repository, as
## typetools owns typetools/checker-framework, then ORG:BRANCH names the clone
## PROJECT, as -:BRANCH does; see `owns_upstream`.  The upstream repository is
## that of the clone PROJECT, or of the current directory's clone if there is
## no clone PROJECT.  The current directory can
## be any working tree of the project, such as PROJECT, PROJECT-fork-OTHERORG,
## or one of their branch directories, so a command that runs this and then
## acts on BRANCH in the current directory does the same thing in all of them.
## Sets ${SLUG_CLONE} to the clone's pathname, sets the variables that
## `parse_slug` sets, and sets ${clone_project} and ${clone_org} as
## `parse_clone_name` does for the clone that holds the current directory.
## Sets ${SLUG_UPSTREAM_REMOTE} to the name of the clone PROJECT's remote that
## is the upstream repository, such as "origin", if ORG owns the upstream
## repository and so the slug names the clone PROJECT, and to the empty string
## otherwise.  ORG's branch is on that remote.
##
## With --clone, a clone PROJECT-fork-ORG that does not exist is first made
## by `clone_fork`, if ORG's fork has the branch BRANCH.  With
## --clone-for-new-branch, which is for a caller that creates BRANCH, it is
## made if ORG's fork exists.  The fork's URL is derived from the clone
## PROJECT, or from the current directory's clone if there is no clone
## PROJECT.  Without either option, or if the slug names the clone PROJECT, a
## missing clone is an error.
##
## Returns 0 on success.  Otherwise prints an error on standard error and
## leaves the current directory as it was.  Returns 2 if ORG cannot name a
## clone or BRANCH is not a valid branch name, so that the caller can print
## its usage message, and returns 1 if the slug names no clone, or names one
## that --clone cannot make.
##
## This must not run in a subshell, such as in `$(...)`, because then the
## change of directory would not reach the caller.
##
## The project's directories are named PROJECT, PROJECT-fork-ORG, and each of
## those followed by -branch-BRANCH, side by side.  A linked worktree might
## lie elsewhere, as in PROJECT/.claude/worktrees/NAME, so the names are those
## of its main working tree, which holds the `.git` directory.  A bare
## repository, or a git directory outside its working tree, has no main
## working tree that this naming convention could describe, so then they are
## those of the current working tree.
##
## The variables that this function sets for its own use are prefixed with an
## abbreviation of its name, so that they cannot collide with a sourcing
## script's variables.
enter_slug_clone() {
  SLUG_CLONE=''
  SLUG_UPSTREAM_REMOTE=''
  if ! check_slug_org "$1"; then
    return 2
  fi
  # Reject a bad branch name, such as one that contains another ":" or starts
  # with "-", before the caller does anything in the clone, rather than when
  # the branch is used.  A name that `--branch` rewrites, such as "@{-1}", is a
  # reference to a branch rather than a branch's name.
  if [ -z "${slug_branch}" ] \
    || [ "$(git check-ref-format --branch "${slug_branch}" 2> /dev/null)" != "${slug_branch}" ]; then
    echo "${SCRIPT_NAME}: ERROR: not a valid branch name: ${slug_branch}" >&2
    return 2
  fi
  if ! esc_toplevel="$(git rev-parse --show-toplevel 2> /dev/null)" \
    || [ -z "${esc_toplevel}" ]; then
    report_unusable_working_tree "${PWD}" 'ERROR: ' \
      'a slug must be given in a working tree of the project, such as PROJECT, PROJECT-fork-ORG, or one of their branch directories' \
      || true
    return 1
  fi
  esc_main="$(main_working_tree)" || esc_main="${esc_toplevel}"
  esc_main_name="$(basename -- "${esc_main}")"
  parse_clone_name "${esc_main_name%%-branch-*}"
  esc_project="$(dirname -- "${esc_main}")/${clone_project}"
  # True if the slug names the clone PROJECT.
  esc_names_project=false
  if [ "${slug_org}" = '-' ]; then
    esc_names_project=true
  else
    esc_clone="$(dirname -- "${esc_main}")/${clone_project}-fork-${slug_org}"
    if [ ! -d "${esc_clone}" ]; then
      # The clone whose remotes say what the project's repositories are:  the
      # clone PROJECT, whose remote is the upstream repository, in preference
      # to the current directory's clone, which might be of some other fork.
      if is_working_tree_top "${esc_project}"; then
        esc_source="${esc_project}"
      else
        esc_source="${esc_main}"
      fi
      if owns_upstream "${slug_org}" "${esc_source}"; then
        echo "${SCRIPT_NAME}: ${slug_org} owns the upstream repository of ${esc_source}, so the slug $1 names the clone ${esc_project}" >&2
        esc_names_project=true
      fi
    fi
  fi
  if "${esc_names_project}"; then
    esc_clone="${esc_project}"
    esc_description="clone of ${clone_project}"
  else
    esc_description="clone of ${slug_org}'s fork of ${clone_project}"
  fi
  if [ ! -d "${esc_clone}" ]; then
    # The branch that ORG's fork must have for the clone to be made, or the
    # empty string if the fork need only exist.
    case "${2:-}" in
      --clone) esc_fork_branch="${slug_branch}" ;;
      --clone-for-new-branch) esc_fork_branch='' ;;
      *) esc_fork_branch='-' ;;
    esac
    if [ "${esc_fork_branch}" = '-' ] || "${esc_names_project}"; then
      echo "${SCRIPT_NAME}: ERROR: there is no ${esc_description}:  directory does not exist: ${esc_clone}" >&2
      return 1
    fi
    if ! clone_fork "${esc_clone}" "${slug_org}" "${esc_fork_branch}" "${esc_source}"; then
      return 1
    fi
  fi
  is_working_tree_top "${esc_clone}"
  case "$?" in
    0) ;;
    2)
      echo "${SCRIPT_NAME}: ERROR: cannot canonicalize: ${esc_clone}" >&2
      return 1
      ;;
    *)
      report_not_working_tree_top "${esc_clone}" 'ERROR: '
      return 1
      ;;
  esac
  if [ "${slug_org}" != '-' ] && "${esc_names_project}"; then
    # shellcheck disable=SC2034 # set for the caller
    SLUG_UPSTREAM_REMOTE="$(upstream_remote "${esc_clone}" 2> /dev/null)"
  fi
  if ! cd -- "${esc_clone}"; then
    echo "${SCRIPT_NAME}: ERROR: cannot cd to ${esc_clone}" >&2
    return 1
  fi
  # shellcheck disable=SC2034 # set for the caller
  SLUG_CLONE="${esc_clone}"
}

## Usage: split_repository_url URL
## Sets ${repo_url_prefix}, ${repo_url_owner}, and ${repo_url_repo} to the
## parts of URL, the URL or pathname of a repository OWNER/REPO, such as
## "git@github.com:", "typetools", and "checker-framework.git" for
## "git@github.com:typetools/checker-framework.git".  OWNER is the component
## of URL's path that precedes the last one, after any trailing "/" is
## removed, and the prefix is everything before OWNER.  Sets all three to the
## empty string and returns 1 if URL has no such component, as "proj.git" and
## "https://github.com/proj.git" do not:  in the latter, "github.com" is the
## host, not a component of the path.
split_repository_url() {
  repo_url_prefix=''
  repo_url_owner=''
  repo_url_repo=''
  sru_url="$(printf '%s\n' "$1" | sed -e 's|/*$||')"
  sru_repo="${sru_url##*/}"
  sru_rest="${sru_url%/*}"
  if [ "${sru_rest}" = "${sru_url}" ] || [ -z "${sru_repo}" ]; then
    return 1
  fi
  # What precedes OWNER, which ends with the ":" of an scp-style URL or with a
  # "/".
  sru_prefix="$(printf '%s\n' "${sru_rest}" \
    | sed -n -e 's|^\(.*[:/]\)[^:/][^:/]*$|\1|p')"
  # In a URL with a scheme, such as "ssh://git@host:22/proj.git", the path
  # starts at the first "/" after the host, so a prefix with no "/" there
  # ends within the host, and what follows it is not OWNER.
  case "${sru_prefix}" in
    '') return 1 ;;
    *://*/*) ;;
    *://*) return 1 ;;
  esac
  repo_url_prefix="${sru_prefix}"
  repo_url_owner="${sru_rest#"${sru_prefix}"}"
  repo_url_repo="${sru_repo}"
}

## Usage: fork_url URL ORG
## Prints URL, the URL or pathname of a repository OWNER/REPO, with OWNER
## replaced by ORG.  For example, `fork_url
## git@github.com:typetools/checker-framework.git cushon` prints
## "git@github.com:cushon/checker-framework.git".  Prints nothing and returns
## 1 if URL has no OWNER; see `split_repository_url`.
fork_url() {
  split_repository_url "$1" || return 1
  printf '%s%s/%s\n' "${repo_url_prefix}" "$2" "${repo_url_repo}"
}

## Usage: same_owner OWNER1 OWNER2
## Returns 0 if OWNER1 and OWNER2, such as "typetools" and "TypeTools", name
## the same owner of repositories.  GitHub ignores the case of an owner's
## name.
same_owner() {
  [ -n "$1" ] && [ "$(lowercase "$1")" = "$(lowercase "$2")" ]
}

## Usage: lowercase STRING
## Prints STRING in lower case, such as "typetools/jdk" for "TypeTools/JDK".
lowercase() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

## Usage: is_working_tree_top DIRECTORY
## Returns 0 if DIRECTORY is the top level of a working tree, 2 if DIRECTORY
## cannot be canonicalized, as when it does not exist or cannot be entered,
## and 1 otherwise.  A directory within a working tree, which is not its top
## level, would make a command that runs git there act on whatever repository
## contains it.  Both pathnames are canonicalized, because git can spell a
## pathname differently than `pwd -P` does, as Git for Windows does.
is_working_tree_top() {
  if ! iwtt_real="$(physical_path "$1" 2> /dev/null)" || [ -z "${iwtt_real}" ]; then
    return 2
  fi
  iwtt_top="$(git -C "$1" rev-parse --show-toplevel 2> /dev/null)" \
    && [ -n "${iwtt_top}" ] \
    && [ "$(physical_path "${iwtt_top}" 2> /dev/null)" = "${iwtt_real}" ]
}

## Usage: gitfile_git_dir DIRECTORY
## Prints the git directory that the file DIRECTORY/.git names, and returns
## 0.  An example is "/home/me/proj/.git/worktrees/proj-branch-x" in the
## linked worktree "/home/me/proj-branch-x".  (A linked worktree and a
## submodule each have a `.git` file, of the form "gitdir: PATH".)  A
## relative PATH is printed as an absolute pathname, with symbolic links and
## ".." resolved in the part of it that exists.  Prints nothing and returns 1
## if DIRECTORY/.git is not a readable file of that form.  Does not check
## whether the git directory exists.
gitfile_git_dir() {
  [ -f "$1/.git" ] || return 1
  # Clear the variable, because a `read` that cannot open the file leaves it
  # unchanged.  `read` fails on a last line that lacks a newline, so test the
  # line too.  The diagnostic of a file that cannot be opened is discarded:
  # this function's answer, that the file names no git directory, is enough.
  ggd_line=
  IFS= read -r ggd_line 2> /dev/null < "$1/.git" || [ -n "${ggd_line}" ] || return 1
  # Git ignores carriage returns at the end of the file, as in a file with
  # CRLF line endings.
  ggd_cr="$(printf '\r')"
  while [ "${ggd_line%"${ggd_cr}"}" != "${ggd_line}" ]; do
    ggd_line="${ggd_line%"${ggd_cr}"}"
  done
  case "${ggd_line}" in
    'gitdir: '?*) ggd_path="${ggd_line#gitdir: }" ;;
    *) return 1 ;;
  esac
  # Remove trailing slashes, which git accepts, so that the last component of
  # the printed pathname is the git directory's own name.
  while [ "${ggd_path%/}" != "${ggd_path}" ] && [ -n "${ggd_path%/}" ]; do
    ggd_path="${ggd_path%/}"
  done
  case "${ggd_path}" in
    /* | [A-Za-z]:[/\\]*) ;;
    *)
      # Git interprets a relative pathname relative to the directory that
      # holds the `.git` file.  Canonicalize the longest prefix that is an
      # existing directory, so that "/home/me/wt/../proj/.git" is printed as
      # "/home/me/proj/.git" even if "/home/me/proj" does not exist.
      ggd_head="$1/${ggd_path}"
      ggd_tail=
      while [ ! -d "${ggd_head}" ]; do
        ggd_tail="/$(basename -- "${ggd_head}")${ggd_tail}"
        ggd_head="$(dirname -- "${ggd_head}")"
      done
      if ggd_head="$(physical_path "${ggd_head}" 2> /dev/null)" && [ -n "${ggd_head}" ]; then
        ggd_path="${ggd_head%/}${ggd_tail}"
      else
        ggd_path="$1/${ggd_path}"
      fi
      ;;
  esac
  printf '%s\n' "${ggd_path}"
}

## Usage: missing_git_dir DIRECTORY
## Prints the git directory that the file DIRECTORY/.git names, as
## `gitfile_git_dir` does, and returns 0, if that git directory does not
## exist or is not a directory.  An example is
## "/home/me/proj/.git/worktrees/proj-branch-x", in a linked worktree whose
## main working tree "/home/me/proj" was deleted.  Prints nothing and returns
## 1 if DIRECTORY/.git is not a readable file of the form "gitdir: PATH", or
## if the git directory that it names is a directory.
missing_git_dir() {
  mgd_path="$(gitfile_git_dir "$1")" || return 1
  # Git requires a directory; it rejects a regular file.
  [ -d "${mgd_path}" ] && return 1
  printf '%s\n' "${mgd_path}"
}

## Usage: report_unusable_working_tree DIRECTORY PREFIX MESSAGE
## Prints to standard error a diagnostic that DIRECTORY, a directory that git
## cannot use as a working tree, is unusable.  If DIRECTORY is in a broken
## working tree, prints the diagnostic that `report_broken_working_tree`
## prints, and returns 0.  Otherwise prints MESSAGE, such as "not the top
## level of a git working tree: DIRECTORY", and returns 1.  PREFIX, such as
## "ERROR: " or "", begins the diagnostic's first line, after the name of the
## command.
report_unusable_working_tree() {
  report_broken_working_tree "$1" "$2" && return 0
  echo "${SCRIPT_NAME}: $2$3" >&2
  return 1
}

## Usage: report_not_working_tree_top DIRECTORY [PREFIX]
## Prints to standard error a diagnostic that DIRECTORY is not the top level
## of a git working tree, as `report_unusable_working_tree` does.  PREFIX,
## such as "ERROR: ", begins the diagnostic's first line, after the name of
## the command.
report_not_working_tree_top() {
  report_unusable_working_tree "$1" "${2:-}" "not the top level of a git working tree: $1" || true
}

## Usage: report_broken_working_tree DIRECTORY [PREFIX]
## If DIRECTORY is in a broken working tree, prints a diagnostic that says so
## to standard error, and returns 0.  Otherwise prints nothing and returns 1.
## PREFIX, such as "ERROR: ", begins the diagnostic's first line, after the
## name of the command.
##
## A broken working tree is the nearest of DIRECTORY and its ancestors that
## holds a `.git`, if that `.git` is a file that names a git directory that
## does not exist or is not a directory.  An example is a linked worktree whose main working tree
## was deleted:  its files remain, but git refuses every command in it, saying
## only "not a git repository".  The diagnostic names the missing git
## directory and, for a linked worktree, says whether the repository that the
## worktree belongs to exists.
report_broken_working_tree() {
  rbwt_dir="$(physical_path "$1" 2> /dev/null)" || return 1
  [ -n "${rbwt_dir}" ] || return 1
  # Git searches upward for a `.git`, and it stops at the first one that it
  # finds, even one that names a git directory that does not exist.
  rbwt_top="${rbwt_dir}"
  while [ ! -e "${rbwt_top}/.git" ] && [ ! -L "${rbwt_top}/.git" ]; do
    [ "${rbwt_top}" = / ] && return 1
    rbwt_top="$(dirname -- "${rbwt_top}")"
  done
  rbwt_missing="$(missing_git_dir "${rbwt_top}")" || return 1
  if [ "${rbwt_top}" = "${rbwt_dir}" ]; then
    echo "${SCRIPT_NAME}: ${2:-}broken git working tree: $1" >&2
  else
    echo "${SCRIPT_NAME}: ${2:-}in a broken git working tree: $1" >&2
    echo "${SCRIPT_NAME}: the broken working tree is: ${rbwt_top}" >&2
  fi
  if [ -e "${rbwt_missing}" ] || [ -L "${rbwt_missing}" ]; then
    echo "${SCRIPT_NAME}: its .git file names, as its git directory, something that is not a directory: ${rbwt_missing}" >&2
    return 0
  fi
  echo "${SCRIPT_NAME}: its .git file names a git directory that does not exist: ${rbwt_missing}" >&2
  # The git directory of a linked worktree is REPOSITORY/worktrees/NAME,
  # where REPOSITORY is the git directory of the main working tree, such as
  # "/home/me/proj/.git".  A git directory made by `git clone
  # --separate-git-dir` can also have a parent named "worktrees", so an
  # existing REPOSITORY is reported only if it is a git directory.
  rbwt_parent="${rbwt_missing%/*}"
  [ "${rbwt_parent##*/}" = worktrees ] || return 0
  rbwt_repository="${rbwt_parent%/*}"
  if [ -f "${rbwt_repository}/HEAD" ]; then
    echo "${SCRIPT_NAME}: its repository exists but no longer registers this worktree: ${rbwt_repository}" >&2
  elif [ ! -e "${rbwt_repository}" ]; then
    echo "${SCRIPT_NAME}: its repository does not exist; it was moved or deleted: ${rbwt_repository}" >&2
    # Quote the pathname if the shell would not take it as one word.
    case "${rbwt_top}" in
      *[!A-Za-z0-9/._+-]*)
        rbwt_quoted="'$(printf '%s\n' "${rbwt_top}" | sed "s/'/'\\\\''/g")'"
        ;;
      *) rbwt_quoted="${rbwt_top}" ;;
    esac
    echo "${SCRIPT_NAME}: if the repository was moved, running \`git worktree repair ${rbwt_quoted}\` in it reconnects this worktree" >&2
  fi
}

## Usage: upstream_repository DIRECTORY
## Sets three variables that describe the upstream repository of the clone in
## the working tree DIRECTORY, which is a clone of the project, such as
## PROJECT or PROJECT-fork-OTHERORG.  Returns 1, setting each to the empty
## string, if the clone has no remote that `upstream_remote` chooses.
##
##  * ${upstream_repo_url} is the URL, as configured, before
##    `url.<base>.insteadOf` rewrites it, of the remote that `upstream_remote`
##    chooses, such as "git@github.com:typetools/checker-framework.git".  A
##    clone PROJECT-fork-OTHERORG without a remote "upstream" might have only
##    its fork as that remote, so this is the URL of some repository of the
##    project, but not necessarily of the upstream one.
##  * ${upstream_repo_slug} is the GitHub slug of the upstream repository, such
##    as "typetools/checker-framework", or is empty if it is unknown.
##  * ${upstream_repo_owner} is the owner of the upstream repository, such as
##    "typetools", or is empty if it is unknown.
##
## The upstream repository is the one that `gh` uses by default, which the
## setting `remote.REMOTE.gh-resolved` of some remote REMOTE names, as
## `gh repo set-default` writes it:  either a GitHub slug, or "base" for
## REMOTE itself.  Without that setting, it is the repository at
## ${upstream_repo_url}, unless that is OTHERORG's, in a clone
## PROJECT-fork-OTHERORG; then the upstream repository is unknown.
##
## The variables that this function sets for its own use are prefixed with an
## abbreviation of its name, so that they cannot collide with a sourcing
## script's variables.
upstream_repository() {
  upstream_repo_url=''
  upstream_repo_slug=''
  upstream_repo_owner=''
  if ! ur_remote="$(upstream_remote "$1" 2> /dev/null)"; then
    return 1
  fi
  upstream_repo_url="$(git -C "$1" config --get "remote.${ur_remote}.url")"
  gh_resolved "$1" || true
  # shellcheck disable=SC2154 # set by `gh_resolved`, in common-functions.sh
  case "${gh_resolved_value}" in
    */*)
      upstream_repo_slug="${gh_resolved_value}"
      upstream_repo_owner="${gh_resolved_value%%/*}"
      return 0
      ;;
    base)
      ur_url="$(git -C "$1" config --get "remote.${gh_resolved_remote}.url")"
      ;;
    *)
      ur_url="${upstream_repo_url}"
      ur_name="$(basename -- "$(main_working_tree "$1" || printf '%s\n' "$1")")"
      ur_name="${ur_name%%-branch-*}"
      split_repository_url "${ur_url}" || true
      case "${ur_name}" in
        *-fork-*)
          if same_owner "${repo_url_owner}" "${ur_name##*-fork-}"; then
            return 0
          fi
          ;;
      esac
      ;;
  esac
  upstream_repo_slug="$(github_slug "${ur_url}")"
  split_repository_url "${ur_url}" || true
  upstream_repo_owner="${repo_url_owner}"
}

## Usage: owns_upstream ORG DIRECTORY
## Returns 0 if ORG owns the upstream repository of the clone in the working
## tree DIRECTORY, as typetools owns typetools/checker-framework; see
## `upstream_repository`, whose variables this sets.  A slug ORG:BRANCH then
## names a branch of the upstream repository itself, as GitHub's
## "typetools:feature" does for a pull request from a branch of
## typetools/checker-framework.
owns_upstream() {
  upstream_repository "$2" && same_owner "${upstream_repo_owner}" "$1"
}

## Usage: clone_fork DIRECTORY ORG BRANCH SOURCE
## Clones ORG's fork of the project that SOURCE is a clone of into DIRECTORY,
## which does not exist, if that fork has the branch BRANCH, so that a caller
## that then checks out BRANCH there clones nothing for a mistyped ORG or
## BRANCH.  If BRANCH is the empty string, as for a caller that then creates
## a new branch there, the fork need only exist.  SOURCE is a working tree of
## a clone of the project, such as PROJECT.  The fork's URL is the URL of
## SOURCE's upstream remote (see `upstream_repository`), with its owner
## replaced by ORG (see `fork_url`), so `git@github.com:typetools/proj.git`
## gives `git@github.com:ORG/proj.git`.  Returns 0 on success.  Otherwise
## prints an error on standard error and returns 1.
##
## Unless SOURCE is a shallow or a partial clone, the new clone borrows the
## objects that SOURCE has, so that only the others are downloaded, and then
## copies the borrowed ones (`git clone --reference --dissociate`), so that it
## does not depend on SOURCE afterward.  Its remote "origin" is ORG's fork.
## If the owner of SOURCE's upstream repository is known (see
## `upstream_repository`), its remote "upstream" is the upstream repository,
## whose URL is the fork's with ORG replaced by that owner; it is not fetched.
## Then, as in a clone that a user makes of a fork, `git-new-branch` starts a
## new branch at the upstream repository's default branch, and
## `git-pull-upstream` merges from it.  If the GitHub slug ("ORG/REPO") of
## SOURCE's upstream repository is known, the clone's
## `remote.origin.gh-resolved` is set to it, so that `gh` acts on pull
## requests of the upstream repository, as it does in a clone of a fork in
## which `gh repo set-default` has been run.
##
## The queries of the fork disable interactive prompts, as `git_batch_ssh`
## does, so that this function cannot block forever when run from a script.
##
## The variables that this function sets for its own use are prefixed with an
## abbreviation of its name, so that they cannot collide with a sourcing
## script's variables.
clone_fork() {
  cf_dir="$1"
  cf_org="$2"
  cf_branch="$3"
  cf_source="$4"
  if ! upstream_repository "${cf_source}"; then
    echo "${SCRIPT_NAME}: ERROR: cannot determine the URL of ${cf_org}'s fork, because ${cf_source} has no remote named \"upstream\" or \"origin\", and not exactly one remote" >&2
    return 1
  fi
  # The URL as configured, rather than as `url.<base>.insteadOf` rewrites it,
  # so that the rewriting applies in the new clone as it does here.
  if ! cf_fork="$(fork_url "${upstream_repo_url}" "${cf_org}")"; then
    echo "${SCRIPT_NAME}: ERROR: cannot determine the URL of ${cf_org}'s fork from ${upstream_repo_url}, the URL of the upstream remote of ${cf_source}" >&2
    return 1
  fi
  cf_upstream_slug="${upstream_repo_slug}"
  cf_upstream_url=''
  if [ -n "${upstream_repo_owner}" ]; then
    cf_upstream_url="$(fork_url "${upstream_repo_url}" "${upstream_repo_owner}")" || cf_upstream_url=''
  fi

  # Run git in SOURCE, so that SOURCE's `core.sshCommand` and `ssh.variant`,
  # which `git_batch_ssh` passes to git, reach the fork as they reach SOURCE's
  # own remote.  `git ls-remote` also reads the rest of SOURCE's
  # configuration, such as `url.<base>.insteadOf`, but `git clone` reads none
  # of it, so none of it is copied into the new clone.
  #
  # `git ls-remote --exit-code` exits with status 2 if the fork has no such
  # branch, and with some other nonzero status if the fork could not be asked
  # at all, as for a fork that does not exist.  Without a branch, the query
  # is only whether the fork can be asked; even an empty fork can.
  if [ -n "${cf_branch}" ]; then
    set -- --exit-code "${cf_fork}" "refs/heads/${cf_branch}"
    cf_about=" about branch ${cf_branch}"
  else
    set -- "${cf_fork}" HEAD
    cf_about=''
  fi
  cf_error="$(git_batch_ssh "${cf_source}" ls-remote "$@" 2>&1 > /dev/null)"
  case "$?" in
    0) ;;
    2)
      echo "${SCRIPT_NAME}: ERROR: ${cf_org}'s fork ${cf_fork} has no branch ${cf_branch}, so ${cf_dir} was not made" >&2
      return 1
      ;;
    *)
      echo "${SCRIPT_NAME}: ERROR: cannot ask ${cf_fork}${cf_about}, so ${cf_dir} was not made:" >&2
      if [ -n "${cf_error}" ]; then
        echo "${cf_error}" >&2
      fi
      # GitHub names a fork differently than the upstream repository if its
      # owner already has a repository of that name.
      echo "${SCRIPT_NAME}: If ${cf_org}'s fork has a different URL, clone it into ${cf_dir} and run ${SCRIPT_NAME} again." >&2
      return 1
      ;;
  esac

  # A shallow repository cannot serve as a reference.  Neither can a partial
  # clone, one that lacks some objects until they are needed:  the new clone
  # does not download the objects that the reference's refs reach, so it would
  # lack the ones that the reference lacks too, and `--dissociate` would fail
  # to copy them.
  set --
  if [ "$(git -C "${cf_source}" rev-parse --is-shallow-repository 2> /dev/null)" = 'false' ] \
    && [ -z "$(git -C "${cf_source}" config --get extensions.partialClone)" ] \
    && ! git -C "${cf_source}" config --bool --get-regexp '^remote\..*\.promisor$' \
      | grep -q ' true$' \
    && cf_reference="$(git -C "${cf_source}" rev-parse --path-format=absolute --git-common-dir 2> /dev/null)" \
    && [ -n "${cf_reference}" ]; then
    set -- --reference-if-able "${cf_reference}" --dissociate
  fi
  echo "${SCRIPT_NAME}: cloning ${cf_fork} into ${cf_dir}" >&2
  # If the clone fails, `git clone` removes the directory that it made.
  if ! git_batch_ssh "${cf_source}" clone --origin origin "$@" -- "${cf_fork}" "${cf_dir}"; then
    echo "${SCRIPT_NAME}: ERROR: cannot clone ${cf_fork} into ${cf_dir}" >&2
    return 1
  fi
  if [ -n "${cf_upstream_url}" ] \
    && ! git -C "${cf_dir}" remote add upstream "${cf_upstream_url}"; then
    echo "${SCRIPT_NAME}: warning: cannot add the remote upstream ${cf_upstream_url} in ${cf_dir}" >&2
  fi
  if [ -n "${cf_upstream_slug}" ] \
    && ! git -C "${cf_dir}" config remote.origin.gh-resolved "${cf_upstream_slug}"; then
    echo "${SCRIPT_NAME}: warning: cannot set remote.origin.gh-resolved in ${cf_dir}" >&2
  fi
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

## Usage: github_slug URL
## Prints the GitHub slug, such as "ORG/REPO", of the GitHub repository whose
## URL is URL, such as "git@github.com:ORG/REPO.git", or nothing if URL is not
## the URL of a GitHub repository.
github_slug() {
  github_slug_line="$(printf 'url %s\n' "$1" | github_slugs)"
  if [ -n "${github_slug_line}" ]; then
    printf '%s\n' "${github_slug_line#url }"
  fi
}

## Usage: github_slugs
## Reads lines of the form "KEY URL", where KEY contains no space, such as
## "origin git@github.com:ORG/REPO.git", and prints "KEY SLUG" for each line
## whose URL is the URL of a GitHub repository, where SLUG is that
## repository's GitHub slug, such as "ORG/REPO".
github_slugs() {
  sed -n -e 's|/*$||' -e 's|\.git$||' \
    -e 's|^\([^ ]*\) git@github\.com:\([^/]*/[^/]*\)$|\1 \2|p' \
    -e 's|^\([^ ]*\) ssh://git@github\.com/\([^/]*/[^/]*\)$|\1 \2|p' \
    -e 's|^\([^ ]*\) https://\([^@/]*@\)\{0,1\}github\.com/\([^/]*/[^/]*\)$|\1 \3|p'
}

## Usage: github_remote_slugs
## Prints a line "REMOTE SLUG" for each URL of each remote REMOTE of the clone
## in the current directory that is the URL of a GitHub repository, where
## SLUG is that repository's GitHub slug, such as "typetools/jdk".  Each URL
## is considered both as configured and as `url.BASE.insteadOf` rewrites it,
## so a remote can appear more than once.
github_remote_slugs() {
  github_remote_slugs_tab="$(printf '\t')"
  # `git config` prints "remote.REMOTE.url URL", and `git remote -v` prints
  # "REMOTE<tab>URL (fetch)" and "REMOTE<tab>URL (push)".
  {
    git config --get-regexp '^remote\..*\.url$'
    git remote -v
  } | sed -n \
    -e 's/^remote\.\(.*\)\.url /\1 /p' \
    -e "s/^\\([^ ${github_remote_slugs_tab}]*\\)${github_remote_slugs_tab}\\(.*\\) (fetch)\$/\\1 \\2/p" \
    | github_slugs
}

## The number of seconds that a query of GitHub can take before it is
## abandoned, and fails, so that an unresponsive GitHub does not stall a
## command.
github_query_seconds=30

## Usage: with_timeout SECONDS COMMAND [ARGUMENT...]
## Runs COMMAND, an executable rather than a shell function, with the
## ARGUMENTs, and returns its exit status.  Kills COMMAND and returns 124 if it
## runs for more than SECONDS seconds.  The limit needs the `timeout` command
## of GNU coreutils, which Homebrew installs on macOS as `gtimeout`; if
## neither is installed, COMMAND runs without a limit.
with_timeout() {
  with_timeout_seconds="$1"
  shift
  if command -v timeout > /dev/null 2>&1; then
    timeout "${with_timeout_seconds}" "$@"
  elif command -v gtimeout > /dev/null 2>&1; then
    gtimeout "${with_timeout_seconds}" "$@"
  else
    "$@"
  fi
}

## Usage: gh_query DESCRIPTION COMMAND [ARGUMENT...]
## Runs COMMAND, such as `gh`, with the ARGUMENTs and with the time limit
## ${github_query_seconds}, and prints its standard output.  If COMMAND fails,
## prints a diagnostic that says that DESCRIPTION failed, followed by
## COMMAND's error output, and returns 1.  If COMMAND succeeds, its error
## output, such as a warning that gh prints, is discarded, so that it is not
## mistaken for output.  DESCRIPTION is what COMMAND does, phrased as a
## failure, such as "cannot list the pull requests of ORG/REPO"; used for
## diagnostics.
gh_query() {
  gh_query_description="$1"
  shift
  if ! gh_query_errors_file="$(mktemp "${TMPDIR:-/tmp}/${SCRIPT_NAME}-gh.XXXXXX")" \
    || [ -z "${gh_query_errors_file}" ]; then
    printf '%s: %s:\ncannot create a temporary file\n' "${SCRIPT_NAME}" "${gh_query_description}" >&2
    return 1
  fi
  if ! gh_query_output="$(with_timeout "${github_query_seconds}" "$@" < /dev/null 2> "${gh_query_errors_file}")"; then
    gh_query_errors="$(cat -- "${gh_query_errors_file}")"
    rm -f -- "${gh_query_errors_file}"
    if [ -z "${gh_query_errors}" ]; then
      gh_query_errors="$1 failed without a message, perhaps after timing out after ${github_query_seconds} seconds"
    fi
    printf '%s: %s:\n%s\n' "${SCRIPT_NAME}" "${gh_query_description}" "${gh_query_errors}" >&2
    return 1
  fi
  rm -f -- "${gh_query_errors_file}"
  printf '%s\n' "${gh_query_output}"
}

## Usage: working_copy_directories DIRECTORY
## Prints the name of each working copy directory in DIRECTORY, one per line,
## in the order of the C locale, in which, for example, "Z" precedes "a", so
## that the order does not depend on the user's locale.  A working copy
## directory is an entry of DIRECTORY that is the top level of a git working
## tree.  Entries whose names start with "." are ignored, as are symbolic
## links, which could name a working tree twice, and directories that are not
## the top level of a working tree, such as an ordinary directory inside a
## clone.  An entry whose name contains a newline or a tab is skipped, with a
## warning, so that a caller can store each name as a field of a line whose
## fields are separated by tabs.  DIRECTORY must be a physical path, such as
## `physical_path` prints, such as "/home/me/projects".
working_copy_directories() {
  for working_copy_directories_path in "$1"/*; do
    working_copy_directories_name="$(basename -- "${working_copy_directories_path}")"
    case "${working_copy_directories_name}" in
      *'
'* | *"$(printf '\t')"*)
        echo "${SCRIPT_NAME}: skipping ${working_copy_directories_path}, whose name contains a newline or a tab" >&2
        continue
        ;;
    esac
    # `git rev-parse --show-toplevel` prints a physical path, which differs
    # from the entry's path if the entry is a symbolic link or is not the top
    # level of a working tree.  git fails if the entry is not a directory, as
    # when the pattern matches no entry.
    working_copy_directories_toplevel="$(git -C "${working_copy_directories_path}" \
      rev-parse --show-toplevel 2> /dev/null)" || continue
    if [ "${working_copy_directories_toplevel}" = "${working_copy_directories_path}" ]; then
      printf '%s\n' "${working_copy_directories_name}"
    fi
  done | LC_ALL=C sort
}

## Usage: push_destination DIRECTORY BRANCH
## Sets ${push_destination_repo} to the GitHub slug, such as "ORG/REPO", of
## the repository that `git push` in the clone in DIRECTORY pushes a local
## branch BRANCH to, sets ${push_destination_remote} to the name of the
## clone's remote for that repository, such as "origin", and sets
## ${push_destination_branch} to the name of the branch there.  Consults only
## the clone's configuration, not GitHub.
##
## The remote is the one that `push_remote` names.  The branch is the remote
## branch that `is_deleted_branch` asks about:  the one that
## `branch.BRANCH.merge` names, if `branch.BRANCH.remote` is that remote, and
## the branch of the same name otherwise.
##
## Fails, setting nothing, if the clone determines no remote for BRANCH, if
## the remote is not on GitHub, or if `branch.BRANCH.merge` names a ref
## outside `refs/heads/` or names several refs, because a pull request's head
## is one branch.
push_destination() {
  push_destination_branch_name="$2"
  push_destination_remote_name="$(push_remote "$1" "$2")"
  [ -n "${push_destination_remote_name}" ] || return 1
  push_destination_merge="$(git -C "$1" config --get-all "branch.$2.merge")"
  if [ -n "${push_destination_merge}" ] \
    && [ "$(git -C "$1" config --get "branch.$2.remote")" = "${push_destination_remote_name}" ]; then
    case "${push_destination_merge}" in
      *'
'*) return 1 ;;
      refs/heads/?*) push_destination_branch_name="${push_destination_merge#refs/heads/}" ;;
      *) return 1 ;;
    esac
  fi
  push_destination_url="$(git -C "$1" remote get-url --push "${push_destination_remote_name}" 2> /dev/null)" \
    || return 1
  push_destination_slug="$(github_slug "${push_destination_url}")"
  # `git remote get-url` applies `url.BASE.insteadOf`, which may map a GitHub
  # URL to a mirror or a local copy; the configured URL still names GitHub.
  if [ -z "${push_destination_slug}" ]; then
    push_destination_slug="$(github_slug "$(git -C "$1" config --get "remote.${push_destination_remote_name}.url")")"
  fi
  [ -n "${push_destination_slug}" ] || return 1
  push_destination_repo="${push_destination_slug}"
  push_destination_remote="${push_destination_remote_name}"
  push_destination_branch="${push_destination_branch_name}"
}

## Usage: branch_pulls BASE HEAD BRANCH STATE JQ
## Prints a line for each pull request to BASE, a GitHub repository's slug
## such as "ORG/REPO", whose head is the branch BRANCH, such as "feature", of
## the GitHub repository HEAD, such as "ME/REPO", and whose state is STATE:
## "open", "closed", or "all".  Each line is a string that the jq expression
## JQ, such as '"\(.number) \(.base.ref)"', yields for the pull request, as a
## dict parsed from the JSON of GitHub's REST API with keys such as "number"
## and "base", followed by a space and the slug of the pull request's head
## repository as GitHub spells it.  JQ can yield several strings, or none.
## A pull request from a branch of the same name in another repository is
## not included; GitHub ignores the case of a repository's name, so the
## comparison does too.
## Returns 1, after printing a diagnostic, if GitHub cannot be asked, as
## `gh_query` does.
branch_pulls() {
  # The `head` parameter names only the head repository's owner, who might
  # have both the base repository and a fork of it.
  branch_pulls_answer="$(gh_query "cannot list the pull requests from $2:$3" \
    gh api -X GET "repos/$1/pulls" -f "head=${2%%/*}:$3" -f "state=$4" -f per_page=100 \
    --hostname github.com --paginate \
    --jq ".[] | (.head.repo.full_name // \"-\") as \$head | ($5) + \" \" + \$head")" \
    || return 1
  # "$(NF)" rather than "$NF", which tests/test-env-vars-documented.sh would
  # take for a read of an environment variable.
  printf '%s\n' "${branch_pulls_answer}" \
    | awk -v head="$2" 'tolower($(NF)) == tolower(head)'
}

## Usage: pr_repositories DIRECTORY BRANCH [BASE]
## Sets ${pr_base_repo} and ${pr_head_repo} to the GitHub slugs, such as
## "ORG/REPO", of the base and head repositories of the pull requests from a
## local branch BRANCH of the clone in DIRECTORY, sets ${pr_head_remote} to
## the name of the clone's remote for the head repository, such as "origin",
## and sets ${pr_head_branch} to the name of their head branch in the head
## repository.  Fails, setting nothing, if nothing is known about those pull
## requests, or if they say nothing about BRANCH.
##
## The head repository, the remote, and the head branch are the ones that
## `push_destination` names.  The base repository is BASE, a GitHub slug, if
## it is given, and otherwise the head repository's upstream repository,
## which `github_upstream` describes.  A pull request from a branch of the
## same name in another repository, even the base repository, is someone
## else's.
##
## Fails if `gh` is not installed, if a query fails, or if `push_destination`
## fails, because then nothing is known about the pull requests.  Fails if the
## head branch is the head repository's default branch:  a pull request from
## it, such as one that merges a release from `main` into a stable branch,
## says nothing about whether the branch's work is done, because the branch
## outlives every such pull request.  If BASE is given, GitHub is not asked,
## and the caller must ignore a pull request from the head repository's
## default branch itself.
pr_repositories() {
  command -v gh > /dev/null 2>&1 || return 1
  push_destination "$1" "$2" || return 1
  pr_repositories_base="${3:-}"
  if [ -z "${pr_repositories_base}" ]; then
    github_upstream "${push_destination_repo}" 2> /dev/null || return 1
    # shellcheck disable=SC2154 # set by `github_upstream`, in common-functions.sh
    if [ "${push_destination_branch}" = "${github_upstream_default}" ]; then
      return 1
    fi
    # shellcheck disable=SC2154 # set by `github_upstream`, in common-functions.sh
    pr_repositories_base="${github_upstream_repo}"
  fi
  # shellcheck disable=SC2034 # set for the caller
  pr_base_repo="${pr_repositories_base}"
  # shellcheck disable=SC2034 # set for the caller
  pr_head_repo="${push_destination_repo}"
  # shellcheck disable=SC2034 # set for the caller
  pr_head_remote="${push_destination_remote}"
  # shellcheck disable=SC2034 # set for the caller
  pr_head_branch="${push_destination_branch}"
}
