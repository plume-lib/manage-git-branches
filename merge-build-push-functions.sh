# shellcheck shell=sh

# Functions that compute the message of a merge commit; that determine whether
# a merge might have broken a branch's build; and that merge a commit into the
# current branch, build the result, and push it, as `merge_build_push` does.
#
# `common-functions.sh` sources this file.  A script uses these functions by
# sourcing that file, which says what the script must set first.

## Usage: pull_merge_message
## Prints the message of the merge commit that `git pull` would make in the
## current repository from the commits in FETCH_HEAD, as
## `fmt_merge_message` composes it, but with each source that the merge
## merges named without its URL where `source_without_url` can:  for
## example, "Merge remote-tracking branch 'origin/feature' into feature"
## rather than "Merge branch 'feature' of /home/me/repos/proj into feature".
pull_merge_message() {
  if ! pull_message_fetch_head="$(git rev-parse --git-path FETCH_HEAD)" \
    || [ ! -f "${pull_message_fetch_head}" ]; then
    return 1
  fi
  # Each line of FETCH_HEAD is "HASH<TAB>not-for-merge<TAB>SOURCE", where
  # "not-for-merge" can be empty.  `git fmt-merge-msg` ignores a line that
  # says "not-for-merge", such as each other branch that a pull fetched, so
  # it is passed on unchanged.  `merge_build_push` explains the source
  # "... of .".
  while IFS= read -r pull_message_line; do
    pull_message_hash="${pull_message_line%%"	"*}"
    pull_message_rest="${pull_message_line#*"	"}"
    pull_message_flag="${pull_message_rest%%"	"*}"
    pull_message_source="${pull_message_rest#*"	"}"
    if [ -z "${pull_message_flag}" ]; then
      pull_message_source="$(source_without_url "${pull_message_source}" "${pull_message_hash}")"
      case "${pull_message_source}" in
        "remote-tracking branch "*) pull_message_source="${pull_message_source} of ." ;;
      esac
    fi
    printf '%s\t%s\t%s\n' "${pull_message_hash}" "${pull_message_flag}" "${pull_message_source}"
  done < "${pull_message_fetch_head}" | fmt_merge_message
}

## Usage: fmt_merge_message
## Reads lines in the format of FETCH_HEAD, such as
## "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b<TAB><TAB>branch 'feature' of
## github.com:org/proj", and prints the message that `git fmt-merge-msg`
## composes for the merge of their commits into the current branch, as
## `git merge` would compose it.  The message includes the commit summaries
## that `merge.log` turns on, but no comment lines.
fmt_merge_message() {
  # `git fmt-merge-msg` writes comment lines, such as "# By AUTHOR", that
  # `git merge` keeps in a message given with `-m`, so they are removed.  The
  # comment character is set to "#" for both commands, because the summaries
  # that `merge.log` turns on begin with "* ", which `core.commentChar` might
  # be.
  if ! fmt_merge_composed="$(git -c core.commentChar='#' fmt-merge-msg)"; then
    return 1
  fi
  printf '%s\n' "${fmt_merge_composed}" | git -c core.commentChar='#' stripspace --strip-comments
}

## Usage: upstream_description
## Prints a description of the upstream branch of the current branch, in the
## form that `git merge` uses in a merge message:  for example,
## "remote-tracking branch 'origin/feature'", or "branch 'main'" if the
## upstream branch is a branch of the local repository.  If git cannot name
## the upstream branch with a ref of the local repository, as when
## `branch.BRANCH.remote` is a URL, prints "the upstream branch of branch
## 'BRANCH'".
upstream_description() {
  upstream_description_ref="$(git rev-parse --symbolic-full-name '@{upstream}' 2> /dev/null)"
  case "${upstream_description_ref}" in
    refs/remotes/*) echo "remote-tracking branch '${upstream_description_ref#refs/remotes/}'" ;;
    refs/heads/*) echo "branch '${upstream_description_ref#refs/heads/}'" ;;
    *)
      if upstream_description_branch="$(current_branch)"; then
        echo "the upstream branch of branch '${upstream_description_branch}'"
      else
        echo "the upstream branch"
      fi
      ;;
  esac
}

## Usage: in_progress_merge_message
## Prints the message for the merge that is in progress in the current
## directory, the top level of a working tree:  the message in MERGE_MSG,
## which `git merge` or `git pull` wrote, without the list of conflicts that
## git appended to it, with its subject's sources named without their URLs
## where `subject_without_url` can, and with the location in each header of
## the commit summaries that `merge.log` turns on, such as
## "* 'feature' of /home/me/repos/proj:", written as `source_without_pathname`
## writes it, as in "* 'feature' of proj:".  Returns 1 if there is no
## MERGE_MSG or no merge is in progress.
##
## Git writes the list of conflicts as comment lines at the end of the
## message:  a line "C Conflicts:" and one line "C<TAB>FILE" per file, where
## C is the comment character, such as "#".  The list is recognized by that
## form, whatever C is, rather than removed with the other comment lines,
## because the configured comment character can differ from the one git
## used, as with `core.commentChar` "auto", or can begin a header of the
## commit summaries, as "*" does.
in_progress_merge_message() {
  if ! in_progress_head="$(git rev-parse --verify --quiet MERGE_HEAD)" \
    || ! in_progress_file="$(git rev-parse --git-path MERGE_MSG)" \
    || [ ! -f "${in_progress_file}" ]; then
    return 1
  fi
  awk '
    { line[NR] = $0 }
    END {
      n = NR
      for (k = n; k >= 1; k--) {
        if (line[k] ~ / Conflicts:$/) break
      }
      if (k >= 1) {
        prefix = substr(line[k], 1, length(line[k]) - length(" Conflicts:"))
        listed = (prefix != "")
        for (i = k + 1; i <= n && listed; i++) {
          if (substr(line[i], 1, length(prefix) + 1) != prefix "\t") listed = 0
        }
        if (listed) n = k - 1
      }
      while (n >= 1 && line[n] ~ /^[ \t]*$/) n--
      for (i = 1; i <= n; i++) print line[i]
    }' "${in_progress_file}" | {
    if IFS= read -r in_progress_subject; then
      subject_without_url "${in_progress_subject}" "${in_progress_head}"
    fi
    while IFS= read -r in_progress_line; do
      case "${in_progress_line}" in
        "* "*"' of "*": ("*")")
          in_progress_rest="${in_progress_line#"* "}"
          printf '* %s: (%s\n' "$(source_without_pathname "${in_progress_rest%": ("*}")" \
            "${in_progress_rest##*": ("}"
          ;;
        "* "*"' of "*":")
          in_progress_rest="${in_progress_line#"* "}"
          printf '* %s:\n' "$(source_without_pathname "${in_progress_rest%:}")"
          ;;
        *) printf '%s\n' "${in_progress_line}" ;;
      esac
    done
  }
}

## Usage: subject_without_url SUBJECT COMMIT
## Prints SUBJECT, the subject of a merge commit, with each source that
## `git merge` or `git pull` named in it written without its URL where it
## can.  The subject that `git fmt-merge-msg` writes is "Merge SOURCES" or
## "Merge SOURCES into BRANCH", where SOURCES is one source or several
## separated by "; ", such as "branches 'a' and 'b' of /home/me/proj;
## remote-tracking branch 'origin/x'".  If SOURCES is one source, it is
## written as `source_without_url` writes it, given COMMIT, the commit that
## the merge merged from that source; otherwise, each source is written as
## `source_without_pathname` writes it.  For example, prints "Merge
## remote-tracking branch 'origin/feature' into feature" for "Merge branch
## 'feature' of github.com:org/proj into feature", and "Merge branch 'a' of
## p; branch 'b' of github.com:x/y" for "Merge branch 'a' of /home/me/p;
## branch 'b' of github.com:x/y".  Prints any other subject unchanged.
subject_without_url() {
  case "$1" in
    "Merge "*) ;;
    *)
      printf '%s\n' "$1"
      return 0
      ;;
  esac
  subject_url_rest="${1#Merge }"
  # A branch name contains no space, so the last " into " precedes the
  # destination branch.  `git merge` omits " into BRANCH" on the default
  # branch.
  case "${subject_url_rest}" in
    *" into "*)
      subject_url_sources="${subject_url_rest% into *}"
      subject_url_into=" into ${subject_url_rest##* into }"
      ;;
    *)
      subject_url_sources="${subject_url_rest}"
      subject_url_into=''
      ;;
  esac
  # A ref's name contains no space, so a "; " separates two sources.
  case "${subject_url_sources}" in
    *"; "*) ;;
    *)
      printf 'Merge %s%s\n' "$(source_without_url "${subject_url_sources}" "$2")" "${subject_url_into}"
      return 0
      ;;
  esac
  # COMMIT is the commit merged from only one of several sources, so no
  # remote-tracking branch is sought for any of them.
  subject_url_shown=''
  subject_url_separator=''
  subject_url_more="${subject_url_sources}"
  while :; do
    subject_url_shown="${subject_url_shown}${subject_url_separator}$(source_without_pathname "${subject_url_more%%"; "*}")"
    subject_url_separator='; '
    case "${subject_url_more}" in
      *"; "*) subject_url_more="${subject_url_more#*"; "}" ;;
      *) break ;;
    esac
  done
  printf 'Merge %s%s\n' "${subject_url_shown}" "${subject_url_into}"
}

## Usage: source_without_url SOURCE COMMIT
## Prints SOURCE, a source that `git pull` merges, as it writes one in
## FETCH_HEAD and in a merge message, such as "branch 'feature' of
## github.com:org/proj", named without its URL where it can.  COMMIT is the
## commit that the merge merges from SOURCE.  For a source "branch 'BRANCH'
## of URL" where URL is not ".", the local repository, prints
## "remote-tracking branch 'REMOTE/BRANCH'", such as "remote-tracking branch
## 'origin/feature'", if REMOTE/BRANCH tracks BRANCH of URL (see
## `tracking_branch_of`) and contains COMMIT.  Otherwise, prints SOURCE as
## `source_without_pathname` writes it.
source_without_url() {
  case "$1" in
    "branch '"*"' of "*)
      source_url_rest="${1#"branch '"}"
      source_url_branch="${source_url_rest%%"' of "*}"
      source_url_url="${source_url_rest#*"' of "}"
      # A branch's name contains no space.  "branch 'a', tag 'v1' of URL",
      # which names several sources of URL, yields "a', tag 'v1".
      case "${source_url_branch}" in
        *" "*) ;;
        *)
          if [ "${source_url_url}" != . ] \
            && source_url_tracking="$(tracking_branch_of "${source_url_branch}" "${source_url_url}" "$2")"; then
            printf "remote-tracking branch '%s'\n" "${source_url_tracking}"
            return 0
          fi
          ;;
      esac
      ;;
  esac
  source_without_pathname "$1"
}

## Usage: source_without_pathname SOURCE
## Prints SOURCE, one or several sources of one repository as `git pull`
## writes them in FETCH_HEAD and in a merge message, with the location of the
## repository, if it is a pathname in the local file system, which a pushed
## commit message would reveal, replaced by the last component of the
## pathname, such as "proj" for "/home/me/repos/proj".  SOURCE has the form
## "DESCRIPTION of LOCATION", such as "branches 'a' and 'b' of
## /home/me/repos/proj" or "tag 'v1' of github.com:org/proj", or is a
## location alone, for the head of the repository there, such as
## "/home/me/repos/proj".  Prints SOURCE unchanged if its location is ".",
## the local repository, or is not a pathname, or if SOURCE has neither
## form, such as "remote-tracking branch 'origin/feature'".
source_without_pathname() {
  # A description ends with a quoted name, which contains no space, so the
  # first "' of " ends it.  A location alone has no quote and, unlike a
  # subject such as "pull request #12 from org/feature", no space.
  case "$1" in
    *"' of "*)
      source_path_description="${1%%"' of "*}' of "
      source_path_url="${1#*"' of "}"
      ;;
    *"'"* | *" "*)
      printf '%s\n' "$1"
      return 0
      ;;
    *)
      source_path_description=''
      source_path_url="$1"
      ;;
  esac
  # The pathname "." is the local repository, which reveals nothing.
  if [ "${source_path_url}" = . ]; then
    printf '%s\n' "$1"
    return 0
  fi
  case "${source_path_url}" in
    file://*) ;;
    *)
      if ! is_pathname "${source_path_url}"; then
        printf '%s\n' "$1"
        return 0
      fi
      ;;
  esac
  # For the URL "/srv/proj/.git", `git pull` writes "/srv/proj/", whose last
  # component is "proj".
  source_path_path="${source_path_url%"${source_path_url##*[!/]}"}"
  printf '%s%s\n' "${source_path_description}" "${source_path_path##*/}"
}

## Usage: fetch_head_location URL
## Prints URL, a repository's URL, as `git fetch URL` names it in FETCH_HEAD
## and therefore in a merge message:  without the user name and password
## that precede an "@", and without trailing slashes and then without a
## trailing ".git".  For example, prints "github.com:org/proj" for
## "git@github.com:org/proj.git", and "https://github.com/org/proj" for
## "https://user:token@github.com/org/proj.git".  Unlike `git fetch`, does
## not first rewrite URL by `url.BASE.insteadOf`.
fetch_head_location() {
  fetch_head_url="$1"
  # Git removes the text through the first "@", if that "@" is in the part of
  # the URL that names the host:  after the scheme and before the first "/"
  # of a URL with a scheme, or before the first ":" of an scp-style URL such
  # as "git@github.com:org/proj.git".
  case "${fetch_head_url}" in
    *://*)
      fetch_head_rest="${fetch_head_url#*://}"
      case "${fetch_head_rest%%/*}" in
        *@*) fetch_head_url="${fetch_head_url%%://*}://${fetch_head_rest#*@}" ;;
      esac
      ;;
    *:*)
      case "${fetch_head_url%%:*}" in
        *@*) fetch_head_url="${fetch_head_url#*@}" ;;
      esac
      ;;
  esac
  fetch_head_url="${fetch_head_url%"${fetch_head_url##*[!/]}"}"
  printf '%s\n' "${fetch_head_url%.git}"
}

## Usage: tracking_branch_of BRANCH URL COMMIT
## Prints the remote-tracking branch of the current repository, such as
## "origin/feature", that tracks BRANCH of the repository at URL, as
## `git pull` writes both in FETCH_HEAD and in a merge message, such as
## "branch 'feature' of github.com:org/proj", and that contains COMMIT, a
## commit fetched from there.  It is the remote-tracking branch REMOTE/BRANCH
## of a remote REMOTE whose URL is URL, or names the same repository in
## another spelling (see `url_key`), such as "git@github.com:org/proj.git".
## A remote-tracking branch that lacks COMMIT is out of date, as after a
## pull that names the repository by its URL rather than by its remote,
## which updates no remote-tracking branch.  Returns 1, printing nothing, if
## no such remote-tracking branch exists.
tracking_branch_of() {
  for tracking_of_remote in $(git remote); do
    if git merge-base --is-ancestor "$3" "refs/remotes/${tracking_of_remote}/$1" 2> /dev/null \
      && tracking_of_url="$(git ls-remote --get-url "${tracking_of_remote}" 2> /dev/null)" \
      && is_fetch_head_location . "$2" "${tracking_of_url}"; then
      printf '%s/%s\n' "${tracking_of_remote}" "$1"
      return 0
    fi
  done
  return 1
}

## Usage: is_built_remote DIRECTORY REMOTE
## Returns 0 if the branches of the repository that REMOTE names in the clone
## in DIRECTORY were built where they were pushed, and returns 1 otherwise.
## REMOTE is a remote's name, such as "origin", or a URL or a pathname, which
## git accepts in place of a remote's name.  The branches of a repository that
## is not in the local file system, such as one on GitHub, were built where
## they were pushed, and so were those of a bare repository in the local file
## system that has no linked worktree.  The branches of any other repository
## need not have been pushed:  of the local repository, which the remote "."
## names; of a non-bare repository, such as another working clone; of a bare
## repository with a linked worktree, where commits are made; and of a
## repository whose location is not known, as when its pathname names no
## directory or begins with "~".
## Remembers its result for each top level of a working tree and REMOTE in
## ${built_remote_cache}, so it does not notice a later change, such as a
## worktree added to the bare repository, unless that variable is cleared.
is_built_remote() {
  if [ "$2" = . ]; then
    return 1
  fi
  # Git resolves a relative pathname in the top level of the working tree,
  # not in a subdirectory such as DIRECTORY.
  built_remote_top="$(git -C "$1" rev-parse --show-toplevel 2> /dev/null)" \
    || built_remote_top="$1"
  # Each entry is 3 lines:  the result, the top level, and REMOTE.
  built_remote_entry="${built_remote_top}
$2
"
  case "
${built_remote_cache:-}" in
    *"
0
${built_remote_entry}"*) return 0 ;;
    *"
1
${built_remote_entry}"*) return 1 ;;
  esac
  if is_built_remote_uncached "${built_remote_top}" "$2"; then
    built_remote_result=0
  else
    built_remote_result=1
  fi
  built_remote_cache="${built_remote_cache:-}${built_remote_result}
${built_remote_entry}"
  return "${built_remote_result}"
}

## Usage: is_built_remote_uncached TOP REMOTE
## Returns 0 if the branches of the repository that REMOTE names in the clone
## whose working tree has the top level TOP were built where they were pushed,
## and returns 1 otherwise; see `is_built_remote`, which remembers the result.
is_built_remote_uncached() {
  built_remote_key="$(repository_key "$1" "$2")"
  case "${built_remote_key}" in
    '' | '~'*) return 1 ;;
    /*) ;;
    *) return 0 ;;
  esac
  [ "$(git -C "${built_remote_key}" rev-parse --is-bare-repository 2> /dev/null)" = true ] \
    && [ "$(git -C "${built_remote_key}" worktree list --porcelain 2> /dev/null | grep -c '^worktree ')" -eq 1 ]
}

## Usage: remote_branch_refs DIRECTORY
## Prints the full names, separated by spaces, of the remote-tracking branches
## that the branch checked out in DIRECTORY pushes to and pulls from, such as
## "refs/remotes/origin/feature", and whose histories were built where they
## were pushed.  Omits any that does not exist, that is a local branch rather
## than a remote-tracking branch, or whose remote's branches need not have
## been built (see `is_built_remote`), and prints each only once.  If the
## branch pushes to a remote other than the one that it pulls from, first
## fetches the branch that it pushes to, because `git pull` fetches only the
## remote that it pulls from; if that fetch fails, prints a warning and uses
## the remote-tracking branch as it is.
remote_branch_refs() {
  remote_refs_list=''
  if ! remote_refs_branch="$(git -C "$1" symbolic-ref --quiet HEAD)"; then
    printf '\n'
    return 0
  fi
  if remote_refs_push="$(git -C "$1" rev-parse --symbolic-full-name '@{push}' 2> /dev/null)" \
    && git -C "$1" rev-parse --verify --quiet "${remote_refs_push}" > /dev/null; then
    remote_refs_push_remote="$(git -C "$1" for-each-ref --format='%(push:remotename)' "${remote_refs_branch}")"
    # `%(push:remoteref)` is empty unless the remote has push refspecs; then
    # the branch pushes to the branch of the same name.
    remote_refs_push_branch="$(git -C "$1" for-each-ref --format='%(push:remoteref)' "${remote_refs_branch}")"
    case "${remote_refs_push}" in
      refs/remotes/*)
        if [ -n "${remote_refs_push_remote}" ] \
          && [ "${remote_refs_push_remote}" != "$(git -C "$1" for-each-ref --format='%(upstream:remotename)' "${remote_refs_branch}")" ] \
          && is_built_remote "$1" "${remote_refs_push_remote}" \
          && ! git -C "$1" fetch -q "${remote_refs_push_remote}" \
            "+${remote_refs_push_branch:-${remote_refs_branch}}:${remote_refs_push}" < /dev/null; then
          echo "${SCRIPT_NAME}: cannot fetch ${remote_refs_push#refs/remotes/} in $1; it might be out of date" >&2
        fi
        ;;
    esac
  fi
  for remote_refs_kind in push upstream; do
    if remote_refs_ref="$(git -C "$1" rev-parse --symbolic-full-name "@{${remote_refs_kind}}" 2> /dev/null)" \
      && git -C "$1" rev-parse --verify --quiet "${remote_refs_ref}" > /dev/null; then
      case " ${remote_refs_list} " in
        *" ${remote_refs_ref} "*) ;;
        *)
          case "${remote_refs_ref}" in
            refs/remotes/*)
              if is_built_remote "$1" "$(git -C "$1" for-each-ref \
                --format="%(${remote_refs_kind}:remotename)" "${remote_refs_branch}")"; then
                remote_refs_list="${remote_refs_list:+${remote_refs_list} }${remote_refs_ref}"
              fi
              ;;
          esac
          ;;
      esac
    fi
  done
  printf '%s\n' "${remote_refs_list}"
}

## Usage: built_commits DIRECTORY
## Prints, separated by spaces, the merge base of the branch checked out in
## DIRECTORY with each remote-tracking branch that it pushes to and pulls
## from (see `remote_branch_refs`), such as
## "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b".  The histories of those
## commits were built where they were pushed.  The commits are in the
## branch's history, so every repository that has the branch has them.
built_commits() {
  built_list=''
  for built_ref in $(remote_branch_refs "$1"); do
    if built_commit="$(git -C "$1" merge-base HEAD "${built_ref}")"; then
      built_list="${built_list:+${built_list} }${built_commit}"
    fi
  done
  printf '%s\n' "${built_list}"
}

## Usage: has_unbuilt_merge BUILT
## Returns 0 if a merge on the current branch might have broken its build,
## and returns 1 otherwise.  BUILT is a list of commits, separated by spaces,
## whose histories were built elsewhere, such as where they were pushed; for
## example, "refs/remotes/upstream/main 1a2b3c4d".  A merge might have broken
## the build if all of these hold:
##  * the current branch has a merge commit that is in the history of none of
##    the remote branches that the current branch pushes to and pulls from
##    (see `remote_branch_refs`), if any, and the commits in BUILT,
##  * that merge commit's tree differs from each of its parents' trees, so
##    that the merge combined changes, and
##  * the current branch's tree differs from those remote branches' and
##    BUILT's trees.
## Commits in BUILT that are not in the repository are ignored.  If it
## returns 0, it sets ${merge_fix_branch} to the current branch's name, such
## as "feature"; ${merge_fix_account} to an account, for an AI agent, of the
## merge commits that might have broken the build, of what each side of each
## of them changed, and of the commands that show them; and
## ${merge_fix_message} to the message of a commit that fixes the build, such
## as "Fix the build after merging branch 'main'", which names a merge that a
## pull made without the pull's URL where it can (see `subject_without_url`).
## If it returns 1, a failure of the build is not one that a merge on the
## branch caused, and the agent would merely work around it.  For example, a
## pull that fast-forwarded the branch brought only commits that the remote
## already had.  Prints a diagnostic if it returns 1 because git fails.
## The account in ${merge_fix_account} omits each commit in BUILT that is in
## the history of a remote branch or of another commit in BUILT, because it
## excludes no more commits, but that commit's tree still counts.  Of commits
## in BUILT that are the same commit, the account keeps the first.
has_unbuilt_merge() {
  merge_fix_remotes="$(remote_branch_refs .)"
  # The commits in BUILT that are in the repository, each named once:  of two
  # names of one commit, such as a ref and a hash, only the first.
  merge_fix_present=''
  merge_fix_hashes=' '
  for merge_fix_commit in $1; do
    if merge_fix_hash="$(git rev-parse --verify --quiet "${merge_fix_commit}^{commit}")"; then
      case "${merge_fix_hashes}" in
        *" ${merge_fix_hash} "*) ;;
        *)
          merge_fix_hashes="${merge_fix_hashes}${merge_fix_hash} "
          merge_fix_present="${merge_fix_present:+${merge_fix_present} }${merge_fix_commit}"
          ;;
      esac
    fi
  done
  # A commit in the history of a remote branch or of another commit in BUILT,
  # such as the head that a pull fetched, excludes nothing more, and would
  # only lengthen the account.  The other names in ${merge_fix_present} name
  # other commits.
  # `git merge-base --independent` prints, one per line, the commits that
  # are in the history of no other commit given, but it prints a commit that
  # a remote branch is at, so such a commit is excluded separately.
  merge_fix_built=''
  if [ -n "${merge_fix_present}" ]; then
    # shellcheck disable=SC2086 # the variables are lists of commits
    if ! merge_fix_independent="$(git merge-base --independent ${merge_fix_remotes} ${merge_fix_hashes})" \
      || ! merge_fix_remote_hashes="$(git rev-parse ${merge_fix_remotes})"; then
      echo "${SCRIPT_NAME}: cannot compare the built commits in $(pwd), so no AI agent is asked to fix the build" >&2
      return 1
    fi
    merge_fix_independent=" $(printf '%s' "${merge_fix_independent}" | tr '\n' ' ') "
    merge_fix_remote_hashes=" $(printf '%s' "${merge_fix_remote_hashes}" | tr '\n' ' ') "
    # ${merge_fix_hashes} holds the hashes of ${merge_fix_present}, in order.
    # shellcheck disable=SC2086 # the variable is a list of commits
    set -- ${merge_fix_hashes}
    for merge_fix_commit in ${merge_fix_present}; do
      case "${merge_fix_independent}" in
        *" $1 "*)
          case "${merge_fix_remote_hashes}" in
            *" $1 "*) ;;
            *) merge_fix_built="${merge_fix_built:+${merge_fix_built} }${merge_fix_commit}" ;;
          esac
          ;;
      esac
      shift
    done
  fi
  if ! merge_fix_tree="$(git rev-parse --verify --quiet 'HEAD^{tree}')"; then
    echo "${SCRIPT_NAME}: cannot read the tree of HEAD in $(pwd), so no AI agent is asked to fix the build" >&2
    return 1
  fi
  # The build of a tree that a remote branch, or a commit in BUILT, has is
  # not a merge's doing.
  for merge_fix_commit in ${merge_fix_remotes} ${merge_fix_present}; do
    if [ "$(git rev-parse --verify --quiet "${merge_fix_commit}^{tree}")" = "${merge_fix_tree}" ]; then
      return 1
    fi
  done
  # The merge commits that the remote branches and BUILT's histories lack,
  # oldest first.
  # shellcheck disable=SC2086 # the variables are lists of commits
  if ! merge_fix_log="$(git log --reverse --merges --format=%H \
    HEAD --not ${merge_fix_remotes} ${merge_fix_built} --)"; then
    echo "${SCRIPT_NAME}: cannot list the merge commits in $(pwd), so no AI agent is asked to fix the build" >&2
    return 1
  fi
  # The merges that combined changes:  their subjects, as the message of the
  # fix names them (see `subject_without_url`), and, one per merge, a line
  # "* ABBREVIATION SUBJECT" followed, for a merge of two commits that share
  # history, by an indented account of what each side changed.
  merge_fix_subjects=''
  merge_fix_list=''
  for merge_fix_commit in ${merge_fix_log}; do
    if ! merge_fix_merge_tree="$(git rev-parse --verify --quiet "${merge_fix_commit}^{tree}")" \
      || ! merge_fix_parents="$(git rev-parse "${merge_fix_commit}^@")"; then
      echo "${SCRIPT_NAME}: cannot read commit ${merge_fix_commit} in $(pwd), so no AI agent is asked to fix the build" >&2
      return 1
    fi
    merge_fix_combined=1
    for merge_fix_parent in ${merge_fix_parents}; do
      if ! merge_fix_parent_tree="$(git rev-parse --verify --quiet "${merge_fix_parent}^{tree}")"; then
        echo "${SCRIPT_NAME}: cannot read the tree of commit ${merge_fix_parent} in $(pwd), so no AI agent is asked to fix the build" >&2
        return 1
      fi
      if [ "${merge_fix_parent_tree}" = "${merge_fix_merge_tree}" ]; then
        merge_fix_combined=0
      fi
    done
    if [ "${merge_fix_combined}" -eq 1 ]; then
      if ! merge_fix_line="$(git log -1 --format='%h %s' "${merge_fix_commit}")"; then
        echo "${SCRIPT_NAME}: cannot read commit ${merge_fix_commit} in $(pwd), so no AI agent is asked to fix the build" >&2
        return 1
      fi
      merge_fix_subjects="${merge_fix_subjects:+${merge_fix_subjects}
}$(subject_without_url "${merge_fix_line#* }" "${merge_fix_commit}^2")"
      merge_fix_list="${merge_fix_list:+${merge_fix_list}
}* ${merge_fix_line}"
      # A merge of two commits that share history gets an account of the
      # commits that only each of them had.  Those commits' patches show
      # what each side changed, even where the two have several merge bases,
      # as after criss-cross merges; `--remerge-diff` shows, for a merge among
      # them, how the merge differs from git's automatic merge of its parents,
      # such as a conflict's resolution, even one that takes one parent's
      # version.  (`--cc` and `--diff-merges=first-parent` omit a hunk whose
      # result equals a parent's.)  The account names commits by their full hashes, which
      # stay unambiguous after the agent creates objects.  An octopus merge,
      # or one whose parents share no history, gets only its line.
      case "${merge_fix_parents}" in
        *"
"*"
"*) ;;
        *)
          merge_fix_ours="${merge_fix_parents%%"
"*}"
          merge_fix_theirs="${merge_fix_parents#*"
"}"
          merge_fix_ours_log="\`git log -p --remerge-diff ${merge_fix_theirs}..${merge_fix_ours}\` shows the commits that only ${merge_fix_ours} had"
          merge_fix_theirs_log="\`git log -p --remerge-diff ${merge_fix_ours}..${merge_fix_theirs}\` shows the commits that only ${merge_fix_theirs} had"
          if merge_fix_base="$(git merge-base "${merge_fix_ours}" "${merge_fix_theirs}")"; then
            case "${merge_fix_base}" in
              "${merge_fix_ours}") merge_fix_sides="It merged commit ${merge_fix_theirs} into its ancestor, commit ${merge_fix_ours}.  ${merge_fix_theirs_log}." ;;
              "${merge_fix_theirs}") merge_fix_sides="It merged commit ${merge_fix_theirs} into its descendant, commit ${merge_fix_ours}.  ${merge_fix_ours_log}." ;;
              *) merge_fix_sides="It merged commit ${merge_fix_theirs} into commit ${merge_fix_ours}.  ${merge_fix_ours_log}, and ${merge_fix_theirs_log}." ;;
            esac
            merge_fix_list="${merge_fix_list}
  ${merge_fix_sides}"
          fi
          ;;
      esac
    fi
  done
  if [ -z "${merge_fix_subjects}" ]; then
    return 1
  fi
  merge_fix_branch="$(current_branch)" || merge_fix_branch=HEAD
  case "${merge_fix_built}" in
    '') merge_fix_built_history='' ;;
    *' '*) merge_fix_built_history="the histories of $(printf '%s' "${merge_fix_built}" | sed -e 's/ / and /g'), which were built elsewhere" ;;
    *) merge_fix_built_history="the history of ${merge_fix_built}, which was built elsewhere" ;;
  esac
  merge_fix_other=''
  case "${merge_fix_remotes}" in
    '')
      if [ -n "${merge_fix_built}" ]; then
        merge_fix_lack="Branch ${merge_fix_branch} has commits that are not in ${merge_fix_built_history}"
      else
        merge_fix_lack="Branch ${merge_fix_branch} pushes to and pulls from no remote branch whose history is known to have been built, so its commits might not have been built"
      fi
      ;;
    *' '*) merge_fix_lack="Branch ${merge_fix_branch} has commits that the remote branches $(printf '%s' "${merge_fix_remotes}" | sed -e 's/ / and /') lack" ;;
    *) merge_fix_lack="Branch ${merge_fix_branch} has commits that the remote branch ${merge_fix_remotes} lacks" ;;
  esac
  if [ -n "${merge_fix_remotes}" ] && [ -n "${merge_fix_built}" ]; then
    merge_fix_other="other than those in ${merge_fix_built_history}"
  fi
  merge_fix_excluded="${merge_fix_remotes}${merge_fix_remotes:+${merge_fix_built:+ }}${merge_fix_built}"
  merge_fix_account="${merge_fix_lack}${merge_fix_other:+, ${merge_fix_other}}.  Among those commits are these merges, oldest first, any of which might have combined changes that do not fit together:

${merge_fix_list}

\`git log --graph --stat HEAD${merge_fix_excluded:+ --not ${merge_fix_excluded}}\` lists those commits, and for a merge M among them, \`git diff M^1 M\` shows what merging changed."
  # `git merge` writes a subject such as "Merge branch 'main' into feature",
  # and on the default branch it omits " into feature".
  case "${merge_fix_subjects}" in
    *"
"*) merge_fix_description='' ;;
    "Merge "*)
      merge_fix_description="${merge_fix_subjects#Merge }"
      merge_fix_description="${merge_fix_description% into "${merge_fix_branch}"}"
      ;;
    *) merge_fix_description='' ;;
  esac
  if [ -n "${merge_fix_description}" ]; then
    merge_fix_message="Fix the build after merging ${merge_fix_description}"
  else
    merge_fix_message="Fix the build after merges

$(printf '%s\n' "${merge_fix_subjects}" | sed -e 's/^/* /')"
  fi
  return 0
}

## Usage: merge_conflicts COMMIT1 COMMIT2
## Computes git's merge of COMMIT1 and COMMIT2, two revisions such as "HEAD"
## and "upstream/main", without touching the working tree or the index, and
## sets three variables that describe the merge:
##
##  * ${merge_conflicts_tree} is the hash of the merge's tree, in which each
##    conflicted text file contains conflict markers.
##  * ${merge_conflicts_files} is the list of the conflicted files, one per
##    line, such as "data.bin" and "src/main.c", or is empty for a clean
##    merge.  Each file is named relative to the top level of the working
##    tree, and quoted as `git diff --name-only` quotes it.
##  * ${merge_conflicts_regions} is the number of conflict regions, such as 0
##    for a clean merge:  for each conflicted file, the number of lines that
##    begin with the conflict marker "<<<<<<<", or 1 if there are none, as in
##    a binary file.
##
## Returns 1, setting each variable to the empty string, if git cannot
## compute the merge, as when the commits have no merge base.
merge_conflicts() {
  merge_conflicts_tree=''
  merge_conflicts_files=''
  merge_conflicts_regions=''
  # `--no-messages` leaves the tree's hash, followed by the conflicted files,
  # one per line.
  if mc_output="$(git merge-tree --write-tree --name-only --no-messages "$1" "$2" 2> /dev/null)"; then
    mc_status=0
  else
    mc_status="$?"
  fi
  if [ "${mc_status}" -gt 1 ]; then
    return 1
  fi
  mc_tree="$(printf '%s\n' "${mc_output}" | sed -n -e '1p')"
  if [ -z "${mc_tree}" ]; then
    return 1
  fi
  mc_files="$(printf '%s\n' "${mc_output}" | sed -e '1d' | grep . | sort -u)"
  mc_regions=0
  # Each iteration removes the first line from ${mc_rest}.
  mc_rest="${mc_files:+${mc_files}
}"
  while [ -n "${mc_rest}" ]; do
    mc_file="${mc_rest%%
*}"
    mc_rest="${mc_rest#*
}"
    # A quoted name names no file in the tree, and so counts as 1.
    mc_count="$(git cat-file blob "${mc_tree}:${mc_file}" 2> /dev/null | grep -c '^<<<<<<<')" || true
    if [ "${mc_count:-0}" -lt 1 ]; then
      mc_count=1
    fi
    mc_regions=$((mc_regions + mc_count))
  done
  merge_conflicts_tree="${mc_tree}"
  merge_conflicts_files="${mc_files}"
  merge_conflicts_regions="${mc_regions}"
}

## Usage: pull_request_location
## Prints the location from which to fetch the pull requests of the clone in
## the current directory:  the URL of its upstream repository, the GitHub
## repository whose pull requests come from the clone's branches, such as
## "git@github.com:ORG/REPO.git" (see `upstream_repository` and
## `fork_upstream`).  The URL has the same form as the URL of the clone's
## remote for its upstream repository, such as an scp-style one.  For a
## remote that is not on GitHub, such as a repository in the local file
## system, prints that remote's location.  Returns 1, printing nothing, if
## the upstream repository is unknown.
pull_request_location() {
  upstream_repository "$(pwd)" 2> /dev/null || return 1
  if [ -z "${upstream_repo_url}" ]; then
    return 1
  fi
  prl_slug="$(github_slug "${upstream_repo_url}")"
  if [ -z "${prl_slug}" ]; then
    printf '%s\n' "${upstream_repo_url}"
    return 0
  fi
  # shellcheck disable=SC2154 # set by `upstream_repository`, in clone-functions.sh
  prl_upstream="${upstream_repo_slug}"
  if [ -z "${prl_upstream}" ]; then
    # The remote is a fork that the clone's name says is the user's own; its
    # upstream repository is its parent on GitHub.
    fork_upstream "${prl_slug}" 1 2> /dev/null || return 1
    prl_upstream="${fork_upstream_repo:-${prl_slug}}"
  fi
  split_repository_url "${upstream_repo_url}" || return 1
  # shellcheck disable=SC2154 # set by `split_repository_url`, in clone-functions.sh
  printf '%s%s.git\n' "${repo_url_prefix}" "${prl_upstream}"
}

## Usage: merge_landed_pr_heads COMMIT SOURCE
## Prepares the merge of COMMIT into the current branch:  if the current
## branch merged an earlier version of a pull request that landed in COMMIT,
## first merges the pull request's final version, and then the commit that
## landed it.  SOURCE names COMMIT; used for diagnostics.
##
## When GitHub squash-merges a pull request #N, it lands the pull request's
## changes as a single commit S, whose subject ends with " (#N)", such as
## "Fix the parser (#123)".  Suppose that the current branch merged the pull
## request's branch, and that the pull request's branch then changed again
## before it landed.  Then S and the current branch contain different
## versions of the same changes, and git's merge of COMMIT conflicts wherever
## the versions differ, even in a binary file.  The merge of the final head
## commit P of the pull request's branch brings the current branch the
## pull request's later changes.  Then the merge of S makes no change to the
## files that only the pull request changed, and the merge of COMMIT finds
## the pull request's changes on both sides.
##
## Does nothing unless git's merge of COMMIT would have conflicts, and
## accesses the network only if some commit S that is in COMMIT but not in
## the current branch changes a file that the merge would leave conflicted.
## The head commits come from the refs "refs/pull/N/head", which GitHub
## provides, of the repository that `pull_request_location` names.  The pull
## request #N of such an S is a candidate if P is not in the current branch,
## and if the current branch and P have a merge base that COMMIT does not
## contain, which is a commit of a pull request's branch.  A candidate
## qualifies only if all of these hold:
##
##  * S has the tree of git's merge of P into the parent of S, as GitHub's
##    squash merge of P does.  A fork's ref "refs/pull/N/head", for example,
##    belongs to the fork's own pull request #N, not to the one that S landed.
##  * Neither the merge of P nor the merge of S has conflicts.
##  * The merges change the result of the merge of COMMIT only in files that
##    S changes, or in files that the merge of COMMIT leaves conflicted with
##    and without them.  P might bring other changes, such as the reversion
##    of another pull request's branch that P merged earlier and that the
##    current branch still contains.
##
## This function considers the candidates oldest first, and keeps each that
## qualifies and that does not add conflict regions (see `merge_conflicts`)
## to the merge of COMMIT, so that two pull requests that conflict in the
## same file can both be kept.  If the kept merges leave the merge of COMMIT
## fewer conflict regions than it has without them, this function makes them
## with `git merge`, which runs the hooks, and prints a diagnostic for each
## pull request; otherwise it makes none.  At most
## ${landed_pr_max_commits} commits of COMMIT are examined.
##
## Sets ${merged_landed_prs} to the numbers of the pull requests whose final
## versions it merged, such as "#5 #6", or to the empty string if it merged
## none.  A failure to learn about the pull requests, or to make the merges,
## is not an error:  it leaves the merge of COMMIT as it would otherwise be.
## Returns 1, after printing a diagnostic, only if it cannot restore the
## current branch after a failed merge.
landed_pr_max_commits=200
merge_landed_pr_heads() {
  merged_landed_prs=''
  mlph_commit="$1"
  # `git merge-tree --write-tree --name-only` needs git 2.38; the merge that
  # follows needs AUTO_MERGE (see `resolve_merge_conflicts`) anyway.
  git_at_least 42 2> /dev/null || return 0
  if ! mlph_tip="$(git rev-parse --verify HEAD)" \
    || ! mlph_branch="$(git rev-parse --abbrev-ref HEAD)" \
    || ! merge_conflicts "${mlph_tip}" "${mlph_commit}" \
    || [ "${merge_conflicts_regions}" -eq 0 ]; then
    return 0
  fi
  mlph_tree0="${merge_conflicts_tree}"
  mlph_files0="${merge_conflicts_files}"
  mlph_regions0="${merge_conflicts_regions}"
  # Lines "S N", oldest first, for each S that changes a conflicted file.
  # `--reverse` applies after `--max-count`, so these are among the most
  # recent commits.  Each commit's line "<U+0001>S SUBJECT" precedes the
  # files that it changes.
  mlph_squashes="$(git log --no-merges --no-renames --reverse \
    --max-count="${landed_pr_max_commits}" --name-only --format='%x01%H %s' \
    "${mlph_tip}..${mlph_commit}" \
    | MLPH_FILES="${mlph_files0}" awk '
        BEGIN {
          n = split(ENVIRON["MLPH_FILES"], files, "\n")
          for (i = 1; i <= n; i++) {
            conflicted[files[i]] = 1
          }
        }
        /^\001/ {
          sub(/^\001/, "")
          squash = $1
          pr = ""
          if (match($0, / \(#[0-9]+\)$/)) {
            pr = substr($0, RSTART + 3, RLENGTH - 4)
          }
          next
        }
        pr != "" && $0 != "" && ($0 in conflicted) {
          print squash " " pr
          pr = ""
        }')"
  if [ -z "${mlph_squashes}" ]; then
    return 0
  fi
  mlph_location="$(pull_request_location)" || return 0
  # Each line is "P<tab>refs/pull/N/head".
  # shellcheck disable=SC2046 # Each ref name is one word.
  if ! git_batch_ssh_capture . ls-remote "${mlph_location}" \
    $(printf '%s\n' "${mlph_squashes}" | awk '{ print "refs/pull/" $2 "/head" }'); then
    return 0
  fi
  # shellcheck disable=SC2154 # set by `git_batch_ssh_capture`, in common-functions.sh
  mlph_heads="$(printf '%s\n' "${git_batch_ssh_capture_output}" \
    | sed -n -e 's|^\([0-9a-f][0-9a-f]*\)	refs/pull/\([0-9][0-9]*\)/head$|\2 \1|p')"
  if [ -z "${mlph_heads}" ]; then
    return 0
  fi
  # Fetch the head commits that the clone lacks.  No ref records them, and
  # FETCH_HEAD, which a caller can read, is left alone.
  mlph_missing="$(printf '%s\n' "${mlph_heads}" | while read -r mlph_n mlph_p; do
    if ! git cat-file -e "${mlph_p}^{commit}" 2> /dev/null; then
      printf 'refs/pull/%s/head\n' "${mlph_n}"
    fi
  done)"
  if [ -n "${mlph_missing}" ]; then
    # shellcheck disable=SC2086 # Each ref name is one word.
    git_batch_ssh_capture . fetch --quiet --no-tags --no-write-fetch-head \
      "${mlph_location}" ${mlph_missing} || return 0
  fi

  # Try the merges with `git commit-tree`, which leaves the working tree and
  # the index alone.  ${mlph_kept} has a line "S N P" for each kept pull
  # request, and ${mlph_changed} lists the files that their commits S change.
  mlph_old_head="${mlph_tip}"
  mlph_regions="${mlph_regions0}"
  mlph_kept=''
  mlph_changed=''
  # Each iteration removes the first line from ${mlph_rest}.
  mlph_rest="${mlph_squashes}
"
  while [ -n "${mlph_rest}" ] && [ "${mlph_regions}" -gt 0 ]; do
    mlph_line="${mlph_rest%%
*}"
    mlph_rest="${mlph_rest#*
}"
    mlph_s="${mlph_line%% *}"
    mlph_n="${mlph_line#* }"
    mlph_p="$(printf '%s\n' "${mlph_heads}" | awk -v n="${mlph_n}" '$1 == n { print $2; exit }')"
    if [ -z "${mlph_p}" ] \
      || ! git cat-file -e "${mlph_p}^{commit}" 2> /dev/null \
      || git merge-base --is-ancestor "${mlph_p}" "${mlph_tip}"; then
      continue
    fi
    # A merge base that COMMIT lacks is a commit of a pull request's branch,
    # which reached COMMIT, if at all, only as a squash commit.
    mlph_qualifies=0
    for mlph_base in $(git merge-base --all "${mlph_tip}" "${mlph_p}"); do
      if ! git merge-base --is-ancestor "${mlph_base}" "${mlph_commit}"; then
        mlph_qualifies=1
        break
      fi
    done
    if [ "${mlph_qualifies}" -eq 0 ]; then
      continue
    fi
    if ! mlph_squash_tree="$(git rev-parse --verify --quiet "${mlph_s}^{tree}")" \
      || ! mlph_tree="$(git merge-tree --write-tree --no-messages "${mlph_s}^" "${mlph_p}" 2> /dev/null)" \
      || [ "${mlph_tree}" != "${mlph_squash_tree}" ]; then
      continue
    fi
    if ! mlph_tree="$(git merge-tree --write-tree --no-messages "${mlph_tip}" "${mlph_p}" 2> /dev/null)" \
      || ! mlph_merged_p="$(echo 'Merge the final version of a pull request' \
        | git commit-tree "${mlph_tree}" -p "${mlph_tip}" -p "${mlph_p}")" \
      || ! mlph_tree="$(git merge-tree --write-tree --no-messages "${mlph_merged_p}" "${mlph_s}" 2> /dev/null)" \
      || ! mlph_merged_s="$(echo 'Merge the commit that landed a pull request' \
        | git commit-tree "${mlph_tree}" -p "${mlph_merged_p}" -p "${mlph_s}")" \
      || ! merge_conflicts "${mlph_merged_s}" "${mlph_commit}" \
      || [ "${merge_conflicts_regions}" -gt "${mlph_regions}" ] \
      || ! mlph_changed_s="$(git diff-tree -r --no-renames --no-commit-id --name-only "${mlph_s}")"; then
      continue
    fi
    # Print the first file in which the merges change the result of the
    # merge of COMMIT but that neither a kept S nor this one changes and that
    # is not conflicted with and without the merges.
    mlph_unexplained="$(git diff-tree -r --no-renames --name-only "${mlph_tree0}" "${merge_conflicts_tree}" \
      | MLPH_CHANGED="${mlph_changed}
${mlph_changed_s}" MLPH_FILES0="${mlph_files0}" MLPH_FILES="${merge_conflicts_files}" awk '
          BEGIN {
            n = split(ENVIRON["MLPH_CHANGED"], files, "\n")
            for (i = 1; i <= n; i++) {
              changed[files[i]] = 1
            }
            n = split(ENVIRON["MLPH_FILES0"], files, "\n")
            for (i = 1; i <= n; i++) {
              conflicted0[files[i]] = 1
            }
            n = split(ENVIRON["MLPH_FILES"], files, "\n")
            for (i = 1; i <= n; i++) {
              conflicted[files[i]] = 1
            }
          }
          !($0 in changed) && !($0 in conflicted0 && $0 in conflicted) {
            print
            exit
          }')"
    if [ -n "${mlph_unexplained}" ]; then
      continue
    fi
    mlph_tip="${mlph_merged_s}"
    mlph_regions="${merge_conflicts_regions}"
    mlph_kept="${mlph_kept}${mlph_s} ${mlph_n} ${mlph_p}
"
    mlph_changed="${mlph_changed}
${mlph_changed_s}"
  done
  if [ -z "${mlph_kept}" ] || [ "${mlph_regions}" -ge "${mlph_regions0}" ]; then
    return 0
  fi

  # Make the merges for real, so that the hooks run.  The messages write
  # "pull request N" rather than "#N", which would add an event to the
  # timeline of pull request #N when the merges are pushed to GitHub.
  mlph_notes=''
  # Each iteration removes the first line from ${mlph_kept}.
  while [ -n "${mlph_kept}" ]; do
    mlph_line="${mlph_kept%%
*}"
    mlph_kept="${mlph_kept#*
}"
    mlph_s="${mlph_line%% *}"
    mlph_line="${mlph_line#* }"
    mlph_n="${mlph_line%% *}"
    mlph_p="${mlph_line#* }"
    mlph_short_p="$(git rev-parse --short "${mlph_p}")"
    mlph_short_s="$(git rev-parse --short "${mlph_s}")"
    if ! git merge -q --no-ff --no-edit --no-log \
      -m "Merge the final version of pull request ${mlph_n}" \
      -m "Pull request ${mlph_n} landed as commit ${mlph_short_s}, but branch ${mlph_branch} had merged an earlier
version of it.  This merge brings the rest of it, from commit ${mlph_short_p}." \
      "${mlph_p}" \
      || ! git merge -q --no-ff --no-edit --no-log \
        -m "Merge commit ${mlph_short_s}, which landed pull request ${mlph_n}" "${mlph_s}"; then
      # The merge could not start, as when a modified file is in the way, or
      # git's merge differs from `git merge-tree`'s.
      if git rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
        git merge --abort
      fi
      if ! git reset -q --keep "${mlph_old_head}"; then
        echo "${SCRIPT_NAME}: cannot restore branch ${mlph_branch} in $(pwd) to commit ${mlph_old_head} after a failed merge of the final version of pull request #${mlph_n}" >&2
        return 1
      fi
      echo "${SCRIPT_NAME}: cannot merge the final version of pull request #${mlph_n} into branch ${mlph_branch} in $(pwd); merging ${2} without the final versions of the pull requests" >&2
      merged_landed_prs=''
      return 0
    fi
    merged_landed_prs="${merged_landed_prs}${merged_landed_prs:+ }#${mlph_n}"
    mlph_notes="${mlph_notes}${SCRIPT_NAME}: merged the final version of pull request #${mlph_n} (commit ${mlph_short_p}), and then commit ${mlph_short_s}, which landed it, before ${2}:  branch ${mlph_branch} had merged an earlier version of the pull request
"
  done
  printf '%s' "${mlph_notes}" >&2
}

## Usage: merge_build_push COMMIT DESCRIPTION SOURCE NOCOMPILE [RESOLVER [BUILT [DIRECTORY]]]
## Merges COMMIT into the current branch, builds with `compile-project` unless
## NOCOMPILE is 1 or $MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT is set, and
## pushes the current branch if the build succeeds.  DESCRIPTION is the
## source of COMMIT as a line of FETCH_HEAD gives it, which
## `git fmt-merge-msg` turns into the merge message:  either a description of
## a ref of the local repository followed by " of .", such as
## "branch 'feature' of ." or "remote-tracking branch 'upstream/master' of .",
## for which the message is "Merge branch 'feature' into BRANCH" (the "."
## keeps git from appending " of LOCATION"); or a repository's location alone,
## such as "github.com:org/proj", for the head of that repository, for which
## the message is "Merge github.com:org/proj into BRANCH".  SOURCE names
## COMMIT in diagnostics.  Before merging COMMIT, merges the final version of
## each pull request that landed in COMMIT and of which the current branch
## merged an earlier version, if that avoids conflicts (see
## `merge_landed_pr_heads`).  If the merge has conflicts,
## `resolve_merge_conflicts` resolves them, asking RESOLVER, if it is given
## and not empty, about any that `git rerere` did not resolve.  A merge
## without conflicts whose commit a pre-merge-commit hook rejected is
## committed as `commit_rejected_merge` describes.  If the build
## fails,
## `fix_failed_build` asks RESOLVER, if it is given and not empty, to fix
## it, but only if a merge on the current branch might have broken the
## build, as `has_unbuilt_merge` determines.  Its argument is BUILT, a list
## of commits, separated by spaces, whose histories were built elsewhere,
## such as "refs/remotes/upstream/main" or the head that a pull of the
## current branch fetched (see `pull_resolving`), together with the
## `built_commits` of DIRECTORY, a working tree such as the one that COMMIT
## comes from, if DIRECTORY is given and not empty.  The merge commit can be
## the one that this call made, one that a pull made, or one that an earlier
## call made but did not push, as when its build failed.
## After a successful build, removes the entries of AGENT-TODO.md that no
## longer apply, such as one about a failed build (see `prune_agent_todo`).
## Returns 1, after printing a diagnostic, on failure.  Sets
## ${merge_build_push_step} to the step that it reached:  "merging",
## "building", or "pushing".
## ${SCRIPT_DIR} must be set; see the top of this file.
# shellcheck disable=SC2034 # git-push-to reads ${merge_build_push_step}.
merge_build_push() {
  merge_build_push_step='merging'
  # Let git compose the message, as it does for `git merge`, rather than
  # composing it by hand.  Git then writes the "into BRANCH" suffix, which it
  # omits on the default branch, and the commit summaries that `merge.log`
  # turns on.
  if ! merge_message="$(printf '%s\t\t%s\n' "$1" "$2" | fmt_merge_message)"; then
    echo "${SCRIPT_NAME}: cannot compose a merge message for $3" >&2
    return 1
  fi

  # Merge rather than `git pull`, which rebases if `pull.rebase` is set.  A
  # rebase would rewrite the branch that this function is about to push.
  # `--no-edit` keeps a chain of merges from stopping at an editor.
  # `--no-log` prevents a second copy of the commit summaries:  `git merge`
  # appends them to a message given with `-m` when `merge.log` is set, and
  # ${merge_message} already contains the ones that `fmt-merge-msg` wrote.
  # 1 if this call builds the merge, and 0 otherwise.
  if [ "$4" -eq 0 ] && [ -z "${MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT}" ]; then
    merge_builds=1
  else
    merge_builds=0
  fi
  # A build of uncommitted changes, such as those that a failed attempt to
  # fix the build left staged, says nothing about the commit that is pushed.
  # Check before merging, so that a refusal leaves no merge commit behind.
  if [ "${merge_builds}" -eq 1 ] \
    && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "${SCRIPT_NAME}: the working tree of $(pwd) has uncommitted changes; commit or discard them" >&2
    return 1
  fi
  # HEAD before the merges, so that a merge that cannot start can be undone.
  if ! merge_old_head="$(git rev-parse --verify HEAD)"; then
    echo "${SCRIPT_NAME}: cannot read HEAD in $(pwd)" >&2
    return 1
  fi
  if ! merge_landed_pr_heads "$1" "$3"; then
    return 1
  fi
  # HEAD before the merge of COMMIT, so that the agent can be told what the
  # merge did.
  if ! merge_premerge_head="$(git rev-parse --verify HEAD)"; then
    echo "${SCRIPT_NAME}: cannot read HEAD in $(pwd)" >&2
    return 1
  fi
  # `rerere.autoUpdate` false keeps each file that `git rerere` resolves
  # unmerged in the index, where `resolve_merge_conflicts` finds it.  The
  # merge uses the conflict style that the configuration gives:  rerere
  # replays a resolution only for a conflict region that encloses the same
  # text as when the resolution was recorded, and the style determines which
  # lines a region encloses.
  # The state of the working tree before the merge, for
  # `commit_rejected_merge`.
  if ! merge_top="$(git rev-parse --show-toplevel)"; then
    echo "${SCRIPT_NAME}: cannot find the top level of the working tree $(pwd)" >&2
    return 1
  fi
  commit_staged_before "${merge_top}"
  if ! git -c rerere.autoUpdate=false merge -q --no-edit --no-log \
    -m "${merge_message}" "$1"; then
    # A failed merge without MERGE_HEAD did not start, for example because it
    # would overwrite a modified file; there are no conflicts to resolve.
    # Otherwise, `resolve_merge_conflicts` says what is wrong, if anything.
    # Undo the merges of the pull requests' final versions too, which were
    # made only for this merge.
    if ! git rev-parse --verify --quiet MERGE_HEAD > /dev/null; then
      echo "${SCRIPT_NAME}: problem merging $3 into $(pwd)" >&2
      if [ -n "${merged_landed_prs}" ] && ! git reset -q --keep "${merge_old_head}"; then
        echo "${SCRIPT_NAME}: the branch in $(pwd) also has the merges of the final versions of pull requests ${merged_landed_prs}; \`git reset --keep ${merge_old_head}\` removes them" >&2
      fi
      return 1
    fi
    # Git names the conflicted files relative to the top level of the working
    # tree, so `resolve_merge_conflicts` runs there, in a subshell that leaves
    # the current directory unchanged.
    if ! (cd "${merge_top}" && commit_resolved_merge "${5:-}" "$1" "$3" "${merge_message}"); then
      if [ -n "${merged_landed_prs}" ]; then
        echo "${SCRIPT_NAME}: before merging $3, the branch in $(pwd) merged the final versions of pull requests ${merged_landed_prs}; if you abort the merge, \`git reset --keep ${merge_old_head}\` also removes those merges" >&2
      fi
      return 1
    fi
  fi

  if [ "${merge_builds}" -eq 1 ]; then
    merge_build_push_step='building'
    if ! merge_log="$(git rev-parse --path-format=absolute --git-path manage-git-branches-build.log)"; then
      echo "${SCRIPT_NAME}: cannot find the git directory of $(pwd)" >&2
      return 1
    fi
    if ! build_logged "${merge_log}"; then
      echo "${SCRIPT_NAME}: unable to build in $(pwd)" >&2
      # Without the agent, stop as with "--no-llm".  Whether a merge might
      # have broken the build is decided only now, because deciding can
      # fetch.  Whether the agent is ready to run is checked only once the
      # agent is needed, because checking can cost a request to its service.
      if [ -z "${5:-}" ]; then
        return 1
      fi
      merge_built="${6:-}"
      if [ -n "${7:-}" ]; then
        merge_built="${merge_built}${merge_built:+ }$(built_commits "$7")"
      fi
      if ! has_unbuilt_merge "${merge_built}"; then
        return 1
      fi
      if ! agent_available "$5"; then
        [ -z "${agent_unavailable_reason}" ] \
          || merge_build_note "${merge_fix_message}" "${agent_unavailable_reason}  $(agent_rerun_advice "$5" 'fix the build')"
        return 1
      fi
      # What this call's merge did, for the agent.
      if ! merge_new_head="$(git rev-parse --verify HEAD)"; then
        echo "${SCRIPT_NAME}: cannot read HEAD in $(pwd)" >&2
        return 1
      fi
      if [ "${merge_new_head}" = "${merge_premerge_head}" ]; then
        merge_did="Branch ${merge_fix_branch} already contained commit $1, so the script's merge of it changed nothing."
      elif [ "${merge_new_head}" = "$(git rev-parse --verify --quiet "$1^{commit}")" ]; then
        merge_did="The script just fast-forwarded branch ${merge_fix_branch} to commit $1."
      else
        merge_did="The script just merged commit $1 into branch ${merge_fix_branch}."
      fi
      if [ -n "${merged_landed_prs}" ]; then
        merge_did="Before merging commit $1, the script merged into branch ${merge_fix_branch} the final version of each of the pull requests ${merged_landed_prs}, each followed by the commit that landed it; either kind of merge might have broken the build.  ${merge_did}"
      fi
      # `fix_failed_build` runs at the top level of the working tree, where
      # the agent's session, and the command that continues it, start.
      merge_dir="$(pwd)"
      if ! cd -- "${merge_top}"; then
        echo "${SCRIPT_NAME}: cannot cd to ${merge_top}" >&2
        return 1
      fi
      # An earlier entry that says that running the script again suffices is
      # out of date once the agent runs.
      prune_agent_todo 0 build
      fix_failed_build "$5" "${merge_log}" "${merge_fix_message}" "${merge_did}  ${merge_fix_account}"
      merge_fix_status=$?
      if [ "${merge_fix_status}" -eq 3 ]; then
        merge_build_note "${merge_fix_message}" "$(agent_unchanged_reason "$5")  $(agent_rerun_advice "$5" 'fix the build')"
        cd -- "${merge_dir}" || true
        return 1
      elif [ "${merge_fix_status}" -ne 0 ]; then
        report_agent_session "${merge_fix_message}"
        cd -- "${merge_dir}" || true
        return 1
      fi
      if ! cd -- "${merge_dir}"; then
        echo "${SCRIPT_NAME}: cannot cd back to ${merge_dir}" >&2
        return 1
      fi
    fi
    # No merge is in progress, and the build succeeded.
    prune_agent_todo 1
  fi

  merge_build_push_step='pushing'
  if ! git push --quiet; then
    echo "${SCRIPT_NAME}: problem pushing from $(pwd)" >&2
    return 1
  fi
}

## Usage: merge_build_note TASK NOTE
## For `merge_build_push`, when no AI agent tried to fix the build, or none
## did anything:  appends NOTE, one line that ends with the advice of
## `agent_rerun_advice`, to the summary (see `append_summary`), and to
## AGENT-TODO.md, under a heading that gives TASK, such as "Fix the build
## after merging branch 'main'", after a line that names the working tree,
## as in "The build failed in /home/me/myrepo-branch-feature." (see
## `append_agent_note`).  First removes each earlier entry about the build
## of the working tree with such advice, which NOTE replaces (see
## `prune_agent_todo`).
merge_build_note() {
  append_summary "$2"
  prune_agent_todo 0 build
  merge_build_todo="$(agent_todo_path)" || merge_build_todo=''
  # `prune_agent_todo` recognizes the line that names the working tree.
  if append_agent_note "${merge_build_todo}" "$1" "The build failed in ${merge_build_todo%/*}.
$2"; then
    echo "${SCRIPT_NAME}: noted that in ${merge_build_todo}" >&2
  fi
}
