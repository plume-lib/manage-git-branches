# shellcheck shell=sh

# Functions that this package's tests share.  A test sources this file, rather
# than running it as a command, so it has no shebang line and is not
# executable.

## Usage: use_fake_ssh CLONE ARGUMENTS_FILE
## Makes the remote "origin" of the clone CLONE reachable only over SSH, and
## makes that SSH a fake one that appends its arguments to ARGUMENTS_FILE, one
## invocation per line, and then exits with a failure status.  The test can
## then check which options the query passed to SSH, such as the one that
## disables SSH's own prompts.  The fake `ssh` command is created beside
## ARGUMENTS_FILE, which is truncated, so that it holds only the arguments of
## the invocations that the test is about to make.
use_fake_ssh() {
  use_fake_ssh_clone="$1"
  SSH_ARGUMENTS_FILE="$2"
  export SSH_ARGUMENTS_FILE
  use_fake_ssh_command="$(dirname -- "${SSH_ARGUMENTS_FILE}")/fake-ssh"
  cat > "${use_fake_ssh_command}" << 'FAKE_SSH_END'
#!/bin/sh
printf '%s\n' "$*" >> "${SSH_ARGUMENTS_FILE}"
exit 1
FAKE_SSH_END
  chmod +x "${use_fake_ssh_command}"
  git -C "${use_fake_ssh_clone}" config core.sshCommand "${use_fake_ssh_command}"
  git -C "${use_fake_ssh_clone}" config ssh.variant ssh
  git -C "${use_fake_ssh_clone}" remote set-url origin 'ssh://example.invalid/no-such-repo.git'
  : > "${SSH_ARGUMENTS_FILE}"
}

## Usage: make_submodule_superproject DIRECTORY
## Creates, in DIRECTORY, a superproject `super-branch-main` whose submodule
## is checked out at `super-branch-main/sub`.  The submodule's repository has
## a branch "extra" in addition to "main", so that a test can name a branch
## that no directory is using yet.
##
## A submodule's working tree has a `.git` *file* that names a git directory
## in the superproject, which is one of the two states that the commands that
## copy a working copy must refuse.  `protocol.file.allow` is needed because
## git 2.38.1 and later refuse the "file" transport for a submodule by
## default.
make_submodule_superproject() {
  (
    cd -- "$1" || exit 1
    git init -q -b main submodule-origin || exit 1
    cd submodule-origin || exit 1
    echo 'submodule content' > sub.txt
    git add sub.txt
    git commit -q -m 'Initial commit of the submodule'
    git branch extra
    cd .. || exit 1
    git init -q -b main super-branch-main || exit 1
    cd super-branch-main || exit 1
    echo 'superproject content' > super.txt
    git add super.txt
    git commit -q -m 'Initial commit of the superproject'
    git -c protocol.file.allow=always submodule add -q ../submodule-origin sub
    git commit -q -m 'Add the submodule'
  )
}

## Usage: make_linked_worktree DIRECTORY
## Creates, in DIRECTORY, a repository `worktree-branch-main` and a linked
## worktree of it at `worktree-branch-linked`, made by hand with
## `git worktree add`.  The repository has a branch "extra" that no directory
## has checked out, so that a test can name a branch that no directory is
## using yet.
##
## A linked worktree's `.git` is a file that names a git directory inside the
## main working tree's repository, which is the other state that the commands
## that copy a working copy must refuse.
make_linked_worktree() {
  (
    cd -- "$1" || exit 1
    git init -q -b main worktree-branch-main || exit 1
    cd worktree-branch-main || exit 1
    echo 'content' > file.txt
    git add file.txt
    git commit -q -m 'Initial commit'
    git branch extra
    git worktree add -q -b linked ../worktree-branch-linked
  )
}

## Usage: working_tree_state DIRECTORY
## Prints the state of the working tree DIRECTORY that a `git checkout` in it
## would change:  the ref that HEAD names, the commit that HEAD resolves to,
## and the contents of the index.  A test compares this before and after a
## command that must leave DIRECTORY alone.  The ref is the assertion that
## catches a copy which shares DIRECTORY's git directory, because the
## `git checkout` that such a copy runs moves this HEAD.
working_tree_state() {
  git -C "$1" symbolic-ref --quiet HEAD || echo '(detached HEAD)'
  git -C "$1" rev-parse HEAD
  git -C "$1" ls-files --stage
}
