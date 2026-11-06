# The format of `pr-status-config.json`

[`pr-status`](pr-status) (and [`cancel-blocked-ci`](cancel-blocked-ci), which
computes dependencies as `pr-status` does) reads the optional file
`pr-status-config.json` in the directory that holds the working copy
directories.  The file is hand-maintained.  It names the repositories to
report on and the documents to generate, and it records decisions and notes
that `pr-status` cannot compute from GitHub.

If the file does not exist, `pr-status` constructs a default config.  The
default config reports on each GitHub repository that at least 2 of the git
clones in the directory are clones of (or, if there is none, the one that the
most clones are clones of), and its only document is `pr-status.md`.  Writing
a config file is a way to choose the repositories, to name other documents,
and to record notes and decisions.

`pr-status` checks the whole file before it does anything else.  If the file
is not valid JSON or is not a valid config, `pr-status` reports every problem
that it finds, each with the config path of the value that it concerns, and
exits.  For example, a misspelled key is reported as
`repos.daikon.exclude is not a known key; did you mean "excluded"?`, and a
PR number written as a string is reported as
`repos.daikon.excluded.prs[0] is "512", not a PR number such as 527`.

`pr-status --print-config` prints the config that `pr-status` uses, as JSON,
with the defaults filled in, and does nothing else.  If there is no config
file, it prints the default config, which can be the starting point for a
config file.  It does not print a default branch that `pr-status` reads from
GitHub.

## Examples

The smallest config that reports on a repository gives the repository's
name and its GitHub slug:

```json
{
  "repos": {
    "daikon": {"gh": "codespecs/daikon"}
  }
}
```

This config uses every key at the top level and several optional keys in
each repository:

```json
{
  "order": ["daikon", "fjalar"],
  "repos": {
    "daikon": {
      "gh": "codespecs/daikon",
      "clone": "daikon",
      "prefix": "daikon#",
      "label": "Daikon",
      "node_prefix": "daikon_",
      "routine_files": ["CHANGELOG.md"],
      "excluded": {
        "prs": [512],
        "reason": "#512 is an experiment that will not land."
      },
      "extra_dependencies": [[530, 527]],
      "extra_external_dependencies": {"530": ["codespecs/fjalar#95"]},
      "titles": {"527": "Refactor the instrumenter"},
      "labels": {"527": "instrumenter refactoring"},
      "cluster_names": {"527": "instrumenter work"},
      "unblocked_notes": {"527": "needs a review from the instrumenter's author"},
      "detail_notes": {"530": "Rebase after #527 lands."}
    },
    "fjalar": {
      "gh": "codespecs/fjalar",
      "clone": "fjalar",
      "prefix": "fjalar#",
      "label": "Fjalar",
      "node_prefix": "fjalar_"
    }
  },
  "documents": {
    "dependencies": "pr-status.md",
    "unblocked": [
      {
        "file": "unblocked-prs.md",
        "title": "Unblocked PRs",
        "filter": {"unassigned_or": ["mernst"]}
      }
    ]
  },
  "directories": [
    {
      "dirs": ["daikon-old"],
      "status": "a backup of an abandoned branch",
      "relationship": "none"
    }
  ]
}
```

## The top level

The file holds a JSON object with these keys.  Only `"repos"` is required;
see the smallest config in [Examples](#examples).

* `"repos"` (required):  an object that maps each repository name, such as
  `"daikon"`, to a repository object (see below).
* `"order"` (optional):  a list of the repository names, such as
  `["daikon", "fjalar"]`.  It lists each key of `"repos"` exactly once, and
  `pr-status` reports on the repositories in this order.  The default is the
  order in which `"repos"` lists them.
* `"documents"` (optional):  an object that names the documents that
  `pr-status` generates (see below).  The default is
  `{"dependencies": "pr-status.md"}`.
* `"directories"` (optional):  a list of directory objects (see below),
  which describe directories in the "Other directories" section of the
  dependency document.  The default is `[]`.

## A repository object

A repository object describes one GitHub repository.

The repository object's key in `"repos"` is the repository's name, such as
`"daikon"`.  The names of the dependency document's per-repository generated
sections contain it, as in `<!-- BEGIN GENERATED: unblocked-daikon -->`.  A
repository object has no `"name"` key.

### The required key

* `"gh"`:  the repository's GitHub slug, such as `"codespecs/daikon"` (in
  general, `"ORG/REPO"`).  This is the upstream repository, whose open pull
  requests `pr-status` reports on, not a fork.  Two repositories must not
  have the same GitHub slug.

### Optional keys that identify the repository

* `"clone"`:  the path of a git clone of the repository, such as `"daikon"`
  or `"/home/me/src/daikon"`.  A relative path is relative to the directory
  that holds the config file.  `pr-merge-analysis` fetches the pull requests
  into the clone, and `pr-status` never renames or re-creates the clone.
  The default is a clone, in the directory that holds the config file, of
  the repository or of a fork of it with the same name.  Among several, it
  is a clone of the repository itself if there is one, and among those, one
  whose current branch is the default branch, because it has no branch of
  its own to disturb.  If there is none, `pr-status` reports an error.
* `"prefix"`:  the text that precedes a PR number when the documents refer
  to a PR, such as `"daikon#"` (which yields "daikon#95") or `"#"` (which
  yields "#95").  The default is `"#"` if `"repos"` has one repository, and
  otherwise the repository's name followed by "#", as in `"daikon#"`.  Two
  repositories must not have the same prefix, ignoring case, so that a
  reference is unambiguous.  `--highlight` names a PR as `REPO#N`, where
  `REPO` is the prefix without its final "#", the repository's name, or its
  GitHub slug, as in `--highlight daikon#95` or
  `--highlight codespecs/daikon#95`.
* `"label"`:  the repository's name as the documents show it to a reader,
  such as `"Daikon"`.  It appears in headings and list items when the
  documents report on several repositories, as in "## Unblocked PRs
  (Daikon)" and "* Daikon has these dependency clusters:".  The default is
  the repository's name.
* `"node_prefix"`:  the text that precedes a PR number in the id of the PR's
  node in the Mermaid dependency graph, such as `"daikon_"` (which yields the
  node id `daikon_95`) or `"pr"`.  It must consist of letters, digits, and
  underscores, and two repositories must not have the same one.  The
  default is `"pr"` if `"repos"` has one repository, and otherwise the
  repository's name, with each character other than a letter, digit, or
  underscore replaced by "_", followed by "_", as in `"daikon_"`.

### Optional keys that describe the repository

* `"default_branch"`:  the branch that `pr-status` treats as the
  repository's default branch, such as `"main"`.  The default is the
  default branch that GitHub reports for the repository, so give this key
  only to override GitHub.
* `"dir_name"`:  the name that the repository's working copy directories
  start with, such as `"daikon"` in `daikon-fork-mernst-branch-fix-typo`.
  The default is the repository's name.  `pr-status` uses it to decide
  whether a directory's name matches its branch's PR, and to rename a
  directory whose name does not.
* `"dependency_keywords"`:  a list of phrases that, in a PR description,
  precede the PRs that the PR depends on, in addition to the built-in ones
  ("depends on", "depend on", "builds on", "land", and "merge").  For
  example, with `["requires"]`, the description "This requires #12."
  makes #12 a prerequisite.  Matching ignores case.  The default is `[]`.
* `"show_author"`:  true if the tables of PRs have an "Author" column.  The
  default is false.  In an unblocked document, which can report on several
  repositories, the column appears if any repository sets
  `"show_author"`.
* `"routine_files"`:  a list of file names, such as `["CHANGELOG.md"]`,
  whose textual conflicts the documents do not report.  Each one is a base
  name, without a directory, and it matches a file of that name in any
  directory.  The default is `[]`.  A PR that conflicts with the default
  branch only in routine files gets the note "routine files in `master`"
  (with the actual default branch) in its "Textual conflicts" cell.

### Optional keys that change the dependencies

In each of these keys, a PR is given by its number, which must be an open PR
of the repository; an entry for a PR that is not open is ignored.

* `"excluded"`:  an object with these keys:
  * `"prs"`:  a list of PR numbers, such as `[512]`.  `pr-status` leaves
    each of these PRs out of the dependency analysis:  the PR appears in no
    table of PRs, in no dependency, in no generated command, and in no other
    PR's textual conflicts, and its description is not updated.  Its
    working copy directories are still working copies of an open PR:
    `pr-status` omits them from the section "directories" and renames them
    as it renames other PRs' working copy directories.  `cancel-blocked-ci`
    does not cancel the builds of an excluded PR.
  * `"reason"` (optional):  a sentence that explains why, such as `"#512 is
    an experiment that will not land."`.  If at least one of the excluded
    PRs is open, each unblocked document has a section "Excluded by
    decision", which gives the reason or, if there is none, lists the
    excluded PRs that are open.
* `"not_prerequisites"`:  a list of PR numbers.  A PR whose branch contains
  all of the non-merge commits of one of these PRs does not depend on it
  for that reason.  (A PR can still depend on it for another reason, such as
  its description.)  This is useful for a PR whose commits other PRs
  include but that will not land first.
* `"extra_dependencies"`:  a list of pairs of PR numbers, such as
  `[[530, 527]]`.  The pair `[A, B]` makes PR A depend on PR B, as if A's
  description said "Land after #B."
* `"extra_external_dependencies"`:  an object that maps a PR number, as a
  string such as `"530"`, to a list of PRs in other repositories that the PR
  depends on, each given as `"ORG/REPO#N"`, such as
  `["codespecs/fjalar#95"]`.  A listed PR that is not open is ignored.

### Optional keys that change how the documents describe a PR

Each of these keys holds an object that maps a PR number, as a string such
as `"527"`, to text on one line.  The text is Markdown, except in
`"labels"`.  `pr-status` escapes each "|" in text that it puts in a table
cell, and it replaces each double quote in a label by a single quote.

* `"titles"`:  the PR's title in the documents' tables, in place of its
  title on GitHub.
* `"labels"`:  the text of the PR's node in the Mermaid dependency graph,
  after the PR's reference, in place of the first 50 characters of its
  title.
* `"cluster_names"`:  a name for the dependency cluster (a connected
  component of the dependency graph) that contains the PR.  The section
  "clusters" and the comments in the Mermaid graph show it.  Any member of
  the cluster can name it; if several members do, the one with the
  smallest PR number wins.
* `"unblocked_notes"`:  a note that precedes the generated notes in the
  "Notes" cell of the PR's row in a table of unblocked PRs (one that has no
  prerequisite).  The note and the generated notes are joined by "; ", so
  write the note as a phrase, such as `"needs a review from the
  instrumenter's author"`.
* `"detail_notes"`:  a note that precedes the generated notes in the
  "Notes" cell of the PR's row in a table of blocked PRs (one that has a
  prerequisite) and in the section `details-NAME`.  The generated notes are
  sentences, so write the note as one or more sentences, such as `"Rebase
  after #527 lands."`.
* `"independent_notes"`:  a note that precedes the generated notes in the
  "Notes" cell of the PR's row in the section `independent-NAME`, which
  lists the PRs that have no prerequisite and no dependent.  Write the note
  as a phrase, as for `"unblocked_notes"`.

## The documents object

* `"dependencies"` (optional):  the file name of the dependency document,
  such as `"status.md"`.  The default is `"pr-status.md"`.  `pr-status`
  rewrites the document's title and its generated sections, between
  `<!-- BEGIN GENERATED: NAME -->` and `<!-- END GENERATED: NAME -->`, and
  retains the rest.  If the document does not exist, `pr-status` creates
  it.
* `"unblocked"` (optional):  a list of unblocked-document objects.  The
  default is `[]`.  `pr-status` rewrites each unblocked document entirely,
  so do not edit one by hand.

An unblocked document lists the open PRs that depend on no other PR.  An
unblocked-document object has these keys:

* `"file"` (required):  the document's file name, such as
  `"unblocked-prs.md"`.
* `"title"` (required):  the text of the document's "# " heading, such as
  `"Unblocked PRs"`.
* `"filter"` (optional):  which unblocked PRs the document lists:
  * `"all"`:  every unblocked PR.  This is the default.
  * `"unassigned"`:  the unblocked PRs that no one is assigned to.
  * `{"unassigned_or": [LOGIN, ...]}`:  the unblocked PRs that no one is
    assigned to or that are assigned to one of the given GitHub logins, as
    in `{"unassigned_or": ["mernst"]}`.

  With a filter other than `"all"`, the document lists the omitted PRs in a
  section "Excluded because they are assigned to someone" (or "... to
  someone else").

## A directory object

The section "directories" of the dependency document describes each entry
of the directory that holds the working copy directories, other than the
working copies of open PRs' branches.  `pr-status` describes most entries
automatically, such as a clone of the default branch or the working copy of
a landed PR's branch.  A directory object describes some entries by hand,
which overrides the automatic description.  It has these keys, each of which
is required:

* `"dirs"`:  a list of directory names, each relative to the directory that
  holds the working copy directories, such as `["daikon-old"]`.  The table
  omits a listed directory that does not exist or that is the working copy
  of an open PR's branch.
* `"status"`:  the text of the "Status" cell, such as `"a backup of an
  abandoned branch"`.
* `"relationship"`:  the text of the "Relationship to other branches"
  cell, such as `"none"`.
