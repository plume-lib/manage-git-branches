"""Regenerate the PR status documents in the current directory.

Usage (run in the directory that holds the documents and the working copies, which
must not itself be in a git working copy, or pass that directory with -C):
  pr-status            # snapshot, report changes, regenerate the documents
  pr-status --check    # snapshot and report changes, but write no document
  pr-status --print-document  # print the dependency document's file name, and exit
  pr-status --print-config    # print the config, with its defaults filled in, and exit
  pr-status -C DIR     # work in DIR instead of the current directory
  pr-status --highlight avocado-agent#100  # highlight a PR and the PRs it needs to land

Inputs:
  pr-status-config.json    hand-maintained:  repositories, notes, labels, decisions
                           (optional; see default_config for the default, and
                           pr-status-config.md for the format)
  .pr-status-snapshot.json written by the previous run; compared with this run
Each run:
  * reads the open PRs with gh,
  * runs pr-merge-analysis (cached) on them, for each repository,
  * computes the dependencies:  a PR depends on another if its description says
    so, if its branch contains all of the other PR's non-merge commits, or if the
    config says so; PRs that land together (possibly in different repositories) are one
    unit, whose members depend on each other's prerequisites but not on each other,
  * warns about each cycle of dependencies, and omits from the generated push commands
    the PRs in a cycle and the PRs that depend on them,
  * updates each modeled PR description's "Land after" and "Land before" lines,
  * prints what changed since the previous snapshot (input for the summary),
  * renames the working copies whose name does not match their branch's PR, and
    re-creates the ones whose origin is not the PR's head repository as working trees
    of a clone of that repository, when doing so loses no information,
  * prints the directories whose name or origin does not match their branch's PR,
  * rewrites the unblocked documents (if the config names any) and the dependency
    document entirely:  pr-status discards any edit to them,
  * sets the dependency document's title, in its YAML front matter and its "# " heading,
    to the current directory's basename followed by "PR status", as in "src PR status".
"""

from __future__ import annotations

import argparse
import datetime as dt
import functools
import hashlib
import itertools
import json
import operator
import os
import pathlib
import re
import shlex
import subprocess
import sys
from collections import Counter, defaultdict
from typing import TYPE_CHECKING, Any, NamedTuple

import pr_status_config

if TYPE_CHECKING:
    from collections.abc import Callable, Iterable

# The config file's name, which the dependency document mentions.
CONFIG = pr_status_config.CONFIG
# The name of the generated section that resolve-conflicts reads from the dependency document.
CONFLICTING_PUSH_COMMANDS = "conflicting-push-commands"
# The most open PRs of a repository that load_repo reads.
PR_LIMIT = 300
ANALYSIS = str(pathlib.Path(__file__).resolve().parent / "pr-merge-analysis")


class ConfigError(Exception):
    """There is no config file, and no default config can be constructed."""


def run(cmd: list[str]) -> str:
    """Run a command, which must succeed.

    Returns:
        The command's standard output.
    """
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def succeeds(cmd: list[str]) -> bool:
    """Run a command, discarding its output.

    Returns:
        Whether the command succeeded.
    """
    return subprocess.run(cmd, check=False, capture_output=True).returncode == 0


def command_failure(error: subprocess.CalledProcessError) -> str:
    """Describe a command that run raised error for.

    Returns:
        One line:  the command and its standard error.
    """
    return f"{shlex.join(error.cmd)} failed: {' '.join(error.stderr.split())}"


def and_list(items: Iterable[str]) -> str:
    """Join items as an English list, such as "a, b, and c".

    Returns:
        The items, separated by commas and "and".
    """
    items = list(items)
    if len(items) <= 2:
        return " and ".join(items)
    return ", ".join(items[:-1]) + ", and " + items[-1]


def basename(path: str) -> str:
    """Return the last component of a path.

    Returns:
        The part of path after its last "/", ignoring a trailing "/".
    """
    return path.rstrip("/").split("/")[-1]


class Repo:
    """A GitHub repository, its open PRs, and the merge analysis of those PRs."""

    def __init__(self, name: str, cfg: dict[str, Any]) -> None:
        """Create a Repo, with no PRs, from an entry in the config.

        Args:
            name: the entry's key in the config's "repos", such as "daikon".
            cfg: the entry, as a dict parsed from the config file's JSON, with keys such as
                "gh" and "prefix".
        """
        self.name = name
        self.gh = cfg["gh"]
        self.clone = cfg["clone"]
        self.prefix = cfg["prefix"]
        self.label = cfg["label"]
        self.node_prefix = cfg["node_prefix"]
        self.owner = self.gh.split("/")[0]
        self.dir_name = cfg.get("dir_name", self.name)
        self.default_branch = repo_default_branch(cfg)
        self.keywords = cfg.get("dependency_keywords", [])
        self.show_author = cfg.get("show_author", False)
        self.prs: dict[int, dict[str, Any]] = {}  # number -> gh JSON
        self.master_conflicts: dict[int, list[str]] = {}  # number -> list of files
        # (a, b): a contains all non-merge commits of b
        self.contains: set[tuple[int, int]] = set()
        self.pair_conflicts: dict[tuple[int, int], list[str]] = {}  # (a, b) with a < b -> files
        # number -> "landed" | "closed" | None (not a PR)
        self.closed_state: dict[int, str | None] = {}

    @functools.cached_property
    def reviews_and_ci(self) -> ReviewsAndCi:
        """The unresolved review threads and the CI results of the open PRs.

        They are read from GitHub when first used.
        """
        return load_reviews_and_ci(self)

    def ref(self, n: int | str) -> str:
        """Return how documents refer to PR n.

        Returns:
            The PR's number, with the repository's prefix, such as "fjalar#95".
        """
        return f"{self.prefix}{n}"

    def url(self, n: int) -> str:
        """Return the URL of PR n.

        Returns:
            The URL of PR n on GitHub.
        """
        return f"https://github.com/{self.gh}/pull/{n}"

    def link(self, n: int) -> str:
        """Return a Markdown link to PR n.

        Returns:
            A link whose text is the PR's reference and whose target is the PR on GitHub.
        """
        return highlight(self.gh, n, f"[{self.ref(n)}]({self.url(n)})")

    def failed_mark(self, n: int) -> str:
        """Return the mark that a link to PR n carries if the PR's CI failed.

        Returns:
            FAILED_MARK if the PR's CI failed, or "" otherwise.
        """
        return FAILED_MARK if n in self.reviews_and_ci.ci_failed else ""

    def refs(self, ns: Iterable[int]) -> str:
        """Return how documents refer to the PRs ns.

        Returns:
            The PRs' references, in numeric order, as an English list.
        """
        return and_list(self.ref(n) for n in sorted(ns))

    def links(self, ns: Iterable[int]) -> str:
        """Return Markdown links to the PRs ns.

        Returns:
            The PRs' links, in numeric order, as an English list.
        """
        return and_list(self.link(n) for n in sorted(ns))

    def state_of(self, n: int) -> str | None:
        """Return the state of PR n, which is not open.

        Returns:
            "landed", "closed", or None (for an issue or a nonexistent number).
        """
        if n not in self.closed_state:
            try:
                j = json.loads(run(["gh", "pr", "view", str(n), "-R", self.gh, "--json", "state"]))
                self.closed_state[n] = {"MERGED": "landed", "CLOSED": "closed"}.get(j["state"])
            except subprocess.CalledProcessError:
                self.closed_state[n] = None
        return self.closed_state[n]


def load_repo(repo: Repo, pairwise: bool = True) -> None:
    """Read the open PRs and the merge analysis.

    Without pairwise, repo.pair_conflicts stays empty.
    """
    fields = (
        "number,title,headRefName,headRefOid,headRepositoryOwner,baseRefName,"
        "author,assignees,body,updatedAt"
    )
    for pr in json.loads(
        run(
            [
                "gh",
                "pr",
                "list",
                "-R",
                repo.gh,
                "--state",
                "open",
                "--limit",
                str(PR_LIMIT),
                "--json",
                fields,
            ]
        )
    ):
        pr["body"] = pr["body"].replace("\r", "")
        pr["title"] = pr["title"].strip()
        pr["owner"] = (pr.get("headRepositoryOwner") or {}).get("login", "")
        repo.prs[pr["number"]] = pr
    if not repo.prs:
        return
    out = run(
        [
            ANALYSIS,
            *([] if pairwise else ["--no-pairwise"]),
            "--default-branch",
            repo.default_branch,
            # Prune only if repo.prs holds every open PR.  "gh pr list" lists at most
            # PR_LIMIT of them.
            *(["--prune"] if len(repo.prs) < PR_LIMIT else []),
            repo.clone,
            repo.gh,
            *map(str, sorted(repo.prs)),
        ]
    )
    section = None
    for line in out.splitlines():
        if line.startswith("## "):
            section = line.split()[1]
            continue
        if section == "master":
            n, files = line.split(":", 1)
            repo.master_conflicts[int(n)] = files.split()
        elif section == "containment":
            a, _, b = line.split()
            repo.contains.add((int(a), int(b)))
        elif section == "pairwise":
            m = re.match(r"(\d+) vs (\d+):(.*)", line)
            assert m, line
            repo.pair_conflicts[int(m[1]), int(m[2])] = m[3].split()


def branches_conflict(repo: Repo, a: int, b: int) -> bool:
    """Return whether merging the branches of PRs a and b would conflict.

    Args:
        repo: a Repo, which load_repo has read with pairwise conflicts.
        a: the number of an open PR of repo, such as 123.
        b: the number of another open PR of repo.

    Returns:
        True if the merge analysis found a textual conflict between the 2 branches.
    """
    return (min(a, b), max(a, b)) in repo.pair_conflicts


REVIEW_THREAD_FIELDS = "isResolved isOutdated"

REVIEW_THREADS_QUERY = """
query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: 50, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number
        reviewThreads(first: 100) { pageInfo { hasNextPage } nodes { FIELDS } }
        commits(last: 1) {
          nodes {
            commit {
              statusCheckRollup {
                state
                contexts(first: 100) {
                  nodes {
                    ... on CheckRun { status conclusion }
                    ... on StatusContext { state }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
""".replace("FIELDS", REVIEW_THREAD_FIELDS)

PR_REVIEW_THREADS_QUERY = """
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { FIELDS }
      }
    }
  }
}
""".replace("FIELDS", REVIEW_THREAD_FIELDS)


def review_thread_query(repo: Repo, query: str, jq: str, *fields: str) -> list[Any]:
    """Run a paginated GraphQL query about repo, whose variables are $owner, $name, and fields.

    Returns:
        The objects that the jq filter jq yields from each page of the result.
    """
    owner, name = repo.gh.split("/")
    out = run(
        [
            "gh",
            "api",
            "graphql",
            "--paginate",
            "-f",
            f"owner={owner}",
            "-f",
            f"name={name}",
            *(arg for field in fields for arg in ("-F", field)),
            "-f",
            f"query={query}",
            "--jq",
            jq,
        ]
    )
    return [json.loads(line) for line in out.splitlines()]


# The conclusions of a completed check run, and the states of a commit status, that mean failure.
# A cancelled check run is not a failure.
CHECK_FAILURES = {"ACTION_REQUIRED", "FAILURE", "STARTUP_FAILURE", "TIMED_OUT"}
STATUS_FAILURES = {"ERROR", "FAILURE"}


def ci_failed(checks: Iterable[dict[str, Any]]) -> bool:
    """Return whether CI failed, given the checks of a commit.

    Returns:
        True if some check failed, even if other checks are still running.
    """
    return any(
        c.get("conclusion") in CHECK_FAILURES or c.get("state") in STATUS_FAILURES for c in checks
    )


class ReviewsAndCi(NamedTuple):
    """The unresolved review threads and the CI results of a repository's open PRs.

    Attributes:
        review_threads: a map from the number of each open PR, such as 123, to a list with
            an element for each of the PR's unresolved review threads:  True if the thread
            is outdated.
        ci_failed: the numbers of the PRs whose CI failed.
        ci_passed: the numbers of the PRs whose CI completed and passed.
    """

    review_threads: dict[int, list[bool]]
    ci_failed: set[int]
    ci_passed: set[int]


def load_reviews_and_ci(repo: Repo) -> ReviewsAndCi:
    """Return the unresolved review threads and the CI results of the open PRs of repo.

    Args:
        repo: a Repo.

    Returns:
        The unresolved review threads and the CI results, read from GitHub.
    """
    result = ReviewsAndCi({}, set(), set())
    for pr in review_thread_query(
        repo, REVIEW_THREADS_QUERY, ".data.repository.pullRequests.nodes[]"
    ):
        threads = pr["reviewThreads"]["nodes"]
        if pr["reviewThreads"]["pageInfo"]["hasNextPage"]:
            # Query the PR's threads on their own, because --paginate pages only through PRs.
            threads = review_thread_query(
                repo,
                PR_REVIEW_THREADS_QUERY,
                ".data.repository.pullRequest.reviewThreads.nodes[]",
                f"number={pr['number']}",
            )
        result.review_threads[pr["number"]] = [
            t["isOutdated"] for t in threads if not t["isResolved"]
        ]
        commits = pr["commits"]["nodes"]
        rollup = commits[0]["commit"]["statusCheckRollup"] if commits else None
        if rollup and ci_failed(rollup["contexts"]["nodes"]):
            result.ci_failed.add(pr["number"])
        # The rollup's state is SUCCESS only if every check has completed and passed.
        elif rollup and rollup["state"] == "SUCCESS":
            result.ci_passed.add(pr["number"])
    return result


PR_STATES = {"OPEN": "open", "MERGED": "landed", "CLOSED": "closed"}


EXTERNAL_STATE: dict[str, str | None] = {}


def external_state(ref: str) -> str | None:
    """Return the state of a PR "owner/repo#N" in another repository.

    Returns:
        "open", "landed", "closed", or None.
    """
    if ref not in EXTERNAL_STATE:
        gh, n = ref.split("#")
        try:
            j = json.loads(run(["gh", "pr", "view", n, "-R", gh, "--json", "state"]))
            EXTERNAL_STATE[ref] = PR_STATES.get(j["state"])
        except subprocess.CalledProcessError:
            EXTERNAL_STATE[ref] = None
    return EXTERNAL_STATE[ref]


def external_link(ref: str) -> str:
    """Return a Markdown link to a PR "owner/repo#N" in another repository.

    Returns:
        A link whose text is ref and whose target is the PR on GitHub.
    """
    gh, n = ref.split("#")
    return highlight(gh, int(n), f"[{ref}](https://github.com/{gh}/pull/{n})")


# The mark that follows a PR whose CI failed.
FAILED_MARK = " ❌"


# The PRs that the documents highlight, as pairs of a lowercase GitHub slug, such as
# "org/repo", and a PR number.
HIGHLIGHTED: set[tuple[str, int]] = set()

# How the Mermaid graph highlights the node of a PR in HIGHLIGHTED.
HIGHLIGHTED_NODE_STYLE = "fill:#fcc,stroke:#c00,stroke-width:2px"


def highlight(gh: str, n: int, text: str) -> str:
    """Return text, which names PR n of a repository, highlighted if the PR is in HIGHLIGHTED.

    Args:
        gh: the repository's GitHub slug, such as "ORG/REPO".
        n: a PR number.
        text: Markdown that names the PR, such as a link to it.

    Returns:
        text in bold on a light red background, if HIGHLIGHTED contains the PR; otherwise text.
    """
    if (gh.lower(), n) not in HIGHLIGHTED:
        return text
    return f'<span style="background-color:#fcc">**{text}**</span>'


def resolve_pr_names(models: list[Model], names: Iterable[str]) -> set[tuple[str, int]]:
    """Return the open PRs that names name.

    Args:
        models: the model of each repository.
        names: a list of strings, each of which names PRs, separated by commas or whitespace.
            A PR's name is a repository's GitHub slug, its name, or the prefix of its
            references (which is "" when the documents refer to its PRs as "#N"), followed by
            "#" and a PR number, as in "ORG/REPO#100", "REPO#100", or "#100".

    Returns:
        The PRs, as pairs of a lowercase GitHub slug, such as "org/repo", and a PR number.

    Raises:
        ValueError: if a name does not name exactly one repository or does not name an open PR.
    """
    result = set()
    for name in (s for arg in names for s in re.split(r"[,\s]+", arg) if s):
        head, sep, number = name.rpartition("#")
        if not sep or not number.isdigit():
            msg = f"{name} is not of the form REPO#N"
            raise ValueError(msg)
        head = head.lower()
        matches = [
            m
            for m in models
            if head
            in {
                m.repo.gh.lower(),
                m.repo.gh.split("/")[1].lower(),
                m.repo.name.lower(),
                m.repo.prefix.removesuffix("#").lower(),
            }
        ]
        if len(matches) != 1:
            repos = and_list(m.repo.gh for m in matches) if matches else "no repository"
            msg = f"{name} names {repos} of {and_list(m.repo.gh for m in models)}"
            raise ValueError(msg)
        m, n = matches[0], int(number)
        if n not in m.open:
            msg = f"{name} is not an open PR of {m.repo.gh}"
            raise ValueError(msg)
        result.add((m.repo.gh.lower(), n))
    return result


def needed_to_land(models: list[Model], prs: Iterable[tuple[str, int]]) -> set[tuple[str, int]]:
    """Return the PRs that must land for the given PRs to land.

    Those are the given PRs and, recursively, every PR that one of them depends on or lands
    with.  The prerequisites and partners of a PR in a repository that
    models does not describe are not known.

    Args:
        models: the model of each repository, whose dependency graph is computed.
        prs: a set of PRs, as pairs of a lowercase GitHub slug, such as "org/repo", and a PR
            number.

    Returns:
        The PRs that must land, in the same form as prs.
    """
    by_gh = {m.repo.gh.lower(): m for m in models}
    result, todo = set(), list(prs)
    while todo:
        gh, n = todo.pop()
        if (gh, n) in result:
            continue
        result.add((gh, n))
        m = by_gh.get(gh)
        if m is None or n not in m.open:
            continue
        todo.extend((gh, d) for d in m.all_deps[n])
        todo.extend(m.cross_repo_unit[n])
        for ref in m.external[n]:
            g, d = ref.split("#")
            todo.append((g.lower(), int(d)))
    return result


def query_pr_states(refs: Iterable[str]) -> dict[str, str | None]:
    """Look up the states of the PRs "owner/repo#N" in refs, with one GraphQL query.

    Returns:
        A map from each ref to "open", "landed", "closed", or None (not a PR),
        or {} if the query fails.
    """
    refs = sorted(set(refs))
    if not refs:
        return {}
    query = []
    for i, ref in enumerate(refs):
        gh, n = ref.split("#")
        owner, name = gh.split("/")
        query.append(
            f"r{i}: repository(owner: {json.dumps(owner)}, name: {json.dumps(name)}) "
            f"{{ pullRequest(number: {int(n)}) {{ state }} }}"
        )
    # A ref that is not a PR yields an error but no output; the other refs still yield data.
    result = subprocess.run(
        ["gh", "api", "graphql", "-f", "query={" + " ".join(query) + "}"],
        check=False,
        capture_output=True,
        text=True,
    )
    try:
        data = json.loads(result.stdout).get("data")
    except json.JSONDecodeError:
        data = None
    if not data:
        return {}
    states = {}
    for i, ref in enumerate(refs):
        pr = (data.get(f"r{i}") or {}).get("pullRequest")
        states[ref] = PR_STATES.get(pr["state"]) if pr else None
    return states


BASE_KEYWORDS = ["depends on", "depend on", "builds on", "land", "merge"]

# Matches a negation, possibly followed by one word, at the end of the text before a keyword,
# as in "does not depend on", "doesn't actually depend on", or "no longer builds on".
NEGATION_RE = re.compile(r"(\b(not|never|no longer)|n['\u2019]t)\s+(\w+\s+)?$", re.IGNORECASE)

# Matches the start of a landing-order line, such as "Land after #12" or
# "Land with owner/repo#34", which names its PR as "#N", "owner/repo#N", or the PR's URL.
# Group 1 is the word "after", "with", or "before".
LANDING_START_RE = re.compile(
    r"Land (after|with|before)"
    r" (#\d+|[\w.-]+/[\w.-]+#\d+|https://github\.com/[\w.-]+/[\w.-]+/pull/\d+)\b"
)


class PrRefs(NamedTuple):
    """The PRs that a text names.

    Attributes:
        numbers: the numbers, such as 123, of the named PRs in a given repository.
        external: the named PRs in other repositories, such as "owner/repo#123".
    """

    numbers: set[int]
    external: set[str]


def pr_refs(text: str, repo: Repo) -> PrRefs:
    """Return the PRs that the given text names.

    Args:
        text: a part of a PR description, such as "Land after #12 and other/repo#34".
        repo: the repository whose PRs text can name by number alone, as in "#12".

    Returns:
        The PRs that text names, as a PrRefs whose numbers are of PRs in repo.
    """
    numbers = {int(n) for n in re.findall(r"(?<![\w/])#(\d+)\b", text)}
    external = set()
    for gh, n in re.findall(r"\b([\w.-]+/[\w.-]+)#(\d+)\b", text) + re.findall(
        r"github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)", text
    ):
        if gh == repo.gh:
            numbers.add(int(n))
        else:
            external.add(f"{gh}#{n}")
    return PrRefs(numbers, external)


class StatedRelations(NamedTuple):
    """The PRs that a PR's description names as related to the PR.

    A land-with partner, as in "Land with #N", lands together with the PR.  It is neither a
    prerequisite nor a dependent.

    Attributes:
        prerequisites: the numbers, such as 123, of the PR's prerequisites in its repository.
        external_prerequisites: the PR's prerequisites in other repositories, such as
            "owner/repo#123".
        dependents: the numbers of the PR's dependents in its repository.
        partners: the numbers of the PR's land-with partners in its repository.
        external_partners: the PR's land-with partners in other repositories, such as
            "owner/repo#123".
    """

    prerequisites: set[int]
    external_prerequisites: set[str]
    dependents: set[int]
    partners: set[int]
    external_partners: set[str]


class ClosedPr(NamedTuple):
    """A PR that is no longer open.

    Attributes:
        number: the PR's number, such as 123.
        state: "landed" or "closed".
    """

    number: int
    state: str


def stated_relations(body: str, repo: Repo) -> StatedRelations:
    """Return the PRs that the given description of a PR in repo names as related to the PR.

    Returns:
        The PRs that body names, as a StatedRelations.
    """
    keywords = BASE_KEYWORDS + repo.keywords
    pattern = re.compile(r"\b(" + "|".join(re.escape(k) for k in keywords) + r")\b", re.IGNORECASE)
    numbers, external, dependents = set(), set(), set()
    partners, external_partners = set(), set()
    # A colon does not end a sentence, so "Merge with:" and the list that follows stay together.
    for sentence in re.split(r"(?<=[.;])\s+|\n\s*\n(?!\s*https?://)", body):
        for m in pattern.finditer(sentence):
            if NEGATION_RE.search(sentence[: m.start()]):
                continue  # "This PR does not depend on #N" names no relationship
            rest = sentence[m.end() :]
            keyword = m[1].lower()
            if keyword not in ("land", "merge"):
                if re.match(r"\s*(this|it)\b", rest, re.IGNORECASE):
                    continue  # "#N depends on this PR":  #N is a dependent
                refs = pr_refs(rest, repo)
                numbers |= refs.numbers
                external |= refs.external
                continue
            if not (
                re.search(r"\b(first|after)\b", rest, re.IGNORECASE)
                or re.match(
                    r"\s*((this|it)\s+)?(together with|with|right before|before)[\s:]",
                    rest,
                    re.IGNORECASE,
                )
            ):
                continue
            # In "Land it after #A, with #B, and before #C", #A is a prerequisite, #B is a
            # land-with partner, and #C is a dependent.
            parts = re.split(r"\b(after|before|with)\b", rest, flags=re.IGNORECASE)
            for i in range(0, len(parts), 2):
                refs = pr_refs(parts[i], repo)
                preposition = parts[i - 1].lower() if i else None
                # In "To land after it:  #A", this PR is the object, so #A is a dependent.
                if preposition in ("after", "before") and re.match(
                    r"\s*(this|it)\b", parts[i], re.IGNORECASE
                ):
                    preposition = "before" if preposition == "after" else "after"
                if preposition == "before":
                    dependents |= refs.numbers
                elif preposition == "with":
                    partners |= refs.numbers
                    external_partners |= refs.external
                else:
                    numbers |= refs.numbers
                    external |= refs.external
    return StatedRelations(numbers, external, dependents, partners, external_partners)


def landing_line(line: str, repo: Repo) -> tuple[str, str] | None:
    """Parse a landing-order line of a description of a PR in repo.

    A landing-order line has the conventional format, such as "Land after #N.", except
    that it may omit the final period and may continue with text that names no other PR.
    It may name the PR as "owner/repo#N" or by its URL.

    Returns:
        The word "after", "with", or "before", and the PR that the line names, as "#N" if
        it is in repo and as "owner/repo#N" otherwise; or None if line is not a
        landing-order line.
    """
    m = LANDING_START_RE.match(line)
    if not m:
        return None
    refs = pr_refs(line, repo)
    if len(refs.numbers) + len(refs.external) != 1:
        return None
    return m[1], (f"#{refs.numbers.pop()}" if refs.numbers else refs.external.pop())


def malformed_landing_lines(body: str, repo: Repo) -> list[str]:
    """Find the lines of a description that look like landing-order lines but are not.

    Returns:
        The lines that start with the word "Land" followed by the word "after", "with", or
        "before", but are not landing-order lines as defined by landing_line.
    """
    return [
        line
        for line in body.splitlines()
        if re.match(r"Land (after|with|before)\b", line) and not landing_line(line, repo)
    ]


def updated_pr_description(
    body: str,
    repo: Repo,
    prerequisites: Iterable[int],
    dependents: Iterable[int],
    external_prerequisites: Iterable[str] = (),
) -> str:
    """Update the landing-order lines, as defined by landing_line, in a PR description.

    prerequisites and dependents are PR numbers in repo, and external_prerequisites are
    "owner/repo#N" in other repositories.

    A generated line retains the text of an existing landing-order line that says the same
    thing, and otherwise has the conventional format, such as "Land after #N.".

    Existing ``Land with`` lines are retained between the generated "Land after"
    and "Land before" groups, and existing "Land before" lines that name a PR in another
    repository are retained after the generated "Land before" group.

    The landing-order lines replace the existing ones, where the first of them is, unless
    they end the description; then, as when there are none, the landing-order lines begin
    the description.

    Returns:
        The updated description.
    """
    lines = body.splitlines()
    final_newline = body.endswith("\n")
    landing = [(i, landing_line(line, repo)) for i, line in enumerate(lines)]
    landing = [(i, parsed) for i, parsed in landing if parsed]
    existing: dict[tuple[str, str], str] = {}
    for i, parsed in landing:
        existing.setdefault(parsed, lines[i])
    with_lines = [lines[i] for i, (kind, _) in landing if kind == "with"]
    with_refs = {ref for _, (kind, ref) in landing if kind == "with"}
    with_prs = {int(ref[1:]) for ref in with_refs if ref.startswith("#")}
    external_before_lines = [
        lines[i] for i, (kind, ref) in landing if kind == "before" and not ref.startswith("#")
    ]

    def ref_key(ref: str) -> tuple[str, int]:
        gh, n = ref.split("#")
        return gh.lower(), int(n)

    def generated(kind: str, ref: str) -> str:
        return existing.get((kind, ref), f"Land {kind} {ref}.")

    replacement = [
        *(generated("after", f"#{n}") for n in sorted(set(prerequisites) - with_prs)),
        *(
            generated("after", ref)
            for ref in sorted(set(external_prerequisites) - with_refs, key=ref_key)
        ),
        *with_lines,
        *(generated("before", f"#{n}") for n in sorted(set(dependents) - with_prs)),
        *external_before_lines,
    ]

    landing_indices = {i for i, _ in landing}
    at_end = bool(landing) and all(
        i in landing_indices or not lines[i].strip() for i in range(landing[0][0], len(lines))
    )
    if landing and not at_end:
        insertion = landing[0][0]
        lines = [line for i, line in enumerate(lines) if i not in landing_indices]
        lines[insertion:insertion] = replacement
        if not replacement:
            # Remove one blank line that only separated the landing-order block from the body.
            if insertion == 0 and lines and not lines[0]:
                lines.pop(0)
            elif 0 < insertion < len(lines) and not lines[insertion - 1] and not lines[insertion]:
                lines.pop(insertion)
    elif landing or replacement:
        lines = lines[: landing[0][0]] if landing else lines
        # Remove the blank lines that separated a final landing-order block from the body.
        while lines and not lines[-1].strip():
            lines.pop()
        if replacement:
            lines = replacement + ([""] if lines and lines[0] else []) + lines
    else:
        return body

    return "\n".join(lines) + ("\n" if final_newline else "")


class Model:
    """The dependencies among the open PRs of a repository."""

    def __init__(self, repo: Repo, cfg: dict[str, Any]) -> None:
        """Find the dependencies among the open PRs of repo, which load_repo has read.

        unite_partners must be called before the dependency graph is used.
        """
        self.repo = repo
        rc = cfg["repos"][repo.name]
        self.excluded = set(rc.get("excluded", {}).get("prs", []))
        not_prereq = set(rc.get("not_prerequisites", []))
        open_prs = set(repo.prs) - self.excluded
        self.open = open_prs
        self.stated: dict[int, set[int]] = {}
        self.stated_dependents: dict[int, set[int]] = {}
        self.stated_partners: dict[int, set[int]] = {}
        self.external_partners: dict[int, set[str]] = {}
        self.stated_closed: dict[int, list[ClosedPr]] = {}
        self.external: dict[int, list[str]] = {}
        # This model and the models that unite_partners unites it with, as a map from each
        # one's lowercase GitHub slug, such as "org/repo", to the model.
        self.by_gh: dict[str, Model] = {repo.gh.lower(): self}
        relations = {n: stated_relations(repo.prs[n]["body"], repo) for n in open_prs}
        # Look up all the states at once; state_of and external_state look up any that remain.
        external = {e for s in relations.values() for e in s.external_prerequisites} | {
            e for refs in rc.get("extra_external_dependencies", {}).values() for e in refs
        }
        internal = {
            f"{repo.gh}#{m}" for s in relations.values() for m in s.prerequisites - set(repo.prs)
        }
        for ref, state in query_pr_states((external - set(EXTERNAL_STATE)) | internal).items():
            if ref in external:
                EXTERNAL_STATE[ref] = state
            else:
                repo.closed_state[int(ref.split("#")[1])] = state if state != "open" else None
        for n in open_prs:
            s = relations[n]
            names = s.prerequisites - {n}
            self.stated[n] = names & open_prs
            self.stated_dependents[n] = (s.dependents - {n}) & open_prs
            self.stated_partners[n] = (s.partners - {n}) & open_prs
            self.external_partners[n] = s.external_partners
            self.stated_closed[n] = sorted(
                ClosedPr(m, state) for m in names - set(repo.prs) if (state := repo.state_of(m))
            )
            self.external[n] = sorted(
                e for e in s.external_prerequisites if external_state(e) == "open"
            )
        for n, refs in rc.get("extra_external_dependencies", {}).items():
            if int(n) in open_prs:
                self.external[int(n)] = sorted(
                    set(self.external[int(n)]) | {e for e in refs if external_state(e) == "open"}
                )
        deps: defaultdict[int, set[int]] = defaultdict(set)
        for n in open_prs:
            deps[n] |= self.stated[n]
            for m in self.stated_dependents[n]:
                deps[m].add(n)
        # A stacked PR depends on the PR whose branch is its base branch.
        self.base_pr: dict[int, int] = {}
        by_head = {(pr["owner"].lower(), pr["headRefName"]): m for m, pr in repo.prs.items()}
        for n in open_prs:
            base = repo.prs[n]["baseRefName"]
            if base != repo.default_branch:
                m = by_head.get((repo.owner.lower(), base))
                if m in open_prs:
                    deps[n].add(m)
                    self.base_pr[n] = m
        for a, b in repo.contains:
            if (
                a in open_prs
                and b in open_prs
                and b not in not_prereq
                and (b, a) not in repo.contains
            ):
                deps[a].add(b)
        self.extra: defaultdict[int, set[int]] = defaultdict(set)
        for a, b in rc.get("extra_dependencies", []):
            if a in open_prs and b in open_prs:
                deps[a].add(b)
                self.extra[a].add(b)
        self.deps = deps
        # The members, in this repository, of each PR's land-with unit.
        self.unit = {n: {n} for n in open_prs}
        # The members, in every repository, of each PR's land-with unit, as pairs of a
        # lowercase GitHub slug, such as "org/repo", and a PR number.
        self.cross_repo_unit = {n: {(repo.gh.lower(), n)} for n in open_prs}
        # The external prerequisites that each PR has because of its land-with unit.
        self.inherited_external: dict[int, set[str]] = {}

    def compute_graph(self) -> None:
        """Compute the dependency graph from the dependencies that unite_partners set."""
        open_prs, deps = self.open, self.deps
        self.all_deps = {n: self.closure(deps, n) for n in open_prs}
        # Each PR that depends on its own unit, such as two PRs whose descriptions say to land
        # each after the other.
        self.cyclic = sorted(
            n for n in open_prs if any(self.unit[n] & self.all_deps[d] for d in deps[n])
        )
        # The unit members whose commits each PR's branch contains, but not vice versa.
        contains = self.repo.contains
        covered = {
            n: {m for m in self.unit[n] - {n} if (n, m) in contains and (m, n) not in contains}
            for n in open_prs
        }
        # Direct dependencies:  the transitive reduction, in which a dependency on a PR also
        # covers the unit members whose commits its branch contains.
        self.direct: dict[int, set[int]] = {}
        for n in open_prs:
            indirect = (
                set().union(*(self.all_deps[d] | covered[d] for d in self.all_deps[n]))
                if self.all_deps[n]
                else set()
            )
            self.direct[n] = self.all_deps[n] - indirect
        self.dependents: defaultdict[int, set[int]] = defaultdict(set)
        for n in open_prs:
            for d in self.direct[n]:
                self.dependents[d].add(n)
        self.all_dependents = {n: {m for m in open_prs if n in self.all_deps[m]} for n in open_prs}
        # The PRs in a cycle, and the PRs that depend on one.  A cycle makes their direct
        # dependencies wrong:  each member of a cycle covers the others, so a dependent of
        # the cycle can have no direct prerequisite at all.
        self.cycle_affected = set(self.cyclic).union(*(self.all_dependents[n] for n in self.cyclic))

    @staticmethod
    def closure(deps: dict[int, set[int]], n: int) -> set[int]:
        """Compute the transitive dependencies of n.

        Returns:
            Every PR that n depends on, directly or transitively, according to deps.
        """
        seen, todo = set(), list(deps[n])
        while todo:
            d = todo.pop()
            if d not in seen and d != n:
                seen.add(d)
                todo.extend(deps[d])
        return seen

    def in_graph(self, n: int) -> bool:
        """Return whether PR n depends on, or is depended on by, another open PR.

        Returns:
            True if PR n has a direct prerequisite or a direct dependent.
        """
        return bool(self.direct[n] or self.dependents[n])

    def is_blocked(self, n: int) -> bool:
        """Return whether PR n depends on another open PR.

        Returns:
            True if PR n has a prerequisite, in this or another repository, or is in or after
            a cycle of dependencies.
        """
        return bool(self.direct[n] or self.external[n] or n in self.cycle_affected)

    def unblocked(self) -> list[int]:
        """Return the PRs that depend on no other open PR.

        Returns:
            The sorted numbers of the PRs that are not blocked.
        """
        return sorted(n for n in self.open if not self.is_blocked(n))

    def blocked(self) -> list[int]:
        """Return the PRs that depend on another open PR.

        Returns:
            The sorted numbers of the blocked PRs.
        """
        return sorted(n for n in self.open if self.is_blocked(n))

    def independent(self) -> list[int]:
        """Return the PRs that have no prerequisite and no dependent.

        Returns:
            The sorted numbers of the PRs that are unrelated to every other open PR.
        """
        return sorted(n for n in self.open if not self.in_graph(n) and not self.is_blocked(n))

    def assignees(self, n: int) -> list[str]:
        """Return the assignees of PR n.

        Returns:
            The GitHub logins of the PR's assignees.
        """
        return [a["login"] for a in self.repo.prs[n]["assignees"]]

    def assigned_to(self, n: int) -> str:
        """Return the "Assigned to" cell of PR n.

        Returns:
            The PR's assignees, as an English list.
        """
        return and_list(self.assignees(n))

    def conflicting_prerequisites(self, n: int) -> set[int]:
        """Return the direct prerequisites of PR n whose branches conflict with PR n's.

        Returns:
            The numbers of the direct prerequisites of PR n whose branches cannot be merged
            cleanly into PR n's branch.
        """
        return {d for d in self.direct[n] if branches_conflict(self.repo, n, d)}

    def unresolved_threads(self, n: int) -> str:
        """Return the "Unresolved threads" cell of PR n.

        Returns:
            The number of the PR's unresolved review threads and how many of them are
            outdated, followed by a red X if the PR's CI failed or a green checkmark if it
            completed and passed, followed by shuffle arrows (🔀) if merging the default
            branch or a direct prerequisite into the PR would conflict, in any file; or "" if
            none of these applies.
        """
        reviews_and_ci = self.repo.reviews_and_ci
        threads = reviews_and_ci.review_threads.get(n, [])
        cell = []
        if threads:
            outdated = sum(threads)
            cell.append(str(len(threads)) + (f" ({outdated} outdated)" if outdated else ""))
        if n in reviews_and_ci.ci_failed:
            cell.append(FAILED_MARK)
        elif n in reviews_and_ci.ci_passed:
            cell.append(" ✅")
        if n in self.repo.master_conflicts or self.conflicting_prerequisites(n):
            cell.append(" 🔀")
        return "".join(cell)

    def head_status(self, a: int, b: int) -> str:
        """Return whether a's branch has b's current commits.

        Returns:
            "yes", "newest" (a lacks only b's newest commits), or "none".
        """
        g = ["git", "-C", self.repo.clone]
        pa, pb = f"refs/remotes/pr/{a}", f"refs/remotes/pr/{b}"
        if succeeds([*g, "merge-base", "--is-ancestor", pb, pa]):
            return "yes"
        missing = run(
            [*g, "rev-list", "--no-merges", pb, f"^{pa}", "^refs/remotes/csm/master"]
        ).split()
        if not missing:
            return "yes"  # a lacks only merge commits of b
        own = run([*g, "rev-list", "--no-merges", pb, "^refs/remotes/csm/master"]).split()
        return "none" if len(missing) == len(own) else "newest"

    def levels(self) -> dict[int, int]:
        """Compute each PR's level in the dependency graph.

        Returns:
            A map from each PR in the dependency graph to 1 plus the largest level of its
            direct prerequisites, or to 1 if it has none.
        """
        level: dict[int, int] = {}

        def lev(n: int) -> int:
            if n not in level:
                level[n] = 1  # provisional, so that a cycle of dependencies terminates
                level[n] = 1 + max((lev(d) for d in self.direct[n]), default=0)
            return level[n]

        for n in self.open:
            if self.in_graph(n):
                lev(n)
        return level

    def components(self) -> list[list[int]]:
        """Compute the connected components of the dependency graph.

        Returns:
            The components, each a sorted list of PR numbers, ordered by their smallest PR.
        """
        nodes = sorted(n for n in self.open if self.in_graph(n))
        seen, comps = set(), []
        for n in nodes:
            if n in seen:
                continue
            comp, todo = set(), [n]
            while todo:
                m = todo.pop()
                if m in comp:
                    continue
                comp.add(m)
                todo.extend(self.direct[m] | self.dependents[m])
            seen |= comp
            comps.append(sorted(comp))
        return comps


def unite_partners(models: list[Model]) -> None:
    """Make each set of land-with partners one unit, and compute each model's graph.

    The partners of a PR are the PRs that its description says to land with it, and the
    PRs whose descriptions say to land with it, in any of the models' repositories.  A unit
    is a set of PRs that are connected by the partner relation.  Each member of a unit
    depends on every prerequisite of every member, and on no member.
    """
    by_gh = {m.repo.gh.lower(): m for m in models}
    for model in models:
        model.by_gh = by_gh
    neighbors = defaultdict(set)  # (model, PR number) -> partners
    for model in models:
        for n in model.open:
            partners = {(model, m) for m in model.stated_partners[n]}
            for ref in model.external_partners[n]:
                gh, m = ref.split("#")
                other = by_gh.get(gh.lower())
                if other and int(m) in other.open:
                    partners.add((other, int(m)))
            for p in partners:
                neighbors[model, n].add(p)
                neighbors[p].add((model, n))
    seen = set()
    for start in list(neighbors):
        if start in seen:
            continue
        unit, todo = set(), [start]
        while todo:
            member = todo.pop()
            if member not in unit:
                unit.add(member)
                todo.extend(neighbors[member])
        seen |= unit
        # The prerequisites of the unit:  a map from (lowercase repository, PR number) to the
        # PR's reference.
        prereqs = {}
        for model, n in unit:
            gh = model.repo.gh
            prereqs.update({(gh.lower(), d): f"{gh}#{d}" for d in model.deps[n]})
            for ref in model.external[n]:
                g, d = ref.split("#")
                prereqs[g.lower(), int(d)] = ref
        members = {(model.repo.gh.lower(), n) for model, n in unit}
        prereqs = {key: ref for key, ref in prereqs.items() if key not in members}
        for model, n in unit:
            gh = model.repo.gh.lower()
            model.unit[n] = {m for other, m in unit if other is model}
            model.cross_repo_unit[n] = {(other.repo.gh.lower(), m) for other, m in unit}
            model.deps[n] = {d for (g, d) in prereqs if g == gh and d in model.open}
            inherited = {ref for (g, _), ref in prereqs.items() if g != gh} - set(model.external[n])
            model.inherited_external[n] = inherited
            model.external[n] = sorted(set(model.external[n]) | inherited)
    for model in models:
        model.compute_graph()


def load_models(cfg: dict[str, Any], pairwise: bool = True) -> list[Model]:
    """Read the open PRs of each repository that cfg describes, and model their dependencies.

    Returns:
        The model of each repository, in the order that cfg gives.
    """
    models = []
    for name in cfg["order"]:
        repo = Repo(name, cfg["repos"][name])
        load_repo(repo, pairwise=pairwise)
        models.append(Model(repo, cfg))
    unite_partners(models)
    return models


class DescriptionUpdate(NamedTuple):
    """An update of a PR's description.

    Attributes:
        model: the Model of the PR's repository.
        number: the PR's number, such as 123.
        body: the PR's updated description.
    """

    model: Model
    number: int
    body: str


class FailedDescriptionUpdate(NamedTuple):
    """An update of a PR's description that GitHub rejected.

    Attributes:
        model: the Model of the PR's repository.
        number: the PR's number, such as 123.
        error: the error of the `gh` command that tried to update the description.
    """

    model: Model
    number: int
    error: subprocess.CalledProcessError


def description_updates(models: list[Model]) -> list[DescriptionUpdate]:
    """Return the updates of the PR descriptions whose conventional landing-order lines are stale.

    Returns:
        A DescriptionUpdate for each such PR description.
    """
    updates = []
    for model in models:
        for n in sorted(model.open):
            body = model.repo.prs[n]["body"]
            for line in malformed_landing_lines(body, model.repo):
                print(
                    f"pr-status: warning: {model.repo.url(n)}:"
                    f" malformed landing-order line: {line}",
                    file=sys.stderr,
                )
            unit = model.unit[n]
            updated = updated_pr_description(
                body,
                model.repo,
                model.direct[n] - unit,
                model.dependents[n] - unit,
                model.external[n],
            )
            if updated != body:
                updates.append(DescriptionUpdate(model, n, updated))
    return updates


def refresh_description_facts(model: Model, cfg: dict[str, Any], n: int) -> None:
    """Refresh the facts derived from one locally updated PR description."""
    r = model.repo
    s = stated_relations(r.prs[n]["body"], r)
    names = s.prerequisites - {n}
    model.stated[n] = names & model.open
    model.stated_dependents[n] = (s.dependents - {n}) & model.open
    model.stated_partners[n] = (s.partners - {n}) & model.open
    model.external_partners[n] = s.external_partners
    model.stated_closed[n] = sorted(
        ClosedPr(m, state) for m in names - set(r.prs) if (state := r.state_of(m))
    )
    configured = cfg["repos"][r.name].get("extra_external_dependencies", {}).get(str(n), [])
    model.external[n] = sorted(
        {ref for ref in s.external_prerequisites | set(configured) if external_state(ref) == "open"}
        | model.inherited_external.get(n, set())
    )


def apply_description_updates(
    updates: Iterable[DescriptionUpdate], cfg: dict[str, Any]
) -> list[FailedDescriptionUpdate]:
    """Write PR description updates to GitHub and reflect them in the in-memory facts.

    Returns:
        The updates that GitHub rejected.
    """
    failures = []
    for model, n, body in updates:
        r = model.repo
        try:
            run(["gh", "pr", "edit", str(n), "-R", r.gh, "--body", body])
        except subprocess.CalledProcessError as error:
            failures.append(FailedDescriptionUpdate(model, n, error))
            continue
        r.prs[n]["body"] = body
        refresh_description_facts(model, cfg, n)
    return failures


def needed_by(model: Model, n: int) -> str:
    """Return the "Needed by" cell of PR n.

    Returns:
        The PR's direct dependents, followed by its transitive ones, or "" if it has none.
    """
    direct = model.dependents[n]
    if not direct:
        return ""
    r = model.repo
    text = r.links(direct)
    more = model.all_dependents[n] - direct
    if more:
        text += f" (and transitively {r.links(more)})"
    return text


def external_failed_mark(model: Model, ref: str) -> str:
    """Return the mark that a link to the PR ref carries if the PR's CI failed.

    Args:
        model: a Model.
        ref: a PR in another repository, such as "owner/repo#5".

    Returns:
        FAILED_MARK if the PR's repository is one of the models that unite_partners united
        with model and the PR's CI failed, or "" otherwise.
    """
    gh, n = ref.split("#")
    other = model.by_gh.get(gh.lower())
    return other.repo.failed_mark(int(n)) if other else ""


def depends_on(model: Model, n: int, mark_failed: bool = False) -> str:
    """Return the "Depends on" cell of PR n.

    If mark_failed is true, each prerequisite whose CI failed is followed by a red X.

    Returns:
        The PR's direct prerequisites, followed by its transitive ones.  Shuffle arrows (🔀)
        follow each direct prerequisite whose branch cannot be merged cleanly into the PR's.
        If there is none but the PR conflicts with the default branch, such as master, the
        cell ends with "(and `master` 🔀)".
    """
    r = model.repo

    def link(d: int) -> str:
        return r.link(d) + (r.failed_mark(d) if mark_failed else "")

    def ext_link(e: str) -> str:
        return external_link(e) + (external_failed_mark(model, e) if mark_failed else "")

    conflicting = model.conflicting_prerequisites(n)
    items = [link(d) + (" 🔀" if d in conflicting else "") for d in sorted(model.direct[n])] + [
        ext_link(e) for e in model.external[n]
    ]
    more = and_list(link(d) for d in sorted(model.all_deps[n] - model.direct[n]))
    # In a cycle of dependencies, a PR can have no direct prerequisite.
    text = and_list(items) if items else more
    if items and more:
        text += f" (and transitively {more})"
    if not conflicting and n in r.master_conflicts:
        text += f" (and `{r.default_branch}` 🔀)"
    return text


def auto_notes(model: Model, n: int, master: bool = True) -> list[str]:
    """Generate the notes about PR n that do not come from the config.

    If master is false, omit the note about conflicts with the default branch, which the
    table that contains the notes gives in another column, such as "Textual conflicts" or
    "Depends on".

    Returns:
        Note fragments, each starting with a lowercase letter.
    """
    r = model.repo
    notes = []
    if n in model.cyclic:
        notes.append("it is in a cycle of dependencies")
    elif n in model.cycle_affected:
        notes.append("it depends on a cycle of dependencies")
    if n in model.base_pr:
        notes.append(f"its base branch is {r.link(model.base_pr[n])}'s branch")
    landed = [c.number for c in model.stated_closed[n] if c.state == "landed"]
    if landed:
        notes.append(
            f"its description still names the landed {r.links(landed)} as "
            + ("a prerequisite" if len(landed) == 1 else "prerequisites")
        )
    if master and n in r.master_conflicts:
        notes.append(
            f"conflicts with `{r.default_branch}` in "
            + and_list(f"`{f}`" for f in r.master_conflicts[n])
        )
    return notes


def fix_empty_cells(lines: Iterable[str]) -> list[str]:
    """Write each empty table cell as "| |", not "|  |".

    Returns:
        The lines, with their empty table cells rewritten.
    """
    return [
        re.sub(r"(?<=\|)  (?=\|)", " ", line) if line.startswith("|") else line for line in lines
    ]


def table_row(cells: Iterable[str]) -> str:
    """Return a Markdown table row containing cells.

    Pipe characters within a cell are escaped so that they do not create extra columns.

    Returns:
        A Markdown table row.
    """
    return "| " + " | ".join(re.sub(r"(?<!\\)\|", r"\\|", cell) for cell in cells) + " |"


def capitalize(s: str) -> str:
    """Capitalize the first letter of s, leaving the rest of s unchanged.

    Returns:
        s, with its first letter in uppercase.
    """
    return s[:1].upper() + s[1:] if s else s


def unblocked_notes(model: Model, cfg: dict[str, Any], n: int, master: bool = True) -> str:
    """Return the "Notes" cell of PR n in a table of unblocked PRs.

    If master is false, omit the note about conflicts with the default branch.

    Returns:
        The PR's notes from the config, followed by the generated ones.
    """
    manual = cfg["repos"][model.repo.name].get("unblocked_notes", {}).get(str(n), "")
    parts = ([manual] if manual else []) + auto_notes(model, n, master)
    return capitalize("; ".join(parts))


def detail_notes(model: Model, cfg: dict[str, Any], n: int, master: bool = True) -> str:
    """Return the "Notes" cell of PR n in a table of PRs that have dependencies.

    If master is false, omit the note about conflicts with the default branch.

    Returns:
        The PR's notes from the config, followed by the generated ones, as sentences.
    """
    manual = cfg["repos"][model.repo.name].get("detail_notes", {}).get(str(n), "")
    parts = ([manual] if manual else []) + [
        capitalize(s) + "." for s in auto_notes(model, n, master)
    ]
    return "  ".join(parts)


def title(model: Model, cfg: dict[str, Any], n: int) -> str:
    """Return the title of PR n.

    Returns:
        The PR's title from the config, or else from GitHub.
    """
    return cfg["repos"][model.repo.name].get("titles", {}).get(str(n), model.repo.prs[n]["title"])


class LinkEntry(NamedTuple):
    """An entry of the directory that holds the working copy directories that is a symbolic link.

    Attributes:
        target: the link's target, such as "daikon-branch-main".
    """

    target: str


class GitEntry(NamedTuple):
    """An entry of the directory that holds the working copy directories that is a git clone.

    Attributes:
        owner: the lowercase owner of the clone's origin on GitHub, such as "plume-lib", or ""
            if the origin is not on GitHub.
        repo_name: the lowercase name of the clone's origin on GitHub, such as "daikon", or the
            origin's URL if it is not on GitHub.
        branch: the clone's current branch, such as "main", or "" if HEAD is detached.
    """

    owner: str
    repo_name: str
    branch: str


class PlainEntry(NamedTuple):
    """A plain directory in the directory that holds the working copy directories.

    A plain directory is neither a symbolic link nor a git clone.
    """


# An entry of the directory that holds the working copy directories.
DirectoryEntry = LinkEntry | GitEntry | PlainEntry

DIRECTORIES: dict[str, DirectoryEntry] | None = None


def scan_directories(base: str) -> dict[str, DirectoryEntry]:
    """Classify each entry of base, once.

    Returns:
        A map from each entry of base to a LinkEntry, a GitEntry, or a PlainEntry.
    """
    global DIRECTORIES
    if DIRECTORIES is None:
        DIRECTORIES = {}
        for path in sorted(pathlib.Path(base).iterdir()):
            d = path.name
            if d.startswith(".") or not (path.is_dir() or path.is_symlink()):
                continue
            if path.is_symlink():
                DIRECTORIES[d] = LinkEntry(str(path.readlink()))
                continue
            try:
                url = run(["git", "-C", str(path), "remote", "get-url", "origin"]).strip()
                branch = run(["git", "-C", str(path), "branch", "--show-current"]).strip()
            except subprocess.CalledProcessError:
                DIRECTORIES[d] = PlainEntry()
                continue
            m = re.search(r"github\.com[:/]+([^/]+)/(.+?)(?:\.git)?/?$", url)
            if m:
                DIRECTORIES[d] = GitEntry(m[1].lower(), m[2].lower(), branch)
            else:
                DIRECTORIES[d] = GitEntry("", url, branch)
    return DIRECTORIES


# The git clones among DIRECTORIES, or None if they have not been computed since
# DIRECTORIES changed.
GIT_ENTRIES: dict[str, GitEntry] | None = None


def git_entries(base: str) -> dict[str, GitEntry]:
    """Return the git clones among the entries of base, once.

    Returns:
        A map from each entry of base that is a git clone to its GitEntry.
    """
    global GIT_ENTRIES
    if GIT_ENTRIES is None:
        GIT_ENTRIES = {
            d: info for d, info in scan_directories(base).items() if isinstance(info, GitEntry)
        }
    return GIT_ENTRIES


def pr_directories(repo: Repo, pr: dict[str, Any], base: str) -> list[str]:
    """Find the working copies of a PR's branch.

    Returns:
        The entries of base whose current branch is the PR's head branch and whose origin is
        the PR's head repository or the upstream repository.
    """
    owner, name = repo.gh.lower().split("/")
    result = []
    for d, info in git_entries(base).items():
        if (
            info.repo_name == name
            and info.branch == pr["headRefName"]
            and (
                info.owner == pr["owner"].lower()
                or (info.owner == owner and info.branch != repo.default_branch)
            )
        ):
            result.append(d)
    return result


def pr_directory(repo: Repo, n: int, base: str) -> str:
    """Return the "Directory" cell of PR n.

    Returns:
        The PR's working copies, or "(none)".
    """
    dirs = pr_directories(repo, repo.prs[n], base)
    return ", ".join(f"`{base}/{d}/`" for d in dirs) if dirs else "(none)"


# (GitHub repository, branch) -> gh JSON of every PR with that head branch
PRS_WITH_HEAD: dict[tuple[str, str], list[dict[str, Any]]] = {}


def prs_with_head(repo: Repo, branch: str) -> list[dict[str, Any]]:
    """Find the PRs, in any state and from any fork, whose head branch is branch.

    Returns:
        The gh JSON of each PR:  its number, state, and head repository's owner.
    """
    key = repo.gh, branch
    if key not in PRS_WITH_HEAD:
        PRS_WITH_HEAD[key] = json.loads(
            run(
                [
                    "gh",
                    "pr",
                    "list",
                    "-R",
                    repo.gh,
                    "--state",
                    "all",
                    "--head",
                    branch,
                    "--json",
                    "number,state,headRepositoryOwner",
                ]
            )
        )
    return PRS_WITH_HEAD[key]


def head_owner(pr: dict[str, Any]) -> str:
    """Return the lowercase owner of a PR's head repository, from gh JSON.

    Returns:
        The owner, or "" if the head repository has been deleted.
    """
    return (pr.get("headRepositoryOwner") or {}).get("login", "").lower()


def pr_state(pr: dict[str, Any]) -> str:
    """Return the state of a PR, from gh JSON.

    Returns:
        "landed", "closed", or "open".
    """
    return {"MERGED": "landed", "CLOSED": "closed"}.get(pr["state"], pr["state"].lower())


def worktree_paths(path: str | pathlib.Path) -> list[str]:
    """Return the working trees of the repository whose working tree is path.

    Returns:
        The paths of the working trees, the main one first.
    """
    out = run(["git", "-C", str(path), "worktree", "list", "--porcelain"])
    return [
        line.removeprefix("worktree ") for line in out.splitlines() if line.startswith("worktree ")
    ]


def is_linked_worktree(path: str | pathlib.Path) -> bool:
    """Return whether path is a linked working tree, which `git worktree add` created.

    Returns:
        True if path/.git is a file rather than a directory.
    """
    return pathlib.Path(path, ".git").is_file()


def fork_clone(base: str, owner: str, name: str) -> str | None:
    """Find a clone of owner's repository name, in which to create a working tree.

    Returns:
        An entry of base whose origin is owner/name, or None.
    """
    clones = [
        d for d, info in git_entries(base).items() if (info.owner, info.repo_name) == (owner, name)
    ]
    return clones[0] if clones else None


def rename_obstacle(models: list[Model], base: str, d: str, new: str, owner: str) -> str | None:
    """Return why fix_directory cannot rename entry d of base to new without losing information.

    If d's origin is not owner's repository, fix_directory re-creates d as a working tree of
    a clone of owner's repository; then d must be a linked working tree with no staged
    changes, and base must contain such a clone.

    Returns:
        The reason, or None if d can be renamed.
    """
    path = pathlib.Path(base, d)
    info = git_entries(base)[d]
    if any(pathlib.Path(m.repo.clone).resolve() == path.resolve() for m in models):
        return "it is the clone that pr-status analyzes"
    if new != d:
        if pathlib.Path(base, new).exists() or pathlib.Path(base, new).is_symlink():
            return f"{new} exists"
        for e, other in scan_directories(base).items():
            if (
                isinstance(other, LinkEntry)
                and pathlib.Path(base, other.target).resolve() == path.resolve()
            ):
                return f"{e} links to it"
    if info.owner != owner:
        origin = f"{info.owner}/{info.repo_name}"
        if not is_linked_worktree(path):
            return f"its origin is {origin}, and it is not a linked working tree"
        if fork_clone(base, owner, info.repo_name) is None:
            return f"its origin is {origin}, and no entry is a clone of {owner}/{info.repo_name}"
        if not succeeds(["git", "-C", str(path), "diff", "--cached", "--quiet"]):
            return f"its origin is {origin}, and it has staged changes"
    return None


def record_directory(base: str, d: str, new: str, info: DirectoryEntry) -> None:
    """Record in the result of scan_directories that entry d of base is now new, with info."""
    global DIRECTORIES, GIT_ENTRIES
    entries = scan_directories(base)
    del entries[d]
    entries[new] = info
    DIRECTORIES = dict(sorted(entries.items()))
    GIT_ENTRIES = None


def fix_directory(base: str, d: str, new: str, owner: str) -> str | None:
    """Rename entry d of base to new, and make its origin owner's repository.

    If d's origin is another repository, re-create d as a working tree of a clone of owner's
    repository, retaining every file in d, including untracked and ignored ones.  Otherwise,
    rename d, which may be a main or a linked working tree.  rename_obstacle must have
    returned None.

    Returns:
        None, or a problem that prevented completing the fix.
    """
    info = git_entries(base)[d]
    path, new_path = pathlib.Path(base, d), pathlib.Path(base, new)
    if info.owner == owner:
        if is_linked_worktree(path):
            run(["git", "-C", str(path), "worktree", "move", str(path), str(new_path)])
        else:
            path.rename(new_path)
            if len(worktree_paths(new_path)) > 1:
                # Each linked working tree refers to the main one by its path.
                run(["git", "-C", str(new_path), "worktree", "repair"])
        record_directory(base, d, new, info)
        return None
    branch = info.branch
    old = ["git", "-C", str(path)]
    clone = fork_clone(base, owner, info.repo_name)
    assert clone is not None, "rename_obstacle checks that there is a clone"
    fork = ["git", "-C", str(pathlib.Path(base, clone))]
    head = run([*old, "rev-parse", "HEAD"])
    status = run([*old, "status", "--porcelain"])
    created = run([*old, "config", "--default", "", f"branch.{branch}.createdforbranchdirectory"])
    # Fetching fails if it would lose commits of the fork's branch, or if the fork's branch is
    # checked out.  Nothing has changed yet.
    run([*fork, "fetch", str(path), f"refs/heads/{branch}:refs/heads/{branch}"])
    if succeeds([*fork, "fetch", "--quiet", "origin", branch]):
        run([*fork, "branch", "--quiet", f"--set-upstream-to=origin/{branch}", branch])
    if created.strip():
        run([*fork, "config", f"branch.{branch}.createdforbranchdirectory", created.strip()])
    main_worktree = worktree_paths(path)[0]
    # A name that starts with "." is not an entry for scan_directories.
    holder = pathlib.Path(base, f".pr-status-{d}")
    run([*old, "worktree", "move", str(path), str(holder)])
    new_git = ["git", "-C", str(new_path)]
    try:
        run([*fork, "worktree", "add", "--quiet", "--no-checkout", str(new_path), branch])
        for entry in holder.iterdir():
            if entry.name != ".git":
                entry.rename(new_path / entry.name)
        run([*new_git, "reset", "--quiet"])
        record_directory(base, d, new, GitEntry(owner, info.repo_name, branch))
        if (
            run([*new_git, "rev-parse", "HEAD"]) != head
            or run([*new_git, "status", "--porcelain"]) != status
        ):
            return f"the git status of {new} differs from that of {d}, which is now {holder}"
    except subprocess.CalledProcessError as error:
        return f"{command_failure(error)}; {d} is now {holder}"
    except OSError as error:
        return f"{error}; {d} is now {holder}"
    run(["git", "-C", main_worktree, "worktree", "remove", "--force", str(holder)])
    return None


def directory_problems(
    models: list[Model], base: str, fix: bool = False
) -> tuple[list[str], list[str]]:
    """Find the directories that do not follow the naming and remote conventions.

    A working copy of a PR's branch from OWNER is named PROJECT-fork-OWNER-branch-BRANCH (or
    PROJECT-fork-OWNER), and its origin is OWNER's repository.  A PR from the upstream
    repository's owner may also be in PROJECT-branch-BRANCH (or PROJECT).  A "/" in BRANCH is
    written as "-".

    If fix is true, rename each misnamed working copy to PROJECT-fork-OWNER-branch-BRANCH, and
    re-create each working copy whose origin is not OWNER's repository as a working tree of a
    clone of OWNER's repository (see fix_directory), unless it is the working copy of more
    than one PR or fixing it might lose information (see rename_obstacle).

    Returns:
        A pair:  one line for each problem, and one line for each fix.
    """
    by_repo = {m.repo.gh.lower().split("/")[1]: m.repo for m in models}
    problems = []
    renames = []

    def fix_or_report(d: str, ref: str, new: str, owner: str, problem: str) -> None:
        """Fix entry d of base, the working copy of ref; report problem if that fails."""
        obstacle = rename_obstacle(models, base, d, new, owner)
        if obstacle is None:
            info = git_entries(base)[d]
            clone = fork_clone(base, owner, info.repo_name) if info.owner != owner else None
            try:
                obstacle = fix_directory(base, d, new, owner)
            except subprocess.CalledProcessError as error:
                obstacle = command_failure(error)
            if obstacle is None:
                fixed = d if new == d else f"{d} -> {new}"
                if clone:
                    fixed += f", now a working tree of {clone}"
                renames.append(f"{fixed} (the working copy of {ref})")
                return
        problems.append(f"{problem}; not fixed: {obstacle}")

    wanted = defaultdict(list)  # directory -> [(PR reference, new name, PR owner)]
    for m in models:
        r = m.repo
        for n in sorted(r.prs):
            pr = r.prs[n]
            owner = pr["owner"].lower()
            branch = pr["headRefName"].replace("/", "-")
            names = {f"{r.dir_name}-fork-{owner}-branch-{branch}", f"{r.dir_name}-fork-{owner}"}
            if owner == r.owner.lower():
                names |= {f"{r.dir_name}-branch-{branch}", r.dir_name}
            names = {name.lower() for name in names}
            for d in pr_directories(r, pr, base):
                if d.lower() not in names:
                    new = f"{r.dir_name}-fork-{pr['owner']}-branch-{branch}"
                    wanted[d].append((r.ref(n), new, owner))
    for d, prs in sorted(wanted.items()):
        if fix and len(prs) == 1:
            ref, new, owner = prs[0]
            fix_or_report(
                d, ref, new, owner, f"{d}: the working copy of {ref} should be named {new}"
            )
            continue
        problems += [f"{d}: the working copy of {ref} should be named {new}" for ref, new, _ in prs]
    for d, info in git_entries(base).items():
        r = by_repo.get(info.repo_name)
        if r is None or info.owner != r.owner.lower() or info.branch in (r.default_branch, ""):
            continue
        prs = prs_with_head(r, info.branch)
        if any(head_owner(p) == info.owner for p in prs):
            continue
        prs = sorted((p for p in prs if head_owner(p)), key=operator.itemgetter("number"))
        lines = [
            f"{d}: its origin is {r.gh}, but the branch {info.branch} of the {pr_state(p)} "
            f"{r.ref(p['number'])} is in {head_owner(p)}/{info.repo_name}"
            for p in prs
        ]
        owners = {head_owner(p) for p in prs}
        # A misnamed directory has already been fixed, or reported, above.
        if fix and len(owners) == 1 and d not in wanted:
            (owner,) = owners
            new = f"{r.dir_name}-fork-{owner}-branch-{info.branch.replace('/', '-')}"
            ref = r.refs(p["number"] for p in prs)
            fix_or_report(d, ref, new, owner, "; ".join(lines))
            continue
        problems += lines
    return problems, renames


# ---------- unblocked documents ----------


def keep(model: Model, n: int, flt: str | dict[str, list[str]]) -> bool:
    """Return whether PR n passes a document's filter.

    Args:
        model: a Model.
        n: the number of an open PR of model's repository, such as 123.
        flt: an unblocked document's filter:  "all", "unassigned", or a dict whose key
            "unassigned_or" maps to GitHub logins, such as {"unassigned_or": ["mernst"]}.

    Returns:
        True if the document should list PR n.
    """
    who = model.assignees(n)
    if isinstance(flt, dict):
        return not who or any(w in flt["unassigned_or"] for w in who)
    if flt == "unassigned":
        return not who
    return True


def unblocked_doc(
    models: list[Model], cfg: dict[str, Any], base: str, doc: dict[str, Any], as_of: str
) -> str:
    """Generate an unblocked document.

    Returns:
        The text of the document that doc describes.
    """
    flt = doc.get("filter", "all")
    show_author = any(m.repo.show_author for m in models)
    lines = [
        f"# {doc['title']}",
        "",
        'An "unblocked" or "nonblocked" pull request is one that depends on no other PR.',
        "",
        f"As of {as_of}.",
        (
            "Generated by `pr-status` from GitHub and `pr-status-config.json`;"
            " do not edit it by hand."
        ),
        f"See `{cfg['documents']['dependencies']}` for how dependencies are determined.",
        "Each of these PRs can land without first landing any other open PR.",
    ]
    if flt == "unassigned":
        lines.append("No one is assigned to any of these PRs.")
    elif flt != "all":
        lines.append(
            f"Each of these PRs is unassigned or assigned to {and_list(flt['unassigned_or'])}."
        )
    lines.append('Some of them are prerequisites of other PRs (see "Needed by").')
    for m in models:
        r = m.repo
        heading = [
            "PR",
            *(["Author"] if show_author else []),
            "Assigned to",
            "Unresolved threads",
            "Title",
            "Directory",
            "Needed by",
            "Notes",
        ]
        lines += [
            "",
            *([f"## {r.label}", ""] if len(models) > 1 else []),
            table_row(heading),
            "|" + " --- |" * len(heading),
        ]
        for n in m.unblocked():
            if not keep(m, n, flt):
                continue
            author = [r.prs[n]["author"]["login"]] if show_author else []
            cells = [
                r.link(n),
                *author,
                m.assigned_to(n),
                m.unresolved_threads(n),
                title(m, cfg, n),
                pr_directory(r, n, base),
                needed_by(m, n),
                unblocked_notes(m, cfg, n),
            ]
            lines.append(table_row(cells))
    # Each model, its excluded PRs that are open, and the reason for excluding them.
    excluded = [
        (
            m,
            m.excluded & set(m.repo.prs),
            cfg["repos"][m.repo.name].get("excluded", {}).get("reason"),
        )
        for m in models
    ]
    if any(prs for _, prs, _ in excluded):
        lines += ["", "## Excluded by decision", ""]
        for m, prs, reason in excluded:
            if prs:
                lines.append(f"* {m.repo.label}: {reason or m.repo.links(prs) + '.'}")
    lines += ["", "## Excluded because they depend on another PR", ""]
    for m in models:
        items = []
        for n in m.blocked():
            on = [m.repo.link(d) for d in sorted(m.direct[n])] + [
                external_link(e) for e in m.external[n]
            ]
            # In a cycle of dependencies, a PR can have no direct prerequisite.
            items.append(f"{m.repo.link(n)} (on {', '.join(on) or depends_on(m, n)})")
        if items:
            lines.append(f"* {m.repo.label}: {', '.join(items)}.")
    if flt != "all":
        lines += [
            "",
            "## Excluded because they are assigned to someone"
            + ("" if flt == "unassigned" else " else"),
            "",
        ]
        for m in models:
            by = defaultdict(list)
            for n in m.unblocked():
                if not keep(m, n, flt):
                    by[", ".join(m.assignees(n))].append(n)
            if by:
                groups = [f"{m.repo.links(ns)} ({who})" for who, ns in sorted(by.items())]
                lines.append(f"* {m.repo.label}: {'; '.join(groups)}.")
    return "\n".join(fix_empty_cells(lines)) + "\n"


# ---------- generated sections of the dependency document ----------


def headed(heading: str, label: str | None, lines: list[str], level: int = 2) -> list[str]:
    """Return the given lines, preceded by the given heading.

    Args:
        heading: a heading, such as "Blocked PRs".
        label: a repository's label, such as "daikon", to follow the heading in parentheses,
            or None to omit it.
        lines: the lines that follow the heading.
        level: the heading's level, such as 2 for a "## " heading.

    Returns:
        The heading and lines, set off by blank lines.
    """
    if label is not None:
        heading += f" ({label})"
    return ["", f"{'#' * level} {heading}", "", *lines, ""]


def gen_status(models: list[Model]) -> list[str]:
    """Generate the "status" section.

    Returns:
        The section's lines:  a "Status" heading and which PRs are in a cycle of dependencies,
        which PRs conflict with the default branch, and which dependent branches lack their
        prerequisites' current commits; or no lines if there is no such PR or branch.
    """
    lines = []
    for m in models:
        r = m.repo
        if m.cyclic:
            lines.append(
                f"* {r.label} PRs in a cycle of dependencies, which the push commands omit"
                f" along with the PRs that depend on them: {r.links(m.cyclic)}."
            )
        conflicting = sorted(r.master_conflicts)
        if conflicting:
            lines.append(
                f"* {r.label} PRs that conflict with `{r.default_branch}`: {r.links(conflicting)}."
            )
    behind = []
    for m in models:
        r = m.repo
        for n in sorted(m.open):
            newest = [d for d in sorted(m.direct[n]) if m.head_status(n, d) == "newest"]
            none = [d for d in sorted(m.direct[n]) if m.head_status(n, d) == "none"]
            parts = []
            if newest:
                parts.append(
                    f"the newest commits of {r.links(newest)}"
                    if len(newest) > 1
                    else f"{r.link(newest[0])}'s newest commits"
                )
            if none:
                parts.append(f"every commit of {r.links(none)}")
            if parts:
                behind.append(f"  * {r.link(n)} lacks {and_list(parts)}.")
    if behind:
        lines.append("* Dependent branches that lack their prerequisites' current commits:")
        lines += behind
    return headed("Status", None, lines) if lines else []


def gen_clusters(models: list[Model], cfg: dict[str, Any]) -> list[str]:
    """Generate the "clusters" section.

    Returns:
        The section's lines:  a "Dependency clusters" heading and each repository's connected
        components of the dependency graph, or no lines if no repository has a component.
    """
    lines = []
    for m in models:
        names = cfg["repos"][m.repo.name].get("cluster_names", {})
        comps = m.components()
        if not comps:
            continue
        lines.append(f"* {m.repo.label} has these dependency clusters:")
        for comp in comps:
            name = next((names[str(n)] for n in comp if str(n) in names), None)
            members = m.repo.links(comp)
            lines.append(f"  * {name} ({members})" if name else f"  * {members}")
    return headed("Dependency clusters", None, lines) if lines else []


def gen_graph(models: list[Model], cfg: dict[str, Any]) -> list[str]:
    """Generate the "graph" section.

    Returns:
        The section's lines:  a "Dependency graph" heading and a Mermaid graph of the
        dependencies, or no lines if no PR is in the dependency graph.
    """
    if not any(m.components() for m in models):
        return []
    lines = ["```mermaid", "graph BT"]
    for m in models:
        r = m.repo
        labels = cfg["repos"][r.name].get("labels", {})
        names = cfg["repos"][r.name].get("cluster_names", {})
        for comp in m.components():
            name = next((names[str(n)] for n in comp if str(n) in names), None)
            lines.append(f"  %% {r.label}: {name or r.refs(comp)}")
            for n in comp:
                label = labels.get(str(n)) or r.prs[n]["title"][:50]
                label = label.replace('"', "'")
                lines.append(f'  {r.node_prefix}{n}["{r.ref(n)} {label}"]')
            for n in comp:
                lines.extend(
                    f"  {r.node_prefix}{d} --> {r.node_prefix}{n}" for d in sorted(m.direct[n])
                )
            lines.append("")
    if lines[-1] == "":
        lines.pop()
    highlighted = [
        f"{m.repo.node_prefix}{n}"
        for m in models
        for comp in m.components()
        for n in comp
        if (m.repo.gh.lower(), n) in HIGHLIGHTED
    ]
    if highlighted:
        lines.extend(
            [
                f"  classDef highlighted {HIGHLIGHTED_NODE_STYLE}",
                f"  class {','.join(highlighted)} highlighted",
            ]
        )
    lines.append("```")
    return headed("Dependency graph", None, lines)


def dependency_cells(model: Model, n: int, mark_failed: bool = False) -> list[str]:
    """Return the dependency cells of PR n, which has a prerequisite.

    If mark_failed is true, each prerequisite in the "Depends on" cell whose CI failed is
    followed by a red X.

    Returns:
        The "Depends on", "Stated in description", and
        "Branch contains prerequisites' commits" cells.
    """
    r = model.repo
    direct = sorted(model.direct[n])
    stated = [
        r.link(d) for d in direct if d in model.stated[n] or n in model.stated_dependents[d]
    ] + [external_link(e) for e in model.external[n]]
    unstated = [
        r.link(d)
        for d in direct
        if d not in model.stated[n] and n not in model.stated_dependents[d]
    ]
    if not unstated:
        stated_text = "yes"
    elif not stated:
        stated_text = "no"
    else:
        stated_text = f"{and_list(stated)}:  yes; {and_list(unstated)}:  no"
    status = {d: model.head_status(n, d) for d in direct}
    newest = [d for d in direct if status[d] == "newest"]
    none = [d for d in direct if status[d] == "none"]
    if not direct:
        contains = "not applicable"
    elif not newest and not none:
        contains = "yes"
    else:
        parts = []
        if newest:
            parts.append(
                f"lacks the newest commits of {r.links(newest)}"
                if len(newest) > 1
                else f"lacks {r.link(newest[0])}'s newest commits"
            )
        if none:
            parts.append(f"lacks every commit of {r.links(none)}")
        contains = f"no ({'; '.join(parts)})"
    return [depends_on(model, n, mark_failed), stated_text, contains]


def gen_details(model: Model, cfg: dict[str, Any], label: str | None) -> list[str]:
    """Generate the "details" section of the given repository.

    Args:
        model: a repository's model.
        cfg: the configuration.
        label: the repository's label, such as "daikon", to follow the section's heading, or
            None to omit it.

    Returns:
        The section's lines:  a "Dependency details" heading and a table of the PRs in the
        dependency graph, or no lines if no PR is in the dependency graph.
    """
    r = model.repo
    shown = [n for n in sorted(model.open) if model.in_graph(n) or model.external[n]]
    if not shown:
        return []
    lines = [
        (
            "| PR | Assigned to | Depends on | Stated in description"
            " | Branch contains prerequisites' commits | Notes |"
        ),
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for n in shown:
        t = title(model, cfg, n)
        has_prerequisite = bool(model.direct[n] or model.external[n])
        if has_prerequisite:
            cells = dependency_cells(model, n)
        else:
            cells = ["none", "not applicable", "not applicable"]
        # The "Depends on" cell of a PR that has a prerequisite marks the PR's conflict with
        # the default branch, unless a direct prerequisite conflicts too.
        notes = detail_notes(model, cfg, n, master=not has_prerequisite)
        lines.append(table_row([r.link(n) + " " + t, model.assigned_to(n), *cells, notes]))
    return headed("Dependency details", label, lines)


def gen_prerequisites(model: Model, label: str | None) -> list[str]:
    """Generate the "prerequisites" section of the given repository.

    Args:
        model: a repository's model.
        label: the repository's label, such as "daikon", to follow the section's heading, or
            None to omit it.

    Returns:
        The section's lines:  a "Prerequisites" heading and the prerequisites that have no
        prerequisite of their own, or no lines if there are none.
    """
    r = model.repo
    items = []
    for n in sorted(model.open):
        if model.direct[n] or not model.dependents[n]:
            continue
        extra = [f"needed by {needed_by(model, n)}"]
        who = model.assignees(n)
        if who:
            extra.append("assigned to " + and_list(who))
        items.append(f"{r.link(n)} ({'; '.join(extra)})")
    if not items:
        return []
    lines = [f"Prerequisites with no prerequisite of their own: {and_list(items)}."]
    return headed("Prerequisites", label, lines)


def textual_conflicts(model: Model, cfg: dict[str, Any], n: int) -> str:
    """Return the "Textual conflicts" cell of PR n.

    If PR n conflicts with the default branch or with a neighbor in a chain of dependencies
    (a direct prerequisite or a direct dependent), the cell gives only those conflicts.

    Returns:
        The non-routine files in which PR n conflicts with the default branch and with other
        open PRs, grouped by partner, or "none".  A group of more than 4 files is given as a
        count.  The default branch comes first, both among the groups and within each group's
        partners.  If PR n conflicts with the default branch, such as master, only in
        routine files, a final group says so:  "routine files in `master` 🔀".
    """
    r = model.repo
    routine = set(cfg["repos"][r.name].get("routine_files", []))
    # file -> partners, where None stands for the default branch
    by_file: dict[str, set[int | None]] = defaultdict(set)
    for f in r.master_conflicts.get(n, []):
        if basename(f) not in routine:
            by_file[basename(f)].add(None)
    for (a, b), files in r.pair_conflicts.items():
        if n not in (a, b):
            continue
        other = b if a == n else a
        if other in model.excluded:
            continue
        for f in files:
            if basename(f) not in routine:
                by_file[basename(f)].add(other)
    neighbors = {None} | model.direct[n] | model.dependents[n]
    if any(partners & neighbors for partners in by_file.values()):
        by_file = {f: partners & neighbors for f, partners in by_file.items()}
        by_file = {f: partners for f, partners in by_file.items() if partners}
    by_partners = defaultdict(list)
    for f, partners in by_file.items():
        by_partners[frozenset(partners)].append(f)

    def partner_list(partners: frozenset[int | None]) -> str:
        prs = [r.link(m) for m in sorted(m for m in partners if m is not None)]
        return and_list(([f"`{r.default_branch}`"] if None in partners else []) + prs)

    groups = [
        (f"{len(files)}+ files" if len(files) > 4 else and_list(f"`{f}`" for f in sorted(files)))
        + f" with {partner_list(partners)}"
        for partners, files in sorted(
            by_partners.items(), key=lambda kv: (None not in kv[0], sorted(kv[1]))
        )
    ]
    if n in r.master_conflicts and None not in set().union(*by_file.values()):
        groups.append(f"routine files in `{r.default_branch}` 🔀")
    return "; ".join(groups) or "none"


def gen_independent(model: Model, cfg: dict[str, Any], label: str | None) -> list[str]:
    """Generate the "independent" section of the given repository.

    Args:
        model: a repository's model.
        cfg: the configuration.
        label: the repository's label, such as "daikon", to follow the section's heading, or
            None to omit it.

    Returns:
        The section's lines:  an "Independent PRs" heading and a table of the PRs that have no
        prerequisite and no dependent, or no lines if there are none.
    """
    r = model.repo
    independent = model.independent()
    if not independent:
        return []
    notes = cfg["repos"][r.name].get("independent_notes", {})
    lines = [
        "| PR | Assigned to | Unresolved threads | Title | Textual conflicts | Notes |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for n in independent:
        note = notes.get(str(n), "")
        auto = auto_notes(model, n, master=False)
        note = capitalize("; ".join(([note] if note else []) + auto))
        cells = [
            r.link(n),
            model.assigned_to(n),
            model.unresolved_threads(n),
            title(model, cfg, n),
            textual_conflicts(model, cfg, n),
            note,
        ]
        lines.append(table_row(cells))
    return headed("Independent PRs", label, lines)


def pr_table(
    model: Model,
    cfg: dict[str, Any],
    base: str,
    heading: list[str],
    rows: Iterable[tuple[int, list[str]]],
) -> list[str]:
    """Generate a table of PRs.

    The table's first columns are PR, Author (if the repository shows authors), Assigned to,
    Unresolved threads, Title, and Directory; heading names the remaining columns, and rows
    maps each PR to the cells of its remaining columns.

    Returns:
        The table's lines.
    """
    r = model.repo
    heading = [
        "PR",
        *(["Author"] if r.show_author else []),
        "Assigned to",
        "Unresolved threads",
        "Title",
        "Directory",
        *heading,
    ]
    lines = [table_row(heading), "|" + " --- |" * len(heading)]
    for n, cells in rows:
        author = [r.prs[n]["author"]["login"]] if r.show_author else []
        row = [
            r.link(n),
            *author,
            model.assigned_to(n),
            model.unresolved_threads(n),
            title(model, cfg, n),
            pr_directory(r, n, base),
            *cells,
        ]
        lines.append(table_row(row))
    return lines


def gen_unblocked(model: Model, cfg: dict[str, Any], base: str, label: str | None) -> list[str]:
    """Generate the "unblocked-REPO" section.

    Args:
        model: a repository's model.
        cfg: the configuration.
        base: the directory that holds the working copy directories.
        label: the repository's label, such as "daikon", to follow the section's heading, or
            None to omit it.

    Returns:
        The section's lines:  an "Unblocked PRs" heading and a table of the PRs that depend
        on no other open PR (or "None." if there are none), or no lines if the repository has
        no open PR.
    """
    if not model.open:
        return []
    unblocked = model.unblocked()
    if not unblocked:
        return headed("Unblocked PRs", label, ["None."])
    table = pr_table(
        model,
        cfg,
        base,
        ["Needed by", "Textual conflicts", "Notes"],
        [
            (
                n,
                [
                    needed_by(model, n),
                    textual_conflicts(model, cfg, n),
                    unblocked_notes(model, cfg, n, master=False),
                ],
            )
            for n in unblocked
        ],
    )
    return headed("Unblocked PRs", label, table)


def gen_blocked(model: Model, cfg: dict[str, Any], base: str, label: str | None) -> list[str]:
    """Generate the "blocked-REPO" section.

    Args:
        model: a repository's model.
        cfg: the configuration.
        base: the directory that holds the working copy directories.
        label: the repository's label, such as "daikon", to follow the section's heading, or
            None to omit it.

    Returns:
        The section's lines:  a "Blocked PRs" heading and a table of the PRs that depend on
        another open PR, or no lines if no PR is blocked.
    """
    blocked = model.blocked()
    if not blocked:
        return []
    table = pr_table(
        model,
        cfg,
        base,
        ["Depends on", "Stated in description", "Branch contains prerequisites' commits", "Notes"],
        [
            (
                n,
                [
                    *dependency_cells(model, n, mark_failed=True),
                    detail_notes(model, cfg, n, master=False),
                ],
            )
            for n in blocked
        ],
    )
    return headed("Blocked PRs", label, table)


def gen_directories(models: list[Model], cfg: dict[str, Any], base: str) -> list[str]:
    """Generate the "directories" section.

    Returns:
        The section's lines:  an "Other directories" heading and a table of the entries of
        base that are not a working copy of an open PR's branch, or no lines if every entry
        is such a working copy.
    """
    dirs_info = scan_directories(base)
    working = set()
    for m in models:
        for pr in m.repo.prs.values():
            working.update(pr_directories(m.repo, pr, base))
    rows, covered = [], set()
    for row in cfg["directories"]:
        dirs = [d for d in row["dirs"] if d in dirs_info and d not in working]
        covered |= set(row["dirs"])
        if dirs:
            rows.append((dirs, row["status"], row["relationship"]))
    by_repo = {m.repo.gh.lower().split("/")[1]: m for m in models}
    groups = defaultdict(list)  # (status, relationship) -> directories
    landed = defaultdict(list)  # (repository, state) -> [(directory, ref)]
    for d, info in dirs_info.items():
        if d in working or d in covered:
            continue
        if isinstance(info, LinkEntry):
            groups[f"a symbolic link to `{info.target}`", "none"].append(d)
        elif isinstance(info, PlainEntry):
            groups["not a git repository", "none"].append(d)
        elif info.repo_name not in by_repo:
            where = f"{info.owner}/{info.repo_name}" if info.owner else info.repo_name
            groups[
                f"`{where}`, branch `{info.branch}`" if info.branch else f"`{where}`",
                "another repository",
            ].append(d)
        else:
            m = by_repo[info.repo_name]
            r = m.repo
            if info.branch in (r.default_branch, ""):
                branch = f"`{r.default_branch}`"
                is_upstream = info.owner == r.owner.lower()
                state = f"upstream {branch}" if is_upstream else f"a fork's {branch}"
                groups[state, "none"].append(d)
                continue
            prs = prs_with_head(r, info.branch)
            found = [p for p in prs if head_owner(p) in (info.owner, r.owner.lower())]
            if not found and info.owner == r.owner.lower():
                # A clone of the upstream repository that holds a fork's branch, which
                # directory_problems reports.
                found = [p for p in prs if head_owner(p)]
            if not found:
                groups["a branch with no PR", "unknown"].append(d)
                continue
            p = max(found, key=operator.itemgetter("number"))
            landed[r.name, pr_state(p)].append((d, r.link(p["number"])))
    for (status, rel), dirs in groups.items():
        if status.startswith("a symbolic link"):
            rows += [([d], status, rel) for d in dirs]
        else:
            rows.append((dirs, status, rel))
    for (_, state), pairs in sorted(landed.items()):
        refs = [ref for _, ref in pairs]
        if state == "open":
            status = f"another copy of the branch of the open {and_list(refs)}"
        else:
            status = f"the {state} {and_list(refs)}"
        status += ", respectively" if len(refs) > 1 else ""
        rows.append(([d for d, _ in pairs], status, "none"))
    if not rows:
        return []
    lines = ["| Directory | Status | Relationship to other branches |", "| --- | --- | --- |"]
    for dirs, status, rel in rows:
        lines.append(table_row([", ".join(f"`{d}`" for d in dirs), status, rel]))
    return headed("Other directories", None, lines)


def dependency_document(
    models: list[Model], cfg: dict[str, Any], base: str, as_of: str, title: str
) -> str:
    """Generate the dependency document.

    The lines "<!-- BEGIN GENERATED: conflicting-push-commands -->" and
    "<!-- END GENERATED: conflicting-push-commands -->" delimit the document's
    "Dependency chains with conflicts" section, which resolve-conflicts reads.  They are
    present even if the section is empty.

    Args:
        models: a list of the models of the repositories, one per repository
        cfg: the configuration
        base: the directory that holds the working copy directories
        as_of: the time of the PRs' data, such as "2026-11-05 17:59 PST"
        title: the document's title, such as "src PR status"

    Returns:
        The text of the dependency document:  YAML front matter and a "# " heading that give
        title, then its sections, including each optional section that cfg names.
    """
    optional = set(cfg["documents"].get("optional_sections", []))
    all_commands = push_commands(models, base)
    conflicting_commands = push_commands(models, base, conflicts_only=True)
    lines = [
        "---",
        f"title: {yaml_string(title)}",
        "---",
        "",
        f"# {title}",
        "",
        f"As of {as_of}.",
        "Generated by `pr-status`; do not edit it by hand.",
        "",
        "## How dependencies are determined",
        "",
        (
            'A PR depends on another PR if its description says so (for example, "Land after #N"),'
            " if its base branch is the other PR's branch,"
            " if its branch contains all of the other PR's non-merge commits,"
            f" or if `{CONFIG}` says so."
            ' PRs that land together, as "Land with #N" says, are one unit,'
            " which may span repositories:  each member depends on every prerequisite of every"
            " member, and on no member, even if its branch contains another member's commits."
        ),
        "",
        *gen_status(models),
        *gen_clusters(models, cfg),
        *(gen_graph(models, cfg) if "graph" in optional else []),
        *gen_updating_branches(models, all_commands),
        "",
        f"<!-- BEGIN GENERATED: {CONFLICTING_PUSH_COMMANDS} -->",
        *gen_push_commands(conflicting_commands, base, conflicts_only=True),
        f"<!-- END GENERATED: {CONFLICTING_PUSH_COMMANDS} -->",
        *gen_push_commands(all_commands, base),
    ]
    # Each repository's label distinguishes its sections' headings in a multi-repository
    # document.
    labeled = len(models) > 1
    for m in models:
        label = m.repo.label if labeled else None
        lines += gen_unblocked(m, cfg, base, label)
        lines += gen_blocked(m, cfg, base, label)
        if "details" in optional:
            lines += gen_details(m, cfg, label)
        if "prerequisites" in optional:
            lines += gen_prerequisites(m, label)
        if "independent" in optional:
            lines += gen_independent(m, cfg, label)
    lines += gen_directories(models, cfg, base)
    # Each section is set off by blank lines, so adjacent sections yield several.
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(fix_empty_cells(lines)))
    return text.rstrip("\n") + "\n"


def yaml_string(s: str) -> str:
    """Return a YAML scalar that YAML reads as the given string.

    The scalar is plain (unquoted) if s consists of words, made of letters, digits, "_", and
    ".", separated by spaces and "-", and contains a space, as in "src PR status".  A plain
    scalar without a space, such as "true", "null", or "123", might be read as a boolean, null,
    or number, so the scalar is quoted otherwise.

    Returns:
        s, or s quoted for YAML.
    """
    if " " in s and re.fullmatch(r"[\w.]([\w. -]*[\w.])?", s):
        return s
    # A JSON string is a YAML double-quoted scalar.  Escaping a character outside the Basic
    # Multilingual Plane, as ensure_ascii does, would yield a surrogate pair, which YAML rejects.
    return json.dumps(s, ensure_ascii=False)


# ---------- commands that update dependent branches ----------


def chain_has_conflict(repo: Repo, prs: list[int], has_upstream: bool) -> bool:
    """Return whether merging a chain of PRs would encounter a textual conflict.

    A later merge receives every earlier branch in the chain.  Therefore, a conflict
    between any 2 PRs in the chain can affect a merge, not only a conflict between 2
    adjacent PRs.  If the chain starts with upstream, every PR also receives upstream.

    Returns:
        True if at least one merge in the chain would conflict.
    """
    return (has_upstream and any(n in repo.master_conflicts for n in prs)) or any(
        branches_conflict(repo, a, b) for a, b in itertools.combinations(prs, 2)
    )


class PushChains(NamedTuple):
    """The `git-push-to` chains of a repository, as push_chains computes them.

    Attributes:
        chains: the chains, each a list of directories, such as ["daikon", "daikon-branch-a"],
            each of which `git-push-to` pushes into the next.
        missing: the numbers, such as 123, of the PRs that have no working copy.
        has_upstream: True if there is a working copy of the upstream default branch.
    """

    chains: list[list[str]]
    missing: list[int]
    has_upstream: bool


def push_chains(model: Model, base: str, conflicts_only: bool = False) -> PushChains:
    """Compute the `git-push-to` chains that update every PR from upstream and its prerequisites.

    Each chain is a list of directories, each of which `git-push-to` pushes into the next.
    Each chain starts with a working copy of the upstream default branch, if there is one.
    A chain may contain a single PR, which has no direct prerequisite or dependent that has
    a working copy; such a chain exists only if there is a working copy of upstream.
    Before a chain pushes into a directory, the chains that precede it have updated that
    directory's prerequisites.
    If conflicts_only is true, retain a whole chain only if merging it would encounter a
    conflict between 2 of its PRs, or between upstream and one of its PRs.
    No chain contains a PR that is in, or depends on, a cycle of dependencies.

    Returns:
        The chains, as a PushChains.
    """
    r = model.repo
    owner, name = r.gh.lower().split("/")
    upstream = [
        d
        for d, info in git_entries(base).items()
        if info == GitEntry(owner, name, r.default_branch)
    ][:1]
    dirs = {n: pr_directories(r, r.prs[n], base) for n in model.open}
    missing = sorted(n for n in model.open if not dirs[n])
    pushable = {n for n in model.open if dirs[n] and n not in model.cycle_affected}
    edges = {(d, n) for n in pushable for d in model.direct[n] if d in pushable}
    in_edge = {n for e in edges for n in e}
    level = model.levels()
    pr_chains = []
    for d, n in sorted(edges, key=lambda e: (level[e[0]], e)):
        if (d, n) not in edges:
            continue
        edges.discard((d, n))
        chain = [d, n]
        # Extend the chain from n only if this chain has made n up to date.
        while len(model.direct[chain[-1]]) == 1:
            nxt = min((m for p, m in edges if p == chain[-1]), default=None)
            if nxt is None:
                break
            edges.discard((chain[-1], nxt))
            chain.append(nxt)
        pr_chains.append(chain)
    if upstream:
        pr_chains += [[n] for n in sorted(pushable) if n not in in_edge]
    # A stable sort, which retains the order of the chains that start at the same level.
    # A PR that is not in the dependency graph has no level; it would be at level 1.
    pr_chains.sort(key=lambda chain: level.get(chain[0], 1))
    chains = [
        upstream + [dirs[n][0] for n in chain]
        for chain in pr_chains
        if not conflicts_only or chain_has_conflict(r, chain, bool(upstream))
    ]
    return PushChains(chains, missing, bool(upstream))


class PushCommands(NamedTuple):
    """The shell commands that update the PRs' branches, as push_commands generates them."""

    lines: list[str]
    """The commands' lines, such as "git-push-to \\"."""
    notes: list[str]
    """Notes about what the commands omit."""
    chain_count: int
    """The number of `git-push-to` chains that the commands run."""

    def is_empty(self) -> bool:
        """Return True if the commands run no chain and have no note.

        Returns:
            True if the commands run no chain and have no note.
        """
        return self.chain_count == 0 and not self.notes


def push_commands(models: list[Model], base: str, conflicts_only: bool = False) -> PushCommands:
    """Return the shell commands that update each PR's branch from upstream and its prerequisites.

    Returns:
        The commands, as a PushCommands.
    """
    lines = [f"cd {base} && \\"]
    notes = []
    chain_count = 0
    for m in models:
        r = m.repo
        chains, missing, has_upstream = push_chains(m, base, conflicts_only)
        chain_count += len(chains)
        for chain in chains:
            lines += ["git-push-to \\", *(f"  {d} \\" for d in chain[:-1]), f"  {chain[-1]}"]
            lines[-1] += " && \\"
        if missing:
            notes.append(
                f"{r.label} PRs with no working copy, which these commands omit: {r.links(missing)}"
            )
        if m.cycle_affected:
            notes.append(
                f"{r.label} PRs in or after a cycle of dependencies, which these commands omit:"
                f" {r.links(sorted(m.cycle_affected))}"
            )
        if not has_upstream and len(missing) < len(m.open):
            notes.append(
                f"No working copy of upstream {r.label} `{r.default_branch}`,"
                " so these commands do not push it"
            )
    lines.append('echo "success"')
    return PushCommands(lines, notes, chain_count)


def gen_push_commands(commands: PushCommands, base: str, conflicts_only: bool = False) -> list[str]:
    """Return the lines of the "push-commands" or "conflicting-push-commands" section.

    Args:
        commands: shell commands that update the PRs' branches
        base: the directory that holds the working copy directories of the repositories
        conflicts_only: True if the lines are those of the "conflicting-push-commands" section,
            whose chains are the ones with conflicts; False if they are those of the
            "push-commands" section

    Returns:
        The section's lines:  a heading; with conflicts_only, an introduction and a suggestion
        to run resolve-conflicts; then the notes of commands; then commands in a fenced code
        block, if they run a chain.  Or no lines if commands run no chain and either
        conflicts_only is true or commands have no note.
    """
    if commands.is_empty() or (conflicts_only and commands.chain_count == 0):
        return []
    lines = []
    if conflicts_only:
        lines += [
            (
                "This subset repeats a whole dependency chain if at least one merge in the chain"
                " would result in a textual conflict."
            ),
            "",
            (
                f"Run `cd {base} && resolve-conflicts`, which runs these commands with an AI"
                " agent's help, repeating until no chain has conflicts."
            ),
            "Alternatively, run the commands yourself.",
            "",
        ]
    lines += [f"{note}." for note in commands.notes]
    if commands.chain_count > 0:
        lines += [""] if commands.notes else []
        lines += ["```sh", *commands.lines, "```"]
    if conflicts_only:
        return headed("Dependency chains with conflicts", None, lines, level=3)
    return headed("All dependency chains", None, lines, level=3)


def gen_updating_branches(models: list[Model], commands: PushCommands) -> list[str]:
    """Generate the "updating-branches" section.

    Args:
        models: a list of the models of the repositories, one per repository
        commands: the shell commands that update the branches of the PRs of the models

    Returns:
        The section's lines:  an "Updating branches" heading and an introduction to the
        "conflicting-push-commands" and "push-commands" sections that follow it, or no lines
        if commands run no chain and have no note.
    """
    if commands.is_empty():
        return []
    if len(models) == 1:
        upstream = f"upstream `{models[0].repo.default_branch}`"
    else:
        upstream = "the upstream default branch"
    lines = [
        "Each command updates one dependency chain.",
        (
            f"It starts with {upstream}, then pushes each PR's branch into the branches of the PRs"
            " that directly depend on it, prerequisites first."
        ),
        f"A chain may consist of {upstream} and a single PR that has no prerequisite or dependent.",
        "`git-push-to` merges, compiles, and pushes; see its documentation.",
    ]
    return headed("Updating branches", None, lines)


# ---------- snapshot and changes ----------


def facts(models: list[Model]) -> dict[str, Any]:
    """Collect the facts that the snapshot records.

    Returns:
        A map from each repository's name to its PRs, dependencies, conflicts with the default
        branch, and unblocked PRs.
    """
    result = {}
    for m in models:
        r = m.repo
        result[r.name] = {
            "prs": {
                str(n): {
                    "title": pr["title"],
                    "head": pr["headRefOid"],
                    "assignees": sorted(m.assignees(n)) if n in m.open else [],
                    "body_sha": hashlib.sha256(pr["body"].encode()).hexdigest(),
                    "stated": sorted(m.stated.get(n, [])),
                }
                for n, pr in r.prs.items()
            },
            "direct": {str(n): sorted(m.direct[n]) for n in m.open},
            "master_conflicts": {str(n): fs for n, fs in r.master_conflicts.items()},
            "unblocked": m.unblocked(),
        }
    return result


def report_changes(models: list[Model], old: dict[str, Any], new: dict[str, Any]) -> list[str]:
    """Compare the facts of the previous snapshot with the current ones.

    Returns:
        One line for each change.
    """
    out = []
    for m in models:
        r = m.repo
        o, n = old.get(r.name), new[r.name]
        if not o:
            out.append(f"{r.label}: no previous snapshot")
            continue
        op, np_ = o["prs"], n["prs"]
        out.extend(
            f"opened: {r.ref(k)} {np_[k]['title']}" for k in sorted(set(np_) - set(op), key=int)
        )
        for k in sorted(set(op) - set(np_), key=int):
            state = r.state_of(int(k)) or "gone"
            out.append(f"{state}: {r.ref(k)} {op[k]['title']}")
        for k in sorted(set(op) & set(np_), key=int):
            a, b = op[k], np_[k]
            ref = r.ref(k)
            if a["title"] != b["title"]:
                out.append(f"retitled: {ref}: {b['title']}")
            if a["assignees"] != b["assignees"]:
                out.append(f"assignees: {ref}: {a['assignees']} -> {b['assignees']}")
            if a["body_sha"] != b["body_sha"]:
                out.append(
                    f"description changed: {ref}"
                    + (
                        f" (stated prerequisites {a['stated']} -> {b['stated']})"
                        if a["stated"] != b["stated"]
                        else ""
                    )
                )
            if a["head"] != b["head"]:
                out.append(f"new commits: {ref}")
        od, nd = o["direct"], n["direct"]
        out.extend(
            f"dependencies: {r.ref(k)}: {od.get(k)} -> {nd[k]}"
            for k in sorted(set(od) | set(nd), key=int)
            if od.get(k) != nd.get(k) and k in nd
        )
        oc: dict[str, list[str]] = o["master_conflicts"]
        nc: dict[str, list[str]] = n["master_conflicts"]
        out.extend(
            f"master conflicts: {r.ref(k)}: {oc.get(k)} -> {nc[k]}"
            for k in sorted(nc, key=int)
            if oc.get(k) != nc[k]
        )
        if o["unblocked"] != n["unblocked"]:
            added = sorted(set(n["unblocked"]) - set(o["unblocked"]))
            removed = sorted(set(o["unblocked"]) - set(n["unblocked"]))
            if added:
                out.append(f"newly unblocked: {r.refs(added)}")
            blocked = [k for k in removed if k in m.open]
            # A landed PR is already reported as landed.
            gone = [k for k in removed if k not in m.open and r.state_of(k) != "landed"]
            if blocked:
                out.append(f"newly blocked: {r.refs(blocked)}")
            if gone:
                out.append(f"no longer unblocked (gone): {r.refs(gone)}")
    return out


# The default branch that GitHub reports for each repository that github_default_branch or
# default_config has read it for, as a map from the repository's GitHub slug, such as
# "ORG/REPO", to the branch, such as "main".
GITHUB_DEFAULT_BRANCHES: dict[str, str] = {}


def github_default_branch(gh: str) -> str:
    """Return the default branch that GitHub reports for the given repository.

    It is read from GitHub at most once per run.

    Args:
        gh: a repository's GitHub slug, such as "ORG/REPO".

    Returns:
        The default branch, such as "main", even if a config names a different one.
    """
    if gh not in GITHUB_DEFAULT_BRANCHES:
        fields = ["--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"]
        GITHUB_DEFAULT_BRANCHES[gh] = run(["gh", "repo", "view", gh, *fields]).strip()
    return GITHUB_DEFAULT_BRANCHES[gh]


def repo_default_branch(rc: dict[str, Any]) -> str:
    """Return the default branch of the repository that the given config entry describes.

    Args:
        rc: a repository's entry in a config, as a dict parsed from the config file's JSON,
            with keys such as "gh" and "default_branch".

    Returns:
        The branch that rc names, or else the one that GitHub reports, such as "main".
    """
    configured = rc.get("default_branch")
    return configured if configured is not None else github_default_branch(rc["gh"])


def fork_source(owner: str, name: str) -> str | None:
    """Return the repository that the given GitHub repository is a fork of, at its root.

    Args:
        owner: the owner of a GitHub repository, such as "mernst".
        name: the repository's name, such as "daikon".

    Returns:
        The lowercase GitHub slug of the repository that owner/name was ultimately forked
        from, such as "codespecs/daikon"; or None if owner/name is not a fork or gh cannot
        view it.
    """
    try:
        source = run(["gh", "api", f"repos/{owner}/{name}", "--jq", '.source.full_name // ""'])
    except subprocess.CalledProcessError:
        return None
    return source.strip().lower() or None


def find_clone(base: str, owner: str, name: str, default_branch: Callable[[], str]) -> str | None:
    """Return the clone in base of the GitHub repository owner/name, or of a fork of it.

    A fork counts only if it has the same name.  The clone is a clone of owner/name itself
    if there is one, and among several, a clone whose current branch is the default branch,
    which has no branch of its own to disturb.  If there is no clone of owner/name itself,
    GitHub is asked which of the clones' origins are forks of owner/name.

    Args:
        base: the directory that holds the working copy directories.
        owner: the owner of a GitHub repository, such as "codespecs".
        name: the repository's name, such as "daikon".
        default_branch: a function that returns the repository's default branch, such as
            "main"; it is called only if base holds more than one candidate clone.

    Returns:
        The clone's path, or None if base holds no clone of the repository or of a fork.
    """
    entries = git_entries(base)
    owner, name = owner.lower(), name.lower()
    named = sorted(d for d, info in entries.items() if info.owner and info.repo_name == name)
    clones = [d for d in named if entries[d].owner == owner]
    if not clones:
        forks = {
            o
            for o in {entries[d].owner for d in named}
            if fork_source(o, name) == f"{owner}/{name}"
        }
        clones = [d for d in named if entries[d].owner in forks]
    if not clones:
        return None
    if len(clones) > 1:
        branch = default_branch()
        clones.sort(key=lambda d: (entries[d].owner != owner, entries[d].branch != branch, d))
    return str(pathlib.Path(base) / clones[0])


def default_config(base: str) -> dict[str, Any]:
    """Construct the config to use when there is no config file.

    The config describes each GitHub repository that at least 2 of the git clones in base
    are clones of (or, if there is none, the one that the most clones are clones of), or its
    upstream if that repository is a fork with the same name.  Clones are grouped by
    repository name, so the clones of a repository and of its forks are counted together.
    The config has no notes or decisions, and its only document is pr-status.md.
    (Its "Unblocked PRs" sections serve in place of an unblocked document.)

    Returns:
        The default config, with each default that pr_status_config.with_defaults sets.

    Raises:
        ConfigError: if base contains no clone of a GitHub repository that gh can view.
    """
    # The clones of repositories on GitHub.
    clones = {d: info for d, info in git_entries(base).items() if info.owner}
    if not clones:
        msg = f"no {pr_status_config.CONFIG} and no clone of a GitHub repository in {base}"
        raise ConfigError(msg)
    counts = Counter(info.repo_name for info in clones.values()).most_common()
    names = [name for name, count in counts if count >= 2] or [counts[0][0]]
    fields = ["--json", "nameWithOwner,parent,defaultBranchRef"]
    repos: dict[str, dict[str, Any]] = {}
    for name in names:
        first_owner = next(info.owner for info in clones.values() if info.repo_name == name)
        try:
            j = json.loads(run(["gh", "repo", "view", f"{first_owner}/{name}", *fields]))
            parent = j["parent"]
            # A renamed fork, such as of a large project, is a project of its own.
            if parent and parent["name"].lower() == name:
                j = json.loads(
                    run(
                        [
                            "gh",
                            "repo",
                            "view",
                            f"{parent['owner']['login']}/{parent['name']}",
                            *fields,
                        ]
                    )
                )
        except subprocess.CalledProcessError as error:
            print(
                f"pr-status: skipping {name}: {error.stderr.strip()}",
                file=sys.stderr,
            )
            continue
        gh = j["nameWithOwner"]
        if any(r["gh"] == gh for r in repos.values()):
            continue
        default_branch = j["defaultBranchRef"]["name"]
        # Repo reads the default branch from here, so that the config, which --print-config
        # prints, need not name it.
        GITHUB_DEFAULT_BRANCHES[gh] = default_branch
        clone = find_clone(base, gh.split("/")[0], name, lambda b=default_branch: b)
        if clone is None:
            continue
        repos[gh.split("/")[1]] = {"gh": gh, "clone": clone}
    if not repos:
        msg = f"no {pr_status_config.CONFIG} and no GitHub repository that gh can view"
        raise ConfigError(msg)
    print(
        "pr-status: reporting on " + and_list(r["gh"] for r in repos.values()),
        file=sys.stderr,
    )
    return pr_status_config.with_defaults({"repos": repos})


def load_config(program: str) -> dict[str, Any]:
    """Return the config for the current directory, which holds the working copy directories.

    Exit with an error message if the current directory is in a git working copy, if the
    config file is not a valid config, if the config names no clone of a repository and the
    current directory holds none, or if there is no config file and default_config cannot
    construct a config.

    Args:
        program: the name of the running program; used for diagnostics.

    Returns:
        The config, as pr_status_config.read_config_file returns it, with a clone for each
        repository; or, if there is no config file, as default_config constructs it.
    """
    base = str(pathlib.Path.cwd())
    # The current directory holds the working copy directories; it is not one of them.
    toplevel = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], check=False, capture_output=True, text=True
    )
    if toplevel.returncode == 0:
        sys.exit(
            f"{program}: {base} is in the git working copy {toplevel.stdout.strip()}; "
            f"run {program} in the directory that holds the working copy directories"
        )
    cfg = pr_status_config.read_config_file(program)
    if cfg is None:
        try:
            return default_config(base)
        except ConfigError as error:
            sys.exit(f"{program}: {error}")
    problems = []
    for key, rc in cfg["repos"].items():
        if "clone" in rc:
            continue
        owner, name = rc["gh"].split("/")
        clone = find_clone(
            base,
            owner,
            name,
            lambda rc=rc: repo_default_branch(rc),
        )
        if clone is None:
            problems.append(
                f'{pr_status_config.key_path("repos", key)} has no "clone", and {base} holds'
                f" no clone of {rc['gh']} or of a fork of it"
            )
        rc["clone"] = clone
    if problems:
        sys.exit("\n".join(f"{program}: {pr_status_config.CONFIG}: {p}" for p in problems))
    return cfg


def shell_word(word: str) -> str:
    """Return the given word, quoted if a shell would not otherwise read it as that one word.

    Unlike shlex.quote, this does not quote a word for a "#" that does not start it, such as
    the one in "repo#100", because a shell treats such a "#" as an ordinary character.

    Args:
        word: a command-line argument, such as "repo#100".

    Returns:
        word, or word quoted for a shell.
    """
    unquoted = word.replace("#", "")
    if word.startswith("#") or shlex.quote(unquoted) != unquoted:
        return shlex.quote(word)
    return word


def main() -> None:
    """Report changes and regenerate the documents."""
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="report changes, but change no document, snapshot, PR description, or directory",
    )
    parser.add_argument(
        "--print-document",
        action="store_true",
        help="print the file name of the dependency document, and do nothing else",
    )
    parser.add_argument(
        "--print-config",
        action="store_true",
        help="print the config as JSON, with its defaults filled in, and do nothing else",
    )
    parser.add_argument(
        "-C",
        "--directory",
        metavar="DIR",
        help="change to DIR before doing anything else",
    )
    parser.add_argument(
        "--highlight",
        action="extend",
        nargs="+",
        default=[],
        metavar="PR",
        help=(
            "in the documents, highlight each PR (such as REPO#N or ORG/REPO#N) and every PR"
            " that must land for it to land:  the PRs that it depends on or lands with,"
            " recursively"
        ),
    )
    args = parser.parse_args()
    check_only = args.check
    if args.directory is not None:
        try:
            os.chdir(args.directory)
        except OSError as error:
            sys.exit(f"pr-status: cannot change to directory {args.directory}: {error.strerror}")
    if args.print_document:
        print(
            pr_status_config.dependency_document_name(
                pr_status_config.read_config_file("pr-status")
            )
        )
        return
    if args.print_config:
        print(json.dumps(load_config("pr-status"), indent=2))
        return
    base = str(pathlib.Path.cwd())
    cfg = load_config("pr-status")
    dependencies = pathlib.Path(pr_status_config.dependency_document_name(cfg))
    models = load_models(cfg)
    try:
        HIGHLIGHTED.update(needed_to_land(models, resolve_pr_names(models, args.highlight)))
    except ValueError as error:
        sys.exit(f"pr-status: --highlight: {error}")
    updates = description_updates(models)
    failed_updates = []
    if not check_only:
        failed_updates = apply_description_updates(updates, cfg)
    now = dt.datetime.now().astimezone()
    # A 24-hour clock, with "am" after a morning time, as in "2026-11-05 09:07am PST"
    # and "2026-11-05 15:07 PST".
    am = "am" if now.hour < 12 else ""
    as_of = f"{now:%Y-%m-%d %H:%M}{am} {now:%Z}"
    if HIGHLIGHTED:
        command = " ".join(shell_word(w) for w in ["pr-status", "--highlight", *args.highlight])
        as_of += f", by `{command}`"
    new = facts(models)
    old = {}
    if pathlib.Path(pr_status_config.SNAPSHOT).exists():
        with pathlib.Path(pr_status_config.SNAPSHOT).open() as f:
            old = json.load(f)
    changes = report_changes(models, old.get("facts", {}), new)
    if changes:
        print(f"## Changes since the previous snapshot ({old.get('time', 'none')})")
        for line in changes:
            print(line)
    for m in models:
        if m.cyclic:
            print(
                f"pr-status: warning: a cycle of dependencies contains {m.repo.refs(m.cyclic)};"
                " the push commands omit the cycle and the PRs that depend on it",
                file=sys.stderr,
            )
    problems, renames = directory_problems(models, base, fix=not check_only)
    if renames:
        print("## Fixed directories, to match their branch's PR")
        for line in renames:
            print(line)
    if problems:
        print("## Directories whose name or origin does not match their branch's PR")
        for line in problems:
            print(line)
    # Print each distinct error once, listing every PR that it affected.
    refs_by_detail: dict[str, list[str]] = {}
    for m, n, error in failed_updates:
        refs_by_detail.setdefault(error.stderr.strip(), []).append(m.repo.ref(n))
    for detail, refs in refs_by_detail.items():
        print(
            f"pr-status: in {base}: could not update the description of {and_list(refs)}"
            + (f": {detail}" if detail else ""),
            file=sys.stderr,
        )
    if failed_updates:
        stale_descriptions = [(m, n) for m in models for n in sorted(m.open) if m.stated_closed[n]]
        if stale_descriptions:
            print("## GitHub PR descriptions that name landed or closed PRs as prerequisites")
            for m, n in stale_descriptions:
                print(
                    f"{m.repo.ref(n)}: "
                    + ", ".join(f"{m.repo.ref(c.number)} ({c.state})" for c in m.stated_closed[n])
                )
    if updates and check_only:
        print("## GitHub PR descriptions need updates")
        for m, n, _ in updates:
            print(m.repo.ref(n))
    if check_only:
        return
    unblocked_docs = cfg["documents"].get("unblocked", [])
    for doc in unblocked_docs:
        pathlib.Path(doc["file"]).write_text(unblocked_doc(models, cfg, base, doc, as_of))
    title = f"{pathlib.Path(base).name} PR status"
    dependencies.write_text(dependency_document(models, cfg, base, as_of, title))
    with pathlib.Path(pr_status_config.SNAPSHOT).open("w") as f:
        json.dump({"time": now.isoformat(timespec="seconds"), "facts": new}, f, indent=1)
    written = [d["file"] for d in unblocked_docs]
    written += [str(dependencies), pr_status_config.SNAPSHOT]
    print(f"## Wrote {and_list(written)}")
    if failed_updates:
        sys.exit(1)


if __name__ == "__main__":
    main()
