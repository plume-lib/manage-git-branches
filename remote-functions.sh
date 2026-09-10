# shellcheck shell=sh

# Functions that this package's commands share.  Other scripts source this
# file, rather than running it as a command, so it has no shebang line and is
# not executable.
#
# A script that sources this file must set ${SCRIPT_DIR} to the directory that
# contains this package's files, because `git_batch_ssh` runs a wrapper script
# from that directory.
#
# Most of these functions are about remotes, which is what the file is named
# for.  `conflict_abort_command` is not, but it is shared by the same commands,
# and this is the file that they all source.

## Usage: remote_is_usable DIRECTORY REMOTES NAME
## Tests whether NAME names a remote that a git command run in DIRECTORY can
## contact.  REMOTES is the output of `git remote` in the clone in question:
## the names of its remotes, one per line.
##
## Configuration can name a remote that a clone does not have.
## `remote.pushDefault` in particular is a default for every branch of every
## clone, commonly set once in ~/.gitconfig to name a fork; in a clone that has
## no such remote, it names a remote that only some other clone has.  A query
## about such a name fails, which would silently disable a check, and a command
## that names it in advice to the user fails with "does not appear to be a git
## repository", which hides the actual problem.  So `push_remote` skips such a
## name and considers the next possibility.
##
## Git accepts a URL or a pathname wherever it accepts a remote's name, and
## permits one as the value of `branch.BRANCH.remote` or `remote.pushDefault`
## -- `git push --set-upstream ../other.git BRANCH` writes one there -- so
## those count as usable as well.  A string that contains ":" is an scp-style
## or a scheme-style URL, and "~" begins a pathname in the shell syntax that
## git accepts for a local repository.  Any other string is a pathname only if
## it names a repository:  git does accept "/" in the name of a remote
## (`git remote add team/fork URL` succeeds), so a slash does not distinguish a
## pathname from the name of a remote that this clone lacks, and only the file
## system does.  A relative pathname is resolved in DIRECTORY, where git
## resolves the ones it is given.
##
## Merely existing is not enough.  A file or a directory of that name is
## commonplace -- a working tree that contains a directory named "upstream"
## would make `remote.pushDefault = upstream` look usable in a clone whose
## only remote is "origin" -- and a query to such a "remote" fails in exactly
## the way that this function exists to prevent.  A bundle file does not count
## either:  git can fetch from one, but this package's callers push to the
## remote they choose, or advise the user to.
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
    *) remote_is_usable_path="$1/$3" ;;
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
## wherever it accepts a remote's name and which `push_remote` therefore
## reports when that is what the configuration says.
##
## A command that requires the name of a remote, such as
## `git remote set-branches`, fails on a URL or a pathname ("No such remote"),
## and `git fetch URL` records no remote-tracking branch, so advice that names
## one must be worded differently.
is_remote_name() {
  git -C "$1" remote | grep -q -x -F -- "$2"
}

## Usage: push_remote_consider NAME
## A helper for `push_remote`:  sets ${push_remote_result} to NAME if
## ${push_remote_result} is not set yet and NAME is a remote that the clone in
## ${push_remote_dir} can contact.
push_remote_consider() {
  if [ -z "${push_remote_result}" ] \
    && remote_is_usable "${push_remote_dir}" "${push_remote_remotes}" "$1"; then
    push_remote_result="$1"
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
  push_remote_dir="$1"
  push_remote_branch="$2"
  push_remote_remotes="$(git -C "${push_remote_dir}" remote)"
  push_remote_result=''
  if [ -n "${push_remote_branch}" ]; then
    push_remote_consider \
      "$(git -C "${push_remote_dir}" config --get "branch.${push_remote_branch}.pushRemote")"
    push_remote_consider \
      "$(git -C "${push_remote_dir}" config --get "branch.${push_remote_branch}.remote")"
  fi
  push_remote_consider "$(git -C "${push_remote_dir}" config --get remote.pushDefault)"
  # Git uses the remote named "origin" when no configuration names a remote.
  push_remote_consider 'origin'
  if [ -z "${push_remote_result}" ] \
    && [ "$(printf '%s\n' "${push_remote_remotes}" | grep -c '.')" -eq 1 ]; then
    # The clone has no remote named "origin", but it has exactly one other
    # remote, which is therefore the only remote the branch could be pushed to.
    push_remote_result="${push_remote_remotes}"
  fi
  printf '%s\n' "${push_remote_result}"
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
  git_batch_ssh_command="${GIT_SSH_COMMAND:-$(git -C "${git_batch_ssh_dir}" config --get core.sshCommand)}"
  git_batch_ssh_variant="${GIT_SSH_VARIANT:-$(git -C "${git_batch_ssh_dir}" config --get ssh.variant)}"

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

## Usage: conflict_abort_command DIRECTORY
## Prints the git command that abandons the operation that left conflicts in
## DIRECTORY:  `git rebase --abort` or `git merge --abort`.
##
## `git pull` merges or rebases, depending on `pull.rebase` and
## `branch.BRANCH.rebase`, and each state has its own way out:  advising
## `git merge --abort` during a rebase gives the user a command that fails with
## "There is no merge to abort (MERGE_HEAD missing)", which leaves the conflicts
## in place and says nothing about what would clear them.  A rebase records its
## state in the `rebase-merge` directory of the repository, or in
## `rebase-apply` when it applies patches; a merge leaves no such directory.
conflict_abort_command() {
  if ! conflict_abort_command_gitdir="$(git -C "$1" rev-parse --absolute-git-dir 2> /dev/null)"; then
    conflict_abort_command_gitdir=''
  fi
  if [ -n "${conflict_abort_command_gitdir}" ] \
    && { [ -d "${conflict_abort_command_gitdir}/rebase-merge" ] \
      || [ -d "${conflict_abort_command_gitdir}/rebase-apply" ]; }; then
    echo 'git rebase --abort'
  else
    echo 'git merge --abort'
  fi
}
