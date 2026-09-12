# manage-git-branches

This package provides scripts to support managing multiple branches of a
git repository.

The scripts support a work style in which you have a separate working copy
(a.k.a. "clone") for each branch that you work on.  You never switch
branches within a working copy.  I find that this reduces branch confusion.
This work style replaces mechanisms such as `git stash`.

The key principles of this work style are:

1. Do not run git commands in the main branch, except `git pull`.  (Or,
   use [`mvc pull`](https://github.com/plume-lib/multi-version-control).)
2. Do not change branches in any working copy.
   That is, never run `git checkout`, and never run `git stash`.
3. To create a new branch, run the command `gnb` or `git-new-branch`.  It
   creates a new directory holding a new branch that starts as a copy of
   the branch from which you ran `gnb`.
4. To check out an existing branch, run `gcb` or `git-checkout-branch`.
   It creates a new directory and checks out the branch there.

## Commands

The commands are:

* [`git-checkout-branch`](git-checkout-branch) `BRANCHNAME`:
  Checks out the given branch of the repository in a new working copy
  directory.  Run this command from within a working copy; the new directory
  is a sibling of the working copy.  Below is a definition for an alias
  `gcb`.
* [`git-new-branch`](git-new-branch) `BRANCHNAME`:
  Creates and checks out the given branch of the repository in a new working
  copy directory.  Run this command from within a working copy; the new
  directory is a sibling of the working copy.  This command does not push the
  new branch.
  Below is a definition for an alias `gnb`.
* [`git-push-to`](git-push-to) `[--nocompile] FROM_DIR TO_DIR ...`:
  Pulls from FROM_DIR into TO_DIR, compiles TO_DIR, then pushes TO_DIR to
  its remote if compilation succeeds.
  Each directory must be the top level of a working copy (that is, of a git
  clone) and must have an upstream branch.
  You may also pass a list of directories: each is pushed into the subsequent one.
* [`git-pull-from`](git-pull-from) `[--nocompile] OTHER-REPO-DIR`:
  Pulls from OTHER-REPO-DIR into the current directory, compiles the current
  directory, then pushes the current directory to its remote if compilation
  succeeds.
  OTHER-REPO-DIR and the current directory must both be the top level of a
  working copy (that is, a git clone) and must each have an upstream branch.
* [`is-deleted-branch`](is-deleted-branch) `DIRECTORY`:
  Tests whether the given directory is the top level of a deleted branch.
* [`git-orphaned-branches`](git-orphaned-branches) `[--print0] [--remove]`:
  Lists directories named `*-branch-*`, below the current directory, that are
  working copies for branches that were deleted in the remote repository.
  With `--remove`, removes each of them instead of printing them.
  Typical usage is `git-orphaned-branches --remove` or `rmgob` (see
  alias below).
* [`git-remove-branch-directory`](git-remove-branch-directory)
  `[--force] [--force-uncommitted] [--force-unpushed] DIRECTORY...`:
  Removes a branch directory, unless the removal would lose work:  it refuses
  a directory that holds uncommitted changes to tracked files, or commits
  that no remote-tracking ref holds.
* [`compile-project`](compile-project) `[--clean] [DIRECTORY]`:
  Runs a Gradle, Maven, or Make command to compile the project that contains
  the given directory, which defaults to the current directory.
  The command-line arguments for the compilation can be customized, using the
  environment variables described below.
* [`relative-path`](relative-path) `BASE TARGET`:
  Prints the pathname of TARGET, relative to BASE.  This is a portable
  replacement for GNU `realpath --relative-to=BASE TARGET`.

More documentation of each script appears at the top of the script.
Click the command names above to see that documentation.

## Environment variables

These environment variables customize the behavior of the commands.  Each one
takes effect when it is set to a non-empty value.

* `GRADLE_ASSEMBLE_FLAGS`: `compile-project` passes this to `gradlew assemble`
  or `gradle assemble`.
* `MVN_COMPILE_FLAGS`: `compile-project` passes this to `mvnw compile` or
  `mvn compile`.
* `MAKE_FLAGS`: `compile-project` passes this to `make`.
* `ERR_IF_NO_BUILDFILE`: `compile-project` fails if it finds no buildfile.
  Otherwise, `compile-project` succeeds when it finds no buildfile.
* `MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT`: `git-push-to` and
  `git-pull-from` skip the compilation step, and push whenever the merge
  succeeds.
* `DEBUG`: `git-orphaned-branches` prints a message about each directory that
  it examines.
* `GIT_SSH_COMMAND` and `GIT_SSH`: `is-deleted-branch`,
  `git-orphaned-branches`, `git-new-branch`, `git-checkout-branch`, and
  `git-push-to` use these standard Git variables to select the SSH command
  when they query a remote repository.
* `GIT_SSH_VARIANT`: `is-deleted-branch`, `git-orphaned-branches`,
  `git-new-branch`, `git-checkout-branch`, and `git-push-to` use this standard
  Git variable to determine whether the selected SSH command accepts OpenSSH
  options.

## Installation

Clone this repository:

```sh
git clone https://github.com/mernst/manage-git-branches.git
```

For convenience, add the following commands to your shell startup file,
such as `~/.profile`.

```sh
export PATH="/path/to/manage-git-branches:${PATH}"
alias gcb=git-checkout-branch
alias gnb=git-new-branch
alias rmgob='git-orphaned-branches --remove'
```

## Testing

To run the tests, run `tests/run-tests.sh`.  Each test creates its
repositories under a temporary directory and removes them afterward.

## One branch per directory

If you use `git-checkout-branch` and `git-new-branch`, then you will never
switch the branch for a working copy.  That is, you will never run `git checkout
BRANCHNAME`.  Instead, you will have a separate working directory for each
branch that you work on.  The directory's name will be
`REPONAME-branch-BRANCHNAME`.

This convention enables you to easily work on multiple branches at a time:

* No confusion about which fork or branch you are on:  this information is
  evident in the directory name.
* No need to switch branches with `git checkout`.  Just use file system
  operations such as `cd` and `ln`.
* No need to commit or stash changes before switching branches, which would
  otherwise be necessary to avoid accidentally mixing work between
  branches.  Never run `git stash` again!
* Faster builds, because each branch has its own version of built executables,
  avoiding the need for your build system to recompile everything when
  switching branches.
* Easier non-git operations:  comparing branches using your favorite tool,
  searching multiple branches, reconciling branches, copying text between
  them, etc.
* A disadvantage is greater disk usage than if you have a single clone and
  you switch branches within that clone.  Usually, disk space is plentiful
  and the foregoing advantages are worthwhile.  If you have very large
  repositories and limited disk space, however, this approach may be
  undesirable.

If other programs need a specific name for your repository, then you may wish to
make the directory `REPONAME` be a symbolic link to whichever branch you are
working on at the time, such as `REPONAME-branch-main` when you want to use the
main branch.

## Programs for managing multiple git clones

The
[multi-version-control](https://github.com/plume-lib/multi-version-control)
program manages multiple clones, much as the scripts in this repository
manage multiple branches.

## License

This package is distributed under the [MIT License](LICENSE).
