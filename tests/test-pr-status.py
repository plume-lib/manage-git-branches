"""Tests for the pr-status script that do not access GitHub or local repositories."""

import sys
import types
import unittest
from pathlib import Path
from unittest import mock

TOPLEVEL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOPLEVEL))

import pr_status  # ruff: ignore[module-import-not-at-top-of-file]

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
            [model.unresolved_threads(n) for n in (1, 2, 3, 4)], [" 🔀", " 🔀", " 🔀", ""]
        )
        model.repo.master_conflicts = {}
        model.repo.pair_conflicts = {(1, 3): ["c.txt"], (2, 3): ["a.txt"]}
        self.assertEqual([model.unresolved_threads(n) for n in (1, 2, 3, 4)], ["", " 🔀", "", ""])

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
    """Tests for resolve_pr_names, needed_to_land, and highlight."""

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
            pr_status.resolve_pr_names(models, ["Owner/Repo#1, other/repo#5", "other/repo#6"]),
            {("owner/repo", 1), ("other/repo", 5), ("other/repo", 6)},
        )

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
            {
                "name": "repo",
                "gh": "Owner/Repo",
                "clone": "/base/repo",
                "prefix": "#",
                "label": "repo",
                "node_prefix": "pr",
            }
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
            {
                "name": gh,
                "gh": gh,
                "clone": "/base/repo",
                "prefix": "#",
                "label": gh,
                "node_prefix": "pr",
            }
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
            levels=lambda: levels,
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


class SectionGeneratorsTest(unittest.TestCase):
    """Tests for section_generators."""

    def test_generates_conflicting_commands_section(self):
        """The conflict-only section is generated without any configuration."""
        generators = pr_status.section_generators(
            [], {"documents": {}}, "/base", "2026-10-30 12:00 PDT"
        )
        self.assertIn("conflicting-push-commands", generators)


AS_OF = "<!-- BEGIN GENERATED: as-of -->\n<!-- END GENERATED: as-of -->\n"
HEADER = "---\ntitle: src PR status\n---\n\n# src PR status\n\n" + AS_OF


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


class SetHeaderTest(unittest.TestCase):
    """Tests for set_header."""

    def test_adds_header(self):
        """A document without front matter, a heading, or an as-of section gains them."""
        self.assertEqual(pr_status.set_header("Body.\n", "src PR status"), HEADER + "\nBody.\n")

    def test_replaces_heading(self):
        """A document's heading is replaced."""
        self.assertEqual(
            pr_status.set_header("# PR dependencies\n\nBody.\n", "src PR status"),
            HEADER + "\nBody.\n",
        )

    def test_replaces_title_and_retains_other_entries(self):
        """The front matter's title is replaced, and its other entries are retained."""
        text = "---\nauthor: me\ntitle: old\n---\n\n# old\n\nBody.\n"
        self.assertEqual(
            pr_status.set_header(text, "src PR status"),
            "---\nauthor: me\ntitle: src PR status\n---\n\n# src PR status\n\n"
            + AS_OF
            + "\nBody.\n",
        )

    def test_replaces_multi_line_title(self):
        """The continuation lines of a multi-line title are replaced too."""
        text = "---\ntitle: >\n  long\n  title\nauthor: me\n---\n\nBody.\n"
        self.assertEqual(
            pr_status.set_header(text, "src PR status"),
            "---\ntitle: src PR status\nauthor: me\n---\n\n# src PR status\n\n"
            + AS_OF
            + "\nBody.\n",
        )

    def test_replaces_multi_line_title_with_blank_line(self):
        """A blank line within a multi-line title is replaced, but one after it is retained."""
        text = "---\ntitle: >\n  long\n\n  title\n\nauthor: me\n---\n\nBody.\n"
        self.assertEqual(
            pr_status.set_header(text, "src PR status"),
            "---\ntitle: src PR status\n\nauthor: me\n---\n\n# src PR status\n\n"
            + AS_OF
            + "\nBody.\n",
        )

    def test_replaces_title_with_other_key_spelling(self):
        """A title whose key is quoted or followed by a space is replaced."""
        for key in ["title :", '"title":', "'title' :"]:
            text = f"---\n{key} old\nauthor: me\n---\n\nBody.\n"
            self.assertEqual(
                pr_status.set_header(text, "src PR status"),
                "---\ntitle: src PR status\nauthor: me\n---\n\n# src PR status\n\n"
                + AS_OF
                + "\nBody.\n",
            )

    def test_replaces_tab_separated_heading(self):
        """A heading whose "#" is followed by a tab is replaced."""
        self.assertEqual(
            pr_status.set_header("#\tPR dependencies\n\nBody.\n", "src PR status"),
            HEADER + "\nBody.\n",
        )

    def test_adds_title_to_front_matter(self):
        """Front matter without a title gains one."""
        self.assertEqual(
            pr_status.set_header("---\nauthor: me\n---\nBody.\n", "src PR status"),
            "---\ntitle: src PR status\nauthor: me\n---\n\n# src PR status\n\n"
            + AS_OF
            + "\nBody.\n",
        )

    def test_empty_front_matter(self):
        """Empty front matter gains a title."""
        self.assertEqual(pr_status.set_header("---\n---\n", "src PR status"), HEADER)

    def test_front_matter_ends_at_first_delimiter(self):
        """A thematic break in the body does not end the front matter."""
        text = "---\n---\n\n# Old\n\nText\n\n---\n\nMore\n"
        self.assertEqual(
            pr_status.set_header(text, "src PR status"),
            HEADER + "\nText\n\n---\n\nMore\n",
        )

    def test_retains_as_of_section(self):
        """An existing as-of section is retained, even if it does not follow the heading."""
        text = "# Old\n\nIntro.\n\n" + AS_OF
        self.assertEqual(
            pr_status.set_header(text, "src PR status"),
            "---\ntitle: src PR status\n---\n\n# src PR status\n\nIntro.\n\n" + AS_OF,
        )

    def test_idempotent(self):
        """Setting the same title again changes nothing."""
        text = pr_status.set_header("# PR dependencies\n\nBody.\n", "src PR status")
        self.assertEqual(pr_status.set_header(text, "src PR status"), text)

    def test_quotes_title(self):
        """A title that YAML would misread unquoted is quoted."""
        self.assertEqual(
            pr_status.set_header("", "a: #b PR status"),
            '---\ntitle: "a: #b PR status"\n---\n\n# a: #b PR status\n\n' + AS_OF,
        )


class DefaultDependencyDocumentTest(unittest.TestCase):
    """Tests for the header of a new dependency document."""

    def test_header(self):
        """A new dependency document gets front matter, a heading, and an as-of section."""
        text = pr_status.set_header(pr_status.default_dependency_document([]), "src PR status")
        self.assertTrue(text.startswith(HEADER + "\nThe title and the generated"), text)


class GenPushCommandsTest(unittest.TestCase):
    """Tests for gen_push_commands."""

    CHAIN = ("cd /base && \\", "git-push-to \\", "  pr1 \\", "  pr2 && \\", 'echo "success"')
    NO_CHAIN = ("cd /base && \\", 'echo "success"')

    def generate(self, commands, conflicts_only):
        """Run gen_push_commands, with push_commands returning the given commands and no notes.

        Args:
            commands: the commands' lines, either CHAIN or NO_CHAIN
            conflicts_only: True to generate the "conflicting-push-commands" section; False
                to generate the "push-commands" section

        Returns:
            The section's lines.
        """
        chain_count = 1 if commands == self.CHAIN else 0
        result = pr_status.PushCommands(list(commands), [], chain_count)
        with mock.patch.object(pr_status, "push_commands", return_value=result):
            return pr_status.gen_push_commands([], "/base", conflicts_only)

    def test_suggests_resolve_conflicts_first(self):
        """The conflict-only section suggests resolve-conflicts before the commands."""
        lines = self.generate(self.CHAIN, conflicts_only=True)
        self.assertIn("`cd /base && resolve-conflicts`", lines[0])
        self.assertEqual(lines[lines.index("```sh") :], ["```sh", *self.CHAIN, "```"])

    def test_no_suggestion_without_chains(self):
        """With no chain, the conflict-only section suggests nothing."""
        self.assertEqual(
            self.generate(self.NO_CHAIN, conflicts_only=True), ["```sh", *self.NO_CHAIN, "```"]
        )

    def test_no_suggestion_for_all_chains(self):
        """The section of all chains does not suggest resolve-conflicts."""
        self.assertEqual(
            self.generate(self.CHAIN, conflicts_only=False), ["```sh", *self.CHAIN, "```"]
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

    def test_valid_filters(self):
        """is_valid_filter accepts each form of filter."""
        for flt in ["all", "unassigned", {"unassigned_or": []}, {"unassigned_or": ["a", "b"]}]:
            with self.subTest(flt=flt):
                self.assertTrue(pr_status.is_valid_filter(flt))

    def test_invalid_filters(self):
        """is_valid_filter rejects a misspelled or malformed filter."""
        for flt in [
            "unasigned",
            None,
            ["a"],
            {},
            {"unassigned-or": ["a"]},
            {"unassigned_or": "a"},
            {"unassigned_or": [1]},
            {"unassigned_or": ["a"], "extra": 1},
        ]:
            with self.subTest(flt=flt):
                self.assertFalse(pr_status.is_valid_filter(flt))

    def test_unknown_filter(self):
        """An unblocked document with an unknown filter is an error."""
        doc = {"file": "unblocked.md", "title": "Unblocked", "filter": "unasigned"}
        cfg = {"documents": {"dependencies": "pr-status.md", "unblocked": [doc]}}
        with self.assertRaises(SystemExit) as cm:
            pr_status.check_unblocked_filters(cfg, "pr-status")
        self.assertIn('the filter of unblocked.md is "unasigned"', str(cm.exception))

    def test_no_filter(self):
        """An unblocked document with no filter is not an error."""
        doc = {"file": "unblocked.md", "title": "Unblocked"}
        cfg = {"documents": {"dependencies": "pr-status.md", "unblocked": [doc]}}
        pr_status.check_unblocked_filters(cfg, "pr-status")


if __name__ == "__main__":
    unittest.main()
