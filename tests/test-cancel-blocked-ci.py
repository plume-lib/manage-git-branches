"""Tests for the cancel-blocked-ci script.

The tests contact no server:  fakes replace the HTTP requests that the script makes and
the pr-status script that it imports.
"""

from __future__ import annotations

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from typing import TYPE_CHECKING, Any
from unittest import mock

TOPLEVEL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOPLEVEL))

import ci_build  # ruff: ignore[module-import-not-at-top-of-file]
import request_util  # ruff: ignore[module-import-not-at-top-of-file]

if TYPE_CHECKING:
    import types

CIRCLECI = "https://circleci.com/api/v2"


def load_script() -> types.ModuleType:
    """Import cancel-blocked-ci, with a fake pr-status script.

    Returns:
        The imported module.
    """
    with tempfile.TemporaryDirectory() as tmp:
        fake = Path(tmp) / "pr-status.py"
        fake.write_text('CONFIG = "pr-status-config.json"\n')
        loader = importlib.machinery.SourceFileLoader(
            "cancel_blocked_ci", str(TOPLEVEL / "cancel-blocked-ci")
        )
        spec = importlib.util.spec_from_loader(loader.name, loader)
        assert spec is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[loader.name] = module
        with (
            mock.patch("pathlib.Path.exists", return_value=False),
            mock.patch("shutil.which", return_value=str(fake)),
        ):
            loader.exec_module(module)
    return module


cancel_blocked_ci = load_script()
Check = cancel_blocked_ci.Check
BuildState = cancel_blocked_ci.BuildState


class CancelBlockedCiTest(unittest.TestCase):
    """Tests for cancel-blocked-ci."""

    def test_options(self) -> None:
        """An unknown option is rejected before anything is examined or cancelled."""
        for args in [["--dryrun"], ["extra"]]:
            with (
                self.subTest(args=args),
                mock.patch.object(sys, "argv", ["cancel-blocked-ci", *args]),
                mock.patch.object(cancel_blocked_ci, "blocked_prs", side_effect=AssertionError),
                contextlib.redirect_stderr(io.StringIO()),
                self.assertRaises(SystemExit) as cm,
            ):
                cancel_blocked_ci.main()
            self.assertEqual(cm.exception.code, 2)

    def test_pr_name(self) -> None:
        """A bare "#N" is preceded by the repository's label, and another reference is not."""
        self.assertEqual(cancel_blocked_ci.pr_name("daikon", "#555"), "daikon #555")
        self.assertEqual(cancel_blocked_ci.pr_name("daikon", "daikon#555"), "daikon#555")
        # A reference with a prefix names its repository, even if the prefix is not the label.
        self.assertEqual(cancel_blocked_ci.pr_name("Daikon", "daikon#555"), "daikon#555")

    def test_blocked_prs(self) -> None:
        """Open PRs make shared branches:  every base branch, and unblocked PRs' head branches.

        The head branch of a blocked PR, or of a PR from a fork, is not made shared.
        """
        prs = {
            1: {"owner": "org", "headRefName": "feature", "baseRefName": "main"},
            2: {"owner": "org", "headRefName": "feature", "baseRefName": "develop"},
            3: {"owner": "org", "headRefName": "blocked-only", "baseRefName": "main"},
            4: {"owner": "fork", "headRefName": "fix", "baseRefName": "main"},
        }
        model = mock.Mock()
        model.repo.label = "repo"
        model.repo.gh = "Org/repo"
        model.repo.prs = prs
        model.repo.ref.side_effect = lambda n: f"#{n}"
        model.blocked.return_value = [2, 3]
        with mock.patch.object(
            cancel_blocked_ci.pr_status, "load_models", create=True, return_value=[model]
        ):
            [repo] = cancel_blocked_ci.blocked_prs({})
        self.assertEqual(
            repo.prs,
            [
                cancel_blocked_ci.BlockedPr("repo #2", prs[2]),
                cancel_blocked_ci.BlockedPr("repo #3", prs[3]),
            ],
        )
        self.assertEqual(repo.pr_shared_branches, {"main", "develop", "feature"})

    def test_circleci_workflows_of_jobs(self) -> None:
        """The workflows of jobs whose URLs do not contain workflow ids come from lookups.

        Once a job's workflow is found, the workflow's other jobs are not looked up.
        """
        jobs = [
            Check("pending", f"job{n}", f"https://circleci.com/gh/org/repo/{n}") for n in (1, 2, 3)
        ]
        # Job 2 is not looked up, because it is in job 1's workflow.
        pages = {
            f"{CIRCLECI}/project/gh/org/repo/job/1": {"latest_workflow": {"id": "w9"}},
            f"{CIRCLECI}/project/gh/org/repo/job/3": {"latest_workflow": {"id": "w8"}},
            f"{CIRCLECI}/workflow/w9/job": {"items": [{"job_number": 1}, {"job_number": 2}]},
            f"{CIRCLECI}/workflow/w8/job": {"items": [{"job_number": 3}, {"name": "approval"}]},
        }
        requested = []

        def http(_method: str, url: str, *_: Any, **_kwargs: Any) -> bytes:
            requested.append(url)
            return json.dumps(pages[url]).encode()

        with (
            mock.patch.object(request_util, "http", http),
            mock.patch.object(ci_build, "circleci_token", return_value="token"),
            mock.patch.object(cancel_blocked_ci, "failed", new=False),
        ):
            result = cancel_blocked_ci.circleci_workflows_of_jobs("repo#5", jobs)
            self.assertFalse(cancel_blocked_ci.failed)
        self.assertEqual(
            [(b.key, b.status, b.description) for b in result],
            [
                (("circleci", "w9"), "pending", "CircleCI workflow w9 (job1)"),
                (("circleci", "w8"), "pending", "CircleCI workflow w8 (job3)"),
            ],
        )
        self.assertEqual(sorted(requested), sorted(pages))

    def test_state_of_empty_response(self) -> None:
        """An empty response for a build's state raises an error in REQUEST_ERRORS."""
        with (
            mock.patch.object(request_util, "http", return_value=b""),
            mock.patch.object(ci_build, "circleci_token", return_value="token"),
            mock.patch.object(ci_build, "azure_headers", return_value={}),
            self.assertRaises(request_util.REQUEST_ERRORS),
        ):
            cancel_blocked_ci.circleci_workflow_state("w9")
        with (
            mock.patch.object(request_util, "http", return_value=b""),
            mock.patch.object(ci_build, "azure_headers", return_value={}),
            self.assertRaises(request_util.REQUEST_ERRORS),
        ):
            cancel_blocked_ci.azure_build_state("org", "p", 1)

    def test_unfinished_other_builds(self) -> None:
        """Only the unfinished builds of the given branches are a commit's builds.

        A build whose branch cannot be found, or that has no branch, is reported, and the
        exit status becomes 1.
        """
        workflow = "0123456789abcdef0123456789abcdef0123"
        other_workflow = "fedcba9876543210fedcba9876543210fedc"
        tag_workflow = "abcdefabcdefabcdefabcdefabcdefabcdef"
        checks = [
            Check("in_progress", "ci", "https://dev.azure.com/org/p/_build/results?buildId=1"),
            Check("in_progress", "ci", "https://dev.azure.com/org/p/_build/results?buildId=2"),
            Check("in_progress", "ci", "https://dev.azure.com/org/p/_build/results?buildId=3"),
            Check("completed", "ci", "https://dev.azure.com/org/p/_build/results?buildId=4"),
            # Finding the branch of build 5 fails.
            Check("in_progress", "ci", "https://dev.azure.com/org/p/_build/results?buildId=5"),
            # GitHub shows build 6 as unfinished, but it has finished.
            Check("in_progress", "ci", "https://dev.azure.com/org/p/_build/results?buildId=6"),
            Check("pending", "build", f"https://app.circleci.com/workflow/{workflow}"),
            Check("pending", "build", f"https://app.circleci.com/workflow/{other_workflow}"),
            Check("pending", "build", f"https://app.circleci.com/workflow/{tag_workflow}"),
        ]
        azure_states = {
            1: BuildState("refs/pull/5/merge", False),
            2: BuildState("refs/heads/feature", False),
            3: BuildState("refs/heads/other", False),
            6: BuildState("refs/pull/5/merge", True),
        }

        def azure_build_state(_org: str, _project: str, build: int) -> BuildState:
            if build not in azure_states:
                raise urllib.error.URLError("unreachable")
            return azure_states[build]

        circleci_states = {
            workflow: BuildState("feature", False),
            other_workflow: BuildState("other", False),
            tag_workflow: BuildState(None, False),
        }
        for branches, expected in [
            (
                {"pull/5", "feature"},
                [("azure", "org", "1"), ("azure", "org", "2"), ("circleci", workflow)],
            ),
            ({"pull/5"}, [("azure", "org", "1")]),
        ]:
            with (
                self.subTest(branches=branches),
                mock.patch.object(cancel_blocked_ci, "checks", return_value=checks),
                mock.patch.object(cancel_blocked_ci, "azure_build_state", azure_build_state),
                mock.patch.object(
                    cancel_blocked_ci, "circleci_workflow_state", circleci_states.get
                ),
                mock.patch.object(cancel_blocked_ci, "failed", new=False),
                contextlib.redirect_stderr(io.StringIO()) as stderr,
            ):
                result = cancel_blocked_ci.unfinished_other_builds(
                    "repo#5", "org/repo", "abc", branches
                )
                self.assertTrue(cancel_blocked_ci.failed)
            self.assertEqual([build.key for build in result], expected)
            self.assertIn("repo#5: failed to find the branch of", stderr.getvalue())
            self.assertIn("buildId=5", stderr.getvalue())
            self.assertIn(
                f"repo#5: not cancelling https://app.circleci.com/workflow/{tag_workflow}",
                stderr.getvalue(),
            )

    def test_unfinished_runs(self) -> None:
        """Unfinished runs are grouped by head branch and by head repository owner.

        The owner is in lower case, and it is None if the head repository is gone.
        """
        runs = [
            {"id": 1, "head_branch": "main", "head_repository": {"owner": {"login": "Org"}}},
            {"id": 2, "head_branch": "main", "head_repository": {"owner": {"login": "org"}}},
            {"id": 3, "head_branch": "main", "head_repository": None},
        ]
        with mock.patch.object(request_util, "gh_api", return_value=[{"workflow_runs": runs}]):
            result = cancel_blocked_ci.unfinished_runs("org/repo")
        self.assertEqual(
            {key: [r["id"] for r in branch_runs] for key, branch_runs in result.items()},
            {("org", "main"): [1, 2], (None, "main"): [3]},
        )

    def test_blocked_pr_runs(self) -> None:
        """A blocked PR's runs are those that it or a push started on its head branch.

        If the head branch is a shared branch, they are only those that the PR started.
        The PR's owner can differ in letter case from the owner in runs.
        """
        runs = {
            ("org", "main"): [
                {"id": n, "event": event}
                for n, event in enumerate(["pull_request", "push", "schedule", "workflow_dispatch"])
            ]
        }
        pr = {"owner": "Org", "headRefName": "main", "number": 5}
        for on_shared_branch, expected in [(False, [0, 1]), (True, [0])]:
            with self.subTest(on_shared_branch=on_shared_branch):
                self.assertEqual(
                    [
                        r["id"]
                        for r in cancel_blocked_ci.blocked_pr_runs(pr, runs, on_shared_branch)
                    ],
                    expected,
                )
        is_on_shared_branch = cancel_blocked_ci.is_on_shared_branch
        self.assertTrue(is_on_shared_branch("Org/repo", {"master", "main"}, pr))
        self.assertFalse(is_on_shared_branch("org/repo", {"master", "develop"}, pr))
        self.assertFalse(is_on_shared_branch("fork/repo", {"main"}, pr | {"owner": "other"}))
        pr_branches = cancel_blocked_ci.pr_branches
        self.assertEqual(pr_branches("org/repo", {"master"}, pr), {"pull/5", "main"})
        self.assertEqual(pr_branches("org/repo", {"master", "main"}, pr), {"pull/5"})
        self.assertEqual(pr_branches("upstream/repo", {"master"}, pr), {"pull/5"})

    def test_cancel(self) -> None:
        """A failure to cancel a build is reported unless the build has finished."""

        def cancelling() -> None:
            raise urllib.error.URLError("refused")

        def state_fails() -> BuildState:
            raise urllib.error.URLError("unreachable")

        for state_function, reported in [
            (lambda: BuildState("main", True), False),
            (lambda: BuildState("main", False), True),
            (state_fails, True),
        ]:
            build = cancel_blocked_ci.Build(
                ("github", 1), "queued", "run 1 (ci)", "https://x/1", cancelling, state_function
            )
            with (
                self.subTest(state_function=state_function),
                mock.patch.object(cancel_blocked_ci, "failed", new=False),
                contextlib.redirect_stderr(io.StringIO()) as stderr,
            ):
                build.cancel("repo#5")
                self.assertEqual(cancel_blocked_ci.failed, reported)
            self.assertEqual("repo#5: failed to cancel https://x/1" in stderr.getvalue(), reported)


if __name__ == "__main__":
    unittest.main()
