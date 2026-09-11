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
## in the superproject, which is one of the three states that the commands
## that copy a working copy must refuse.  `protocol.file.allow` is needed
## because git 2.38.1 and later refuse the "file" transport for a submodule
## by default.
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
## main working tree's repository, which is another of the states that the
## commands that copy a working copy must refuse.
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

## Usage: make_separate_git_dir_worktree DIRECTORY
## Creates, in DIRECTORY, a repository whose working tree is
## `separate-branch-main` and whose git directory is `separate-git-dir`
## beside it, made by hand with `git init --separate-git-dir`.  The
## repository has a branch "extra" that no directory has checked out, so that
## a test can name a branch that no directory is using yet.
##
## Such a working tree is a *main* working tree, but its `.git` is a file that
## names the git directory beside it, which is the third state that the
## commands that copy a working copy must refuse.  It is not a linked
## worktree, and it has no other working tree to send the user to:  git takes
## the main working tree to be the parent of the git directory, so
## `git worktree list` names the git directory itself here.
make_separate_git_dir_worktree() {
  (
    cd -- "$1" || exit 1
    git init -q -b main --separate-git-dir separate-git-dir \
      separate-branch-main || exit 1
    cd separate-branch-main || exit 1
    echo 'content' > file.txt
    git add file.txt
    git commit -q -m 'Initial commit'
    git branch extra
  )
}

## Usage: make_symlinked_git_dir_worktree DIRECTORY
## Creates, in DIRECTORY, a repository whose working tree is
## `symlink-branch-main` and whose git directory is `symlink-git-dir` beside
## it, named by a *symbolic link* `symlink-branch-main/.git` rather than by a
## `.git` file.  The repository has a branch "extra" that no directory has
## checked out, so that a test can name a branch that no directory is using
## yet.
##
## Such a `.git` answers `test -d`, because `-d` follows symbolic links, but
## `cp -Rp` copies the link rather than what it names, and the relative target
## `../symlink-git-dir` resolves to the same git directory from the sibling
## copy.  So this is a fourth state that the commands that copy a working copy
## must refuse.
make_symlinked_git_dir_worktree() {
  (
    cd -- "$1" || exit 1
    git init -q -b main symlink-branch-main || exit 1
    cd symlink-branch-main || exit 1
    echo 'content' > file.txt
    git add file.txt
    git commit -q -m 'Initial commit'
    git branch extra
    mv .git ../symlink-git-dir || exit 1
    ln -s ../symlink-git-dir .git || exit 1
  )
}

## Usage: make_env_git_dir_worktree DIRECTORY
## Creates, in DIRECTORY, a working tree `env-branch-main` that holds no
## `.git` at all and a git directory `env-git-dir` beside it.  A test reaches
## the working tree by setting GIT_DIR to the git directory and GIT_WORK_TREE
## to the working tree, which is how git finds a repository that no `.git`
## names.  The repository has a branch "extra" that no directory has checked
## out, so that a test can name a branch that no directory is using yet.
##
## A copy of such a working tree holds no repository, and the environment
## still names the original's git directory, so the checkout moves the
## original's HEAD.  It is the fifth state that the commands that copy a
## working copy must refuse.
make_env_git_dir_worktree() {
  (
    cd -- "$1" || exit 1
    git init -q -b main env-branch-main || exit 1
    cd env-branch-main || exit 1
    echo 'content' > file.txt
    git add file.txt
    git commit -q -m 'Initial commit'
    git branch extra
    mv .git ../env-git-dir || exit 1
  )
}

## Usage: working_tree_state DIRECTORY [GIT_DIRECTORY]
## Prints the state of the working tree DIRECTORY that a `git checkout` in it
## would change:  the ref that HEAD names, the commit that HEAD resolves to,
## and the contents of the index.  A test compares this before and after a
## command that must leave DIRECTORY alone.  The ref is the assertion that
## catches a copy which shares DIRECTORY's git directory, because the
## `git checkout` that such a copy runs moves this HEAD.
##
## Git finds the repository from DIRECTORY itself, which is what every working
## tree but one permits.  A working tree that holds no `.git` at all is the
## exception:  a test that makes one names its repository as GIT_DIRECTORY
## here, as the environment names it for the command under test.
working_tree_state() {
  if [ -n "${2-}" ]; then
    set -- --git-dir="$2" --work-tree="$1"
  else
    set -- -C "$1"
  fi
  git "$@" symbolic-ref --quiet HEAD || echo '(detached HEAD)'
  git "$@" rev-parse HEAD
  git "$@" ls-files --stage
}

## Usage: make_counting_git DIRECTORY LOG
## Creates, in DIRECTORY, a `git` command that appends its arguments to LOG,
## one invocation per line, and then runs the real git.  A test that puts
## DIRECTORY first on PATH can then count the git commands that the command
## under test ran, and in particular the questions it asked a remote.
##
## Counting git commands is cheaper than a fake SSH, and it counts the
## queries that these tests actually make, whose remotes are local pathnames
## that never reach SSH.
##
## Exports GIT_COMMAND_LOG, which the fake `git` appends to, and empties it,
## so that it holds only the commands that the test is about to run.
make_counting_git() {
  mkdir -p "$1" || return 1
  make_counting_git_real="$(command -v git)"
  # If DIRECTORY is already on PATH, the fake `git` would exec itself forever.
  if [ "${make_counting_git_real}" = "$1/git" ]; then
    echo "make_counting_git: $1 is already on PATH" >&2
    return 1
  fi
  GIT_COMMAND_LOG="$2"
  export GIT_COMMAND_LOG
  cat > "$1/git" << COUNTING_GIT_END
#!/bin/sh
printf '%s\n' "\$*" >> "\${GIT_COMMAND_LOG}"
exec "${make_counting_git_real}" "\$@"
COUNTING_GIT_END
  chmod +x "$1/git" || return 1
  : > "${GIT_COMMAND_LOG}"
}

## Usage: count_remote_queries
## Prints the number of questions that the commands in ${GIT_COMMAND_LOG}
## asked a remote:  the `git ls-remote` invocations, except the
## `ls-remote --get-url` ones, which print a URL from the local configuration
## and ask nothing.
count_remote_queries() {
  count_remote_queries_all="$(grep -c 'ls-remote' "${GIT_COMMAND_LOG}" || true)"
  count_remote_queries_local="$(grep -c 'ls-remote --get-url' \
    "${GIT_COMMAND_LOG}" || true)"
  echo "$((count_remote_queries_all - count_remote_queries_local))"
}
