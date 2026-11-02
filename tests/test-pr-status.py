"""Tests for the pr-status script that do not access GitHub or local repositories."""

import importlib.machinery
import importlib.util
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

TOPLEVEL = Path(__file__).resolve().parent.parent


def load_script() -> types.ModuleType:
    """Import pr-status, whose name is not a legal module name.

    Returns:
        The imported module.
    """
    loader = importlib.machinery.SourceFileLoader("pr_status", str(TOPLEVEL / "pr-status"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


pr_status = load_script()

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
    """Tests for stated_prerequisites."""

    repo = types.SimpleNamespace(gh="owner/repo", keywords=[])

    def test_land_with_is_partner(self):
        """A land-with PR is a partner, not a prerequisite."""
        self.assertEqual(
            pr_status.stated_prerequisites("Land with #5.", self.repo),
            (set(), set(), set(), {5}, set()),
        )

    def test_after_with_before(self):
        """One sentence can name a prerequisite, a partner, and a dependent."""
        self.assertEqual(
            pr_status.stated_prerequisites("Land it after #1, with #2, and before #3.", self.repo),
            ({1}, set(), {3}, {2}, set()),
        )

    def test_this_pr_as_object(self):
        """In "land after it", the named PRs land after this PR."""
        self.assertEqual(
            pr_status.stated_prerequisites("To land after it: #1 and #2.", self.repo),
            (set(), set(), {1, 2}, set(), set()),
        )
        self.assertEqual(
            pr_status.stated_prerequisites("To land before this PR: #3.", self.repo),
            ({3}, set(), set(), set(), set()),
        )

    def test_land_with_other_repository(self):
        """A land-with PR in another repository is an external partner."""
        self.assertEqual(
            pr_status.stated_prerequisites("Land with other/repo#5.", self.repo),
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
                self.assertEqual(pr_status.stated_prerequisites(body, self.repo), none)
        self.assertEqual(
            pr_status.stated_prerequisites("It is not new, but it depends on #5.", self.repo),
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
            failures = pr_status.apply_description_updates([(model, 1, "new")], {})
        self.assertEqual(failures, [(model, 1, error)])
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
        upstream = {"master": ("git", "owner", "repo", "master")} if has_upstream else {}
        # pr_directories receives the PR's data, so look up the PR's number by identity.
        ids = {id(repo.prs[n]): n for n in direct}
        with (
            mock.patch.object(pr_status, "scan_directories", return_value=upstream),
            mock.patch.object(
                pr_status, "pr_directories", lambda _r, pr, _base: [f"pr{ids[id(pr)]}"]
            ),
        ):
            return pr_status.push_chains(model, "/base", conflicts_only)[0]

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


class GenPushCommandsTest(unittest.TestCase):
    """Tests for gen_push_commands."""

    CHAIN = ("cd /base && \\", "(cd pr1 && git-push-to ../pr2) && \\", 'echo "success"')
    NO_CHAIN = ("cd /base && \\", 'echo "success"')

    def generate(self, commands, conflicts_only):
        """Run gen_push_commands, with push_commands returning the given commands and no notes.

        Returns:
            The section's lines.
        """
        with mock.patch.object(pr_status, "push_commands", return_value=(list(commands), [])):
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


if __name__ == "__main__":
    unittest.main()
