# manage-git-branches

This package provides scripts to support managing multiple branches of a
git repository.

The scripts support a work style in which you have a separate working tree
for each branch that you work on.  You never switch branches within a
working tree.  I find that this reduces branch confusion.
This work style replaces mechanisms such as `git stash`.

The key principles of this work style are:

1. Do not run git commands in the main branch, except `git pull`.  (Or,
   use [`mvc pull`](https://github.com/plume-lib/multi-version-control).)
2. Do not change branches in any working tree.
   That is, never run `git switch`, `git checkout`, or `git stash`.
3. To create a new branch, run the command `gnb` or `git-new-branch`.  It
   creates a new directory holding a new branch that starts as a copy of
   the branch from which you ran `gnb`.
4. To check out an existing branch, run `gcb` or `git-checkout-branch`.
   It creates a new directory and checks out the branch there.

## Commands

The commands are:

* [`git-checkout-branch`](git-checkout-branch) `[--no-pull] BRANCHNAME`:
  Checks out the given branch of the repository in a new working tree
  directory.  Run this command from within a working tree; the new directory
  is a sibling of the working tree.

  Instead of BRANCHNAME, the argument can be a slug of the form
  `ORG:BRANCHNAME`, such as `git-checkout-branch mernst:feature`, which is
  how GitHub shows a pull request's branch.  It does what
  `git-checkout-branch BRANCHNAME` does in the sibling clone
  `PROJECT-fork-ORG`.  ORG `-` stands for the clone `PROJECT` itself, and so
  does an ORG that owns the project's upstream repository, as `typetools`
  owns `typetools/checker-framework`, if there is no clone
  `PROJECT-fork-ORG`.  Otherwise, if there is no clone `PROJECT-fork-ORG`,
  the command first makes one, if ORG's fork has the branch.  The new
  clone's remote `origin` is ORG's fork, and its remote `upstream` is the
  upstream repository.

  Below is a definition for an alias `gcb`.
* [`git-new-branch`](git-new-branch)
  `[--clean | --copy] [--verbose] [--allow-upstream] BRANCHNAME`:
  Creates the given branch of the repository in a new directory that is a
  sibling of the current working tree.  This command does not push the
  new branch.

  The new branch starts at the current commit, after a `git pull`.  But on
  a fork's default branch that lags behind the upstream repository's, it
  starts at the upstream repository's default branch, to which the current
  branch is fast-forwarded.  In a clone of a fork that has no `upstream`
  remote, the upstream repository is the fork's parent, as for
  `git-diff-upstream`.

  By default, the new directory is a worktree (see [below](#worktrees)) whose
  contents are the same as the current directory's, including uncommitted
  changes and untracked files; `--clean` and
  `--copy` make other kinds of directory.

  Instead of BRANCHNAME, the argument can be a slug of the form
  `ORG:BRANCHNAME`, such as `git-new-branch mernst:feature`.  It does what
  `git-new-branch --clean BRANCHNAME` does in the sibling clone
  `PROJECT-fork-ORG`.  ORG `-` stands for the clone `PROJECT` itself, and so
  does an ORG that owns the project's upstream repository, if there is no
  clone `PROJECT-fork-ORG`.  Otherwise, if there is no clone
  `PROJECT-fork-ORG`, the command first makes one, as `git-checkout-branch`
  does, if ORG's fork exists.

  In a clone of an upstream repository whose fork is in a sibling directory
  `PROJECT-fork-ORG`, the command refuses, because a branch for a pull
  request belongs in the fork; `--allow-upstream` overrides the refusal.
  If git's configuration sets `github.user`, only a fork whose ORG is that
  user counts.

  `git-new-branch --help` (or `-h`) prints a synopsis, which describes the
  modes.  The comments in [`git-new-branch`](git-new-branch) give more details.

  Below is a definition for an alias `gnb`.
* [`git-push-to`](git-push-to)
  `[--nocompile] [--no-pull-first] [--rebase | --squash] [--llm | --no-llm]
  [--claude | --codex] [--summary FILE] FROM_DIR TO_DIR ...`:

  Pulls from FROM_DIR into TO_DIR, compiles TO_DIR, then pushes TO_DIR to
  its remote if compilation succeeds.  Each directory must be the top level
  of a working tree and must have an upstream branch.  You can also pass a
  list of directories: each is pushed into the subsequent one.

  Instead of directories, you can pass slugs of the form `ORG:BRANCH`, such
  as `git-push-to upstream:main myname:feature`.  Each slug names the
  directory `PROJECT-fork-ORG-branch-BRANCH` in the current directory.  As
  for `git-checkout-branch`, ORG `-` stands for the clone `PROJECT` itself,
  and so does an ORG that owns the project's upstream repository, if there
  is no clone `PROJECT-fork-ORG`.  Unlike `git-checkout-branch`, this
  command never makes a clone.  A slug can
  also be just `BRANCH`, as in `git-push-to main feature`.  It matches
  every ORG.  It also matches `PROJECT-branch-BRANCH`, as created by
  `git-new-branch` from a clone `PROJECT`, and it matches the clone
  `PROJECT` itself if that has BRANCH checked out and no
  `PROJECT-branch-BRANCH` exists; those directories form one more chain per
  PROJECT.

  With `--rebase` or `--squash`, it then does what `git-rebase-to` does.

  With `--no-pull-first`, it does not pull the first directory, so the chain
  merges the commit that the first directory already has.  A run of several
  chains that start with the same directory, such as a working copy of the
  upstream default branch, pulls it only for the first chain, so that every
  chain merges the same commit of it, even if its remote changes during the
  run.  Otherwise, a branch could get a newer upstream commit than a branch
  that it builds on, and merging the latter into the former would later be a
  criss-cross merge, which has several merge bases.  `git-push-to` itself
  does so for the chains of slugs, and `pr-status` and `resolve-conflicts`
  pass `--no-pull-first` to each such chain after the first that pulled the
  directory.

  Suppose that a branch merged an earlier version of a pull request, whose
  branch then changed again before the pull request was squash-merged.
  Then the squash commit and the branch contain different versions of the
  same changes, and merging the squash commit into the branch conflicts
  wherever they differ, even in binary files.  When a merge would have
  conflicts, `git-push-to` first merges the pull request's final version,
  from the upstream repository's ref `refs/pull/N/head`, and then the squash
  commit, if that leaves fewer conflicts.

  When a merge or a pull has conflicts, it uses the resolutions that
  `git rerere` recorded, and it asks an AI agent, Claude (or, with
  `--codex`, Codex), to resolve the conflicts that remain.  The agent
  examines every change of both sides of the merge and combines them; it
  can edit any part of any file, and it can delete files but not create
  them.  The script checks every resolution and lists, for your review, the
  changes that the agent made outside the conflict regions, and each
  resolution by the agent that is one side's version of the file, unless
  that side already contains the other side's changes to the file, as when
  the other side squash-merged a pull request whose branch the first side
  merged.  The agent's instructions start with the file
  `merge-conflict-instructions.md`, which also suits a merge that you
  resolve yourself.  If the build fails, and TO_DIR's branch has a merge
  that neither its remote branches nor those of FROM_DIR's branch contain,
  such as the one that it just made, it asks the agent to fix the build, up
  to 3 times, and commits the fix.  `--no-llm` turns off the agent;
  `--llm`, `--claude` (the default), and `--codex` turn it on.

  If the agent fails without changing anything, as when its service is
  briefly unavailable, `git-push-to` runs it again, up to 2 more times (see
  `MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE` and `MANAGE_GIT_BRANCHES_LLM_TIMEOUT`).

  If the agent fails, or if `git-push-to` rejects its work, `git-push-to`
  prints a command that continues
  the agent's session interactively, unless the agent failed each time
  without changing anything and was then not ready to run.  In that case,
  the session did nothing worth continuing, and running `git-push-to` again,
  once the agent can run, asks the agent to do its task again.

  With `--summary FILE`, it appends to FILE each change by the agent to
  review, each merge that it left in progress, each agent session that can
  be continued, and, if a push or rebase fails, the step that failed.

* [`git-rebase-to`](git-rebase-to)
  `[--nocompile] [--no-pull-first] [--squash] [--llm | --no-llm]
  [--claude | --codex] [--summary FILE] FROM_DIR TO_DIR ...`:
  Runs `git-push-to` on the arguments, then rebases each branch onto the
  previous branch, to eliminate merge commits, and force-pushes each
  branch.  This is useful for maintaining a stack of GitHub pull requests,
  each of whose base is the previous one.  With `--squash`, each branch
  becomes a single commit on top of the previous branch.
  The arguments may be slugs, as for `git-push-to`.
* [`git-pull-from`](git-pull-from)
  `[--nocompile] [--llm | --no-llm] [--claude | --codex] OTHER-REPO-DIR`:
  Pulls from OTHER-REPO-DIR into the current directory, just as
  `git-push-to` does.
* [`git-pull-upstream`](git-pull-upstream)
  `[--nocompile] [--allow-dependent] [--llm | --no-llm] [--claude | --codex]`:
  Merges the default branch of the remote `upstream` (or `origin`, if there
  is no `upstream`, or the only remote, if there is neither) into the current
  branch, compiles, then pushes the current branch if compilation succeeds.
  It chooses the upstream repository as `git-diff-upstream` does, so in a
  GitHub fork that a user owns, it can merge from the fork's parent.

  It does not push a branch whose push destination is the default branch of
  the upstream repository, nor, in a fork, any branch of the upstream
  repository.

  It does not merge into a branch whose open pull request builds on another
  pull request:  one whose base branch is the branch of another open pull
  request, or whose description says "Land after #N" for an open pull
  request N.  Such a branch receives the default branch through the branch
  that it builds on, and receiving it directly as well would make a later
  merge of that branch a criss-cross merge, which has several merge bases.
  Update such a branch with `git-push-to`, as the chains that `pr-status`
  prints do, or pass `--allow-dependent` to merge anyway.  It asks GitHub
  with `gh`, and it skips this check if `gh` cannot be used.  It reads the
  "Land after" lines with `pr-status --print-land-after`, which needs
  Python 3.10 or later; if `python3` is older, it runs `pr-status` with
  `uv`, if `uv` is installed (see [Python version](#python-version)), and
  otherwise it ignores those lines.

  Unlike `git-pull-from`, it needs no working tree for the default branch.
  It handles conflicts and a failed build as `git-push-to` does.
* [`pr-status`](pr-status)
  `[--check | --print-document | --print-config | --print-land-after ORG/REPO |`
  `--print-conflicting-push-chains | --print-missing-branches] [-C DIR]`
  `[--highlight PR|bottleneck...]`:
  Computes the dependencies among the open pull requests, updates the "Land
  after" and "Land before" lines of their descriptions, and regenerates
  `pr-status.md`,
  which lists the dependencies and the `git-push-to` commands that update
  each dependency chain.  In a Markdown renderer that keeps HTML event
  handlers, each block of commands has a button (📋) that copies the
  commands.

  Run it in a directory that holds the working copy directories, or pass
  that directory with `-C`.

  It prints what changed since its previous run.
  With `--check`, it writes no document.  With `--print-document`, it
  prints the file name of the document that it regenerates and does nothing
  else.  With `--print-config`, it prints its config, with the defaults
  filled in, and does nothing else.
  With `--print-land-after ORG/REPO`, it reads the description of a pull
  request of `ORG/REPO` on standard input, prints the number of the pull
  request that each of its "Land after" lines names in `ORG/REPO`, one per
  line, and does nothing else.
  With `--print-missing-branches`, it prints the branches that resolving the
  conflicts needs, but that have no working copy (as of its previous run),
  and does nothing else:  one line per branch, holding a directory and the
  branch as `OWNER:BRANCH`, separated by a tab.  The directory is an entry of
  the directory that holds the working copy directories (`DIR`, with `-C`).
  In that directory, `git-checkout-branch OWNER:BRANCH` makes a working copy
  of the branch, as another entry of the directory that holds the working
  copy directories, after which `git-push-to` can merge it.
  `--highlight PR...` highlights, wherever the documents that it regenerates
  name it, each given PR (such as `REPO#100` or `ORG/REPO#100`) and every
  PR that must land for it to land.
* [`pr-merge-analysis`](pr-merge-analysis)
  `[--no-pairwise] [--default-branch BRANCH] [--prune] REPO_DIR OWNER/REPO [PR_NUMBER...]`:
  For the given open pull requests of the GitHub repository OWNER/REPO (by
  default, all of them), reports which ones conflict with the default
  branch, which ones contain every non-merge commit of another and the
  other's changes, and (unless `--no-pairwise`) which pairs conflict with
  each other.  It fetches the
  pull requests into `REPO_DIR`, a clone of the repository, and caches its
  results in the current directory.  When the run covers every open pull
  request (no PR number is given, or `--prune` says that the given ones are
  all of them), it removes the cached results for commits that are no longer
  the head of an open pull request, and it deletes from `REPO_DIR` the refs of
  the pull requests that are not open.  `--default-branch BRANCH` compares
  against BRANCH rather than the repository's default branch.
  `pr-status` runs it.
* [`resolve-conflicts`](resolve-conflicts)
  `[--nocompile] [--claude | --codex] [-C DIR]`:
  Runs `pr-status`, which regenerates the dependency document
  `pr-status.md`, then runs `git-push-to` on each chain of its section
  "Dependency chains with conflicts",
  with `--claude` (or `--codex`), which asks an AI agent for help, and with
  `--no-pull-first` for each chain whose first directory an earlier chain
  since `pr-status` ran pulled.
  It ends with a summary of the chains that failed or that have changes by
  the agent to review, each with what `git-push-to --summary` wrote for it,
  which names the step that failed.
* [`crreview-resolve-all`](crreview-resolve-all)
  `[--dry-run] [--agent claude|codex] [-C DIR]`:
  Runs
  [`crreview-resolve`](https://github.com/mernst/mdedots/blob/main/share/crreview-resolve),
  which addresses the unresolved CodeRabbit review comments on the current
  branch's pull request, in each working copy directory that holds an open
  pull request that you opened:  one whose head is the branch that
  `git push` in the directory pushes to.

  With `--dry-run`, it prints
  the directories and pull requests but runs nothing.  `--agent` is passed
  to `crreview-resolve`.  Run it in a directory that holds the working copy
  directories, or pass that directory with `-C`.
* [`fix-renovate-prs`](fix-renovate-prs) `[--dry-run] [-C DIR]`:
  For each open pull request that Renovate opened and whose CI fails, in a
  repository that a working copy directory is a clone of, runs
  `rerun-failed-ci` and then, unless that reran a transient failure, runs
  Claude Code (with every permission) in the directory of the pull
  request's branch, which it makes with `git-checkout-branch --no-pull` if no
  working copy directory has that branch.  Claude either commits a fix, which this
  command pushes to the pull request's branch, or explains why the CI
  cannot pass, which this command posts as a comment on the pull request.
  Claude does not upgrade the JDK that the project uses; if the only fix is
  to upgrade it, Claude explains that the CI cannot pass.
  A pull request whose CI is running or waits for a human to approve a
  check is skipped, as is one for which such a comment was posted at its
  current head commit.  The last thing that this
  command prints is a report, which a human should review.  It gives the
  URL and the directory of each pull request that this command acted on,
  and the URL of each pull request that it could not handle, with an
  explanation.  With
  `--dry-run`, it prints the failing pull requests and the directories but
  changes nothing.  Run it in a directory that holds the working copy
  directories, or pass that directory with `-C`.  This command needs `gh`,
  `claude`, and Python 3.9 or later.
* [`is-deleted-branch`](is-deleted-branch) `DIRECTORY`:
  Tests whether the given directory is the top level of a deleted branch.
  It is also true of a directory that holds nothing but leftovers, which a
  branch directory can leave behind when its working tree is gone:  Eclipse
  `.project` files, Python `.venv` directories, and `*.egg-info`
  directories.  A `.venv` or `*.egg-info` directory is a leftover only if
  it holds no version-control checkout, and a directory of leftovers counts
  only if no git working tree tracks a file in it.
* [`git-orphaned-branches`](git-orphaned-branches) `[--print0] [--remove]`:
  Lists directories named `*-branch-*`, below the current directory, that are
  working trees for branches that were deleted in the remote repository, or
  that hold nothing but leftovers, as for `is-deleted-branch`.
  With `--remove`, removes each of them instead of printing them.

  Typical usage is `git-orphaned-branches --remove` or `rmgob` (see
  alias below).

  A directory named `.cache` or `.claude`, such as `~/.cache` or a
  repository's `.claude`, is not examined, nor is anything below it.
  Neither is the `projects` directory of a Claude Code configuration
  directory that has some other name, such as the directory that
  `CLAUDE_CONFIG_DIR` names:  it holds a directory, named for a path such as
  `-home-me-repo-branch-feature`, for each directory that Claude Code has run
  in.
  Nor is a directory checked whose name matches `*-branch-*` only because it
  embeds an absolute path, with each `/` written as `-`, such as the Gradle
  test report `[-home-me-repo-branch-feature-tests-all]` in
  `/home/me/repo-branch-feature/build/reports/`, or
  `[-home-me-repo-branch-other-tests-all]` in a build directory copied from
  the sibling working tree `/home/me/repo-branch-other`; the directories
  below it are still examined.

  A directory whose branch still exists in the remote, but whose GitHub pull
  requests are all closed or merged, is neither listed nor removed; a warning
  about it is printed instead.
  If one of the pull requests was merged, the directory has no uncommitted
  changes to tracked files, and its HEAD is the commit that the remote branch
  names, the warning also gives the commands that delete the remote branch
  and then remove the directory.

  Likewise, a warning is printed about a directory named `*-branch-*` that
  is in no git working tree and either holds more than leftovers, such as
  one whose removal failed on files that another user owns, or holds no
  leftover at all, such as an empty directory; about one that is in a git
  working tree that tracks none of its files; and about one that is in a
  working tree that git cannot use, such as a linked worktree whose main
  working tree was moved.

* [`git-remove-branch-directory`](git-remove-branch-directory)
  `[--force] [--force-uncommitted] [--force-unpushed] [--repository DIR]
  DIRECTORY...`:
  Removes a branch directory (a directory that holds a branch's working
  tree, or one that holds nothing of value, such as a directory that
  `git-orphaned-branches` reports), unless the removal would lose work.

  If it cannot remove all files, as when a container running as root
  created files in the directory, it moves what remains to a new directory in
  `/tmp`, whose cleanup runs as root, provided that `/tmp` is on the same
  file system, or else to a new directory beneath `~/tmp/DELETEME`, under the
  same condition.

* [`git-outgoing`](git-outgoing)
  `[--only-branch BRANCH]... [--omitted | GIT-LOG-ARGS]`:
  Shows the commits on local branches that have not been pushed.
  Unlike `git log --branches --not --remotes`, it omits a branch whose
  changes are already in a remote's default branch, as after a squash-merge.
* [`git-diff-upstream`](git-diff-upstream) `[--no-fetch] [GIT-DIFF-ARGS]`:
  Fetches the remote `upstream` (or `origin`, if there is no `upstream`, or
  the only remote, if there is neither), then shows the differences between
  its default branch and the working tree, ignoring changes in the amount of
  whitespace and using the patience diff algorithm.
  If there is no `upstream`, it uses instead the repository that `gh` uses
  by default, if `gh repo set-default` has named one, or else, if the remote
  is a GitHub fork that a user (not an organization) owns, the fork's parent,
  without adding a remote.
  Like a GitHub pull request, it diffs from the merge base, so upstream
  changes that have not been merged into the current branch do not appear.
* [`cancel-blocked-ci`](cancel-blocked-ci) `[--dry-run]`:  Cancels certain
  CI builds: for blocked pull requests (ones that depend on another open
  pull request), and ones that are redundant because of a more recent build
  of the same branch.  Run it in a directory that holds the working copy
  directories.  Works for Azure Pipelines, CircleCI, and GitHub Actions.
  This command needs Python 3.11 or later, `gh`, and `pr_status.py`.
* [`rerun-failed-ci`](rerun-failed-ci)
  `[--dry-run] [--max-attempts N] [--exit-3-if-reran] [PR | BRANCH | URL]...`:
  For each transient failure of a CI job, reruns it.  Works on the given
  GitHub pull request (by default, the one for the current branch).  A URL
  names an Azure Pipelines, CircleCI, or GitHub Actions job or workflow.
  With `--exit-3-if-reran`, the exit status is 3 if it reran some job.
  `rerun-failed-ci --classify LOG-FILE...` prints the line of each log that
  shows a transient failure.  This command needs Python 3.9 or later and
  `gh`.
* [`normalize-log`](normalize-log) `[FILE]...`:
  Prints the file (by default, standard input) without formatting that
  affects a terminal:  terminal escape sequences, a leading byte order
  mark, a leading timestamp, and carriage returns.  It also deletes
  progress messages that a terminal would overwrite or erase:  the text
  before a carriage return that is not at the end of a line, and the text
  before an escape sequence that erases the whole line.
* [`compile-project`](compile-project) `[--clean] [DIRECTORY]`:
  Runs a Gradle, Maven, or Make command to compile the project that contains
  the given directory, which defaults to the current directory.
  The command-line arguments for the compilation can be customized, using the
  environment variables described below.
  It prints nothing unless the build fails or writes to standard error, or no
  buildfile is found and `ERR_IF_NO_BUILDFILE` is set, as if it were run under
  [`cronic`](https://github.com/plume-lib/plume-scripts#cronic).
  Then it prints, to standard error, the build's standard output and standard
  error together, in approximately the order in which the build wrote them.
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
* `MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT`: `git-push-to`,
  `git-pull-from`, `git-pull-upstream`, and `git-rebase-to` skip the
  compilation step, and push whenever the merge succeeds.
* `MANAGE_GIT_BRANCHES_LLM_TIMEOUT`: the number of seconds that `git-push-to`,
  `git-pull-from`, `git-pull-upstream`, and `git-rebase-to` let an AI agent
  run when it resolves merge conflicts or fixes a build.  The time covers the
  agent's attempts after it failed without changing anything, and the pauses
  before them (see `MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE`).  An agent that runs
  longer is stopped and is not run again; if it was resolving merge
  conflicts, the merge is left in progress.  The default is 1800
  (30 minutes); 0 means no limit.
* `MANAGE_GIT_BRANCHES_LLM_RETRY_PAUSE`: the number of seconds that
  `git-push-to`, `git-pull-from`, `git-pull-upstream`, and `git-rebase-to`
  wait before running an AI agent again after it failed without changing any
  file, as when its service was briefly unavailable.  The default is 60.
* `MANAGE_GIT_BRANCHES_RENOVATE_TIMEOUT`: the number of seconds that
  `fix-renovate-prs` lets Claude Code run on one pull request.  A session
  that runs longer is stopped, and nothing is pushed.  The default is 7200
  (2 hours); 0 means no limit.
* `PR_MERGE_ANALYSIS_CACHE`: the file in which `pr-merge-analysis` caches its
  results.  The default is `.pr-merge-analysis-cache.tsv` in the current
  directory.  Several repositories can share the cache file.
* `DEBUG`: `git-orphaned-branches` prints a message about each directory that
  it examines.
* `AZURE_DEVOPS_EXT_PAT`: the commands that use the Azure DevOps API use this
  Azure DevOps personal access token, which must have the
  "Build (Read & execute)" scope.  If it is not set, they use the account
  that `az login` logged in.
* `CIRCLECI_CLI_TOKEN`: the commands that use the CircleCI API use this
  CircleCI API token.  If it is not set, they use the `token` in
  `~/.circleci/cli.yml` or (for the snap package)
  `~/snap/circleci/current/.circleci/cli.yml`, which `circleci setup` writes.
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

### Python version

If your Python version is too old to run one of the scripts, you have two
options, both of which require
[uv](https://docs.astral.sh/uv/).

1. Install a newer Python.

   1. Run this command:

      ```sh
      uv python install 3.15 --default
      ```

   2. Ensure that `~/.local/bin` appears early on your `PATH` (before any
      other directory that contains a `python` or `python3` executable).

2. Run the command with a newer Python:

   ```sh
   uv run --no-project --python 3.15 pr-status
   ```

   You can define an alias, such as:

   ```sh
   alias pr-status='uv run --no-project --python 3.15 pr-status'
   ```

   `git-pull-upstream`, which runs `pr-status`, does this itself if `uv` is
   installed.

## Testing

To run the tests, run `tests/run-tests.sh`.  Each test creates its
repositories under a temporary directory and removes them afterward.

## One branch per directory

If you use `git-checkout-branch` and `git-new-branch`, then you will never
switch the branch for a working tree.  That is, you will never run `git checkout
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
  you switch branches within that clone.  The branch directories share one
  repository, but each has its own working tree and build output, which is
  usually most of a directory's size:  sharing the repository saves 10-30%
  of each branch directory.  (`git-new-branch --clean` saves more, because
  the new directory holds no build output.)  Usually, disk space is
  plentiful and the foregoing advantages are worthwhile.  If you have very
  large repositories and limited disk space, however, this approach may be
  undesirable.

If other programs need a specific name for your repository, then you may wish to
make the directory `REPONAME` be a symbolic link to whichever branch you are
working on at the time, such as `REPONAME-branch-main` when you want to use the
main branch.

## Worktrees

`git-new-branch` and `git-checkout-branch` make each branch directory a
linked worktree of the repository that you ran them in, made by
`git worktree add`.  There is one exception:  if that repository is a branch
directory's own clone, `REPONAME-branch-OTHER`, and a sibling `REPONAME` is a
clone that would push a new branch to the same repositories, the new worktree
belongs to `REPONAME` instead, so that `REPONAME-branch-OTHER` can still be
removed once OTHER is done.  A clone of your fork and a clone of its upstream
repository push to different repositories, so neither hosts the other's
worktrees.  (The commands fall back to the repository that you ran them in
when `REPONAME` cannot host the worktree without a difference, such as when
either repository is a sparse checkout.)  All the branch directories of one
repository share one object store, so the repository is
not copied.  This has some consequences:

* A branch directory's `.git` is a file, not a directory.  A tool that tests
  for a `.git` directory to recognize a working tree does not recognize a
  branch directory; such a tool should ask git, with
  `git rev-parse --show-toplevel`.
* The branch directories share their configuration, hooks, and branches:
  `git config` in one affects all of them.
* A branch that has submodules is an exception.  Git does not support a
  submodule in more than one worktree, so `git-new-branch` and
  `git-checkout-branch` make a full copy instead, which is an independent
  clone.  The copy includes `.git`, so it can be made only from a directory
  whose `.git` is a directory, such as a clone:  run in a linked worktree,
  whose `.git` is a file, the commands refuse, and say to run them in the
  main working tree instead.

Do not remove or move a worktree with file-system commands:

* Do not `rm -rf` it.  That leaves its branch, so the branch name stays
  taken, and a stale registration in the repository.  Use
  `git-remove-branch-directory` instead.
* Do not `mv` it.  It keeps working, so nothing looks wrong, but its
  registration still names the old path, and the `git worktree prune` that
  `git gc` eventually runs then deletes the registration, after which the
  directory is no longer a working tree.  Use `git worktree move` instead,
  or run `git worktree repair` in a directory that was already moved.
* Do not remove or move the main working tree -- the clone that the
  worktrees were made from -- while worktrees depend on it.  Removing it
  removes the repository that all of them use, and moving it breaks them
  until you run `git worktree repair` in it.

None of this applies to a directory made by `git-new-branch --copy`, or to
the copy that `git-new-branch` or `git-checkout-branch` makes for a working
tree or branch that has submodules:  each of those is an independent clone,
which you can remove or move like any other directory.

`git-new-branch`, `git-checkout-branch`, `git-remove-branch-directory`, and
`git-orphaned-branches` require git 2.31 or later.  The default mode of
`git-new-branch` requires git 2.36 or later in a sparse checkout or with
per-worktree configuration.

## Programs for managing multiple git clones

The
[multi-version-control](https://github.com/plume-lib/multi-version-control)
program manages multiple clones, much as the scripts in this repository
manage multiple branches.

## License

This package is distributed under the [MIT License](LICENSE).
