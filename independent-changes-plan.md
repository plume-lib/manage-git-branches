# Plan: changes that do not depend on the worktree conversion

Companion to worktree-plan.md.  Everything here is correct and worth doing even
if `git-new-branch` never becomes worktree-based, so each item can land on its
own and be reviewed on its own merits.  Landing them first also shrinks the main
change: three of the six steps of worktree-plan.md §10 largely move here.

Sections are ordered by value, not by dependency; §9 gives a suggested order.

## 1. Refuse to run where `.git` is not a directory (a present-day corruption bug)

**This is a data-corruption bug in today's scripts, reachable without any
worktree.**  Both `git-new-branch` (git-new-branch:253) and
`git-checkout-branch` (git-checkout-branch:342) run `\cp -Rp -- .`, which copies
`.git` itself.  That is harmless when `.git` is a directory -- the copy is an
independent clone, which is the design -- but when `.git` is a *file* naming a
git directory elsewhere, the copy names the **same** git directory as the
original, so the two share one HEAD and one index.  The `git checkout -b` that
follows then moves the *source's* HEAD and writes the *source's* index.

Two ways a user reaches it today:

* **Inside a submodule.**  Verified: in a superproject with submodule `sub`,
  `git -C sub rev-parse --show-toplevel` is the submodule's root, so the scripts
  operate there; `sub/.git` says `gitdir: ../.git/modules/sub`; and a copy made
  as a sibling resolves that same relative path, so
  `git -C sub-branch-x rev-parse --absolute-git-dir` and
  `git -C sub rev-parse --absolute-git-dir` are the *identical* path.  Running
  `git-new-branch` in a submodule directory is an easy mistake -- the user is
  one `cd` away from where they meant to be.
* **Inside a linked worktree** that the user created by hand with
  `git worktree add`.  Same mechanism (worktree-plan.md fact 9).

### The fix

Before anything expensive -- before the `git pull`, before the remote queries,
before the copy -- refuse when the top level's `.git` is not a directory:

```sh
if [ -e .git ] && [ ! -d .git ]; then ... refuse ... fi
```

Test for "not a directory" rather than comparing git directories.  The
`--git-dir` versus `--git-common-dir` comparison that worktree-plan.md §6.1 uses
identifies a linked worktree but **not** a submodule, whose two are equal; and a
plain `-d .git` test needs no `git rev-parse --path-format=absolute`, so this
change imposes no new minimum git version.

The message must say which case it is and where to go instead, since the two
remedies differ:

* a submodule's working tree -- run the command in the superproject, whose
  branches are the ones worth branching;
* a linked worktree -- run the command in the main working tree.

Distinguish them by asking git: `git rev-parse --show-superproject-working-tree`
prints a path for a submodule and nothing otherwise.

### Tests for the guard

In tests/test-git-new-branch.sh and tests/test-git-checkout-branch.sh: a
submodule working tree and a hand-made linked worktree are each refused, the
message names the right remedy, no directory is created, and -- the assertion
that matters -- the source's `HEAD` and index are unchanged afterward.  A normal
clone still succeeds, so the guard has not caught the ordinary case.

### Interaction: §6.1 of the main plan

worktree-plan.md §6.1's interim refusal is a narrower version of this one, and
§5.12's `--copy`-from-a-worktree refusal is what survives of it.  When the
worktree modes land, the linked-worktree half of this refusal is relaxed for the
worktree modes and kept for `--copy`; the submodule half stays as it is, because
§4.3 keeps submodule repositories on full copies.

## 2. `git-orphaned-branches`: recognize a working tree whose `.git` is a file

`git-orphaned-branches:123` tests `[ -d "$dir/.git" ]`, so a directory whose
`.git` is a file -- a submodule, or a linked worktree -- falls into the `else`
branch, is checked only for a lone `.project` file, and is silently ignored.
claude-review.md:149 reports this.  Verified: with a worktree whose branch was
deleted on the remote, `is-deleted-branch` correctly returns 0 while
`git-orphaned-branches` prints nothing at all.

Decide "is this a working tree" by asking git -- `git -C "$dir" rev-parse
--git-dir`, or `--show-toplevel` -- rather than by testing for a directory.
`is-deleted-branch` already answers correctly for such a directory
(worktree-plan.md fact 2), so this is a one-line fix plus a test.

**Include the host filter** of worktree-plan.md §6.2 in the same change: never
report a directory whose `.git` is the repository that another live worktree
depends on.  It is cheap, it belongs to the same "be worktree-aware" edit in the
same file, and it matters as soon as a user has hand-made worktrees -- reporting
such a directory invites a deletion that breaks a working tree the user never
named.

### Tests for the scan

In tests/test-git-orphaned-branches.sh: a worktree directory whose branch was
deleted is reported; a submodule directory is classified as a working tree rather
than as `.project`-only junk; a worktree-hosting directory whose own branch was
deleted is *not* reported, while its own orphaned worktrees still are; and a
plain clone behaves exactly as before.

## 3. `is-deleted-branch`: fix the status-2 wording

Its documentation says status 2 means "the directory is not the top level of a
clone".  That is wrong today, not merely imprecise: the script accepts a
submodule working tree and a linked worktree and answers about them correctly, and
neither is a clone.  Say "not the top level of a working tree".  Mention that a
bare repository is status 2 as well, which the code already implements.

Documentation only; no behavior change.  The broader terminology sweep of
worktree-plan.md §8 is **not** independent -- today a branch directory really is
a clone, so rewriting the README's "working copy (a.k.a. clone)" would be
premature.

## 4. `git-push-to`: name the branch in the merge message

Today the script pulls from a relative pathname (git-push-to:301-316), and the
merge message it produces is

```text
Merge ./../r-branch-feature
```

which names the directory but not the branch.  Verified cause: for a pathname
with no refspec, `git fetch` writes `<sha>\t\t./../r-branch-feature` into
FETCH_HEAD, leaving `fmt-merge-msg` nothing to name.

Pass the branch name as well -- git's ordinary two-operand form -- and git's own
machinery does the rest.  Verified between two independent clones of one
upstream:

```text
$ git pull -- ./../r-branch-feature feature
FETCH_HEAD:  <sha>\t\tbranch 'feature' of ./../r-branch-feature
subject:     Merge branch 'feature' of ./../r-branch-feature
```

The branch name is already in hand: `check_upstream` determines it and refuses a
detached HEAD (git-push-to:136-138), so no new machinery is needed.  The path
stays, and should -- these commits did come from another repository -- so
`relative-path` and the `./`-prefix hack keep their full rationale.

This is also slightly more than cosmetic: `git pull PATH` merges whatever FROM's
HEAD points at, while `git pull PATH BRANCH` merges the branch the script
determined and validated.  If FROM's HEAD moved in between, today's form merges
something the script never checked.

Rejected: `-m "Merge branch 'feature'"`, which would drop the path.  It
fabricates the message instead of letting git describe what it merged, and it
discards the commit-summary list that `merge.log` turns on.

### Tests for the merge message

The merge commit's subject names the branch, the path in it is relative, and it
does not contain the test's temporary-directory prefix -- the assertion that
catches an absolute path leaking into shared history.

### Interaction: §6.4 of the main plan

worktree-plan.md §6.4 keeps this form for independent clones and replaces it with
`git merge -- BRANCH` for related worktrees, where there is nothing to fetch.
This change is the half that helps everyone, including submodule repositories,
which §4.3 keeps on full copies forever.

## 5. One remote query per remote URL, not per directory

worktree-plan.md §1.2 presents batched remote queries as a benefit of worktrees.
**Most of that saving does not depend on worktrees at all**, and this is the most
valuable item in this file after §1.

`is-deleted-branch` asks one question -- does this remote still have this branch?
-- with one `git ls-remote` per directory.  What determines whether two of those
queries can be merged is not whether the directories share a repository but
whether they talk to the **same remote URL**.  In this package's workflow every
`REPO-branch-*` directory of one project is a clone of the same upstream, so
today `rmgob` over twenty branch directories of one project opens twenty SSH
connections to the same host to ask twenty questions that one
`git ls-remote --heads URL` answers.

### Design

* Group the directories by the **resolved URL** of the remote that
  `push_remote` chooses for each -- `git -C DIR remote get-url REMOTE`, or
  `git ls-remote --get-url REMOTE`, which also handles `url.*.insteadOf`
  rewriting and a remote given as a pathname.
* Also key on the effective SSH configuration: `git_batch_ssh` takes its
  `core.sshCommand` and `ssh.variant` from the directory it is given
  (remote-functions.sh), so two directories that resolve the same URL but
  configure SSH differently must stay in separate groups.  Equal URL *and* equal
  SSH configuration is the grouping key.
* Issue one `git ls-remote --heads URL` per group, through `git_batch_ssh` with
  a representative member's configuration, and answer every member from its
  output (`SHA<TAB>refname`, one line per ref).
* Fall back to a per-directory query for any directory whose configured upstream
  refs are not all under `refs/heads/` -- `branch.BRANCH.merge` may name any ref,
  and `--heads` would not report such a one.  This keeps the batch exact rather
  than approximately right.
* Prefer `--heads` over naming each branch as a pattern: no chunking, no
  command-line length limit, and one answer serves any number of questions.

### Where the code lives

Move the body of `is-deleted-branch` into remote-functions.sh as a function that
answers for one directory and returns the same exit statuses the command
documents (0, 1, 2, 3, 64 -- `git-push-to` and `git-orphaned-branches` both
switch on them), leaving the command a thin wrapper so its interface does not
change.  Add a second function that takes several directories, groups them as
above, and answers each.  `git-orphaned-branches` and `git-push-to` source those.

The refactor by itself is a pure no-behavior-change commit and can land before
the batching.  This follows commit 701dc28, which moved remote determination and
the prompt-free queries into remote-functions.sh for exactly this kind of
sharing.

### Tests for the query count

Count the queries with a fake `git` on PATH that appends its subcommand to a log
and then execs the real git -- cheaper than a fake SSH, since these tests' remotes
are local pathnames that never reach SSH.  `git-orphaned-branches` over several
clones of one upstream issues exactly one `ls-remote` and reports the same
directories that one query per directory reports; clones of *different* upstreams
still issue one each; a directory whose upstream ref is outside `refs/heads/`
falls back to its own query and still gets the right answer; and two clones that
configure `core.sshCommand` differently are queried separately.

### Interaction: §6.6 of the main plan

This **supersedes** worktree-plan.md §6.6's saving 1, and simplifies it: grouping
by URL subsumes grouping by repository, since two related worktrees that push to
one remote resolve one URL. `related_worktrees` is then needed only for saving 2
(one `git fetch` per group) and for §6.4's merge-by-name -- both of which do
require a shared object store. worktree-plan.md §6.6 and §1.2 should be amended
to say so.

## 6. `git-push-to`: stop doing a middle directory's work twice

`git-push-to A B C` calls `git_push_to A B` and then `git_push_to B C`
(git-push-to's main loop), so B is the "to" of the first call and the "from" of
the second.  Each call runs `check_branch_exists` (one `ls-remote`) and a
`git pull` for *both* of its directories, so in a three-directory chain B is
queried twice and fetched twice.  Nothing about worktrees is involved.

Recommendation, split by risk:

* **Deduplicate the query.**  Remember which directories this invocation has
  already asked about and reuse the answer.  Safe: it is the same question about
  the same directory within one run, and worktree-plan.md §6.6 already accepts
  an up-front snapshot of the remote for the same reason.
* **Leave the second `git pull` in place**, or make it opt-in.  It is *nearly*
  redundant -- the first call has just merged into B and pushed it -- but not
  quite: a concurrent push by someone else between the two calls would be picked
  up today and missed if the fetch is skipped.  That is a change in merge
  semantics, not just a saving, so it deserves its own decision rather than
  riding along with a cleanup.

### Tests for the deduplication

With the query counter of §5: a three-directory chain issues three `ls-remote`
calls rather than four, and a four-directory chain four rather than six.

## 7. Safe removal: `git-remove-branch-directory`, `--remove`, and `rmgob`

worktree-plan.md §7 motivates this script by the leftovers that a worktree
deletion leaves behind.  But the safety half of it is **more** valuable today,
not less: in the clone model, `rm -rf REPO-branch-X` destroys the objects along
with the directory, so unpushed commits are gone irrecoverably -- whereas with
worktrees the shared object store and the surviving branch ref make the same
accident recoverable.  The README's recommended `rmgob` is
`git-orphaned-branches --print0 | xargs -0 rm -rf`, which deletes whatever it is
handed without looking.

So the clone-only version of the script is worth having on its own:

* `git-remove-branch-directory [--force] [--force-uncommitted]
  [--force-unpushed] DIRECTORY...`, removing a clone or a non-repository with
  `rm -rf`.
* The two safety checks of worktree-plan.md §7.3, each with its own waiver, each
  refusal naming the check, quantifying what would be lost, and quoting the flag
  that waives it.  For a clone the unpushed-commits question is about *every*
  branch, not just the checked-out one, because `rm -rf` takes all of its refs:
  `git -C DIR rev-list --count --branches --not --remotes`.
* The guardrails of worktree-plan.md §7.4, neither of them waivable.
* `git-orphaned-branches --remove`, which runs the script on each directory it
  would report, in two phases (scan, then remove); and the `rmgob` alias becomes
  `git-orphaned-branches --remove`.

Say in the README that the new `rmgob` can leave a directory behind, with a
reason, where the old one deleted unconditionally.

### Interaction: §7 of the main plan

worktree-plan.md §7 then adds only the worktree-specific parts: `git worktree
remove --force`, deleting the branch ref, removing the one administrative
directory instead of pruning, the §7.5 already-deleted case, and the host
guardrail.  The script's interface, its checks, its messages, and its tests are
already in place.

## 8. What is *not* independent

Recorded so that nobody tries to pull these forward:

* **The three modes** (`--clean`, `--copy`) and everything in worktree-plan.md
  §5 -- they exist because the default mode becomes a worktree.
* **Refusing an unborn HEAD** (§5.8).  It is a behavior *removal* whose
  justification is the version-dependence of `git worktree add -b` on an unborn
  HEAD.  Today's script creates such a directory harmlessly; there is no
  independent benefit.
* **The index copy** (§5.4) and the **cleanup rework** (§5.6) -- both exist only
  to serve `git worktree add`.
* **The terminology sweep** (§8), for the reason in §3 above.
* **`git worktree list` as an inventory** for `git-orphaned-branches`, which
  needs the branch directories to be worktrees before it finds anything.
* **Saving 2** (one `git fetch` per group) and **merge-by-name** (§6.4's worktree
  half) -- both need a shared object store.
* **The git 2.31 minimum** (§5.5).  Nothing in this file needs it; keep these
  changes version-neutral so they can land without that discussion.

## 9. Suggested order

1. **§1**, the corruption guard.  It is a bug fix with a real failure mode, it is
   small, and it needs no new infrastructure.
2. **§2**, the `git-orphaned-branches` fix and host filter.
3. **§3**, the wording fix, which can ride along with §2.
4. **§4**, the merge message.  Independent of everything above.
5. **§5a**, the `is-deleted-branch` refactor into remote-functions.sh: no
   behavior change.
6. **§5b**, the URL-keyed batching, on top of the refactor.
7. **§6**, the chain deduplication, which reuses §5's grouping and its test
   harness.
8. **§7**, the removal script and `--remove`.

Steps 1-4 are each an afternoon.  Steps 5-8 are the substantial ones, and each
delivers a benefit that worktree-plan.md currently attributes to the worktree
conversion.

## 10. Effect on worktree-plan.md

If all of this lands first:

* §10 step 1 (the `git-orphaned-branches` fix) is done.
* §10 step 5 (removal) keeps only the worktree-specific half (§7 above).
* §10 step 6a (batched `ls-remote`) is done, and §6.6 should be amended: saving
  1 is URL-keyed and needs no `related_worktrees`, which remains only for saving
  2 and for §6.4's merge-by-name.
* §1.2's framing needs revising, since most of the network saving it claims for
  worktrees is available without them.
* §6.1's interim refusal becomes a *relaxation* of §1 above rather than a new
  restriction, which is a smaller and safer edit.

What remains of the main change is then the part that is genuinely about
worktrees: the three modes, the index, the cleanup, one fetch per group, and
merge-by-name.
