This package provides scripts to support managing multiple branches of a git repository.

The commands are:
 * [`git-checkout-branch`](git-checkout-branch)` BRANCHNAME`:
   Checks out the given branch of the repository in a new working copy directory.
   Run this command from within a working copy; the new directory is a sibling of it.
 * [`git-new-branch`](git-new-branch)` BRANCHNME`:
   Creates and checks out the given branch of the repository in a new working copy directory.
   Run this command from within a working copy; the new directory is a sibling of it.
 * [`git-push-to`](git-push-to)` FROMDIR TODIR ...`:
   Pull from FROMDIR into TODIR, compile it, then push TODIR to its remote if
   compilation succeeded.
   The two directories should be working copies (that is, git clones).
   You may also pass a list of directories: each is pushed into the subsequent one.
 * [`git-pull-from`](git-pull-from)` FROMDIR`:
   Pull from FROMDIR into the current directory, compile it, then push it to its
   remote if compilation succeeded.
   The two directories should be working copies (that is, git clones).
 * [`git-orphaned-branches`](git-orphaned-branches):
   Lists directories named `*-branch-*` that are a working copy for a branch that
   was deleted in the remote.  Typical usage is `rm -rf $(git-orphaned-branches)`.
 * [`compile-project`](compile-project):
   Runs a Gradle or Maven command to compile the project that contains the current directory.
   The command-line arguments for the compilation can be customized.

More documentation of each script appears at the top of the script.
Click the command names above to see that documentation.


## Installation

Clone the repository:
```
git clone https://github.com/mernst/manage-git-branches.git
```

Add the following commands to your shell startup file, such as `~/.profile`.

```
export PATH=".../path/to/manage-git-branches:${PATH}"
alias gcb=git-checkout-branch
alias gnb=git-new-branch
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
 * No need to commit changes before switching branches, which is necessary to
   avoid accidentally mixing work between branches.
 * Faster builds, because each branch has its own version of built executables,
   avoiding the need for your build system to recompile everything when
   switching branches.
 * Easier non-git operations:  comparing branches using your favorite tool,
   searching multiple branches, reconciling branches, copying text between them,
   etc.
 * Greater disk usage than if you have a single clone and you switch branches
   within that clone.  Usually, disk space is plentiful and the foregoing
   advantages are worthwhile.  If you have very large repositories and limited
   disk space, however, this approach may be undesirable.

If other programs need a specific name for your repository, then you may wish to
make the directory `REPONAME` be a symbolic link to whichever branch you are
working on at the time, such as `REPONAME-branch-main` when you want to use the
main branch.


## Other programs for managing multiple Git clones

See [multi-version-control](https://github.com/plume-lib/multi-version-control).
