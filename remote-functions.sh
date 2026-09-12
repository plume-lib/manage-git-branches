# shellcheck shell=sh

# Functions that this package's commands share.  Other scripts source this
# file, rather than running it as a command, so it has no shebang line and is
# not executable.
#
# A script that sources this file must set ${SCRIPT_DIR} to the directory that
# contains this package's files, because `git_batch_ssh` runs a wrapper script
# from that directory.  It must also set ${SCRIPT_NAME} to its own name, which
# the diagnostics below use.

## Usage: check_git_dir_is_directory DIRECTORY
## Tests whether DIRECTORY, the top level of a working tree, holds its own
## repository:  that is, whether DIRECTORY/.git is a directory and is not a
## symbolic link to one.  Returns 0 if it is.  Otherwise prints a diagnostic
## that says where to run the command instead, and returns 1.
##
## `git-new-branch` and `git-checkout-branch` copy the top level with
## `cp -Rp`, which copies `.git` along with everything else.  That is the
## design when `.git` is a directory:  the copy is an independent clone.  When
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
## directories, so comparing the two as strings needs no
## `--path-format=absolute`, which git gained only in version 2.31.
##
## `git rev-parse` prints an option that it does not recognize, rather than
## failing, so a git too old for one of these options answers with the
## option's own name.  Such an answer, and a query that fails outright, leave
## the distinction unavailable; the diagnostic then says only that the git
## directory lies elsewhere, which is the part that is certain.  A git that
## does not recognize `--show-superproject-working-tree` cannot rule out a
## submodule, whose `--git-dir` and `--git-common-dir` are equal just as they
## are in a repository made with `--separate-git-dir`, so that answer
## discards the comparison as well, rather than offering the remedy for the
## wrong one of the two.
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
## would miss the submodule; and `-d` answers in every version of git.
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
    echo "${SCRIPT_NAME}: ERROR: $1 has no .git, so its git directory is named by the environment or by configuration elsewhere." >&2
    echo "${SCRIPT_NAME}: A copy of it would hold no repository, and the checkout would move this working tree's HEAD and rewrite its index." >&2
    echo "${SCRIPT_NAME}: Run ${SCRIPT_NAME} in a working tree that holds its own .git directory, with GIT_DIR and GIT_WORK_TREE unset." >&2
    return 1
  fi
  check_git_dir_superproject="$(git -C "$1" rev-parse \
    --show-superproject-working-tree 2> /dev/null)"
  check_git_dir_submodule_known=1
  case "${check_git_dir_superproject}" in
    --show-superproject-working-tree)
      check_git_dir_superproject=
      check_git_dir_submodule_known=
      ;;
  esac
  if [ -n "${check_git_dir_superproject}" ]; then
    echo "${SCRIPT_NAME}: ERROR: $1 is the working tree of a submodule, whose .git is a file rather than a directory." >&2
    echo "${SCRIPT_NAME}: A copy of it would share this working tree's git directory, so the checkout would move this working tree's HEAD and rewrite its index." >&2
    echo "${SCRIPT_NAME}: Run ${SCRIPT_NAME} in the superproject ${check_git_dir_superproject} instead, whose branches are the ones worth branching." >&2
    return 1
  fi
  check_git_dir_gitdir="$(git -C "$1" rev-parse --git-dir 2> /dev/null)"
  check_git_dir_common="$(git -C "$1" rev-parse --git-common-dir 2> /dev/null)"
  case "${check_git_dir_common}" in
    --git-common-dir) check_git_dir_common= ;;
  esac
  if [ -z "${check_git_dir_gitdir}" ] || [ -z "${check_git_dir_common}" ] \
    || [ -z "${check_git_dir_submodule_known}" ]; then
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
## A helper for `push_remote` and `fetch_remote`:  sets ${remote_result} to
## NAME if ${remote_result} is not set yet and NAME is a remote that the clone
## in ${remote_dir} can contact.
remote_consider() {
  if [ -z "${remote_result}" ] \
    && remote_is_usable "${remote_dir}" "${remote_remotes}" "$1"; then
    remote_result="$1"
  fi
}

## Usage: remote_consider_sole
## A helper for `push_remote` and `fetch_remote`:  sets ${remote_result} to
## the sole remote of the clone in ${remote_dir}, if ${remote_result} is not
## set yet and that clone has exactly one remote.  Such a clone has no remote
## named "origin", because `remote_consider origin` would have accepted it,
## but its one remote is the only remote that any branch of it could come
## from or go to.
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
## Four things decide it.  One is the URL that REMOTE resolves to, which is
## what determines whether two queries ask the same repository -- not whether
## the directories share a repository, and not what they call the remote.
## `git ls-remote --get-url` resolves it, applying `url.*.insteadOf` rewriting
## as the query itself would.
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
## A remote given as a pathname is resolved in the directory that names it, so
## two directories that both say "../upstream.git" do not name one repository.
## Canonicalize such a pathname.  A pathname that cannot be canonicalized, or
## a key that contains a newline (which the list of keys could not hold),
## yields no key at all:  a query that is not shared is always correct, merely
## slower.
remote_heads_key() {
  remote_heads_key_url="$(git -C "$1" ls-remote --get-url "$2" 2> /dev/null)" \
    || return 0
  if [ -z "${remote_heads_key_url}" ]; then
    return 0
  fi
  # Git reads a string as a URL if it has a scheme, and as an scp-style URL if
  # a colon precedes the first slash.  Anything else is a pathname, and "~"
  # begins one that is not relative to DIRECTORY.  An empty location below
  # means "a pathname", which the next block canonicalizes.
  case "${remote_heads_key_url}" in
    *://* | '~'*) remote_heads_key_location="${remote_heads_key_url}" ;;
    *:*)
      case "${remote_heads_key_url%%:*}" in
        */*) remote_heads_key_location='' ;;
        *) remote_heads_key_location="${remote_heads_key_url}" ;;
      esac
      ;;
    *) remote_heads_key_location='' ;;
  esac
  if [ -z "${remote_heads_key_location}" ]; then
    case "${remote_heads_key_url}" in
      /*) remote_heads_key_path="${remote_heads_key_url}" ;;
      *) remote_heads_key_path="$1/${remote_heads_key_url}" ;;
    esac
    # Unlike the `physical_path` calls in `is_deleted_branch`, which explain
    # the failure that they let through, this one is expected to fail:  a
    # remote that names a pathname that no longer exists is an ordinary
    # reason to have no key.  Discard `cd`'s diagnostic, which would name the
    # pathname with no hint of what asked about it.
    remote_heads_key_location="$(physical_path "${remote_heads_key_path}" \
      2> /dev/null)" || return 0
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
## `is_deleted_branch` also requires a `.project` file at DIRECTORY's own top
## level, so that an empty directory, which satisfies this test only
## vacuously, is not reported as a deleted branch.
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
  # Require a `.project` file in DIRECTORY itself.  `only_dot_project` is
  # satisfied by a directory that holds nothing at all, and an empty directory
  # is not evidence of an Eclipse project that a branch directory once held.
  if [ -f "${is_deleted_branch_dir}/.project" ] \
    && [ ! -L "${is_deleted_branch_dir}/.project" ] \
    && only_dot_project "${is_deleted_branch_dir}"; then
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
