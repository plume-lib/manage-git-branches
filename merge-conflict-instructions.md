# Resolving merge conflicts

These instructions are for a `git merge` that stopped with conflicts.  HEAD
is the branch being merged into, and MERGE_HEAD is the commit being merged
in.  `git-push-to` gives these instructions to the AI agent that resolves
the conflicts, and they are also suitable for a person or an agent that
resolves conflicts interactively.

The goal is a merge that contains every change that HEAD made since the
merge base and every change that MERGE_HEAD made since the merge base,
combined so that they work together.

## Step 1:  learn what each side changed

Examine all the changes of both sides, not just the conflict regions:  git's
automatic merge of the text outside the conflict regions, and of the files
that have no conflicts, can be wrong too.

* `git log MERGE_HEAD..HEAD` lists the commits on HEAD, and
  `git log HEAD..MERGE_HEAD` lists the commits being merged in.  Their
  messages explain the intent of each change.
* `git diff MERGE_HEAD...HEAD` shows every change on HEAD since the merge
  base.
* `git diff HEAD...MERGE_HEAD` shows every change being merged in since the
  merge base.
* `git log --merge -p -- FILE` shows the commits on either side that changed
  a conflicted file.  `git show :1:FILE`, `git show :2:FILE`, and
  `git show :3:FILE` show its version in the merge base, on HEAD, and in
  MERGE_HEAD.

Read every hunk of both diffs.  If the diffs are too large for that, use
`git diff --stat` with the same arguments to list the changed files, and
read every hunk in each conflicted file and in each file that defines or
uses something that a conflicted file or the other side changes.

## Step 2:  resolve the conflicts

* A conflict region starts with a line `<<<<<<<` and ends with a line
  `>>>>>>>`.  It holds the text of HEAD; then, in the "diff3" conflict
  style, after a line `|||||||`, the text of the merge base; then, after a
  line `=======`, the text being merged in.  Remove every conflict marker
  line.
* Do not resolve a conflict, or a file, by taking one side's text and
  discarding the other side's, as `git checkout --ours` or `--theirs`,
  `git merge -X ours` or `-X theirs`, or rewriting the file from one parent
  would.  For each conflict, determine what each side changed relative to
  the merge base, and write text that makes both changes.  Taking one side's
  text is correct only if the other side's change is already present in it,
  or if the other side's change is obsolete; then say so.
* Keep every hunk that git merged cleanly, but edit any part of any file,
  including text outside the conflict regions and files that have no
  conflicts, wherever combining the two sides requires it:  for example,
  when one side renames a method or changes its signature and the other side
  adds a call to it, or when one side moves code that the other side
  changes.  Do not make changes that the merge does not require, such as
  refactorings or fixes of unrelated problems.
* Create or delete a file only if combining the two sides requires it.
* If you cannot resolve a conflict with confidence, say so rather than
  guessing.

## Step 3:  check that no change was lost

For each file that either side changed:

* `git diff HEAD -- FILE`, which shows what the merge adds to HEAD, should
  contain each hunk of `git diff HEAD...MERGE_HEAD -- FILE`, which shows the
  changes being merged in, possibly adapted to the changes on HEAD.
* `git diff MERGE_HEAD -- FILE`, which shows what the merge adds to
  MERGE_HEAD, should contain each hunk of `git diff MERGE_HEAD...HEAD -- FILE`,
  which shows the changes on HEAD, possibly adapted to the changes being
  merged in.

A hunk that is missing from either one is a lost change; restore it.

`git diff AUTO_MERGE` shows how the working tree differs from git's
automatic merge, which contains the conflict markers.  Each change that it
shows outside a conflict region must be one that combining the two sides
requires.  Investigate any other change; it usually means that the
resolution undid one side's work.
