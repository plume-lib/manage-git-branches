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

    def test_blocked_pr_runs(self) -> None:
        """A blocked PR's runs are those that it or a push started on its head branch."""
        runs = {
            ("org", "main"): [
                {"id": n, "event": event}
                for n, event in enumerate(["pull_request", "push", "schedule", "workflow_dispatch"])
            ]
        }
        pr = {"owner": "org", "headRefName": "main", "number": 5}
        for on_default_branch, expected in [(False, [0, 1]), (True, [0])]:
            with self.subTest(on_default_branch=on_default_branch):
                self.assertEqual(
                    [
                        r["id"]
                        for r in cancel_blocked_ci.blocked_pr_runs(pr, runs, on_default_branch)
                    ],
                    expected,
                )
        self.assertTrue(cancel_blocked_ci.is_default_branch("Org/repo", "main", pr))
        self.assertFalse(cancel_blocked_ci.is_default_branch("org/repo", "master", pr))
        self.assertFalse(
            cancel_blocked_ci.is_default_branch("fork/repo", "main", pr | {"owner": "other"})
        )
        self.assertEqual(cancel_blocked_ci.pr_branches("org/repo", pr, False), {"pull/5", "main"})
        self.assertEqual(cancel_blocked_ci.pr_branches("org/repo", pr, True), {"pull/5"})
        self.assertEqual(cancel_blocked_ci.pr_branches("upstream/repo", pr, False), {"pull/5"})

    def test_unfinished_other_builds(self) -> None:
        """Only the unfinished builds of the given branches are a commit's builds.

        A build whose branch cannot be found is reported, and the exit status becomes 1.
        A build that has no branch is reported.
        """
        workflow = "0123456789abcdef0123456789abcdef0123"
        other_workflow = "fedcba9876543210fedcba9876543210fedc"
        tag_workflow = "abcdefabcdefabcdefabcdefabcdefabcdef"
        checks = [
            ("in_progress", "ci", "https://dev.azure.com/org/p/_build/results?buildId=1"),
            ("in_progress", "ci", "https://dev.azure.com/org/p/_build/results?buildId=2"),
            ("in_progress", "ci", "https://dev.azure.com/org/p/_build/results?buildId=3"),
            ("completed", "ci", "https://dev.azure.com/org/p/_build/results?buildId=4"),
            # Finding the branch of build 5 fails.
            ("in_progress", "ci", "https://dev.azure.com/org/p/_build/results?buildId=5"),
            # GitHub shows build 6 as unfinished, but it has finished.
            ("in_progress", "ci", "https://dev.azure.com/org/p/_build/results?buildId=6"),
            ("pending", "build", f"https://app.circleci.com/workflow/{workflow}"),
            ("pending", "build", f"https://app.circleci.com/workflow/{other_workflow}"),
            ("pending", "build", f"https://app.circleci.com/workflow/{tag_workflow}"),
        ]
        azure_states = {
            1: ("refs/pull/5/merge", False),
            2: ("refs/heads/feature", False),
            3: ("refs/heads/other", False),
            6: ("refs/pull/5/merge", True),
        }

        def azure_build_state(_org: str, _project: str, build: int) -> tuple[str, bool]:
            if build not in azure_states:
                raise urllib.error.URLError("unreachable")
            return azure_states[build]

        circleci_states = {
            workflow: ("feature", False),
            other_workflow: ("other", False),
            tag_workflow: (None, False),
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
            self.assertEqual([identifier for identifier, _ in result], expected)
            self.assertIn("repo#5: failed to find the branch of", stderr.getvalue())
            self.assertIn("buildId=5", stderr.getvalue())
            self.assertIn(
                f"repo#5: not cancelling https://app.circleci.com/workflow/{tag_workflow}",
                stderr.getvalue(),
            )

    def test_circleci_workflows_of_jobs(self) -> None:
        """The workflows of jobs whose URLs name no workflow come from job lookups."""
        jobs = [("pending", f"job{n}", f"https://circleci.com/gh/org/repo/{n}") for n in (1, 2)]
        pages = {
            f"{CIRCLECI}/project/gh/org/repo/job/{n}": {"latest_workflow": {"id": "w9"}}
            for n in (1, 2)
        }

        def http(_method: str, url: str, *_: Any, **_kwargs: Any) -> bytes:
            return json.dumps(pages[url]).encode()

        with (
            mock.patch.object(request_util, "http", http),
            mock.patch.object(ci_build, "circleci_token", return_value="token"),
        ):
            result = cancel_blocked_ci.circleci_workflows_of_jobs("repo#5", jobs)
        self.assertEqual(result, [("w9", ("pending", "job1")), ("w9", ("pending", "job2"))])

    def test_unless_finished(self) -> None:
        """A failure to cancel a build is raised unless the build has finished."""
        error = urllib.error.URLError("refused")

        def cancelling() -> None:
            raise error

        def lookup_fails() -> bool:
            raise urllib.error.URLError("unreachable")

        cancel_blocked_ci.unless_finished(cancelling, lambda: True)()
        for finished in [lambda: False, lookup_fails]:
            with (
                self.subTest(finished=finished),
                self.assertRaises(urllib.error.URLError) as cm,
            ):
                cancel_blocked_ci.unless_finished(cancelling, finished)()
            self.assertIs(cm.exception, error)


if __name__ == "__main__":
    unittest.main()
