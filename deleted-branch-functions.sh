# shellcheck shell=sh

# Functions that determine whether the branch of a working tree was deleted in
# its remote, as `is_deleted_branch` does.
#
# `common-functions.sh` sources this file.  A script uses these functions by
# sourcing that file, which says what the script must set first.

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
  case "${url_location_url}" in
    '') return 0 ;;
    '~'*)
      printf '%s\n' "${url_location_url}"
      return 0
      ;;
  esac
  if ! is_pathname "${url_location_url}"; then
    printf '%s\n' "${url_location_url}"
    return 0
  fi
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

## Usage: is_pathname URL
## Returns 0 if URL, a location of a repository that git accepts, such as
## "../proj" or "git@github.com:org/proj.git", is a pathname, and returns 1
## if it is a URL.  Git reads a string as a URL if it has a scheme, such as
## "https://" or "file://", and as an scp-style URL if a colon precedes its
## first slash.
is_pathname() {
  case "$1" in
    *://*) return 1 ;;
    *:*)
      case "${1%%:*}" in
        */*) ;;
        *) return 1 ;;
      esac
      ;;
  esac
  return 0
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
## one "SHA<TAB>refname" line per branch, and ${remote_heads_error} to what
## git printed on standard error, which says why the remote could not be
## asked when it could not.
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
  remote_heads_error=''
  if [ -n "$3" ]; then
    remote_heads_index="$(printf '%s\n' "${remote_heads_keys}" \
      | grep -n -x -F -- "$3" | head -n 1)"
    remote_heads_index="${remote_heads_index%%:*}"
    if [ -n "${remote_heads_index}" ]; then
      eval "remote_heads_output=\${remote_heads_output_${remote_heads_index}}"
      return 0
    fi
  fi
  if git_batch_ssh_capture "$1" ls-remote --heads "$2"; then
    remote_heads_status=0
  else
    remote_heads_status="$?"
  fi
  # shellcheck disable=SC2154 # set by `git_batch_ssh_capture`, in common-functions.sh
  remote_heads_output="${git_batch_ssh_capture_output}"
  # shellcheck disable=SC2154 # set by `git_batch_ssh_capture`, in common-functions.sh
  remote_heads_error="${git_batch_ssh_capture_error}"
  if [ -n "$3" ] && [ "${remote_heads_status}" -eq 0 ]; then
    remote_heads_answers=$((remote_heads_answers + 1))
    remote_heads_keys="${remote_heads_keys}$3
"
    eval "remote_heads_output_${remote_heads_answers}=\${remote_heads_output}"
  fi
  return "${remote_heads_status}"
}

## Usage: is_build_output_name NAME
## Returns 0 (true) if NAME, the last component of a directory's pathname, is
## the name of a directory of Python build output:  `.venv`, a virtual
## environment, or a name that ends in `.egg-info`, such as
## `myproject.egg-info`, which holds package metadata.  Such a directory holds
## no branch directory and no work, except as `holds_no_checkout` tests.
is_build_output_name() {
  case "$1" in
    '.venv' | *.egg-info) return 0 ;;
  esac
  return 1
}

## Usage: holds_no_checkout DIRECTORY
## Returns 0 (true) if a directory DIRECTORY holds no version-control
## checkout:  that is, if nothing in DIRECTORY, at any depth, is named `.git`,
## `.hg`, `.svn`, or `.bzr`.  Returns 1 (false) if the user cannot read some
## directory in DIRECTORY, which might hold a checkout.
##
## `find` writes newline-separated text, which cannot represent a file name
## that contains a newline, but this function needs only whether `find` wrote
## anything, which such a name does not obscure.
holds_no_checkout() {
  holds_no_checkout_found="$(find "$1" \( -name .git -o -name .hg -o -name .svn \
    -o -name .bzr \) -prune -print 2> /dev/null)" || return 1
  [ -z "${holds_no_checkout_found}" ]
}

## Usage: only_leftovers DIRECTORY
## Returns 0 (true) if DIRECTORY holds nothing but leftovers:  files and
## directories that tools other than git create in a working tree and that
## remain after the working tree itself is gone.  A leftover is one of these:
##  * an Eclipse `.project` file, which is a regular file;
##  * a directory of Python build output that holds no version-control
##    checkout, as `holds_no_checkout` tests:  either a Python virtual environment, which is a directory named `.venv`,
##    or Python package metadata, which is a directory whose name ends in
##    `.egg-info`, such as `myproject.egg-info`.
## That is, every entry of DIRECTORY is a leftover or is a directory that
## itself holds nothing but leftovers.  A directory that holds nothing at all
## satisfies this, which is what lets an empty subdirectory -- such as the
## `bin` that Eclipse makes for a project's build output -- count as nothing.
##
## Such a directory's contents are build output, which a build re-creates, so
## they need not be leftovers themselves.  Nor need they belong to the user:
## a container that runs as root creates them owned by root, and they are
## what remains when the user's `rm -rf` of a branch directory cannot remove
## them.  A `.venv` or `*.egg-info` directory that holds a version-control
## checkout is not a leftover, because `pip install -e git+URL#egg=NAME`
## clones a repository into `.venv/src/`, and that clone can hold unpushed
## work.
##
## This says only what is in DIRECTORY; the caller decides what that means.
## A directory that holds nothing satisfies this test only vacuously, so the
## variable `only_leftovers_found` is set to a nonempty value if at least one
## leftover was seen, and is left alone otherwise.  A caller that
## distinguishes a tree of leftovers from a tree of nothing -- as
## `is_leftover_tree` does -- sets that variable to the empty string before
## the call and tests it after.  A shell function has no local variables, so
## the recursive calls below all set the one variable, and it therefore
## reports about the whole tree.
##
## A symbolic link is content, whether it names a directory, a file, or
## nothing:  it is never a leftover, and it is not descended into.  Following
## one that names an ancestor would not terminate, and a link is something
## that the user put there.
##
## `find` would be simpler, but `find` communicates through newline-separated
## text, which cannot represent a file name that contains a newline, whereas
## the globs and the positional parameters below can hold any file name.
##
## The entries that remain to be examined are held in the positional
## parameters, which a shell makes local to a function call, so the recursive
## call below gets its own and this call's are intact when it returns.  A
## `for` loop over a variable could not recurse, because a shell function has
## no local variables.
only_leftovers() {
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
        # A *directory* named `.project` can hold anything, so leave it to the
        # test below, which descends into it like any other directory.
        if [ -f "$1" ] && [ ! -L "$1" ]; then
          only_leftovers_found=1
          shift
          continue
        fi
        ;;
    esac
    # A *file* with the name of a directory of build output can hold anything,
    # so leave it to the test below, which treats it as content.
    if is_build_output_name "${1##*/}" && [ -d "$1" ] && [ ! -L "$1" ]; then
      if ! holds_no_checkout "$1"; then
        return 1
      fi
      only_leftovers_found=1
      shift
      continue
    fi
    # When a pattern matches nothing, the shell leaves it unexpanded.  Such a
    # pathname names no entry, so it is not content.
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then
      shift
      continue
    fi
    if [ ! -d "$1" ] || [ -L "$1" ] || ! only_leftovers "$1"; then
      return 1
    fi
    shift
  done
  return 0
}

## Usage: is_leftover_tree DIRECTORY
## Returns 0 (true) if a directory DIRECTORY holds nothing but leftovers, as
## `only_leftovers` tests, and holds at least one leftover.
##
## `only_leftovers` is satisfied by a directory that holds nothing at all, and
## a tree of nothing but empty directories is not evidence of a working tree
## that a branch directory once held.  The leftover need not be in DIRECTORY
## itself:  a branch whose Eclipse projects were all below its top level, such
## as a `java/lib` that Eclipse knew as a project, leaves its metadata there
## and none at the top.
is_leftover_tree() {
  only_leftovers_found=
  only_leftovers "$1" && [ -n "${only_leftovers_found}" ]
}

## Usage: warn_cannot_list_branches REMOTE DIRECTORY ERROR
## Prints, on standard error, that the branches of a remote REMOTE of the
## working tree DIRECTORY cannot be listed, followed by ERROR, indented, if it
## is nonempty.  ERROR is what the git command that tried to list them printed
## on standard error, such as "Host key verification failed.".
##
## ERROR is printed only the first time that it is seen.  When a later call
## has the same ERROR, the warning instead names the directory whose warning
## printed it.  A scan of many directories, such as `git-orphaned-branches`
## performs, fails the same way in each of them when the network is down, and
## git's error is several lines long.
##
## ${warn_cannot_list_branches_count} is the number of distinct errors
## printed; the variables `warn_cannot_list_branches_error_N` and
## `warn_cannot_list_branches_dir_N` hold the Nth of them and the directory
## whose warning printed it.  A shell has no associative array.
warn_cannot_list_branches_count=0
warn_cannot_list_branches() {
  if [ -z "$3" ]; then
    echo "${SCRIPT_NAME}: cannot list branches of remote $1 for $2" >&2
    return 0
  fi
  warn_cannot_list_branches_seen=''
  warn_cannot_list_branches_index=1
  while [ "${warn_cannot_list_branches_index}" -le "${warn_cannot_list_branches_count}" ]; do
    eval "warn_cannot_list_branches_seen=\${warn_cannot_list_branches_error_${warn_cannot_list_branches_index}}"
    if [ "${warn_cannot_list_branches_seen}" = "$3" ]; then
      eval "warn_cannot_list_branches_seen=\${warn_cannot_list_branches_dir_${warn_cannot_list_branches_index}}"
      echo "${SCRIPT_NAME}: cannot list branches of remote $1 for $2, for the same reason as for ${warn_cannot_list_branches_seen}" >&2
      return 0
    fi
    warn_cannot_list_branches_index=$((warn_cannot_list_branches_index + 1))
  done
  warn_cannot_list_branches_count=$((warn_cannot_list_branches_count + 1))
  eval "warn_cannot_list_branches_error_${warn_cannot_list_branches_count}=\$3"
  eval "warn_cannot_list_branches_dir_${warn_cannot_list_branches_count}=\$2"
  echo "${SCRIPT_NAME}: cannot list branches of remote $1 for $2:" >&2
  # Indent only nonempty lines, so that a blank line gets no trailing spaces.
  printf '%s\n' "$3" | sed -e 's/^./  &/' >&2
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
## Also sets the variable `is_deleted_branch_no_usable_repository` to a
## nonempty value (true) if this returns status 2 because DIRECTORY is a
## directory at which git can use no repository, and to the empty string
## (false) otherwise, including when DIRECTORY does not exist or is not a
## directory.  Git can use no repository at DIRECTORY if no repository
## contains DIRECTORY; if the one that contains it is broken, such as a linked
## worktree whose `.git` file names a git directory that no longer exists; if
## git refuses it, such as one that another user owns and that
## `safe.directory` does not allow; or if git cannot enter DIRECTORY.  The
## variable lets a caller explain status 2 without asking git again.
##
## Also sets the variable `is_deleted_branch_heads`, when this returns status
## 1, to lines "SHA<TAB>refname" that the remote listed, such as
## "3f2a9c...<TAB>refs/heads/feature", among which is one for each upstream
## ref of the branch that exists in the remote; and sets it to the empty
## string otherwise.  The variable lets a caller learn the commit that the
## remote branch names without asking the remote again.
##
## The body lives here rather than in the command so that the other commands
## of this package can ask the question directly.
is_deleted_branch() {
  is_deleted_branch_dir="$1"
  is_deleted_branch_no_usable_repository=
  is_deleted_branch_heads=

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

  # A directory that holds nothing but leftovers, such as Eclipse `.project`
  # files and a Python `.venv` directory, is the leftover of a branch directory
  # whose working tree is gone:  what remains is what other tools made, and
  # none of the branch itself.  Such a directory is as removable as one whose
  # branch was deleted in its remote, so answer 0 for it.  `only_leftovers`
  # says which files and directories are leftovers.  The tests below would
  # call such a directory "not the top level of a working tree" (status 2):
  # that is true, and it would leave the caller's question -- may this
  # directory be removed? -- unanswered when it has an answer.
  #
  # Answer 0 only for a directory of leftovers that no working tree claims:
  # one at which git can use no repository, or one in a working tree that
  # tracks none of its files, such as a leftover in a home directory that is a
  # repository of configuration files.  A directory in a working tree that
  # tracks a file in it, such as a test fixture that holds a `*.egg-info`
  # directory, is part of that working tree, and removing it would delete
  # tracked files.  The top level of a working tree holds its `.git`, which is
  # not a leftover.

  # `git -C DIR rev-parse` succeeds for every directory within a working tree,
  # so also require that DIRECTORY is that working tree's top level.  A
  # subdirectory is not itself a working tree, and answering for the enclosing
  # one would answer a question that the caller did not ask.
  #
  # `--is-bare-repository` prints a line, "true" or "false", whenever git can
  # use a repository at DIRECTORY, even one that has no working tree, such as a
  # bare repository or a `.git` directory.  For such a repository,
  # `--show-toplevel` then fails in recent versions of git and prints an empty
  # line in older ones.  So a failure with no output means that git can use no
  # repository there.
  if ! is_deleted_branch_toplevel="$(git -C "${is_deleted_branch_dir}" rev-parse \
    --is-bare-repository --show-toplevel 2> /dev/null)"; then
    if [ -z "${is_deleted_branch_toplevel}" ]; then
      if is_leftover_tree "${is_deleted_branch_dir}"; then
        return 0
      fi
      # shellcheck disable=SC2034 # Callers read it; see the documentation above.
      is_deleted_branch_no_usable_repository=1
    fi
    return 2
  fi
  # Remove the line that `--is-bare-repository` printed.  A command
  # substitution removes trailing newlines, so an empty last line leaves none.
  case "${is_deleted_branch_toplevel}" in
    *'
'*)
      is_deleted_branch_toplevel="${is_deleted_branch_toplevel#*
}"
      ;;
    *) is_deleted_branch_toplevel= ;;
  esac
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
    # or otherwise.  It is a leftover if the working tree tracks no file in it,
    # which is status 1 of `git ls-files --error-unmatch`.
    if is_leftover_tree "${is_deleted_branch_dir}"; then
      git -C "${is_deleted_branch_dir}" ls-files --error-unmatch -- . \
        > /dev/null 2>&1
      if [ "$?" -eq 1 ]; then
        return 0
      fi
    fi
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
      warn_cannot_list_branches "${is_deleted_branch_remote}" \
        "${is_deleted_branch_dir}" "${remote_heads_error}"
      return 3
    fi
    # Each line of the listing is "SHA<TAB>refname".
    is_deleted_branch_listed="$(printf '%s\n' "${remote_heads_output}" | cut -f 2)"
    for is_deleted_branch_ref_arg in "$@"; do
      if printf '%s\n' "${is_deleted_branch_listed}" \
        | grep -q -x -F -- "${is_deleted_branch_ref_arg}"; then
        # The branch still exists in the remote.
        # shellcheck disable=SC2034 # Callers read it; see the documentation above.
        is_deleted_branch_heads="${remote_heads_output}"
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
  if git_batch_ssh_capture "${is_deleted_branch_dir}" \
    ls-remote --exit-code "${is_deleted_branch_remote}" "$@"; then
    is_deleted_branch_status=0
  else
    is_deleted_branch_status="$?"
  fi
  case "${is_deleted_branch_status}" in
    0)
      # The branch still exists in the remote.
      # shellcheck disable=SC2034 # Callers read it; see the documentation above.
      is_deleted_branch_heads="${git_batch_ssh_capture_output}"
      return 1
      ;;
    2)
      # The branch was deleted in the remote.
      return 0
      ;;
    *)
      # The remote could not be contacted (say, the network is down), so it is
      # unknown whether the branch still exists there.
      warn_cannot_list_branches "${is_deleted_branch_remote}" \
        "${is_deleted_branch_dir}" "${git_batch_ssh_capture_error}"
      return 3
      ;;
  esac
}
