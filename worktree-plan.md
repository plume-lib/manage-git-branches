# Plan: make `git-new-branch` create a worktree instead of a copied clone

## 1. Goals and what they buy

The goal is less disk space (§1.1).  Fewer network accesses, once a second goal,
needs no worktrees and is already implemented (§1.2).

### 1.1 Less disk space

`git-new-branch` currently creates the new branch directory with
`\cp -Rp -- . "${BRANCHDIR}-TMP"` (git-new-branch:256), so every branch
directory holds a complete second copy of the repository's object store.
Replace that copy with `git worktree add`, so that all branch directories of one
repository share one object store.

Because the new directory must still inherit uncommitted and untracked files
(§4.1), the working tree is still copied.  The saving is therefore **exactly the
size of `.git`**.  Measured on this machine:

| directory | total | `.git` | saving |
| --- | --- | --- | --- |
| `manage-git-branches-branch-worktrees` | 52 MB | 13 MB | 25% |
| `mdedots-branch-linting6` | 100 MB | 29 MB | 29% |
| `plume-scripts-branch-fix-4` | 110 MB | 10 MB | 9% |

So expect roughly 10-30% per branch directory, not the near-total saving that a
clean worktree would give.  For `plume-scripts` in particular, most of the 110 MB
is untracked build output, which the new directory still duplicates by design.
This is the cost of the §4.1 requirement, and it is worth stating in the commit
message so the tradeoff is on record.

A repository that has submodules saves nothing: it keeps the current full copy
(§4.3).  Neither does `--copy`, which is that same full copy on request (§2).

`--clean` saves much more, because it copies nothing at all: the new directory
holds the tracked files and no build output.  For `plume-scripts`, where 100 of
the 110 MB is untracked, that is the difference between 10 MB saved and about
100 MB saved.  It is the right mode when a fresh tree is wanted; it is not the
default, because §4.1 requires that the default carry the current work forward.

### 1.2 Fewer network accesses

**Already implemented, without worktrees.**  What lets two "does the remote
still have this branch?" queries merge is not a shared repository but a shared
remote **URL**, and every `REPO-branch-*` directory of one project is a clone of
the same upstream.  `remote_heads_key` and `remote_heads` in remote-functions.sh
group the queries by resolved URL and SSH configuration and issue one
`git ls-remote --heads` per group, so `git-orphaned-branches` over twenty
branch directories makes one query, and a `git-push-to` chain makes one.

Worktrees would allow two further savings in `git-push-to`, because related
worktrees share refs: one `git fetch` per group instead of one `git pull` per
directory, and no fetch from a sibling directory.  Both are deferred (§10.1
item 8): together they save a connection or two per `git-push-to` run, and they
would need a relatedness predicate, grouping, a fast-forward fast path with a
`git pull` fallback, and a refspec check.

## 2. The core change

`git-new-branch` gains two options and so has three modes:

```text
git-new-branch [--clean | --copy] NEWBRANCHNAME
```

| mode | the new directory is | local changes | copied |
| --- | --- | --- | --- |
| default | a worktree | inherited (§4.1) | the working tree |
| `--clean` | a worktree | **none** | nothing |
| `--copy` | an independent clone | inherited | everything |

"Copied" means copied by this script: the default mode copies the working tree
including untracked and ignored files, `--clean` copies nothing (git writes the
tracked files from the shared object store), and `--copy` copies the whole
directory, `.git` included, as today.

* **Default** -- a worktree whose contents match the current directory, including
  uncommitted, untracked, and ignored files.  This is the mode that §4.1 requires
  and the four steps below implement.
* **`--clean`** -- a worktree holding a clean checkout of HEAD and nothing else.
  One `git worktree add`; no copy, no temporary directory, no index to install.
  It is the cheapest mode in both time and disk, and the one to use when the
  point is a fresh tree rather than a continuation of the current work (§5.11).
* **`--copy`** -- exactly today's behavior: `cp -Rp` of the whole directory
  including `.git`, then create the branch in the copy, so the new directory is
  an independent clone that shares nothing.  This is also the code path that a
  repository with submodules falls back to (§4.3), so the option and the fallback
  are one implementation, not two (§5.12).

The default mode replaces lines 245-269 (the `${BRANCH_TMPDIR}` test, the `cp`,
the `git checkout -b`, and the `mv`) with four steps:

1. Copy every top-level entry **except `.git`** from the source into a plain
   `${BRANCH_TMPDIR}` -- an ordinary directory, not yet a worktree.  This is the
   slow step, and it happens under the temporary name, as today.
2. `git worktree add --no-checkout -q -b "${BRANCHNAME}" "${BRANCHDIR}"`.  With
   `--no-checkout` this creates `${BRANCHDIR}` containing nothing but the `.git`
   file, so it writes no tracked file that the copy would then overwrite.
3. Move the new `.git` file into `${BRANCH_TMPDIR}`, remove the now-empty
   `${BRANCHDIR}`, and rename `${BRANCH_TMPDIR}` to `${BRANCHDIR}`.
4. Install the index: copy the source's index file to the new worktree's index
   (§5.4), which reproduces the source's staged state exactly.

Everything before that -- argument checking, the `HEAD` rejection, the local
branch-name collision test, the `${BRANCHDIR}` existence test, the `git pull`,
the remote determination, and both remote collision checks
(git-new-branch:65-244) -- stays as it is, apart from the `.git` guard that
§6.1 narrows, and applies to all three modes.

**What the command touches, in every mode.**  The plan assumes this invariant
throughout, so it is worth stating once:

* The source's **working tree** is never modified.  Files are read and copied;
  nothing in the source directory is created, changed, or removed.
* The source's **repository** is modified, in two ways that are new.  The
  `git pull` updates it, as it does today; and in the worktree modes
  `git worktree add` writes a branch ref and a `.git/worktrees` entry into it.
  Before this change, `git-new-branch`'s only effect was to create a new
  directory.
* No **remote** is modified, in any mode.  The remote is read -- the pull, and
  the collision query -- and never written; in particular the new branch is not
  pushed.  This is today's promise (git-new-branch:12-15) and it survives.

Verified end to end: the resulting directory's
`git status --porcelain=v1 --ignored` is identical to the source's, and
`diff -r --exclude=.git` reports the contents identical (fact 13).

## 3. Facts verified against git 2.53.0

These were checked by experiment, not from memory, because several of them
determine the design below.

1. A linked worktree's `.git` is a **file** containing
   `gitdir: /abs/path/to/MAINDIR/.git/worktrees/NAME`.  Both paths are absolute.
2. `git rev-parse --show-toplevel`, `--absolute-git-dir`, `--git-common-dir`,
   `symbolic-ref HEAD`, `config`, `pull`, `push`, and `ls-remote` all behave
   normally in a linked worktree.  `is-deleted-branch` already returns the right
   answer for a worktree directory (verified: status 0 for a deleted branch).
3. **`mv` silently half-breaks a worktree.**  Afterward the worktree still works,
   but `.git/worktrees/NAME/gitdir` still names the old path, `git worktree list`
   marks the entry `prunable`, and `git worktree prune` (which `git gc` runs, per
   `gc.worktreePruneExpire`, three months by default) then deletes the
   administrative directory and kills the worktree.  `git worktree repair PATH`
   fixes it.  **Consequence: no step of this plan may `mv` a registered worktree.**
4. `rm -rf` of a worktree directory leaves both a stale registration under
   `.git/worktrees/` **and** the branch ref (verified: `git branch --list` still
   showed the branch).  `git worktree remove` also leaves the branch ref.
   **Consequence: `rmgob` no longer frees the branch name; see §7.**
5. `git worktree add` creates missing parent directories, accepts an existing
   *empty* directory, and refuses a non-empty one (`fatal: '...' already exists`).
6. `git worktree add -b BRANCH` refuses a branch that already exists
   (`fatal: a branch named 'x' already exists`) and refuses a branch already
   checked out in another worktree without `--force`.
7. `git worktree add -b` succeeds on an **unborn** HEAD in git 2.53 (a fresh
   `git init` with no commit); older versions fail there, and `--orphan`
   (git 2.42+) is the explicit spelling.  See §5.8.
8. **`git worktree add` does not populate submodules** (verified: the new
   worktree's submodule directory is empty) -- but with the copy of §2 the
   submodule's files arrive anyway, which turns out to be worse; see fact 16.
9. **`cp -Rp` of a whole worktree directory produces an aliasing disaster.**  The
   copy's `.git` file names the *source worktree's* administrative directory, so
   `git -C copy rev-parse --absolute-git-dir` returns the source's git dir: the
   copy and the original share one HEAD and one index.  This is why the copy in
   §2 must skip `.git`, and it is the forcing constraint of §6.1.
10. Fetching from a sibling worktree of one repository, as `git-push-to`'s
    `fetch_branch` does, works normally, so `git-push-to` and `git-pull-from`
    need no change to keep working.
11. A branch name that begins with `-` (such as the `-n` that
    tests/test-branch-directory-name.sh uses) breaks `git worktree add -b -n`
    exactly as it breaks today's `git checkout -b -n`: `git branch` reads it as
    an option. `refs/heads/-n` is nonetheless a valid refname (`git
    check-ref-format` accepts it). Pre-existing limitation, not a regression;
    optional hardening in §5.9.
12. `git worktree add --no-checkout` creates the directory with **only** the
    `.git` file and an **empty index** (0 entries; `git status` then reports every
    tracked path as staged-deleted).  So the index must be installed explicitly.
13. Copying every top-level entry but `.git`, and then copying the source's index
    file to the new worktree's index, reproduces the source exactly.  Verified with
    a source that had a staged change, an unstaged change, a deleted tracked file,
    an untracked file, an untracked directory, and an ignored file:
    `git status --porcelain=v1 --ignored` was identical in both directories, and
    `diff -r --exclude=.git` reported no difference.
14. A public-API alternative to copying the index, if reaching into
    `.git/worktrees/NAME/index` is judged too intrusive: in the new worktree, run
    `git read-tree HEAD`, `git update-index -q --refresh`, and then
    `git diff --cached --binary HEAD` in the source piped to
    `git apply --cached --binary` in the new worktree.  Verified to give the
    identical status.  It needs a valid HEAD, so it does not cover §5.8.
15. `git worktree move` does move a *dirty* worktree and updates the registration
    correctly -- but the administrative directory keeps its original basename
    forever, so adding at `X-TMP` and moving to `X` leaves
    `.git/worktrees/REPO-branch-X-TMP` permanently.  This is why §2 adds the
    worktree at the final path.
16. **Submodules break.**  A submodule's `.git` file says
    `gitdir: ../.git/modules/sub`, which does not resolve in a linked worktree
    (whose `.git` is a file).  Copying it is fatal, and not just for the
    submodule: `git status` in the *whole* new worktree fails with
    `fatal: not a git repository: sub/../.git/modules/sub`.  Rewriting the pointer
    to `<git-common-dir>/modules/sub` repairs the superproject, but then both
    worktrees' submodule share one git dir -- verified identical
    `--absolute-git-dir` -- hence one HEAD and one index.  Git does not support
    per-worktree submodule checkouts.  See §4.3.
17. **A prune that catches a moved worktree cannot be undone.**  With one
    worktree deleted with `rm -rf` and another moved with `mv`,
    `git worktree prune -v` reports removing *both* registrations ("gitdir file
    points to non-existent location").  The moved directory is then no longer a
    working tree -- `git status` in it says
    `fatal: not a git repository: .../worktrees/NAME` -- and
    `git worktree repair` on it fails with
    `unable to locate repository; .git file does not reference a repository`,
    because the administrative directory it would repair is gone.  The files and
    the branch ref survive, so no work is lost, but the working tree has to be
    recreated.  This is why no script here runs `prune` (§5.7, §7.2).

## 4. Behavior changes

### 4.1 The new directory inherits uncommitted and untracked files (requirement)

**Decided: required.**  The new directory must hold what the source directory
holds -- uncommitted modifications, staged changes, untracked files, and ignored
files such as build output and `.venv` -- as the current header comment promises
("the same directory contents as the current repository", git-new-branch:8-9).
The README's "faster builds" advantage and its "never run `git stash`" principle
both depend on this.

The design of §2 delivers it, at the cost described in §1: the working tree is
still copied, so only the object store is shared.  Fidelity is exact, including
the staged-versus-unstaged distinction and uncommitted deletions of tracked
files (fact 13).

A cheaper variant is possible later: let `git worktree add` check out the tracked
files from the shared object store, apply `git diff HEAD` for the modifications,
and copy only the untracked and ignored entries.  It would avoid copying
unmodified tracked content, but it requires enumerating untracked paths, and
`git ls-files -z` output cannot be split safely by a POSIX `sh` (no `read -d ''`),
which is exactly the pathname-safety problem this package is careful about
elsewhere.  The whole-entry copy of §2 sidesteps it and costs no more than today.

### 4.2 Config, hooks, and refs become shared

**Decided: acceptable.**  All branch directories of one repository now share one
object store, one set of refs, one `config`, one `hooks/` directory, and one
`info/exclude`.  Nothing here needs to be worked around; what remains is to
document the consequences and to keep the shared branch namespace tidy (§7).

* `git config` in one branch directory affects every branch directory.  Should
  one setting ever need to be per-directory, the escape hatch is
  `extensions.worktreeConfig` with `git config --worktree`, but no such setting
  is planned and the scripts should not enable it.
* Branch refs are shared, which is what makes §7 necessary: sharing the refs is
  fine, but a branch whose directory is gone still occupies its name.
* `git gc` or `git repack` in one directory rewrites the objects that all of them
  use.  This is safe (worktree HEADs and indexes are gc roots), but it is no
  longer an isolated operation.
* Deleting or moving the main working tree (`REPO-branch-main`) breaks every
  worktree that depends on it.  `git worktree repair` recovers from a move.

### 4.3 Submodules: fall back to copying the whole directory

**Decided: fall back to the current full copy.**  Fact 16 makes a submodule
repository unusable in the worktree design: the copied submodule pointer is fatal
to the whole new worktree, and the repair shares one submodule checkout between
two branch directories, which is precisely the branch confusion this package
exists to prevent.

So when `.gitmodules` exists at the top level, `git-new-branch` takes the
**current** code path -- `cp -Rp -- .` of the whole directory *including* `.git`,
then create the branch in the copy -- and prints one line saying that the
repository has submodules, so the new directory is a full copy rather than a
worktree.  The existing path is a dozen lines and is already known to work;
keeping it costs little and avoids both breaking submodule users and shipping a
subtly shared submodule.

Implementation notes:

* Choose the path *before* the copy, from
  `[ -e "${TOPLEVEL}/.gitmodules" ]`, so the expensive work happens only once.
  A `.gitmodules` that is present but registers no submodule is harmless: the
  fallback is merely a full copy, which is what today's script always does.
* Keep the two paths as two small blocks with one shared tail, rather than
  interleaving them, so that each remains readable and the fallback stays easy to
  delete if git ever supports per-worktree submodules.
* The fallback keeps its `-TMP`-then-`mv` structure exactly as today
  (git-new-branch:245-269): the copied directory is an independent clone, not a
  registered worktree, so `mv` is safe there (fact 3 applies only to worktrees).
* `git-remove-branch-directory` (§7) must therefore handle both layouts, which it
  does by construction.
* Submodules are the *only* condition that selects this path automatically, and
  it is the same path as the `--copy` option of §2, so there is one
  implementation to write and test.  Two other corners that a fallback might have
  covered are refusals instead: too old a git (§5.5) and an unborn HEAD (§5.8).

### 4.4 `.git` is a file

A branch directory's `.git` becomes a file.  A tool that tests `-d .git` to
recognize a working tree -- a user's script, a shell prompt, an editor plugin --
will no longer recognize one.  Such a tool should ask git instead
(`git rev-parse --show-toplevel`).  Nothing in this package tests `-d .git` that
way.

## 5. Detailed design for `git-new-branch`

### 5.1 The copy (step 1)

**Keep the `${BRANCH_TMPDIR}` existence test** (git-new-branch:251-254) that §2
lists among the replaced lines.  Without it the copy merges into whatever a
crashed earlier run left at that name, and the result is a new branch directory
holding another branch's files.  Test it immediately before the copy, as today,
and set `${TMPDIR_TO_CLEAN}` only after the test passes, so the traps never
remove a directory this run did not create -- the reasoning of the comment at
git-new-branch:245-250, which survives the change.

Then `\cp -Rp -- . "${BRANCH_TMPDIR}"` becomes a loop over the top-level entries
that skips `.git`:

```sh
for entry in ./* ./.*; do
  case "${entry##*/}" in '.' | '..' | '.git') continue ;; esac
  # A pattern that matched nothing, which the shell leaves unexpanded.
  if [ ! -e "${entry}" ] && [ ! -L "${entry}" ]; then continue; fi
  \cp -Rp -- "${entry}" "${BRANCH_TMPDIR}/" || fail
done
```

Notes for the implementation:

* `.git` must be skipped, not copied: copying it either duplicates the object
  store (defeating the change) or, when the source is itself a worktree, produces
  the aliasing of fact 9.
* Glob `./*` rather than `*`, so an entry whose name begins with `-` reaches `cp`
  as `./-name`; `--` is used as well.
* `cp -Rp` (not `-a`, not `--exclude`) keeps this POSIX, as the current code and
  `relative-path` do; `-R` does not follow symbolic links, so links are copied as
  links.
* Test `-e` *or* `-L`, so a dangling symbolic link is copied rather than skipped.
* The two globs together must not miss anything: `./.*` covers dotfiles, and
  `.` and `..` are skipped by name.  `only_dot_project` in remote-functions.sh already
  uses this idiom, so the reasoning is consistent within the package.
* Do not `set -f`: the entries come from globbing, not from data.

#### Rejected alternative: copy everything, then remove `.git`

That is, keep today's `\cp -Rp -- . "${BRANCH_TMPDIR}"` unchanged and follow it
with `rm -rf -- "${BRANCH_TMPDIR}/.git"`.  It is the simpler code -- two commands
instead of the loop above, and it is the same copy command that `--copy` (§5.12)
needs anyway, so the default mode would become "`--copy`'s copy, minus `.git`".
It is also fidelity-proof: `cp -Rp -- .` copies every entry by construction, so
it cannot silently miss one, which is the loop's one real risk (§9 covers it with
a test).

It loses on the goal of the change:

* **Peak disk.**  It writes the whole object store and then deletes it, so it
  needs room for a full copy at its high-water mark.  That can fail with ENOSPC
  in exactly the situation that motivates this plan -- a disk full of branch
  directories -- turning a success into a failure.  The loop never allocates
  those bytes at all.
* **Time and I/O.**  The extra cost is twice the size of `.git`: write it, then
  delete it.  `.git` is 13 MB here (§1.1) but hundreds of MB or more in an old
  project, and it is mostly small files -- loose objects and refs -- which are
  the slowest kind to both copy and remove, and dramatically so on a network or
  FUSE filesystem.
* **It reintroduces what the change removes,** briefly.  A reviewer reading
  "duplicate the object store, then delete it" in a commit whose purpose is not
  to duplicate the object store will ask why; the answer would be "because the
  loop is fiddly", which is not a good enough reason.

The two designs are otherwise equivalent: both handle a `.git` that is a file
(a worktree source) and a `.git` that is a symbolic link, and both leave nothing
behind on failure, since the trap removes `${BRANCH_TMPDIR}` either way.  The
loop additionally gives a per-entry diagnostic ("cannot copy ./sub") where the
single `cp` gives a directory-level one.

### 5.2 Create the worktree (step 2)

```sh
git worktree add --no-checkout -q -b "${BRANCHNAME}" "${BRANCHDIR}"
```

`${BRANCHDIR}` is absolute (git-new-branch:119-123), so it can never be mistaken
for an option and needs no `--`.  `--no-checkout` matters: without it git writes
the tracked files and step 3 immediately overwrites them, doubling the I/O.

Keep the early `[ -e "${BRANCHDIR}" ]` test (git-new-branch:152-155): it runs
before any network access and its message is better than git's.  Let
`git worktree add` be the final authority (fact 5).

Add the worktree at the final path: adding at `${BRANCHDIR}-TMP` and running
`git worktree move` would leave `.git/worktrees/REPO-branch-X-TMP` as the
administrative name forever (fact 15).

### 5.3 Populate the directory (step 3)

```sh
mv -- "${BRANCHDIR}/.git" "${BRANCH_TMPDIR}/.git"
rmdir -- "${BRANCHDIR}"
mv -- "${BRANCH_TMPDIR}" "${BRANCHDIR}"
```

The worktree ends up at exactly the path it was registered under, with its
`.git` file in place, so the registration stays valid; fact 3's hazard is a
worktree that ends up somewhere *other* than its registered path.  Verified:
afterward `git worktree list` marks nothing prunable, and, once the index is
installed, `git status` in the new directory matches the source's.

Both paths share a parent directory, so the renames are cheap, and
`${BRANCHDIR}` exists in an incomplete state only between them -- which
preserves the property that today's `-TMP`-then-`mv` provides and that the
comment at git-new-branch:245-250 explains.

### 5.4 Install the index (step 4)

**Decided: copy the index file.**  The index is per-worktree, and `--no-checkout`
leaves it empty (fact 12), so it has to be installed:

```sh
SRC_INDEX="$(git rev-parse --path-format=absolute --git-path index)"
NEW_INDEX="$(git -C "${BRANCHDIR}" rev-parse --path-format=absolute --git-path index)"
\cp -p -- "${SRC_INDEX}" "${NEW_INDEX}"
```

Ask git for both paths with `--git-path index` rather than appending `/index` to
a git directory.  Two reasons, and the second is why `--absolute-git-dir` is not
enough:

* The source's index is at `.git/index` in a clone but at
  `.git/worktrees/NAME/index` when `git-new-branch` runs from inside a worktree,
  which it will be.
* `${GIT_INDEX_FILE}`, if the caller exports it, moves the index that git
  actually uses.  `--git-path index` honors it; `--absolute-git-dir` plus
  `/index` does not, and would copy a file git is not using.  The tests unset
  `GIT_INDEX_FILE` (tests/lib-git-test-env.sh), so this would never surface in
  testing -- a reason to get it right deliberately rather than by accident.

The copy reaches into the new worktree's administrative directory, so it needs a
comment saying why it is sound: the index records repository-relative paths, `cp
-p` preserves the mtimes its stat data refers to, and every blob it names is in
the shared object store, including blobs that only `git add` created.  Verified
in fact 13.

One cost to expect, not a correctness problem: the index also records each
file's `dev` and `ino`, and the copied files are different inodes, so git
considers the entries stat-dirty and re-hashes them on the first `git status` in
the new directory, rewriting the index afterward.  The answers are right (fact
13 compared them) but that first status costs a full re-hash of the working
tree.

The public-API sequence of fact 14 is rejected: it costs two more git
invocations, and it reconstructs the index from a diff rather than reproducing
the one the user has.  (Its inability to handle an unborn HEAD no longer counts
against it, since §5.8 refuses that case, but the other two reasons stand.)

### 5.5 A minimum git version

**Decided: require git 2.31** (March 2021).  There is no fallback for anything
older: the package reports the requirement and exits nonzero.

What each version buys:

| version | feature | used by |
| --- | --- | --- |
| 2.9 | `git worktree add --no-checkout` | §5.2 |
| 2.17 | `git worktree remove` | the cleanup of §5.6 |
| 2.30 | `git worktree repair` | the recovery documented in §4.2 and §8 |
| 2.31 | `git rev-parse --path-format=absolute` | §5.4, §7.2 |

Check once, before any work, with `git-outgoing`'s `require_git`, moved into
remote-functions.sh so that every command shares it:

```sh
require_git 31
```

`require_git` parses `git version` and, for too old a git, prints "requires git
2.31 or later, but found git X" and exits 1.  Moving it means also moving the
version parsing that feeds it, and making `die`'s hard-coded `git-outgoing:`
prefix use `${SCRIPT_NAME}`.

Parse the version rather than probing for `--path-format`.  One mechanism for
the whole package gives one message format, and that message can report the
version it found.  A probe would also need care: `git rev-parse` echoes an
option it does not recognize and exits 0, so the obvious
`git rev-parse --path-format=absolute --git-dir` succeeds on an old git.  The
usual argument for probing -- a distribution that backported a feature into an
older version number -- rarely applies to git.

Document the requirement in the README (§8).

### 5.6 Cleanup on failure and on a signal

The existing `cleanup` (git-new-branch:76-79) removes `${TMPDIR_TO_CLEAN}`.  It
now has two things to undo, so give it two variables:

* `TMPDIR_TO_CLEAN` -- `${BRANCH_TMPDIR}` until the rename of step 3;
  `rm -rf` is still the right removal, even after step 3 has moved the `.git`
  file into it.
* `WORKTREE_TO_CLEAN` -- `${BRANCHDIR}`, set immediately before
  `git worktree add` runs and cleared only after step 4 succeeds.
* `WORKTREE_GITDIR_TO_CLEAN` -- the new worktree's administrative directory,
  read with `git -C "${BRANCHDIR}" rev-parse --absolute-git-dir` as soon as the
  add succeeds (step 4 needs it anyway, §5.4).  Capturing it is what lets the
  fallback below remove exactly one registration instead of pruning.

One `cleanup` serves all three modes of §2, because each variable is empty in the
modes that never set it: the default mode uses both, `--clean` sets only
`WORKTREE_TO_CLEAN` (there is no temporary directory), and `--copy` sets only
`TMPDIR_TO_CLEAN` (there is no worktree), which is exactly the cleanup the
current script already has.  Keeping one `cleanup` rather than three is what
makes the mode selection a matter of which steps run, not of which traps are
installed.

For `${WORKTREE_TO_CLEAN}`, `cleanup` should:

1. `git -C "${TOPLEVEL}" worktree remove --force "${WORKTREE_TO_CLEAN}"`
   (`--force` because git refuses to remove a worktree with modifications, and a
   half-built one has them by construction).
2. If that fails -- the add may have failed partway, leaving a directory that
   git will not remove, or a signal may have arrived between the renames of step
   3, when `${BRANCHDIR}` does not exist -- `rm -rf -- "${WORKTREE_TO_CLEAN}"`
   and then `rm -rf -- "${WORKTREE_GITDIR_TO_CLEAN}"`, if that variable was
   set.
   **Not `git worktree prune`**: prune removes every registration whose
   directory is missing, including that of a worktree the user moved with `mv`
   and has not repaired, and fact 17 shows that damage cannot be undone.
   Removing the one administrative directory this invocation created is
   precise, and it is what §7.2 step 5 does for the same reason.
3. Delete the branch: `git worktree add -b` can leave `refs/heads/${BRANCHNAME}`
   behind when its checkout half fails, and a retry would then hit the "already
   exists in this clone" test.  Use
   `git -C "${TOPLEVEL}" update-ref -d "refs/heads/${BRANCHNAME}"`, not
   `git branch --delete --force`: it takes a full refname, so a branch name
   beginning with `-` cannot be read as an option.

   Delete it only if this run created it.  The local-branch check
   (git-new-branch:147-150) has already established that the branch did not
   exist when the run began, so in practice it did; but that check ran before
   the `git pull` and the remote queries, and something else could have created
   the branch in between.  Recording the branch's absence at the check and
   consulting that record here costs one variable and removes the chance of
   deleting someone else's ref in an error path.

`cleanup` runs after `cd -- "${STARTDIR}"`, and `${STARTDIR}` may no longer
resolve, so every command must name its repository with `git -C "${TOPLEVEL}"`.
`cleanup` now runs `git`, which it does not today, so it must redirect stdin from
`/dev/null` and discard output: an interrupted run must not produce a second wave
of diagnostics or stop to prompt.

### 5.7 A stale registration at `${BRANCHDIR}`

After a `rm -rf` of a branch directory (today's `rmgob`), `.git/worktrees/` keeps
a registration for that path, and `git worktree add` at the same path fails with

```text
fatal: '<path>' is a missing but already registered worktree;
use 'add -f' to override, or 'prune' or 'remove' to clear
```

Do **not** run `git worktree prune` automatically to smooth this over: prune also
deletes the registration of a worktree that the user moved with `mv` and has not
repaired (fact 3), which would destroy a working directory.  Let the add fail and
make sure git's own message reaches the user, since it names the two ways out.
§7 removes the cause.

### 5.8 An unborn HEAD

**Decided: not supported.**  A repository with no commit is refused, in every
mode, with an error.

Detect it before any other work, alongside the other local checks
(git-new-branch:139-155), with `git rev-parse --verify --quiet HEAD`, and say
what is wrong: the repository has no commit, so there is nothing to branch from;
commit something first.  Exit 1, before the `git pull`, so the refusal costs no
network access.

This removes what would otherwise be the plan's most version-dependent corner:
`git worktree add -b` succeeds on an unborn HEAD in git 2.53 but fails in
versions below the `--orphan` of 2.42 (fact 7), which is above the 2.31 that
§5.5 requires.  Refusing outright makes the behavior the same on every supported
git, and it costs the user nothing that a first commit does not fix.  Today's
script creates such a directory by accident, through `cp` plus
`git checkout -b`; that is a behavior change to note in the commit message.

### 5.9 Optional hardening: a branch name that begins with `-`

Today's `git checkout -b -n` and the new `git worktree add -b -n` both fail in
`git branch`'s option parsing (fact 11).  If it is worth fixing, the dash-safe
sequence is `git worktree add -q --no-checkout --detach "${BRANCHDIR}" HEAD`,
then `git -C "${BRANCHDIR}" update-ref "refs/heads/${BRANCHNAME}" HEAD`, then
`git -C "${BRANCHDIR}" symbolic-ref HEAD "refs/heads/${BRANCHNAME}"`: every
refname there begins with `refs/`, so no argument can be read as an option.  Out
of scope for the conversion; worth recording as a follow-up.

### 5.10 Option parsing and mode selection

The usage line becomes
`Usage: ${SCRIPT_NAME} [--clean | --copy] NEWBRANCHNAME`, and the
`[ "$#" -ne 1 ]` test (git-new-branch:65-68) becomes a small option loop:

* `--clean` and `--copy` set the mode.  Giving both is a usage error, whichever
  order they come in, because there is no sensible resolution: they ask for
  opposite things.  Repeating one is harmless and accepted.
* `--` ends option parsing, so a branch name that begins with `-` can be given.
  (It still has to survive `git worktree add -b`; see §5.9.)
* Any other argument that begins with `-` is a usage error, rather than being
  taken as a branch name.  A typo such as `--cleann` must not silently create a
  branch of that name.
* Options precede the branch name.  Exactly one non-option argument is required,
  as today.
* Keep the mode in one variable with three values, and select on it once, at the
  point where the three implementations diverge.  Everything before that point
  (§2's last paragraph) is common, so the checks and diagnostics cannot drift
  apart between modes.

No environment variable to change the default: the modes are per-invocation
decisions, and the README's environment variables are all about configuring
tools, not about choosing what a command does.  A `--inherit` spelling for the
default is not worth adding until someone needs it in a script.

### 5.11 `--clean`

One command:

```sh
git worktree add -q -b "${BRANCHNAME}" "${BRANCHDIR}"
```

With checkout this time, and no `${BRANCH_TMPDIR}`, no rename, and no index to
install: git writes the tracked files from the shared object store and the index
that matches them.

This is the one mode where the worktree is created directly at the final name
with nothing to follow it, so the "nothing appears under the real name until it
is complete" property of §5.3 rests entirely on `git worktree add` being one
fast command.  That is acceptable here -- it takes well under a second, and the
§5.6 cleanup covers a failure or a signal -- and it is why the default mode,
whose copy takes minutes, does the work under the temporary name instead.

**Decided: `--clean` is refused in a repository with submodules**, with a message
naming `--copy` as the mode that works there.

The case for allowing it is real, and worth recording: `git worktree add` in a
submodule repository does *not* break anything -- the fatal state of fact 16
comes from *copying* a submodule's `.git`, which this mode never does -- and an
unpopulated submodule is an ordinary git state, exactly what a plain
`git clone` without `--recurse-submodules` leaves.  The user asked for a clean
tree, and this would give one.

It is refused anyway, for two reasons:

* **One rule instead of two.**  Worktrees are not used for a repository with
  submodules, in any mode.  The default mode already falls back to a full copy
  for exactly this reason (§4.3); letting `--clean` produce a worktree there
  would answer the same limitation two different ways, and would need its own
  paragraph in the README and its own set of tests.
* **The repair path is the hazard.**  A directory whose submodules are empty
  cannot be built in, which is what these directories are for, and the only way
  to populate them -- `git submodule update --init` -- gives every worktree of
  the repository one shared submodule checkout, with one HEAD and one index
  (fact 16).  So the mode would hand the user an incomplete directory whose
  completion leads into the branch confusion this package exists to prevent.  A
  refusal that names `--copy` costs one line of output and leads somewhere that
  works.

The message must not pretend the alternative is equivalent.  `--copy` is the
*most* expensive mode, and a user who asked for `--clean` was asking for the
cheapest -- so say what the trade is: that this repository has submodules, that
a worktree cannot hold them (naming no git version, since git may fix this), and
that `--copy` works but copies the whole directory including `.git`.  A user who
does want an uninitialized-submodule worktree can still run `git worktree add`
directly; this package's commands produce complete working trees.

### 5.12 `--copy`

Today's code, kept: `\cp -Rp -- .` of the whole directory including `.git` into
`${BRANCH_TMPDIR}`, then `git checkout -b` in the copy, then `mv` to
`${BRANCHDIR}` (git-new-branch:245-269 as it stands).  `mv` is safe here because
the copy is an independent clone rather than a registered worktree (fact 3).
The `${TMPDIR_TO_CLEAN}` cleanup that the current script has is exactly right for
this mode and stays as it is.

**Decided: `--copy` is permitted from a clone and refused from a linked
worktree.**  Copying a worktree would produce the aliasing of fact 9 -- a
directory whose `.git` file names the source worktree's administrative directory,
sharing one HEAD and one index -- so `--copy` keeps the refusal that
`check_git_dir_is_directory` already makes from a linked worktree (§6.1), whose
message names the main working tree as the place to run it.  The guard runs
before the `git pull` and the remote queries, so a refusal costs no network
access and no copying.

**This refusal has a sharp edge, and it is the worst corner of the plan.**  The
same test also governs the default mode's submodule fallback, and that
combination is reachable: take a repository whose branch directories are already
worktrees, add a submodule to it, and from then on `git-new-branch` refuses in
*every* branch directory -- the default mode falls back to the copy (§4.3), the
copy refuses from a worktree, and `--clean` refuses in a submodule repository
(§5.11).  The command works only from the main clone.  That is a command
becoming unusable from exactly the directories this package tells the user to
work in.

It is still the right refusal, because each alternative is worse: copying would
alias the source's HEAD and index (fact 9), and switching silently to `--clean`
would drop the local changes that §4.1 requires the command to carry.  But the
message must earn it -- name the main clone by path, say why (the repository has
submodules and this directory is a linked worktree), and say that running the
command there works.  A bare refusal here would be a dead end.

A way out exists -- `git clone --local` of the common dir, then the
working-tree copy of §5.1 over it -- but it is a new code path.  Recorded as
item 6 of §10.1, flagged there as the deferred item a user is most likely to
hit.

### 5.13 Update the header comment

git-new-branch:1-15 must document the three modes of §2: that by default the new
directory is a linked worktree sharing the object store, with the same contents
as the source including uncommitted and untracked files; that `--clean` gives a
worktree holding only a clean checkout of HEAD; and that `--copy` gives an
independent clone, which is also what a repository with submodules gets
automatically (§4.3).  It must also say that the script now writes into the
existing clone (a branch ref and a `.git/worktrees` entry), where before its only
effect was to create a new directory, and that a repository with no commit is
refused (§5.8).  "Every effect of this script is local" remains true and worth
keeping.

#### Warn against deleting or moving the new directory

The header comment must also tell the user what *not* to do with the directory it
just created, because both obvious file-system operations are wrong on a worktree
and neither says so at the time:

* **Do not `rm -rf` it.**  That leaves a stale registration under
  `.git/worktrees/` and, worse, leaves the branch ref, so the branch name stays
  taken and `git-new-branch` later refuses to reuse it (fact 4, §5.7).  Point at
  `git-remove-branch-directory` (§7), which is the counterpart of this command.
* **Do not `mv` it.**  The worktree keeps working, so nothing looks wrong, but its
  registration still names the old path; `git worktree list` marks it `prunable`,
  and the `git worktree prune` that `git gc` eventually runs deletes the
  administrative directory and kills the worktree (fact 3).  Point at
  `git worktree move`, and at `git worktree repair` for a directory already moved.

Say plainly that this applies to the worktree modes -- the default and `--clean`
-- and **not** to `--copy`, whose directory is an independent clone that may be
deleted or moved with ordinary file-system commands, as every branch directory
created by earlier versions of this script may be.  A warning that overreaches
would teach users to distrust the accurate part of it.

The same two warnings belong in the README (§8), where a user reads before
creating a directory rather than after.  Do not print them on every successful
run: `git-new-branch` is run constantly, the message would be noise, and the
information is needed at deletion time, not at creation time.  The success line
stays as it is.

## 6. Ripple effects on the other commands

### 6.1 `git-checkout-branch` must change too (forcing constraint)

Once `git-new-branch` produces worktrees, a user will run `git-checkout-branch`
from inside one.  `git-checkout-branch` still does `\cp -Rp -- .`
(git-checkout-branch:345), which in a worktree copies the `.git` **file** and
produces a directory that shares the source worktree's git dir, HEAD, and index
(fact 9).  The subsequent `git checkout -b` in the copy would move the *source*
worktree's HEAD.  This is silent corruption, so it cannot be left for later.

**Decided: the interim refusal in the same commit that changes
`git-new-branch` (step 2 of §10), then the conversion in the next commit
(step 3).**  It keeps each commit small, which matches this repository's history,
and it never leaves a window in which the corruption is reachable.  The rejected
alternative was to convert both at once.

#### The interim refusal (step 2)

Both branch commands already call `check_git_dir_is_directory`
(remote-functions.sh), which refuses when the top level's `.git` is not a
directory -- a submodule's working tree or a linked worktree, because `cp -Rp`
of either aliases the source's HEAD and index -- and which, for a linked
worktree, names the main working tree as the place to run the command.  Step 2
narrows that guard in `git-new-branch` only, for example with an argument that
lets the caller accept a linked worktree:

* In the default mode and `--clean`, a linked worktree is accepted: neither mode
  copies `.git`.
* Under `--copy`, a linked worktree is still refused (§5.12).
* A submodule's working tree is still refused, in every mode.

`git-checkout-branch`'s call is left alone until step 3, so it keeps refusing a
linked worktree, with the existing message.

* This makes `git-checkout-branch` temporarily unusable from a directory that
  `git-new-branch` created -- which is the price of landing the two changes
  separately, and it is a refusal rather than corruption.
* **Therefore steps 2 and 3 must reach users together.**  Step 2 starts creating
  the very directories from which `git-checkout-branch` refuses, so the interval
  between them is an interval in which the everyday workflow is broken.  Two
  commits, reviewed separately, is the point; two *releases* is not.  Do not
  tag, push to a branch others track, or announce the change between them.  If
  step 3 turns out to need more work than expected, the right move is to hold
  step 2 back, not to ship it alone.

tests/test-git-checkout-branch.sh already asserts the refusal from a linked
worktree; step 3 inverts that expectation.  tests/test-git-new-branch.sh
asserts the same refusal for `git-new-branch`; step 2 inverts it for the default
mode and `--clean` and keeps it for `--copy`.

#### The conversion (step 3)

**Decided: outside a submodule repository, `git-checkout-branch` never carries
the current working tree's local changes.**  Its new directory is a fresh
checkout of the branch: no copy
step, no index to install, no temporary directory, and no `--clean`/`--copy`
options.  One command replaces the copy and the checkout:

```sh
git worktree add -q "${BRANCHDIR}" "${CHECKOUT_START_POINT}"
```

with checkout, and without a start point when the branch already exists locally,
as git-checkout-branch:354-358 decides today.  Its `find_branch` logic, its
upstream configuration (git-checkout-branch:373-380), and all of its diagnostics
survive unchanged.  This is the shape of §5.11, which makes `git-new-branch` the
only command in the package that carries local changes forward -- the command
where §4.1 requires it, because a new branch continues the work in hand, whereas
checking out an existing branch starts from what that branch contains.

That is a **behavior change**, because today's code does carry local changes,
as a side effect of how it gets a cheap clone rather than by intent:

* `\cp -Rp -- .` (git-checkout-branch:345) copies untracked and ignored files,
  and the following `git checkout` never removes them, so today's new directory
  inherits the source's build output and `.venv`.  After the conversion it does
  not, and the first build in a checked-out branch directory is a full one.
* Uncommitted modifications to tracked files are carried too, since
  `git checkout` preserves the ones that do not differ between the branches --
  and *fails* on the ones that do, with "Your local changes to the following
  files would be overwritten by checkout".  So the conversion also removes a
  failure mode: today a dirty working tree can make `git-checkout-branch` fail
  after it has already copied the whole directory.

Both belong in the commit message and in the README's `git-checkout-branch`
bullet.

**Submodules:** in a repository with submodules (§4.3), `git-checkout-branch`
keeps today's code unchanged -- `cp -Rp`, `git checkout`, and `mv` -- just as
`git-new-branch` falls back to its `--copy` path.  A submodule repository's
branch directories are full copies, so today's code works there as it always
has.  The cost is that, in such a repository, the command still carries local
changes along.  A fresh `git clone --local` would avoid that, but it would be a
third way of creating a branch directory, used nowhere else; §10.1 item 6
records it.

Two new things to handle:

* **"branch is already checked out in another worktree."**  The clone model
  permitted the same branch in two directories; the worktree model does not.
  Let `git worktree add` refuse, and make sure its message, which names the
  directory that holds the branch, reaches the user.  An earlier check would
  only save the `git pull` and the remote queries in a rare case.  This is a
  real behavior change for a user who relied on two directories for one
  branch.
* The `--force` escape hatch is deliberately *not* offered: two working trees of
  one branch is precisely the branch confusion this package exists to prevent.

Also update the §5.5 version check for this command, so that `git-new-branch` and
`git-checkout-branch` make the same demand with the same message, from the shared
helper of step 1 of §10.  The submodule condition is shared too: in a
repository with submodules, both commands keep today's code.

### 6.2 `git-orphaned-branches`

**Most of what this command needs is independent of the worktree conversion and
is already implemented**: it recognizes a working tree whose `.git` is a file,
rather than silently ignoring it; it never reports a directory whose `.git` is
the repository another live worktree depends on (`live_dependent_worktree`);
it issues one `ls-remote` per remote URL, so `rmgob` over twenty branch
directories of one project makes one query rather than twenty; and it has the
`--remove` option below.

A further simplification becomes possible once the branch directories are
worktrees, and is worth recording rather than doing: `git worktree list
--porcelain` is an authoritative inventory of one repository's branch
directories, so the recursive filesystem walk -- which descends into every
`node_modules` and package cache under the current directory, as its own
comments lament -- could be skipped for the worktrees of repositories already
found.  It cannot replace the walk, which spans repositories the command was
never told about and also finds `--copy` directories and `.project`-only ones.
§10.1 item 7.

#### `--remove`

**Already implemented**: `git-orphaned-branches --remove` scans, then runs
`git-remove-branch-directory` on each directory it would report, and the
README's `rmgob` alias is `git-orphaned-branches --remove`.  Nothing here
changes it; it removes worktrees once §7 teaches `git-remove-branch-directory`
to.

#### Do not report a directory that hosts another worktree

**Already implemented** (`live_dependent_worktree`), since a user with hand-made
worktrees needs it today.  Recorded here for the reason the conversion makes it
essential: after this change the case is no longer exotic.  Run
`git-new-branch` from `REPO-branch-feature` and the new worktree is registered
inside `REPO-branch-feature/.git` (§5.5's last paragraph -- the host is the
existing clone, not a separate bare repository); when `feature` is merged and
deleted upstream, an unfiltered `--remove` would delete the repository that the
sibling's `.git` file points into, taking out a working tree that may hold
unpushed work and that the user never named.

That filter and §7.4's guardrail overlap deliberately: the filter keeps the host
out of the list, and the guardrail refuses it even when a user names it directly.

### 6.3 `is-deleted-branch`

Nothing here.  The code works on a worktree unchanged (fact 2).  Its
documentation already says "working tree" rather than "clone" for status 2, and
its body is already the function `is_deleted_branch` in remote-functions.sh, with
the command a thin wrapper.

### 6.4 `git-push-to` and `git-pull-from`

Nothing is needed for **correctness**: pulling between two worktrees of one
repository works (fact 10), and `check_upstream` is about configuration, not
layout.  Add a test that pushes and pulls between two worktrees, to keep it that
way.

### 6.5 `compile-project`, `relative-path`

Unaffected.

## 7. The teardown story (the biggest gap)

Today `rm -rf REPO-branch-X` removes the branch completely, because the directory
*is* the repository.  With worktrees it leaves two things behind (fact 4):

1. a stale `.git/worktrees/REPO-branch-X` registration, which makes a later
   `git-new-branch X` fail in the way §5.7 describes, and
2. the branch ref `refs/heads/X` in the shared repository, so `git-new-branch X`
   fails with "branch X already exists in this clone".

**Does `git worktree prune` address problem 1?**  Yes -- that is what it is for,
and it is what git's own message advises -- but it does not get the user anywhere
on its own, for two reasons:

* **Problem 2 is the failure the user actually sees.**  `git-new-branch` tests for
  an existing local branch early (git-new-branch:147-150), long before it touches
  a worktree, so with both problems present the run stops at "branch X already
  exists in this clone" and the stale registration never gets a chance to
  complain.  Pruning fixes problem 1 and changes nothing observable; the branch
  ref has to go too.  Problem 1 alone is reachable only in the reverse order --
  the ref deleted, the registration left -- which is not what an inadvertent
  `rm -rf` produces.
* **Prune is not targeted, and its collateral damage is unrecoverable.**  It
  removes *every* registration whose directory is missing, including that of a
  worktree the user moved with `mv` and has not repaired.  Verified (fact 17):
  after such a prune, `git worktree repair` cannot restore it -- the directory
  keeps its files but is no longer a working tree, and the way back is to add a
  worktree again and move the files.  So prune is a fine thing for a user to run
  deliberately, having read git's message, and a bad thing for a script to run on
  their behalf (§5.7, §7.2).

So removing worktree branch directories with `rm -rf` leaves debris that
accumulates over time.  Sharing the refs is accepted (§4.2), which is precisely
why this needs an answer: the shared branch namespace is now the thing
that outlives a deleted directory.

**Decided: `git-remove-branch-directory` removes worktrees too.**  It is the natural
counterpart to `git-new-branch`, it keeps the branch namespace from filling with
names whose directories are gone, and it keeps `git branch --delete` out of the
documented workflow, which the work style and the guard hook both discourage.
The rejected alternative was to leave removal to the user and document the two
extra commands.

**The script's clone-only form already exists**, with the interface of §7.1,
the two safety checks of §7.3 with their separate waivers, the guardrails of
§7.4 (including the host guardrail), the `--remove` option of §6.2, and the
`rmgob` change -- because the safety half matters *more* in the clone model,
where `rm -rf` destroys the objects along with the directory and unpushed
commits are gone irrecoverably.  Today it refuses any directory whose `.git` is
a file.  So what the sections below add is only the worktree-specific behavior:
removing a linked worktree with `git worktree remove --force` instead of
refusing it (a submodule's working tree, whose `.git` is also a file, is still
refused), deleting the branch ref, removing the one administrative directory
instead of pruning, and the §7.5 already-deleted case.  The interface, the
checks, the messages, and the tests are already in place.

### 7.1 Interface

The existing interface gains one option:

```text
git-remove-branch-directory [--force] [--force-uncommitted] [--force-unpushed]
                            [--repository DIR] DIRECTORY...
```

`--repository` names a working tree of the repository that a DIRECTORY belongs
to, and is needed only for a DIRECTORY that no longer exists (§7.5); it defaults
to the current directory when that is a working tree.

### 7.2 What it does

For each DIRECTORY, in this order -- everything that needs the repository is read
*before* anything is removed, because afterward the information is gone:

1. **Check the argument.**  DIRECTORY must be a directory, or else not exist at
   all -- the §7.5 case, which step 2 handles separately.  A DIRECTORY that
   exists and is not a directory is an error.
2. **Gather every fact that the removal will destroy**, by one of two routes.

   *DIRECTORY exists.*  Classify it by its `.git` and by
   `git -C DIRECTORY rev-parse --path-format=absolute --git-dir` and
   `--path-format=absolute --git-common-dir`:
   * a **clone**: `.git` is a directory.  This covers the pre-worktree
     directories, a `--copy` directory, and the §4.3 submodule fallback.
   * a **linked worktree**: `.git` is a file, and the git dir differs from the
     common dir.
   * **not a repository** at all, which is the `.project`-only directory that
     `git-orphaned-branches` also reports.
   * Anything else is refused, as today.  In particular a **submodule's working
     tree** has a `.git` file but a git dir equal to its common dir, so comparing
     the two git dirs alone would classify it as a clone and `rm -rf` it.
     Removing one is `git submodule deinit`'s job, not this command's.

   Then read the branch name from `git -C DIRECTORY symbolic-ref --quiet HEAD`
   and keep the git directory from above; step 5 needs it.

   *DIRECTORY does not exist.*  None of those `git -C DIRECTORY` commands can
   run, so take every fact from the host instead: in the repository that
   `--repository` names (§7.5), find the entry of
   `git worktree list --porcelain` whose `worktree` line is DIRECTORY's absolute
   path, and read the branch from that entry's `branch` line.  Verified: the
   listing of a missing worktree still carries `branch refs/heads/NAME` along
   with `prunable gitdir file points to non-existent location`, so both facts
   survive.  A missing directory is necessarily a linked worktree -- a clone
   that is gone took its own refs with it and leaves nothing to clean up -- so
   when no entry matches, report that there is nothing to do and move to the
   next DIRECTORY rather than failing.

   The administrative directory cannot be derived from DIRECTORY's basename,
   which differs from it after a `git worktree move` (fact 15), and the porcelain
   listing does not name it.  Find it by scanning
   `<common-dir>/worktrees/*/gitdir` for the file whose contents name
   `DIRECTORY/.git` -- the mapping git itself follows.  If none is found, refuse
   rather than guess.
3. **Run the safety checks of §7.3**, each unless its own flag was given.  A
   DIRECTORY that does not exist has nothing to check: there is no working tree
   to be dirty, and the unpushed-commits check still applies, since its branch
   ref is about to go.
4. **Remove the directory**, unless it is already gone.  **A linked worktree goes
   through `git worktree remove --force`; anything else goes through `rm -rf`**
   -- a clone and a non-repository alike, since neither has a registration to
   unwind and `rm -rf` is exactly what today's `rmgob` does to them.  The
   `--force` here is git's, not ours: git refuses to remove a worktree that has
   any modification, including the ignored build output these directories are
   full of, and §7.3 has already made our own decision about what is safe to
   delete.
5. **If `git worktree remove` failed, or the directory was already gone**,
   `rm -rf` the directory (if any) and then `rm -rf` the administrative directory
   that step 2 found.  This is the step that replaces `git worktree prune`.
6. **For a linked worktree, delete the branch:**
   `git -C HOST update-ref -d "refs/heads/${BRANCH}"`, where HOST is the
   repository that hosts it.  Use `update-ref`, not `git branch --delete`: it
   takes a full refname, so a branch name beginning with `-` cannot be read as an
   option (fact 11).  For a clone, delete nothing -- its refs lived in the
   directory that was just removed.
7. **Report what happened** for this DIRECTORY, per §7.3's message rules, and
   continue with the next one.

**No `git worktree prune`.**  Prune removes every registration whose directory
is missing, including that of a worktree the user moved with `mv` and has not
repaired -- destroying a working tree, which is the hazard §5.7 declines to
risk and fact 17 shows to be unrecoverable.  Step 5 removes exactly the one
registration this invocation is responsible for, so nothing needs pruning.
§5.6's cleanup takes the same approach for the same reason.

### 7.3 Safety checks

The two existing checks, each waived by its own flag, apply to a linked worktree
as well.

* **Uncommitted work in tracked files** -- unchanged.
* **Commits that no other ref holds** -- waived by `--force-unpushed`.  For a
  **clone**, the existing check stays as it is: `rm -rf` destroys every ref of
  the clone, so it asks whether any commit reachable from any ref is held by no
  remote-tracking ref and no tag.
  For a **linked worktree**, removal deletes one ref, so ask about that ref
  alone, in the repository that hosts the worktree:
  `git -C HOST rev-list --count "refs/heads/${BRANCH}" --not
  --exclude="refs/heads/${BRANCH}" --all` must be 0.  A remote-tracking ref
  counts as holding the commits, which is right: those commits are on the
  remote.  Verify the `--exclude`-before-`--all` behavior during
  implementation.

  The messages should reflect a difference in severity: for a worktree the
  objects survive in the shared store until `gc`, so `git fsck --lost-found`
  can still recover them for a while (the ref's reflog cannot: `update-ref -d`
  deletes it along with the ref); for a clone, nothing recovers them.

Two `--force` flags are now involved, and the documentation must not confuse
them: **ours** gates these checks, while **git's**, in
`git worktree remove --force` (§7.2 step 4), is passed unconditionally so that
git does not refuse over the ignored build output these directories are full of.
Ours is the only one the user controls.

### 7.4 Guardrails on `rm -rf`

Unchanged: the script already refuses, without any waiver, the main working tree
of a repository that has live linked worktrees (removing it breaks every one of
them -- §4.2) and the current directory or any ancestor of it.

### 7.5 Cleaning up after a directory that is already gone

**Decided: yes.**  A DIRECTORY that does not exist is accepted, provided it is
still a registered worktree, and the script removes the registration and the
branch ref -- the same final steps as an ordinary removal, with the file-system
step skipped.

This is the case a user most often needs help with: someone who already ran
`rm -rf` on a branch directory, inadvertently or out of habit, and now has the
two leftovers of §7.  Without this, the answer for them is `git worktree prune`
and a `git update-ref`, which is the pair of raw commands this script exists to
replace -- and the prune half carries the unrecoverable collateral damage of
fact 17.

The obstacle is finding the host repository, since `git -C DIRECTORY` needs the
directory.  Resolve it explicitly rather than by guessing:

* Add `--repository DIR`, and default it to the current directory when that is a
  working tree.  Match the argument's absolute path against
  `git worktree list --porcelain` there.
* A missing DIRECTORY with no repository to consult stays an error, with a
  message that says to name one.

Rejected: searching the sibling `*-branch-*` directories for a repository whose
`worktree list` mentions the missing path.  It would usually work -- `rmgob` runs
in the directory that holds them all -- but "usually" is the wrong standard for
a command that deletes refs, and a wrong guess would delete a ref in a
repository the user did not name.

### 7.6 Tests

In tests/test-git-remove-branch-directory.sh: removing a linked worktree deletes
its branch ref and leaves no administrative directory and an intact main
repository; after removal, `git-new-branch` of the same name succeeds again --
which is the whole point; a submodule's working tree is still refused and left
intact (§7.2); and the unpushed-commits check of a linked worktree asks about
its own branch alone, so it refuses for an unpushed commit on that branch and
not for one on another branch of the host repository.

In tests/test-git-checkout-branch.sh, for §6.1's conversion: the new directory
holds a clean checkout -- `git status --porcelain --ignored` in it is empty
although the source has an uncommitted modification, an untracked file, and an
ignored file -- and the source directory is unchanged; a dirty source that would
have made today's `git checkout` fail now succeeds; a submodule repository takes
today's code path and gets an independent clone; and checking out a branch
that another worktree already holds is refused with git's message, which names
that directory.

In tests/test-git-orphaned-branches.sh: `--remove` removes an orphaned linked
worktree, deleting its branch ref, and leaves the worktree's host in place.

For §7.5: a path that no longer exists but is still registered
is cleaned up (registration and ref both gone, `git-new-branch` of that name
succeeds again), a moved-but-unrepaired worktree elsewhere in the same repository
is *not* disturbed by that cleanup (which is what distinguishes it from
`git worktree prune`; fact 17), and a missing path with no repository to consult
is an error.

## 8. Documentation changes

* **README.md**
  * The `git-new-branch` bullet: the new directory is a worktree sharing the
    object store, with the same contents as the source directory -- and the three
    modes of §2, with `[--clean | --copy]` in the command's signature, since the
    README's command list is where a user looks for a command's options.
  * The `rmgob` alias is already `git-orphaned-branches --remove`, and the
    `git-orphaned-branches` and `git-remove-branch-directory` bullets already
    exist.  Add to the `git-remove-branch-directory` bullet that it removes a
    worktree with `git worktree remove` and anything else with `rm -rf`.
  * "One branch per directory": rewrite the disk-usage disadvantage with the
    §1.1 numbers -- the objects are shared, the working tree and build output are
    not.  The "faster builds" advantage is unchanged, since untracked files are
    inherited.  Add the second benefit (§1.2): because the branch directories of
    one repository are related, `git-push-to` fetches from a remote once for the
    whole group rather than pulling once per directory.
  * A new subsection on the worktree layout: `.git` is a file, so a tool that
    tests `-d .git` no longer recognizes a branch directory (§4.4); config,
    hooks, and refs are shared; repositories with submodules get a full copy
    (§4.3).
  * **Do not delete or move a branch directory with file-system commands**, the
    same warning that §5.13 puts in the header comment: `rm -rf` leaves the
    branch ref and a stale registration (use `git-remove-branch-directory`), and
    `mv` breaks the registration in a way that only surfaces at the next
    `git gc` (use `git worktree move`, or `git worktree repair` afterward).  Say
    that this is about the worktree modes and not about a `--copy` directory or
    one created by an earlier version, which are independent clones.  The same
    subsection also covers the main working tree, whose deletion or move breaks
    every worktree that depends on it (§4.2).
  * The minimum git version (§5.5).
* **git-new-branch** header (§5.13) and **git-checkout-branch** header (§6.1).
* **A terminology sweep, throughout.**  Git's own term is **working tree** -- the
  glossary defines it, and `--work-tree`, `GIT_WORK_TREE`, `core.worktree`, and
  `git worktree` all spell it that way; git's two kinds are the **main working
  tree** and a **linked working tree** (or just "worktree").  "Working copy" is
  not a git term at all: it is Subversion's, where it means the whole checkout
  directory *including* its administrative data, which is exactly the
  self-contained thing a branch directory stops being under this change.  So the
  README's "a separate working copy (a.k.a. \"clone\")" is about to become false
  rather than merely informal, and every place that equates a branch directory
  with a clone -- the README's principles list, the command descriptions, and the
  script headers -- should say "working tree", reserving "clone" for a directory
  that really is one (a `--copy` directory, or one from an earlier version).
  This plan's own prose has been swept the same way.
* tests/test-env-vars-documented.sh scans the README for environment variables;
  no new variables are planned, so it needs no change.

## 9. Tests

Change:

* **tests/test-git-new-branch.sh**: the existing assertions on directory
  creation, on the checked-out branch, and on all four collision checks stay
  valid.  Add to the `-TMP` leftover assertions that no worktree registration and
  no branch ref are left behind.
* **tests/test-branch-interrupt.sh**: `git-new-branch` still runs `cp`, so the
  fake-`cp` injection (line 62) still fires.  Extend the assertions: besides no
  `${BRANCHDIR}-TMP`, there must be no `${BRANCHDIR}`, no entry in
  `git worktree list`, and no `refs/heads/BRANCH`; and a subsequent
  `git-new-branch` of the same name must succeed.  Add a second interruption
  point, after the worktree exists, with a fake `git` on PATH that passes
  everything through but interrupts on `worktree add`, so that the §5.6 cleanup
  of a registered worktree is exercised.

Add, for the three modes of §2:

* **Option parsing** (§5.10): `--clean` and `--copy` together are a usage error
  in either order; an unknown option such as `--cleann` is a usage error and
  creates no branch; `--` lets a branch name that begins with `-` through to the
  place where §5.9 says it fails; an option after the branch name is a usage
  error; and each usage error leaves no directory behind.
* **`--clean`** (§5.11): the new directory is a worktree,
  `git status --porcelain --ignored` in it is *empty* even though the source has
  a staged change, an unstaged change, an untracked file and an ignored file;
  and the source directory is unchanged. This is the one place where the
  assertion is the opposite of the default mode's inheritance test, so write the
  two against the same fixture.
* **`--copy`** (§5.12): the new directory is an independent clone -- its `.git`
  is a directory, its `--git-common-dir` differs from the source's, and `git
  worktree list` in the source does not mention it -- and its contents match the
  source, as the default mode's fidelity test asserts for its own mode.
* **`--copy` from a linked worktree is refused** (§5.12), with a message naming
  the main working tree, and creates no directory. Same for the default mode in
  a submodule repository whose source directory is a worktree, which reaches the
  same refusal.
* **`--clean` in a submodule repository is refused** (§5.11), with a message
  naming `--copy`, and creates no directory.  In the same fixture, `--copy`
  succeeds and the default mode falls back to the copy silently (§4.3), so the
  three modes' answers to one repository are asserted together.

Add:

* **Inheritance fidelity** (the §4.1 requirement).  A source with a staged
  change, an unstaged change, an uncommitted deletion of a tracked file, an
  untracked file, an untracked directory, and an ignored file: assert that
  `git status --porcelain=v1 --ignored` in the new directory equals the source's,
  and that `diff -r --exclude=.git` reports no difference.
* **The objects are shared**: the new directory's `.git` is a file, it contains
  no `objects` directory of its own, and `git -C NEW rev-parse --git-common-dir`
  resolves to the same directory as `git -C SOURCE rev-parse --git-common-dir`.
* `git worktree list` in the main clone lists the new directory with the new
  branch, and its administrative name has no `-TMP` suffix (fact 15).
* `git-new-branch` run from inside a worktree branch directory creates a sibling
  worktree registered in the main repository, not a nested one, and copies that
  worktree's index rather than the main clone's (§5.4).
* After `rm -rf` of a worktree branch directory, `git-new-branch` of the same name
  fails with an actionable message (§5.7), and -- once §7 lands -- the removal
  script makes the name reusable.
* A repository with a submodule takes the full-copy fallback and the new directory
  is usable: `git status` succeeds in it, and the submodule's git dir is *not*
  shared with the source (§4.3).
* A repository with no commit is refused, in each of the three modes, with the
  §5.8 message and a nonzero status, and creates no directory.
* `git-orphaned-branches` lists a worktree branch directory whose branch was
  deleted on the remote (§6.2).
* `git-push-to` and `git-pull-from` work between two worktrees of one repository
  (§6.4).
* Too old a git is refused with the §5.5 message and a nonzero status, and
  creates no directory.  If no old git is available, drive it with a fake `git`
  on PATH that reports an old version for `git version` and passes everything
  else through.

## 10. Suggested commit sequence

Each step is independently reviewable and leaves the tree working, which matches
this repository's history of small PRs.

1. **remote-functions.sh: the worktree-aware helpers.**
   `require_git`, moved from `git-outgoing` (§5.5), and the cleanup helper of
   §5.6, with tests in tests/test-remote-functions.sh.
2. **`git-new-branch`: create a worktree.**  §5 in full -- the default mode, the
   `--clean` and `--copy` options (§5.10-§5.12), the §4.3 submodule fallback that
   `--copy` also implements, and the §5.8 refusal -- plus the interim refusal in
   `git-checkout-branch` (§6.1), plus the README and header changes, plus the
   tests of §9.  If this commit wants to be smaller, land the default mode and
   `--copy` first (`--copy` is the existing code, so the two together are the
   change that must not regress) and `--clean` immediately after; do not ship the
   default mode without `--copy`, since `--copy` is the escape hatch for anything
   the worktree path handles badly.
3. **`git-checkout-branch`: create a worktree.**  One `git worktree add` with
   checkout, no copy at all (§6.1); narrows the interim refusal; handles "already
   checked out in another worktree"; keeps today's code for a submodule
   repository; documents the two behavior changes (no inherited build output, and
   no more "local changes would be overwritten" failure).
4. **Removal: the worktree half.**  Teach `git-remove-branch-directory` to
   remove a linked worktree with `git worktree remove --force` instead of
   refusing it (while still refusing a submodule's working tree, §7.2), delete
   the branch ref, remove the one administrative directory rather than prune
   (§7.2), and handle the already-deleted case (§7.5).

Risk and rollback: steps 2 and 3 are self-contained, and branch directories
created by the current version keep working, so old and new branch directories
coexist and a revert affects only directories created after it.

### 10.1 Deferred: not part of this change

**Decided: document these as future todos and implement none of them here.**  Each
is a genuine improvement, none is needed for the change to be correct or
complete, and each would enlarge a series that is already four steps.  Record them
where they will be found again -- an issue apiece, or a "Future work" list in the
README -- when the series lands.

1. **Relative worktree links.**  `worktree.useRelativePaths`, or
   `git worktree add --relative-paths` (git 2.48+), records the links between a
   worktree and its repository as relative paths, so moving the whole tree of
   branch directories keeps them working, where today it needs
   `git worktree repair` (§4.2, fact 3).  Deferred because it raises the version
   requirement well past the 2.31 of §5.5 -- or needs a version test and two
   code paths -- to fix a problem that `git worktree repair` already fixes.
2. **A dash-safe branch name.**  `git worktree add -b -n` fails in `git branch`'s
   option parsing, exactly as today's `git checkout -b -n` does (fact 11).  §5.9
   gives the three-command sequence that avoids it.  Deferred because it is a
   pre-existing limitation that this change neither causes nor worsens, and the
   sequence trades one clear command for three obscure ones.
3. **A cheaper copy.**  The default mode copies whole top-level entries, so it
   copies unmodified tracked content that the shared object store already holds
   (§4.1, last paragraph).  Letting `git worktree add` check out the tracked
   files and copying only the untracked and ignored entries would be faster.
   Deferred because enumerating untracked paths safely needs NUL-separated
   output that a POSIX `sh` cannot split (no `read -d ''`), which is a
   pathname-safety problem this package takes seriously; the whole-entry copy
   costs no more than today's code does.
4. **A shared bare repository** as the worktree host, instead of the existing
   clone's `.git` (§5.5's last paragraph, §11).  Deferred: it needs a migration
   and it redefines what the main working tree is.
5. **Batched pushes and connection reuse** in `git-push-to`.  Deferred as
   rejected-for-now rather than pending: batching the pushes would break the
   command's contract that each directory is pushed only if its own compilation
   succeeded, and connection reuse (`ControlMaster`) belongs in the user's SSH
   configuration.

6. **`git-new-branch --copy` from a linked worktree**, which §5.12 refuses
   because `cp -Rp` of a worktree would alias it (fact 9).  The reachable case is
   a submodule repository whose branch directories are already worktrees, where
   the default mode's fallback then refuses from every branch directory and works
   only from the main clone.  The fix is to clone the common dir with
   `git clone --local`, overlay the non-`.git` entries with the copy of §5.1,
   and create the branch there.  The same helper would let
   `git-checkout-branch` give a submodule repository a fresh checkout instead
   of today's copy (§6.1).  Deferred because it is a new code path with its own
   failure modes, and because the refusal names a directory that does work.

7. **`git worktree list` as an inventory** for `git-orphaned-branches` (§6.2).
   The command walks the filesystem for `*-branch-*` directories, descending
   into every `node_modules` and package cache below the current directory; for
   the worktrees of a repository it has already found, `git worktree list
   --porcelain` answers authoritatively and instantly.  Deferred because it
   cannot replace the walk -- which spans repositories the command was never
   told about, and also finds `--copy` directories and `.project`-only ones -- so
   it is an added fast path with its own consistency question (what to do when
   the two disagree), not a simplification.

8. **Fewer fetches among related worktrees** in `git-push-to` (§1.2).  Related
   worktrees share refs, so one `git fetch REMOTE` could update a whole group,
   with each directory then updated by `git merge --ff-only @{upstream}` when
   its branch has nothing its upstream lacks and `git pull` otherwise; and FROM's
   branch could be merged from the shared ref instead of fetched from FROM's
   directory.  Deferred because it saves a connection or two per run and needs a
   `related_worktrees` predicate (comparing
   `rev-parse --path-format=absolute --git-common-dir`), grouping by
   (repository, remote), a check that the fetch refspecs map each branch's
   upstream (`is_deleted_branch_tracking_refs`), and query-counting tests.
   Reproducing `git pull` for a diverged branch is not an option: it would mean
   reimplementing every setting `git pull` reads.

Item 5 is recorded so that a later reader does not have to rediscover why it was
not done; items 1, 2, 3, 4, 6, 7, and 8 are the ones worth revisiting, and
item 6 is the one a user is most likely to hit.

## 11. Alternatives considered

* **`git clone --local` (hardlinked objects).**  A local clone hardlinks
  `.git/objects`, so it saves about what this plan saves, while preserving every
  current semantic: independent refs and config (so §7 and §4.2 evaporate),
  `rm -rf` remains a complete removal, `.git` stays a directory, submodules keep
  working, and the same branch may be checked out twice.  Its weaknesses are that
  hardlinks do not cross filesystems and that `git gc` in either clone unlinks and
  rewrites packs, so the saving decays.  It is the cheaper conversion but not what
  was asked for; recorded in case the §7 and §4.3 costs are unattractive.
* **A clean worktree (no inherited files).**  Saves far more -- for
  `plume-scripts` the difference is most of 110 MB rather than 10 MB -- but it
  conflicts with the §4.1 requirement.  Rejected.
* **`git clone --shared` / `--reference` (alternates).**  Saves nearly as much and
  keeps refs independent, but `git gc` in the source repository can delete objects
  that only the borrowing repository references, which corrupts it.
  `--dissociate` avoids that and also the saving.  Rejected.
* **A separate shared bare repository** (`REPO.git` beside the branch
  directories, with every branch directory including main as a worktree of it).
  Tidier, and it removes the "do not delete the main working tree" hazard of
  §4.2, but it requires a migration and redefines what the main working tree is.
  Rejected for now, not foreclosed.  The plan as written needs no migration:
  `git-new-branch` works in any existing clone, and directories that earlier
  versions copied keep working untouched.
* **Batching `git-push-to`'s pushes** into one `git push REMOTE A B ...`.  It
  would save further connections, but the command promises that each directory is
  pushed only if its own compilation succeeded, and one push cannot honor that.
  Rejected; a user can set up SSH connection reuse (`ControlMaster`) instead.
* **Caching remote answers on disk between runs**, so that a second `rmgob` in the
  same minute asks nothing.  It saves more than batching does, but a stale cache
  answers "the branch still exists" for a branch that was deleted, or the reverse,
  and this package's commands are the ones that decide whether a directory may be
  deleted.  Rejected: the batching of §1.2 gets the same benefit within one run
  without ever answering from stale data.
