"""Tests for the pr-status script that do not access GitHub or local repositories."""

import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

TOPLEVEL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOPLEVEL))

import pr_status  # ruff: ignore[module-import-not-at-top-of-file]
import pr_status_config  # ruff: ignore[module-import-not-at-top-of-file]

REPO = types.SimpleNamespace(gh="owner/repo", keywords=[])


class TableRowTest(unittest.TestCase):
    """Tests for table_row."""

    def test_escapes_pipes_within_cells(self):
        """A pipe within a cell does not create another Markdown table column."""
        self.assertEqual(
            pr_status.table_row(["Unbox && and ||", "second"]),
            r"| Unbox && and \|\| | second |",
        )
        self.assertEqual(pr_status.table_row([r"already \| escaped"]), r"| already \| escaped |")

    def test_pads_each_cell_with_one_space(self):
        """Each cell has exactly one space on each side, and an empty cell is "| |"."""
        self.assertEqual(
            pr_status.table_row([" leading", "trailing  ", "", " ", " both "]),
            "| leading | trailing | | | both |",
        )


class UpdatedPrDescriptionTest(unittest.TestCase):
    """Tests for updated_pr_description."""

    def test_adds_sorted_lines_before_body(self):
        """New landing-order lines precede the existing description."""
        self.assertEqual(
            pr_status.updated_pr_description("Description.", REPO, {30, 10}, {40, 20}),
            "Land after #10.\nLand after #30.\nLand before #20.\nLand before #40.\n\nDescription.",
        )

    def test_moves_final_block_to_beginning(self):
        """A landing-order block that ends the description moves to its beginning."""
        body = "Description.\n\nMore.\n\nLand after #10.\n\nLand before #30.\n\n"
        self.assertEqual(
            pr_status.updated_pr_description(body, REPO, {10}, {30}),
            "Land after #10.\nLand before #30.\n\nDescription.\n\nMore.\n",
        )

    def test_retains_block_within_body(self):
        """A landing-order block that is followed by other text stays where it is."""
        body = "Description.\n\nLand after #10.\n\nDetails.\n"
        self.assertEqual(pr_status.updated_pr_description(body, REPO, {10}, set()), body)

    def test_replaces_lines_and_retains_land_with(self):
        """All 3 groups use the conventional order."""
        body = "Description.\n\nLand before #90.\nLand with #50.\nLand after #80.\n\nDetails.\n"
        self.assertEqual(
            pr_status.updated_pr_description(body, REPO, {20, 10}, {40, 30}),
            "Description.\n\nLand after #10.\nLand after #20.\nLand with #50.\n"
            "Land before #30.\nLand before #40.\n\nDetails.\n",
        )

    def test_land_with_takes_precedence(self):
        """A land-with relationship is not also written as a before/after relationship."""
        body = "Land with #20."
        self.assertEqual(
            pr_status.updated_pr_description(body, REPO, {10, 20}, {20, 30}),
            "Land after #10.\nLand with #20.\nLand before #30.",
        )

    def test_removes_obsolete_block_and_separator(self):
        """Removing a final landing-order block does not leave a blank line."""
        self.assertEqual(
            pr_status.updated_pr_description(
                "Description.\n\nLand after #10.\n", REPO, set(), set()
            ),
            "Description.\n",
        )

    def test_preserves_unconventional_prose(self):
        """Only complete conventional lines are managed."""
        body = "Please land after #10 because the API changes."
        self.assertEqual(pr_status.updated_pr_description(body, REPO, set(), set()), body)

    def test_retains_text_of_lenient_lines(self):
        """A lenient landing-order line that is still correct is retained verbatim."""
        body = (
            "Description.\n\nLand before #30\n"
            "Land after https://github.com/owner/repo/pull/10.  Until #10 lands, it is here.\n"
            "Land after #20, which is obsolete.\n\nDetails.\n"
        )
        self.assertEqual(
            pr_status.updated_pr_description(body, REPO, {10}, {30}),
            "Description.\n\n"
            "Land after https://github.com/owner/repo/pull/10.  Until #10 lands, it is here.\n"
            "Land before #30\n\nDetails.\n",
        )

    def test_idempotent(self):
        """An up-to-date description is unchanged."""
        body = "Land after #10.\nLand with #20.\nLand before #30.\n\nDescription."
        self.assertEqual(pr_status.updated_pr_description(body, REPO, {10}, {30}), body)

    def test_land_with_takes_precedence_in_both_descriptions(self):
        """Land-with suppresses a generated line in the other PR's description."""
        repo = types.SimpleNamespace(
            gh="owner/repo", prs={1: {"body": "Land with #2."}, 2: {"body": ""}}
        )
        model = types.SimpleNamespace(
            repo=repo,
            open={1, 2},
            direct={1: {2}, 2: set()},
            dependents={1: set(), 2: {1}},
            unit={1: {1, 2}, 2: {1, 2}},
            external={1: [], 2: []},
        )
        self.assertEqual(pr_status.description_updates([model]), [])

    def test_replaces_external_prerequisites(self):
        """A PR in another repository that is no longer a prerequisite is removed."""
        body = "Land after other/repo#1592.\nLand after other/repo#1625.\n\nDescription.\n"
        self.assertEqual(
            pr_status.updated_pr_description(body, REPO, set(), set(), ["other/repo#1625"]),
            "Land after other/repo#1625.\n\nDescription.\n",
        )

    def test_adds_sorted_external_prerequisites(self):
        """External prerequisites follow the prerequisites in the PR's own repository."""
        self.assertEqual(
            pr_status.updated_pr_description(
                "Description.", REPO, {10}, set(), ["other/repo#1000", "other/repo#999", "a/b#5"]
            ),
            "Land after #10.\nLand after a/b#5.\n"
            "Land after other/repo#999.\nLand after other/repo#1000.\n\nDescription.",
        )

    def test_retains_external_land_with_and_land_before(self):
        """External land-with and land-before lines are retained."""
        body = "Land before other/repo#3.\nLand with other/repo#2.\nLand after other/repo#1."
        self.assertEqual(
            pr_status.updated_pr_description(body, REPO, set(), set(), ["other/repo#2"]),
            "Land with other/repo#2.\nLand before other/repo#3.",
        )


class MalformedLandingLinesTest(unittest.TestCase):
    """Tests for malformed_landing_lines."""

    def test_finds_malformed_lines(self):
        """Only lines that start like a landing-order line but are not one are found."""
        body = (
            "Land after #10.\nLand after #10 and #20.\nLand with #30\nLand before PR 40.\n"
            "Land after\nLand with#50.\nLand before\t#60.\n"
            "Land before other/repo#5.\nPlease land after #10.\nLanding after #10.\n"
            "Land without #70.\nLand afterwards.\n"
        )
        self.assertEqual(
            pr_status.malformed_landing_lines(body, REPO),
            [
                "Land after #10 and #20.",
                "Land before PR 40.",
                "Land after",
                "Land with#50.",
                "Land before\t#60.",
            ],
        )

    def test_accepts_lenient_lines(self):
        """A line may omit its period, and its other text may name only the same PR."""
        body = (
            "Land after #10, which changes the API.\n"
            "Land after https://github.com/owner/repo/pull/20.  Until #20 lands, the diff"
            " includes #20's changes.\n"
            "Land with https://github.com/other/repo/pull/30\n"
            "Land before owner/repo#40\n"
            "Land after #50, which needs #60.\n"
            "Land after #70.  See https://github.com/other/repo/pull/70.\n"
        )
        self.assertEqual(
            pr_status.malformed_landing_lines(body, REPO),
            [
                "Land after #50, which needs #60.",
                "Land after #70.  See https://github.com/other/repo/pull/70.",
            ],
        )


class LandingLineTest(unittest.TestCase):
    """Tests for landing_line."""

    def test_normalizes_ref(self):
        """A PR in the same repository is "#N", and others are "owner/repo#N"."""
        self.assertEqual(pr_status.landing_line("Land after #10.", REPO), ("after", "#10"))
        self.assertEqual(
            pr_status.landing_line("Land before https://github.com/owner/repo/pull/20", REPO),
            ("before", "#20"),
        )
        self.assertEqual(
            pr_status.landing_line("Land with https://github.com/other/repo/pull/30", REPO),
            ("with", "other/repo#30"),
        )


class StatedPrerequisitesTest(unittest.TestCase):
    """Tests for stated_relations."""

    repo = types.SimpleNamespace(gh="owner/repo", keywords=[])

    def test_land_with_is_partner(self):
        """A land-with PR is a partner, not a prerequisite."""
        self.assertEqual(
            pr_status.stated_relations("Land with #5.", self.repo),
            (set(), set(), set(), {5}, set()),
        )

    def test_after_with_before(self):
        """One sentence can name a prerequisite, a partner, and a dependent."""
        self.assertEqual(
            pr_status.stated_relations("Land it after #1, with #2, and before #3.", self.repo),
            ({1}, set(), {3}, {2}, set()),
        )

    def test_this_pr_as_object(self):
        """In "land after it", the named PRs land after this PR."""
        self.assertEqual(
            pr_status.stated_relations("To land after it: #1 and #2.", self.repo),
            (set(), set(), {1, 2}, set(), set()),
        )
        self.assertEqual(
            pr_status.stated_relations("To land before this PR: #3.", self.repo),
            ({3}, set(), set(), set(), set()),
        )

    def test_land_with_other_repository(self):
        """A land-with PR in another repository is an external partner."""
        self.assertEqual(
            pr_status.stated_relations("Land with other/repo#5.", self.repo),
            (set(), set(), set(), set(), {"other/repo#5"}),
        )

    def test_negation(self):
        """A negated keyword names no relationship."""
        none = (set(), set(), set(), set(), set())
        for body in [
            "This PR does not depend on any of them:\n* #5 and #6:  refactorings.",
            "It doesn't depend on #5.",
            "It doesn\u2019t really depend on #5.",
            "It no longer builds on #5.",
            "Do not land after #5.",
        ]:
            with self.subTest(body=body):
                self.assertEqual(pr_status.stated_relations(body, self.repo), none)
        self.assertEqual(
            pr_status.stated_relations("It is not new, but it depends on #5.", self.repo),
            ({5}, set(), set(), set(), set()),
        )


class ModelTest(unittest.TestCase):
    """Tests for Model."""

    @staticmethod
    def raw_model(bodies, contains, gh="owner/repo"):
        """Build a model, without its graph, of open PRs.

        The PRs have the given descriptions and branch containment.

        Returns:
            The model.
        """
        prs = {
            n: {"body": body, "baseRefName": "master", "owner": "owner", "headRefName": f"b{n}"}
            for n, body in bodies.items()
        }
        repo = types.SimpleNamespace(
            name=gh,
            gh=gh,
            prefix=f"{gh.split('/')[1]}#",
            owner=gh.split("/")[0],
            default_branch="master",
            keywords=[],
            prs=prs,
            contains=contains,
            closed_state={},
            state_of=lambda _: None,
        )
        return pr_status.Model(repo, {"repos": {gh: {}}})

    def model(self, bodies, contains):
        """Build a model of open PRs with the given descriptions and branch containment.

        Returns:
            The model.
        """
        model = self.raw_model(bodies, contains)
        pr_status.unite_partners([model])
        return model

    def test_containment_is_dependency(self):
        """A PR whose branch contains another's commits depends on it."""
        model = self.model({1: "", 2: ""}, {(1, 2)})
        self.assertEqual(model.blocked(), [1])

    def test_land_with_containment_is_not_dependency(self):
        """A PR does not depend on its land-with partner, even if it contains its commits."""
        for bodies in ({1: "Land with #2.", 2: ""}, {1: "", 2: "Land with #1."}):
            model = self.model(bodies, {(1, 2)})
            self.assertEqual(model.blocked(), [])

    def test_dependency_on_pr_covers_its_land_with_partner(self):
        """A dependency on a land-with partner is not direct if the PR contains the partner."""
        model = self.model({1: "Land with #2.", 2: "", 3: ""}, {(1, 2), (3, 1), (3, 2)})
        self.assertEqual(model.direct[3], {1})
        self.assertEqual(model.all_deps[3], {1, 2})

    def test_unit_members_share_prerequisites(self):
        """Each member of a unit depends on the prerequisites of every member."""
        model = self.model({1: "Land with #2.", 2: "Land with #3.", 3: "", 4: ""}, {(3, 4)})
        self.assertEqual(model.blocked(), [1, 2, 3])
        self.assertEqual(model.direct, {1: {4}, 2: {4}, 3: {4}, 4: set()})

    def test_unit_spans_repositories(self):
        """A unit's members in different repositories share their prerequisites."""
        a = self.raw_model({1: "Land with other/repo#5.", 2: ""}, set())
        b = self.raw_model(
            {5: "Land after #6.", 6: "", 7: "Land with owner/repo#2."}, set(), "other/repo"
        )
        pr_status.unite_partners([a, b])
        self.assertEqual(a.blocked(), [1])
        self.assertEqual(a.external[1], ["other/repo#6"])
        self.assertEqual(b.blocked(), [5])
        self.assertEqual(b.external[7], [])

    def test_cycle_affects_its_dependents(self):
        """A cycle affects its members and the PRs that depend on them, but no prerequisite."""
        model = self.model(
            {1: "Land after #2.", 2: "Land after #1.", 3: "Land after #1.", 4: ""}, {(1, 4)}
        )
        self.assertEqual(model.cyclic, [1, 2])
        self.assertEqual(model.cycle_affected, {1, 2, 3})

    def test_cycle_is_blocked(self):
        """The PRs in or after a cycle are blocked, even with no direct prerequisite."""
        model = self.model(
            {1: "Land after #2.", 2: "Land after #3.", 3: "Land after #1.", 4: "Land after #1."},
            set(),
        )
        self.assertEqual(model.direct, {1: set(), 2: set(), 3: set(), 4: set()})
        self.assertEqual(model.blocked(), [1, 2, 3, 4])
        self.assertEqual(model.unblocked(), [])
        self.assertEqual(model.independent(), [])

    def conflicting_model(self):
        """Return the model of open PRs 1 to 4, whose branches conflict.

        PR 1 depends on 2, which depends on 3; PR 4 depends on 3.  PRs 1 and 3 conflict with
        the default branch in c.txt.  PR 2 conflicts with 1 in b.txt and with 3 in a.txt, and
        PR 1 conflicts with 3 in c.txt.

        Returns:
            The model, whose repository has no review threads and no CI results.
        """
        model = self.model(
            {1: "Land after #2.", 2: "Land after #3.", 3: "", 4: "Land after #3."}, set()
        )
        repo = model.repo
        repo.reviews_and_ci = pr_status.ReviewsAndCi({}, set(), set())
        repo.master_conflicts = {1: ["c.txt"], 3: ["c.txt"]}
        repo.pair_conflicts = {(1, 2): ["b.txt"], (1, 3): ["c.txt"], (2, 3): ["a.txt"]}
        repo.link = lambda n: f"#{n}"
        repo.links = lambda ns: pr_status.and_list(f"#{n}" for n in sorted(ns))
        return model

    def test_unresolved_threads_shows_conflict_with_direct_prerequisite(self):
        """The cell shows 🔀 only if merging the default branch or a direct prerequisite conflicts.

        PR 1's conflict with 3 is not with a direct prerequisite.  2 vs 3 is reported for 2,
        the dependent, not for 3.
        """
        model = self.conflicting_model()
        self.assertEqual(
            [model.unresolved_threads(n) for n in (1, 2, 3, 4)], ["🔀", "🔀", "🔀", ""]
        )
        model.repo.master_conflicts = {}
        model.repo.pair_conflicts = {(1, 3): ["c.txt"], (2, 3): ["a.txt"]}
        self.assertEqual([model.unresolved_threads(n) for n in (1, 2, 3, 4)], ["", "🔀", "", ""])

    def test_unresolved_threads_separates_parts_by_one_space(self):
        """The cell's parts are separated by one space, with none at either end."""
        model = self.conflicting_model()
        model.repo.reviews_and_ci = pr_status.ReviewsAndCi(
            {1: [True, False], 4: [False]}, {1, 2}, {1, 4}
        )
        self.assertEqual(
            [model.unresolved_threads(n) for n in (1, 2, 3, 4)],
            ["2 (1 outdated) ❌ 🔀", "❌ 🔀", "🔀", "1 ✅"],
        )

    def test_depends_on_marks_conflicting_direct_prerequisites(self):
        """The cell shows 🔀 after each conflicting direct prerequisite, or else after master."""
        model = self.conflicting_model()
        self.assertEqual(
            [pr_status.depends_on(model, n) for n in (1, 2, 4)],
            ["#2 🔀 (and transitively #3)", "#3 🔀", "#3"],
        )
        model.repo.pair_conflicts = {(1, 3): ["c.txt"], (2, 3): ["a.txt"]}
        self.assertEqual(
            pr_status.depends_on(model, 1), "#2 (and transitively #3) (and `master` 🔀)"
        )

    def test_textual_conflicts_names_routine_conflicts_with_master(self):
        """The cell names the default branch if PR 3 conflicts with it only in routine files."""
        model = self.conflicting_model()
        cfg = {"repos": {model.repo.name: {"routine_files": ["a.txt"]}}}
        model.repo.master_conflicts[3] = ["a.txt"]
        self.assertEqual(
            pr_status.textual_conflicts(model, cfg, 3),
            "`c.txt` with #1; routine files in `master` 🔀",
        )
        model.repo.master_conflicts[3] = ["a.txt", "c.txt"]
        self.assertEqual(pr_status.textual_conflicts(model, cfg, 3), "`c.txt` with `master`")


class HighlightTest(unittest.TestCase):
    """Tests for highlight_selection, resolve_pr_names, needed_to_land, and highlight."""

    def models(self):
        """Build models of two repositories, whose PRs depend on each other's.

        Returns:
            The models.
        """
        with mock.patch.dict(pr_status.EXTERNAL_STATE, {"other/repo#5": "open"}):
            a = ModelTest.raw_model(
                {1: "Land after #2.", 2: "Land after other/repo#5.", 3: "", 4: "Land after #1."},
                set(),
            )
        b = ModelTest.raw_model({5: "Land after #6.", 6: "", 7: ""}, set(), "other/repo")
        pr_status.unite_partners([a, b])
        return [a, b]

    def test_resolves_names(self):
        """A PR is named by its repository's GitHub slug, name, or reference prefix."""
        models = self.models()
        self.assertEqual(
            pr_status.highlight_selection(models, ["Owner/Repo#1, other/repo#5", "other/repo#6"]),
            {("owner/repo", 1), ("other/repo", 5), ("other/repo", 6)},
        )

    def test_selects_nested(self):
        """The word "nested" selects the PR that starts each longest path of prerequisites."""
        models = self.models()
        self.assertEqual(
            pr_status.highlight_selection(models, ["nested"]),
            {("owner/repo", 2), ("other/repo", 6)},
        )
        self.assertEqual(
            pr_status.highlight_selection(models, ["Nested,other/repo#7"]),
            {("owner/repo", 2), ("other/repo", 6), ("other/repo", 7)},
        )

    def test_deepest_roots(self):
        """Each PR that starts a longest path of prerequisites is a deepest root."""
        model = ModelTest.raw_model(
            {
                1: "",
                2: "",
                3: "Land after #1.\nLand after #2.",
                4: "Land after #3.",
                5: "Land after #2.",
                6: "",
                7: "Land after #6.",
                8: "",
            },
            set(),
        )
        pr_status.unite_partners([model])
        self.assertEqual(model.deepest_roots(), {1, 2})
        empty = ModelTest.raw_model({1: "", 2: ""}, set())
        pr_status.unite_partners([empty])
        self.assertEqual(empty.deepest_roots(), set())

    def test_rejects_bad_names(self):
        """A name must name one repository and an open PR of it."""
        models = self.models()
        for name in ("repo#1", "third/repo#1", "owner/repo#9", "owner/repo", "owner/repo#x"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                pr_status.resolve_pr_names(models, [name])

    def test_transitive_prerequisites_span_repositories(self):
        """The prerequisites of a PR include its transitive ones, in any repository."""
        self.assertEqual(
            pr_status.needed_to_land(self.models(), {("owner/repo", 1)}),
            {("owner/repo", 1), ("owner/repo", 2), ("other/repo", 5), ("other/repo", 6)},
        )

    def test_land_with_partners(self):
        """A PR's land-with partners, in any repository, must land with it."""
        a = ModelTest.raw_model({1: "Land with #2.", 2: "", 3: "", 4: ""}, set())
        b = ModelTest.raw_model(
            {5: "Land with owner/repo#2.", 6: "", 7: "Land after #5."}, {(5, 6)}, "other/repo"
        )
        pr_status.unite_partners([a, b])
        self.assertEqual(
            pr_status.needed_to_land([a, b], {("owner/repo", 1)}),
            {("owner/repo", 1), ("owner/repo", 2), ("other/repo", 5), ("other/repo", 6)},
        )

    def test_highlights_links(self):
        """A link to a highlighted PR, in this or another repository, is highlighted."""
        repo = pr_status.Repo(
            "repo",
            {
                "gh": "Owner/Repo",
                "clone": "/base/repo",
                "prefix": "#",
                "label": "repo",
                "node_prefix": "pr",
                "default_branch": "master",
            },
        )
        with mock.patch.object(pr_status, "HIGHLIGHTED", {("owner/repo", 1), ("other/repo", 5)}):
            self.assertEqual(
                repo.link(1),
                '<span style="background-color:#fcc">'
                "**[#1](https://github.com/Owner/Repo/pull/1)**</span>",
            )
            self.assertEqual(repo.link(2), "[#2](https://github.com/Owner/Repo/pull/2)")
            self.assertEqual(
                pr_status.external_link("other/repo#5"),
                '<span style="background-color:#fcc">'
                "**[other/repo#5](https://github.com/other/repo/pull/5)**</span>",
            )


class DependsOnTest(unittest.TestCase):
    """Tests for depends_on."""

    @staticmethod
    def repo(gh, failed):
        """Build a Repo whose CI results are loaded.

        Returns:
            A Repo with GitHub slug gh, whose PRs in failed failed CI.
        """
        repo = pr_status.Repo(
            gh,
            {
                "gh": gh,
                "clone": "/base/repo",
                "prefix": "#",
                "label": gh,
                "node_prefix": "pr",
                "default_branch": "master",
            },
        )
        repo.reviews_and_ci = pr_status.ReviewsAndCi({}, set(failed), set())
        return repo

    def test_marks_failed_prerequisites(self):
        """A direct, transitive, or external prerequisite whose CI failed has a red X."""
        repo = self.repo("owner/repo", {3})
        repo.prs = {
            n: {"body": body, "baseRefName": "master", "owner": "owner", "headRefName": f"b{n}"}
            for n, body in {
                1: "Land after #2.",
                2: "Land after #3.\nLand after other/repo#5.",
                3: "",
            }.items()
        }
        other = self.repo("other/repo", {5})
        other.prs = {
            5: {"body": "", "baseRefName": "master", "owner": "owner", "headRefName": "b5"}
        }
        with mock.patch.dict(pr_status.EXTERNAL_STATE, {"other/repo#5": "open"}):
            model = pr_status.Model(repo, {"repos": {"owner/repo": {}}})
        other_model = pr_status.Model(other, {"repos": {"other/repo": {}}})
        pr_status.unite_partners([model, other_model])

        def link(gh, n):
            return (
                f"[{'#' if gh == 'owner/repo' else gh + '#'}{n}](https://github.com/{gh}/pull/{n})"
            )

        self.assertEqual(
            pr_status.depends_on(model, 2, mark_failed=True),
            f"{link('owner/repo', 3)} ❌ and {link('other/repo', 5)} ❌",
        )
        self.assertEqual(
            pr_status.depends_on(model, 1, mark_failed=True),
            f"{link('owner/repo', 2)} (and transitively {link('owner/repo', 3)} ❌)",
        )
        self.assertEqual(
            pr_status.depends_on(model, 2),
            f"{link('owner/repo', 3)} and {link('other/repo', 5)}",
        )


class ShellWordTest(unittest.TestCase):
    """Tests for shell_word."""

    def test_quotes_only_when_needed(self):
        """A "#" within a word needs no quoting, but one that starts a word does."""
        self.assertEqual(pr_status.shell_word("repo#100"), "repo#100")
        self.assertEqual(pr_status.shell_word("#100"), "'#100'")
        self.assertEqual(pr_status.shell_word("a#1, b#2"), "'a#1, b#2'")


class ApplyDescriptionUpdatesTest(unittest.TestCase):
    """Tests for apply_description_updates."""

    def test_failed_update_does_not_change_local_description(self):
        """A rejected GitHub update is returned and leaves the fetched body intact."""
        repo = types.SimpleNamespace(
            gh="owner/repo", prs={1: {"body": "old"}}, ref=lambda n: f"#{n}"
        )
        model = types.SimpleNamespace(repo=repo)
        error = pr_status.subprocess.CalledProcessError(1, ["gh"], stderr="denied")
        with (
            mock.patch.object(pr_status, "run", side_effect=error),
            mock.patch.object(pr_status, "refresh_description_facts") as refresh,
        ):
            update = pr_status.DescriptionUpdate(model, 1, "new")
            failures = pr_status.apply_description_updates([update], {})
        self.assertEqual(failures, [pr_status.FailedDescriptionUpdate(model, 1, error)])
        self.assertEqual(repo.prs[1]["body"], "old")
        refresh.assert_not_called()


class ChainHasConflictTest(unittest.TestCase):
    """Tests for chain_has_conflict."""

    def test_clean_chain(self):
        """A chain with no reported conflict is clean."""
        repo = types.SimpleNamespace(master_conflicts={}, pair_conflicts={})
        self.assertFalse(pr_status.chain_has_conflict(repo, [1, 2, 3], True))

    def test_master_conflict_anywhere_in_chain(self):
        """An upstream conflict in a later PR affects the merge that reaches that PR."""
        repo = types.SimpleNamespace(master_conflicts={2: ["file"]}, pair_conflicts={})
        self.assertTrue(pr_status.chain_has_conflict(repo, [1, 2, 3], True))
        self.assertFalse(pr_status.chain_has_conflict(repo, [1, 2, 3], False))

    def test_nonadjacent_pr_conflict(self):
        """A later merge receives earlier, nonadjacent PRs in the chain."""
        repo = types.SimpleNamespace(master_conflicts={}, pair_conflicts={(1, 3): ["file"]})
        self.assertTrue(pr_status.chain_has_conflict(repo, [1, 2, 3], True))


class PushChainsTest(unittest.TestCase):
    """Tests for push_chains."""

    @staticmethod
    def chains(
        direct, master_conflicts, has_upstream=True, conflicts_only=False, cycle_affected=()
    ):
        """Run push_chains on PRs whose direct prerequisites are direct.

        Each PR n has the working copy "pr<n>".

        Returns:
            The chains.
        """
        repo = types.SimpleNamespace(
            gh="owner/repo",
            default_branch="master",
            prs={n: {} for n in direct},
            master_conflicts=master_conflicts,
            pair_conflicts={},
        )
        levels = {n: 1 + len(ds) for n, ds in direct.items() if ds} | {
            d: 1 for ds in direct.values() for d in ds
        }
        model = types.SimpleNamespace(
            repo=repo,
            open=set(direct),
            direct=direct,
            levels=levels,
            cycle_affected=set(cycle_affected),
        )
        upstream = {"master": pr_status.GitEntry("owner", "repo", "master")} if has_upstream else {}
        # pr_directories receives the PR's data, so look up the PR's number by identity.
        ids = {id(repo.prs[n]): n for n in direct}
        with (
            mock.patch.object(pr_status, "git_entries", return_value=upstream),
            mock.patch.object(
                pr_status, "pr_directories", lambda _r, pr, _base: [f"pr{ids[id(pr)]}"]
            ),
        ):
            return pr_status.push_chains(model, "/base", conflicts_only).chains

    def test_single_pr_chain(self):
        """A PR with no prerequisite or dependent forms a chain with upstream."""
        chains = self.chains({1: set(), 2: set(), 3: {2}}, {})
        self.assertEqual(chains, [["master", "pr2", "pr3"], ["master", "pr1"]])

    def test_single_pr_chain_conflicts_only(self):
        """A single-PR chain is retained exactly when its PR conflicts with upstream."""
        chains = self.chains({1: set(), 2: set(), 3: {2}}, {1: ["file"]}, conflicts_only=True)
        self.assertEqual(chains, [["master", "pr1"]])

    def test_no_single_pr_chain_without_upstream(self):
        """Without upstream, a single PR has nothing to push into it."""
        chains = self.chains({1: set(), 2: set(), 3: {2}}, {}, has_upstream=False)
        self.assertEqual(chains, [["pr2", "pr3"]])

    def test_no_chain_touches_cycle(self):
        """No chain pushes into or out of a PR in or after a cycle."""
        chains = self.chains(
            {1: set(), 2: {1, 3}, 3: {2}, 4: {3}, 5: {1}}, {}, cycle_affected={2, 3, 4}
        )
        self.assertEqual(chains, [["master", "pr1", "pr5"]])


class NewSnapshotTest(unittest.TestCase):
    """Tests for new_snapshot."""

    def test_round_trip(self):
        """The chains with conflicts of every repository, in order, survive a JSON round trip."""
        conflicting = [
            pr_status.PushChains([["a", "a-branch-x"]], [], True),
            pr_status.PushChains([], [1], True),
            pr_status.PushChains([["b", "b-branch y"], ["b", "b-branch-z"]], [], True),
        ]
        snapshot = pr_status.new_snapshot("now", {"repo": {}}, conflicting)
        self.assertEqual((snapshot["time"], snapshot["facts"]), ("now", {"repo": {}}))
        self.assertEqual(
            pr_status.format_push_chains(json.loads(json.dumps(snapshot))),
            ["a\ta-branch-x", "b\tb-branch y", "b\tb-branch-z"],
        )


class FormatPushChainsTest(unittest.TestCase):
    """Tests for format_push_chains."""

    def test_one_line_per_chain(self):
        """Each chain is one line, with its directories separated by tabs."""
        snapshot = {"conflicting_push_chains": [["a", "a-branch-x", "a-branch y"], ["b", "c"]]}
        self.assertEqual(
            pr_status.format_push_chains(snapshot), ["a\ta-branch-x\ta-branch y", "b\tc"]
        )

    def test_no_chains(self):
        """A snapshot that records no chain with conflicts yields no line."""
        self.assertEqual(pr_status.format_push_chains({"conflicting_push_chains": []}), [])

    def test_missing_key(self):
        """A snapshot that does not record the chains is an error."""
        with self.assertRaisesRegex(ValueError, "does not record the dependency chains"):
            pr_status.format_push_chains({"time": "now", "facts": {}})

    def test_tab_or_newline(self):
        """A directory whose name contains a tab or newline is an error."""
        for d in ("a\tb", "a\nb"):
            with self.subTest(d=d), self.assertRaisesRegex(ValueError, "tab or newline"):
                pr_status.format_push_chains({"conflicting_push_chains": [["a", d]]})


class PrintConflictingPushChainsTest(unittest.TestCase):
    """Tests for `pr-status --print-conflicting-push-chains`."""

    PR_STATUS = str(Path(__file__).resolve().parent.parent / "pr-status")

    def run_option(self, snapshot):
        """Run `pr-status --print-conflicting-push-chains` in a directory with a snapshot.

        Args:
            snapshot: the text of .pr-status-snapshot.json, or None to write no snapshot

        Returns:
            The completed process, with its output as text.
        """
        with tempfile.TemporaryDirectory() as d:
            if snapshot is not None:
                (Path(d) / pr_status_config.SNAPSHOT).write_text(snapshot)
            return subprocess.run(
                [sys.executable, self.PR_STATUS, "-C", d, "--print-conflicting-push-chains"],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_prints_chains(self):
        """Only the chains are printed, one per line."""
        snapshot = pr_status.new_snapshot(
            "now",
            {},
            [pr_status.PushChains([["a", "a-branch-x"], ["a", "a-branch y", "z"]], [], True)],
        )
        result = self.run_option(json.dumps(snapshot))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "a\ta-branch-x\na\ta-branch y\tz\n")

    def test_no_snapshot(self):
        """Without a snapshot, the option fails, printing nothing to standard output."""
        result = self.run_option(None)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("--print-conflicting-push-chains", result.stderr)


class ExclusiveOptionsTest(unittest.TestCase):
    """Tests that pr-status rejects options that choose different things to do."""

    PR_STATUS = PrintConflictingPushChainsTest.PR_STATUS

    def test_rejected(self):
        """Each combination fails with a usage error, before reading any file."""
        for options in [
            ["--check", "--print-conflicting-push-chains"],
            ["--print-document", "--print-conflicting-push-chains"],
            ["--print-config", "--print-document"],
            ["--print-conflicting-push-chains", "--highlight", "repo#1"],
        ]:
            with self.subTest(options=options), tempfile.TemporaryDirectory() as d:
                result = subprocess.run(
                    [sys.executable, self.PR_STATUS, "-C", d, *options],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertIn("not allowed with", result.stderr)


class PrSectionsTest(unittest.TestCase):
    """Tests for gen_unblocked and gen_blocked."""

    @staticmethod
    def sections(unblocked, blocked, label="repo"):
        """Return the "unblocked-REPO" and "blocked-REPO" sections of the given repository.

        Args:
            unblocked: the numbers of a repository's unblocked PRs, such as [1, 2]
            blocked: the numbers of the repository's blocked PRs
            label: the repository's label, or None to omit it from the sections' headings

        Returns:
            The lines of the two sections, each with "TABLE" in place of its table.  The
            table's cells are mocks.
        """
        model = types.SimpleNamespace(
            open=set(unblocked) | set(blocked),
            unblocked=lambda: sorted(unblocked),
            blocked=lambda: sorted(blocked),
        )
        cells = dict.fromkeys(
            [
                "needed_by",
                "textual_conflicts",
                "unblocked_notes",
                "dependency_cells",
                "detail_notes",
            ],
            mock.DEFAULT,
        )
        with mock.patch.multiple(pr_status, pr_table=mock.Mock(return_value=["TABLE"]), **cells):
            return (
                pr_status.gen_unblocked(model, {}, "/base", label),
                pr_status.gen_blocked(model, {}, "/base", label),
            )

    def test_no_prs(self):
        """With no open PR, neither section has a heading or a table."""
        self.assertEqual(self.sections([], []), ([], []))

    def test_no_blocked_prs(self):
        """With no blocked PR, only the "Unblocked PRs" section has a heading and a table."""
        self.assertEqual(
            self.sections([1], []), (["", "## Unblocked PRs (repo)", "", "TABLE", ""], [])
        )

    def test_no_unblocked_prs(self):
        """With a blocked PR, the "Unblocked PRs" section has a heading, even if it has no PR."""
        self.assertEqual(
            self.sections([], [1]),
            (
                ["", "## Unblocked PRs (repo)", "", "None.", ""],
                ["", "## Blocked PRs (repo)", "", "TABLE", ""],
            ),
        )

    def test_no_label(self):
        """Without a label, the sections' headings name no repository."""
        self.assertEqual(
            self.sections([1], [2], label=None),
            (
                ["", "## Unblocked PRs", "", "TABLE", ""],
                ["", "## Blocked PRs", "", "TABLE", ""],
            ),
        )


class DependencyDocumentTest(unittest.TestCase):
    """Tests for dependency_document."""

    # The generators of the sections that are not per-repository.
    GENERATORS = (
        "gen_status",
        "gen_clusters",
        "gen_graph",
        "gen_updating_branches",
        "gen_directories",
    )
    # The generators of the per-repository sections, whose last argument is a label.
    REPO_GENERATORS = (
        "gen_unblocked",
        "gen_blocked",
        "gen_details",
        "gen_prerequisites",
        "gen_independent",
    )

    @staticmethod
    def section(generator, per_repository):
        """Return a mock of the given section generator.

        Args:
            generator: a section generator's name, such as "gen_status"
            per_repository: True if the generator's last argument is a repository's label

        Returns:
            A function that returns the section's lines:  a "## " heading that names the
            section, such as "## status", and the label (if any), set off by blank lines.
        """

        def generate(*args):
            heading = "## " + generator.removeprefix("gen_")
            if per_repository and args[-1] is not None:
                heading += f" ({args[-1]})"
            return ["", heading, ""]

        return generate

    def document(self, labels=("repo",), optional=None):
        """Return the dependency document, with each section replaced by its heading.

        Args:
            labels: the labels of the repositories, such as ["daikon", "fjalar"]
            optional: the config's "optional_sections", or None to omit it

        Returns:
            The text of the dependency document.
        """
        models = [types.SimpleNamespace(repo=types.SimpleNamespace(label=lbl)) for lbl in labels]
        docs = {} if optional is None else {"optional_sections": optional}
        gens = {g: self.section(g, False) for g in self.GENERATORS}
        gens |= {g: self.section(g, True) for g in self.REPO_GENERATORS}

        def push_commands(_models, chains, _base):
            return "conflicting" if chains == "CONFLICTING" else "all"

        def gen_push_commands(commands, _base, conflicts_only=False):
            return ["", f"### {commands} commands" + (" only" if conflicts_only else ""), ""]

        with mock.patch.multiple(
            pr_status,
            push_commands=push_commands,
            gen_push_commands=gen_push_commands,
            **gens,
        ):
            return pr_status.dependency_document(
                models, {"documents": docs}, "/base", "now", "src PR status", "ALL", "CONFLICTING"
            )

    def test_document(self):
        """The document has a header, then the sections, each set off by one blank line."""
        text = self.document()
        self.assertTrue(
            text.startswith(
                "---\ntitle: src PR status\n---\n\n# src PR status\n\n"
                "As of now.\nGenerated by `pr-status`; do not edit it by hand.\n\n"
                "## How dependencies are determined\n\nA PR depends on another PR if"
            ),
            text,
        )
        self.assertTrue(
            text.endswith(
                " even if its branch contains another member's commits.\n\n"
                "## status\n\n## clusters\n\n## updating_branches\n\n"
                "### conflicting commands only\n\n"
                "### all commands\n\n"
                "## unblocked\n\n## blocked\n\n## directories\n"
            ),
            text,
        )

    def test_no_optional_sections(self):
        """Without "optional_sections", no optional section is generated."""
        text = self.document()
        for name in ("graph", "details", "prerequisites", "independent"):
            with self.subTest(name=name):
                self.assertNotIn(f"## {name}", text)

    def test_optional_sections(self):
        """Each optional section that the config names is generated, in a fixed order."""
        text = self.document(labels=["a", "b"], optional=["independent", "graph", "details"])
        headings = [line for line in text.splitlines() if line.startswith("## ")][1:]
        self.assertEqual(
            headings,
            [
                "## status",
                "## clusters",
                "## graph",
                "## updating_branches",
                "## unblocked (a)",
                "## blocked (a)",
                "## details (a)",
                "## independent (a)",
                "## unblocked (b)",
                "## blocked (b)",
                "## details (b)",
                "## independent (b)",
                "## directories",
            ],
        )

    def test_one_repository_unlabeled(self):
        """With one repository, the per-repository sections' headings name no repository."""
        self.assertIn("## unblocked\n", self.document(optional=["prerequisites"]))
        self.assertIn("## prerequisites\n", self.document(optional=["prerequisites"]))

    def test_quotes_title(self):
        """A title that YAML would misread is quoted in the front matter."""
        with mock.patch.multiple(
            pr_status,
            push_commands=mock.Mock(),
            gen_push_commands=mock.Mock(return_value=[]),
            **dict.fromkeys(self.GENERATORS, mock.Mock(return_value=[])),
        ):
            cfg = {"documents": {}}
            text = pr_status.dependency_document([], cfg, "/base", "now", "a: #b PR status", [], [])
        self.assertTrue(
            text.startswith('---\ntitle: "a: #b PR status"\n---\n\n# a: #b PR status\n\n'),
            text,
        )


class YamlStringTest(unittest.TestCase):
    """Tests for yaml_string."""

    def test_plain(self):
        """Words separated by spaces are not quoted."""
        self.assertEqual(pr_status.yaml_string("src PR status"), "src PR status")

    def test_quotes_non_strings(self):
        """A scalar that YAML would read as a boolean, null, or number is quoted."""
        for s in ["true", "null", "123", "1.5", "yes"]:
            self.assertEqual(pr_status.yaml_string(s), f'"{s}"')

    def test_does_not_escape_astral_characters(self):
        """A character outside the Basic Multilingual Plane is not escaped."""
        self.assertEqual(pr_status.yaml_string("src-\U0001f600"), '"src-\U0001f600"')


class CopyableCodeBlockTest(unittest.TestCase):
    """Tests for copyable_code_block."""

    def test_wraps_fenced_code_block(self):
        """The code block follows the copy button, inside an element that markdownlint permits."""
        self.assertEqual(
            pr_status.copyable_code_block("sh", ["cd /base && \\", 'echo "success"']),
            [
                "<!-- markdownlint-disable no-inline-html -->",
                '<div style="position:relative">',
                pr_status.COPY_BUTTON,
                "",
                "```sh",
                "cd /base && \\",
                'echo "success"',
                "```",
                "",
                "</div>",
                "<!-- markdownlint-enable no-inline-html -->",
            ],
        )

    def test_button_copies_without_final_newline(self):
        """The copy button removes the final newline of the code block's text."""
        self.assertIn(".textContent.replace(/\\n$/, '')", pr_status.COPY_BUTTON)


class GenPushCommandsTest(unittest.TestCase):
    """Tests for gen_push_commands."""

    CHAIN = ("cd /base && \\", "git-push-to \\", "  pr1 \\", "  pr2 && \\", 'echo "success"')
    NO_CHAIN = ("cd /base && \\", 'echo "success"')
    # The lines that end a section whose commands are CHAIN.
    BLOCK = (*pr_status.copyable_code_block("sh", list(CHAIN)), "")

    def generate(self, commands, conflicts_only, notes=()):
        """Run gen_push_commands on the given commands.

        Args:
            commands: the commands' lines, either CHAIN or NO_CHAIN
            conflicts_only: True to generate the "Dependency chains with conflicts" section;
                False to generate the "All dependency chains" section
            notes: the commands' notes, such as ["No working copy of upstream"]

        Returns:
            The section's lines.
        """
        chain_count = 1 if commands == self.CHAIN else 0
        result = pr_status.PushCommands(list(commands), list(notes), chain_count)
        return pr_status.gen_push_commands(result, "/base", conflicts_only)

    def test_suggests_resolve_conflicts_first(self):
        """The conflict-only section suggests resolve-conflicts before the commands."""
        lines = self.generate(self.CHAIN, conflicts_only=True)
        self.assertEqual(lines[:3], ["", "### Dependency chains with conflicts", ""])
        self.assertIn("`cd /base && resolve-conflicts`", lines[5])
        self.assertEqual(lines[-len(self.BLOCK) :], list(self.BLOCK))

    def test_empty_without_chains(self):
        """With no chain and no note, either section is empty."""
        for conflicts_only in [True, False]:
            with self.subTest(conflicts_only=conflicts_only):
                self.assertEqual(self.generate(self.NO_CHAIN, conflicts_only), [])

    def test_notes_without_chains(self):
        """With notes but no chain, only the section of all chains shows the notes."""
        notes = ["No working copy"]
        self.assertEqual(self.generate(self.NO_CHAIN, conflicts_only=True, notes=notes), [])
        self.assertEqual(
            self.generate(self.NO_CHAIN, conflicts_only=False, notes=notes),
            ["", "### All dependency chains", "", "No working copy.", ""],
        )

    def test_notes_with_chains(self):
        """With notes and a chain, the notes precede the commands."""
        self.assertEqual(
            self.generate(self.CHAIN, conflicts_only=False, notes=["No working copy"]),
            [
                "",
                "### All dependency chains",
                "",
                "No working copy.",
                "",
                *self.BLOCK,
            ],
        )

    def test_no_suggestion_for_all_chains(self):
        """The section of all chains does not suggest resolve-conflicts."""
        self.assertEqual(
            self.generate(self.CHAIN, conflicts_only=False),
            ["", "### All dependency chains", "", *self.BLOCK],
        )


class GenUpdatingBranchesTest(unittest.TestCase):
    """Tests for gen_updating_branches."""

    @staticmethod
    def generate(chain_count, notes=()):
        """Run gen_updating_branches for one repository, with the given chains and notes.

        Args:
            chain_count: the number of chains that the push commands run, such as 1
            notes: the push commands' notes, such as ["No working copy of upstream"]

        Returns:
            The section's lines.
        """
        model = types.SimpleNamespace(repo=types.SimpleNamespace(default_branch="master"))
        commands = pr_status.PushCommands([], list(notes), chain_count)
        return pr_status.gen_updating_branches([model], commands)

    def test_empty_without_chains(self):
        """With no chain and no note, the section is empty."""
        self.assertEqual(self.generate(0), [])

    def test_heading_with_notes(self):
        """With a note but no chain, the section has a heading."""
        self.assertEqual(
            self.generate(0, ["No working copy"])[:3], ["", "## Updating branches", ""]
        )

    def test_heading_with_chains(self):
        """With a chain, the section has a heading and names upstream."""
        lines = self.generate(1)
        self.assertEqual(lines[:3], ["", "## Updating branches", ""])
        self.assertIn("upstream `master`", lines[4])


class SimpleSectionsTest(unittest.TestCase):
    """Tests for the sections of the dependency document when they have nothing to show."""

    def test_status_empty(self):
        """With no PR, the "status" section is empty."""
        self.assertEqual(pr_status.gen_status([]), [])

    def test_clusters_empty(self):
        """With no PR, the "clusters" section is empty."""
        self.assertEqual(pr_status.gen_clusters([], {}), [])

    def test_directories_empty(self):
        """With no other directory, the "directories" section is empty."""
        with mock.patch.object(pr_status, "scan_directories", return_value={}):
            self.assertEqual(pr_status.gen_directories([], {"directories": []}, "/base"), [])

    def test_optional_sections_empty(self):
        """With no PR, the optional sections are empty."""
        model = types.SimpleNamespace(
            repo=types.SimpleNamespace(name="repo"),
            open=set(),
            components=list,
            independent=list,
        )
        cfg = {"repos": {"repo": {}}}
        self.assertEqual(pr_status.gen_graph([model], cfg), [])
        self.assertEqual(pr_status.gen_details(model, cfg, "repo"), [])
        self.assertEqual(pr_status.gen_prerequisites(model, "repo"), [])
        self.assertEqual(pr_status.gen_independent(model, cfg, "repo"), [])

    def test_status_heading(self):
        """With a PR that conflicts with the default branch, the section has a heading."""
        repo = types.SimpleNamespace(
            label="repo",
            master_conflicts={1: ["file"]},
            default_branch="master",
            links=lambda ns: ", ".join(f"#{n}" for n in ns),
        )
        model = types.SimpleNamespace(repo=repo, cyclic=[], open=set())
        self.assertEqual(
            pr_status.gen_status([model]),
            ["", "## Status", "", "* repo PRs that conflict with `master`: #1.", ""],
        )


class KeepTest(unittest.TestCase):
    """Tests for keep and for the filter of an unblocked document."""

    @staticmethod
    def model(assignees):
        """Return a model whose PR 1 has the given assignees.

        Returns:
            The model.
        """
        return types.SimpleNamespace(assignees=lambda _n: assignees)

    def test_all(self):
        """The filter "all" keeps every PR."""
        self.assertTrue(pr_status.keep(self.model(["a"]), 1, "all"))

    def test_unassigned(self):
        """The filter "unassigned" keeps only unassigned PRs."""
        self.assertTrue(pr_status.keep(self.model([]), 1, "unassigned"))
        self.assertFalse(pr_status.keep(self.model(["a"]), 1, "unassigned"))

    def test_unassigned_or(self):
        """The filter "unassigned_or" also keeps PRs assigned to one of its logins."""
        flt = {"unassigned_or": ["a"]}
        self.assertTrue(pr_status.keep(self.model([]), 1, flt))
        self.assertTrue(pr_status.keep(self.model(["a", "b"]), 1, flt))
        self.assertFalse(pr_status.keep(self.model(["b"]), 1, flt))


class LoadConfigTest(unittest.TestCase):
    """Tests for load_config."""

    def write(self, text):
        """Write a config file in a fresh directory, which becomes the current one.

        Args:
            text: the config file's contents.
        """
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.addCleanup(os.chdir, Path.cwd())
        os.chdir(directory.name)
        Path(pr_status_config.CONFIG).write_text(text)

    def test_clone_found(self):
        """load_config finds a clone for a repository that names none."""
        self.write(json.dumps({"repos": {"a": {"gh": "o/a"}, "b": {"gh": "o/b", "clone": "x"}}}))
        entries = {"a-fork": pr_status.GitEntry("me", "a", "fix")}
        with (
            mock.patch.object(pr_status, "git_entries", return_value=entries),
            mock.patch.object(pr_status, "fork_source", return_value="o/a"),
        ):
            cfg = pr_status.load_config("pr-status")
        self.assertEqual(cfg["repos"]["a"]["clone"], str(Path.cwd() / "a-fork"))
        self.assertEqual(cfg["repos"]["b"]["clone"], "x")

    def test_no_clone(self):
        """A repository that names no clone, and has none, is an error."""
        self.write(json.dumps({"repos": {"a": {"gh": "o/a"}}}))
        with (
            mock.patch.object(pr_status, "git_entries", return_value={}),
            self.assertRaises(SystemExit) as cm,
        ):
            pr_status.load_config("pr-status")
        self.assertIn('repos.a has no "clone"', str(cm.exception.code))


# Clones of the repositories o/a and o/b, of a fork of o/a, of an unrelated repository
# named "a", and of a repository that is not on GitHub.
CLONES = {
    "a-fork": pr_status.GitEntry("me", "a", "main"),
    "a-feature": pr_status.GitEntry("o", "a", "feature"),
    "a": pr_status.GitEntry("o", "a", "main"),
    "b": pr_status.GitEntry("o", "b", "main"),
    "a-other": pr_status.GitEntry("other", "a", "main"),
    "a-local": pr_status.GitEntry("", "a", "main"),
}
# The repository that each owner's GitHub repository "a" is a fork of, as fork_source reports.
SOURCES = {"me": "o/a", "other": None}


class FindCloneTest(unittest.TestCase):
    """Tests for find_clone."""

    def find(self, names, default_branch):
        """Return the clone that find_clone finds among the given CLONES, for o/a.

        Args:
            names: the names of some entries of CLONES.
            default_branch: what find_clone calls to read the default branch.

        Returns:
            The clone's name, or None if find_clone finds none.
        """
        entries = {d: CLONES[d] for d in names}
        with (
            mock.patch.object(pr_status, "git_entries", return_value=entries),
            mock.patch.object(pr_status, "fork_source", side_effect=lambda o, _: SOURCES[o]),
        ):
            clone = pr_status.find_clone("/base", "O", "A", default_branch)
        return clone and Path(clone).name

    def test_prefers_upstream_default_branch(self):
        """A clone of the upstream repository, on its default branch, is preferred."""
        self.assertEqual(self.find(CLONES, lambda: "main"), "a")

    def test_lone_clone_of_a_fork(self):
        """A lone clone of a fork is found without reading the default branch."""
        names = ["a-fork", "a-other", "a-local", "b"]
        self.assertEqual(self.find(names, mock.Mock(side_effect=AssertionError)), "a-fork")

    def test_none(self):
        """A clone of an unrelated repository, or of one not on GitHub, is not found."""
        self.assertIsNone(self.find(["a-other", "a-local", "b"], lambda: "main"))


def config_repo(**extra):
    """Return a Repo made from a config entry that has the required keys and extra.

    Args:
        extra: config keys, such as default_branch, in addition to the required ones.

    Returns:
        A Repo whose GitHub slug is "Owner/Repo", and that has no PRs.
    """
    return pr_status.Repo(
        "repo",
        {
            "gh": "Owner/Repo",
            "clone": "/base/repo",
            "prefix": "#",
            "label": "repo",
            "node_prefix": "pr",
            "default_branch": "master",
            **extra,
        },
    )


class DefaultBranchTest(unittest.TestCase):
    """Tests for repo_default_branch and github_default_branch."""

    def setUp(self):
        """Forget every default branch that GitHub has reported."""
        patcher = mock.patch.dict(pr_status.GITHUB_DEFAULT_BRANCHES, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_configured(self):
        """A default branch that the config names is used without asking GitHub."""
        with mock.patch.object(pr_status, "run") as run:
            self.assertEqual(config_repo(default_branch="trunk").default_branch, "trunk")
        run.assert_not_called()

    def test_from_github(self):
        """If the config names no default branch, GitHub is asked, once."""
        rc = {"gh": "Owner/Repo"}
        with mock.patch.object(pr_status, "run", return_value="main\n") as run:
            self.assertEqual(pr_status.repo_default_branch(rc), "main")
            self.assertEqual(pr_status.repo_default_branch(rc), "main")
        run.assert_called_once()
        self.assertEqual(run.call_args.args[0][:4], ["gh", "repo", "view", "Owner/Repo"])

    def test_recorded(self):
        """A default branch that is already recorded is used without asking GitHub."""
        pr_status.GITHUB_DEFAULT_BRANCHES["Owner/Repo"] = "trunk"
        with mock.patch.object(pr_status, "run") as run:
            self.assertEqual(pr_status.repo_default_branch({"gh": "Owner/Repo"}), "trunk")
        run.assert_not_called()


class ExcludedByDecisionTest(unittest.TestCase):
    """Tests for the "Excluded by decision" section of an unblocked document."""

    @staticmethod
    def section(excluded, open_prs):
        """Return the "Excluded by decision" section of an unblocked document.

        The document reports on one repository, none of whose open PRs is unblocked.

        Args:
            excluded: the repository's "excluded" config entry.
            open_prs: the numbers of the repository's open PRs.

        Returns:
            The section, without its heading; or None if the document has no such section.
        """
        repo = config_repo()
        repo.prs = {n: {} for n in open_prs}
        model = types.SimpleNamespace(
            repo=repo, excluded=set(excluded["prs"]), unblocked=list, blocked=list
        )
        cfg = {
            "documents": {"dependencies": "pr-status.md"},
            "repos": {"repo": {"excluded": excluded}},
        }
        doc = {"file": "unblocked.md", "title": "Unblocked"}
        text = pr_status.unblocked_doc([model], cfg, "/base", doc, "now")
        parts = text.split("## Excluded by decision\n\n")
        return parts[1].split("\n\n")[0] if len(parts) > 1 else None

    def test_reason(self):
        """The reason, if the config gives one, describes the excluded PRs."""
        self.assertEqual(
            self.section({"prs": [7], "reason": "#7 will not land."}, {7}),
            "* repo: #7 will not land.",
        )

    def test_no_reason(self):
        """Without a reason, the excluded PRs that are open are listed."""
        self.assertEqual(
            self.section({"prs": [9, 7, 5]}, {7, 9}),
            "* repo: [#7](https://github.com/Owner/Repo/pull/7) and"
            " [#9](https://github.com/Owner/Repo/pull/9).",
        )

    def test_none_open(self):
        """If no excluded PR is open, the section is omitted, even if it has a reason."""
        self.assertIsNone(self.section({"prs": [5], "reason": "#5 will not land."}, {7}))


if __name__ == "__main__":
    unittest.main()
