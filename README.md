# manage-git-branches

This package provides scripts to support managing multiple branches of a
git repository.

The scripts support a work style in which you have a separate working copy
(a.k.a. "clone") for each branch that you work on.  You never switch
branches within a working copy.  I find that this reduces branch confusion.
It replaces mechanisms such as `git stash`.

Its key principles are:

1. Do not run git commands in the master branch, except `git pull`.  (Or,
   use [`mvc pull`](https://github.com/mernst/multi-version-control).)
2. Do not change branches in any working copy.
   That is, never run `git checkout`.
3. To create a new branch, run command `gnb` or `git-new-branch`.  It
   creates a new directory holding a new branch that starts as a copy of
   the branch from which you ran `gnb`.
4. To clone/checkout an existing branch, run `gcb`.  It creates a new
   directory and checks out the branch there.

## Commands

The commands are:

* [`git-checkout-branch`](git-checkout-branch)`BRANCHNAME`:
  Checks out the given branch of the repository in a new working copy
  directory.  Run this command from within a working copy; the new
  directory is a sibling of it.  Below is a definition for an alias `gnb`.
* [`git-new-branch`](git-new-branch)`BRANCHNME`:
  Creates and checks out the given branch of the repository in a new
  working copy directory.  Run this command from within a working copy; the
  new directory is a sibling of it.  Below is a definition for an alias
  `gnb`.
* [`git-push-to`](git-push-to)`FROMDIR TODIR ...`:
  Pull from FROMDIR into TODIR, compile it, then push TODIR to its remote
  if compilation succeeded.
  The two directories should be working copies (that is, git clones).
  You may also pass a list of directories: each is pushed into the subsequent one.
* [`git-pull-from`](git-pull-from)`FROMDIR`:
  Pull from FROMDIR into the current directory, compile it, then push it to its
  remote if compilation succeeded.
  The two directories should be working copies (that is, git clones).
* [`git-orphaned-branches`](git-orphaned-branches):
  Lists directories named `*-branch-*` that are a working copy for a branch
  that was deleted in the remote.  Typical usage is `rm -rf
  $(git-orphaned-branches)` or `rmgob` (see alias below).
* [`compile-project`](compile-project):
  Runs a Gradle or Maven command to compile the project that contains the
  current directory.
  The command-line arguments for the compilation can be customized.

More documentation of each script appears at the top of the script.
Click the command names above to see that documentation.

## Installation

Clone this repository:

```sh
git clone https://github.com/mernst/manage-git-branches.git
```

For convenience, add the following commands to your shell startup file, such as `~/.profile`.

```sh
export PATH="/path/to/manage-git-branches:${PATH}"
alias gcb=git-checkout-branch
alias gnb=git-new-branch
alias rmgob='rm -rf $(git-orphaned-branches)'
```

## One branch per directory

If you use `git-checkout-branch` and `git-new-branch`, then you will never
switch the branch for a working copy.  That is, you will never run `git checkout
BRANCHNAME`.  Instead, you will have a separate working directory for each
branch that you work on.  The directory's name will be
`REPONAME-branch-BRANCHNAME`.

This convention enables you to easily work on multiple branches at a time:

* No confusion about which fork or branch you are on:  this information is
  evident in the directory name.
* No need to switch branches with `git checkout`.  (Just use file system
  operations such as `cd` and `ln`.)
* No need to commit or stash changes before switching branches, which would
  otherwise be necessary to avoid accidentally mixing work between
  branches.
* Faster builds, because each branch has its own version of built executables,
  avoiding the need for your build system to recompile everything when
  switching branches.
* Easier non-git operations:  comparing branches using your favorite tool,
  searching multiple branches, reconciling branches, copying text between
  them, etc.
* Greater disk usage than if you have a single clone and you switch
  branches within that clone.  Usually, disk space is plentiful and the
  foregoing advantages are worthwhile.  If you have very large repositories
  and limited disk space, however, this approach may be undesirable.

If other programs need a specific name for your repository, then you may wish to
make the directory `REPONAME` be a symbolic link to whichever branch you are
working on at the time, such as `REPONAME-branch-main` when you want to use the
main branch.

## Programs for managing multiple Git clones

The
[multi-version-control](https://github.com/plume-lib/multi-version-control)
program manages multiple clones, much as this repository manages multiple
branches.
