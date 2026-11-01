"""Tests for the cancel-blocked-ci script.

The tests contact no server:  fakes replace the HTTP requests that the script makes and
the pr-status script that it imports.
"""

from __future__ import annotations

import contextlib
import datetime as dt
import importlib.machinery
import importlib.util
import io
import json
import sys
import tempfile
import unittest
import urllib.error
from email.message import Message
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

    def setUp(self) -> None:
        """Forget the CircleCI responses of other tests."""
        cancel_blocked_ci.recent_pipelines.cache_clear()
        cancel_blocked_ci.unfinished_workflows.cache_clear()

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

    def test_unreadable_azure_project(self) -> None:
        """A response that is not JSON is reported, and the other CI services are examined."""
        stderr = io.StringIO()
        with (
            mock.patch.object(cancel_blocked_ci, "azure_projects", return_value={("org", "p")}),
            mock.patch.object(
                ci_build, "azure_get", side_effect=json.JSONDecodeError("not JSON", "<html>", 0)
            ),
            mock.patch.object(
                cancel_blocked_ci, "redundant_circleci_workflows", return_value=["workflow"]
            ),
            contextlib.redirect_stderr(stderr),
        ):
            result = cancel_blocked_ci.redundant_builds("repo", "org/repo", {}, [])
        self.assertEqual(result, ["workflow"])
        self.assertIn("repo: failed to find redundant Azure Pipelines builds", stderr.getvalue())

    def test_redundant_runs(self) -> None:
        """Only a run that a push or a pull request started can be redundant.

        A run that waits for a concurrency group, or that tests the same commit, makes no
        older run redundant.
        """

        def run(n: int, event: str, status: str = "queued", sha: str = "") -> dict[str, Any]:
            return {
                "id": n,
                "name": "build",
                "status": status,
                "html_url": f"https://github.com/org/repo/actions/runs/{n}",
                "workflow_id": 7,
                "event": event,
                "head_sha": sha or f"sha{n}",
                "created_at": f"2026-10-31T00:00:0{n}Z",
                "head_branch": "main",
                "head_repository": {"owner": {"login": "org"}},
            }

        runs = {
            ("org", "main"): [
                run(0, "push"),
                run(1, "push"),
                run(2, "schedule"),
                run(3, "schedule"),
                run(4, "push", "pending"),
                # Labeling the PR started run 6, which tests the same commit as run 5.
                run(5, "pull_request", sha="pr"),
                run(6, "pull_request", sha="pr"),
            ]
        }
        result = cancel_blocked_ci.redundant_runs("repo", "org/repo", runs)
        self.assertEqual(
            [(identifier, subject, reason) for identifier, subject, _, reason in result],
            [(("github", 0), "repo main", ", made redundant by run 1")],
        )

    def test_redundant_azure_builds(self) -> None:
        """A build that waits for a check of a stage makes no older build redundant.

        Nor does a build of the same commit.
        """

        def build(n: int) -> dict[str, Any]:
            return {
                "id": n,
                "status": "inProgress",
                "reason": "individualCI",
                "sourceBranch": "refs/heads/main",
                # Builds 0 and 2 test the same commit.
                "sourceVersion": f"commit{n % 2}" if n != 3 else "commit3",
                "definition": {"id": 1, "name": "ci"},
                "_links": {
                    "web": {"href": f"https://dev.azure.com/org/p/_build/results?buildId={n}"}
                },
            }

        def azure_get(url: str) -> Any:
            if "/timeline" not in url:
                return {"value": [build(n) for n in (0, 1, 2, 3)]}
            # Build 3 waits for an approval.
            state = "inProgress" if "/builds/3/" in url else "completed"
            return {"records": [{"type": "Checkpoint.Approval", "state": state}]}

        with mock.patch.object(ci_build, "azure_get", azure_get):
            result = cancel_blocked_ci.redundant_azure_builds("repo", "org/repo", "org", "p")
        self.assertEqual(
            [(identifier, reason) for identifier, _, _, reason in result],
            [(("azure", "org", "1"), ", made redundant by build 2")],
        )

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
        """Only the builds of the given branches are a commit's builds.

        A build whose branch cannot be found is reported, and the exit status becomes 1.
        """
        workflow = "0123456789abcdef0123456789abcdef0123"
        other_workflow = "fedcba9876543210fedcba9876543210fedc"
        checks = [
            ("in_progress", "ci", "https://dev.azure.com/org/p/_build/results?buildId=1"),
            ("in_progress", "ci", "https://dev.azure.com/org/p/_build/results?buildId=2"),
            ("in_progress", "ci", "https://dev.azure.com/org/p/_build/results?buildId=3"),
            ("completed", "ci", "https://dev.azure.com/org/p/_build/results?buildId=4"),
            # Finding the branch of build 5 fails.
            ("in_progress", "ci", "https://dev.azure.com/org/p/_build/results?buildId=5"),
            ("pending", "build", f"https://app.circleci.com/workflow/{workflow}"),
            ("pending", "build", f"https://app.circleci.com/workflow/{other_workflow}"),
        ]
        azure_branches = {1: "refs/pull/5/merge", 2: "refs/heads/feature", 3: "refs/heads/other"}

        def azure_build_branch(_org: str, _project: str, build: int) -> str:
            if build not in azure_branches:
                raise urllib.error.URLError("unreachable")
            return azure_branches[build]

        circleci_branches = {workflow: "feature", other_workflow: "other"}
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
                mock.patch.object(
                    cancel_blocked_ci,
                    "azure_build_branch",
                    azure_build_branch,
                ),
                mock.patch.object(
                    cancel_blocked_ci, "circleci_workflow_branch", circleci_branches.get
                ),
                mock.patch.object(cancel_blocked_ci, "failed", new=False),
                contextlib.redirect_stderr(io.StringIO()) as stderr,
            ):
                result = cancel_blocked_ci.unfinished_other_builds("org/repo", "abc", branches)
                self.assertTrue(cancel_blocked_ci.failed)
            self.assertEqual([identifier for identifier, _ in result], expected)
            self.assertIn("failed to find the branch of", stderr.getvalue())
            self.assertIn("buildId=5", stderr.getvalue())

    def test_circleci_workflows_of_jobs(self) -> None:
        """The workflows of jobs come from the recent pipelines, or else from job lookups.

        Only the recent pipelines of the given branches count.
        """
        now = str(dt.datetime.now(dt.UTC))
        jobs = [("pending", f"job{n}", f"https://circleci.com/gh/org/repo/{n}") for n in (1, 2)]

        def pipeline(sha: str) -> dict[str, Any]:
            return {
                "id": "p1",
                "number": 1,
                "created_at": now,
                "vcs": {"branch": "feature", "revision": sha},
                "trigger": {"type": "webhook"},
            }

        workflow = {"id": "w1", "name": "build", "status": "running", "created_at": now}
        looked_up = [("w9", ("pending", "job1"), None), ("w9", ("pending", "job2"), None)]
        for sha, branch, expected, lookups in [
            ("abc", "feature", [("w1", ("running", "build"), "feature")], []),
            # The pipeline of commit abc is on another branch.
            ("abc", "other", looked_up, [1, 2]),
            ("def", "feature", looked_up, [1, 2]),
        ]:
            pages = {
                f"{CIRCLECI}/project/gh/org/repo/pipeline": {"items": [pipeline("abc")]},
                f"{CIRCLECI}/pipeline/p1/workflow": {"items": [workflow]},
                **{
                    f"{CIRCLECI}/project/gh/org/repo/job/{n}": {"latest_workflow": {"id": "w9"}}
                    for n in (1, 2)
                },
            }
            requested = []

            def http(
                _method: str,
                url: str,
                *_: Any,
                pages: dict[str, Any] = pages,
                requested: list[str] = requested,
                **_kwargs: Any,
            ) -> bytes:
                requested.append(url)
                return json.dumps(pages[url]).encode()

            with (
                self.subTest(sha=sha, branch=branch),
                mock.patch.object(request_util, "http", http),
                mock.patch.object(ci_build, "circleci_token", return_value="token"),
            ):
                cancel_blocked_ci.recent_pipelines.cache_clear()
                cancel_blocked_ci.unfinished_workflows.cache_clear()
                result = cancel_blocked_ci.circleci_workflows_of_jobs(
                    "gh/org/repo", sha, {branch}, jobs
                )
                self.assertEqual(result, expected)
                self.assertEqual(
                    sorted(requested),
                    sorted(
                        [f"{CIRCLECI}/project/gh/org/repo/pipeline"]
                        + ([f"{CIRCLECI}/pipeline/p1/workflow"] if not lookups else [])
                        + [f"{CIRCLECI}/project/gh/org/repo/job/{n}" for n in lookups]
                    ),
                )

    def test_azure_projects(self) -> None:
        """The Azure Pipelines projects come from the checks of the default branch and of PRs."""
        checks = {
            "HEAD": [("completed", "ci", "https://github.com/org/repo/actions/runs/1")],
            # A commit status, not a check run, as from an OAuth service connection.
            "pr1": [("pending", "ci", "https://dev.azure.com/org/p/_build/results?buildId=7")],
            "pr2": [
                ("completed", "ci", "https://org2.visualstudio.com/q/_build/results?buildId=8")
            ],
        }
        with mock.patch.object(cancel_blocked_ci, "checks", lambda _gh, sha: checks[sha]):
            self.assertEqual(
                cancel_blocked_ci.azure_projects("org/repo", ["pr1", "pr2"]),
                {("org", "p"), ("org2", "q")},
            )

    def test_circleci_pagination(self) -> None:
        """Every page of recent pipelines and of their workflows is read, and no older page."""
        now = dt.datetime.now(dt.UTC)
        recent, old = str(now), str(now - 2 * cancel_blocked_ci.CIRCLECI_WINDOW)

        def pipeline(n: int, created: str, trigger: str = "webhook") -> dict[str, Any]:
            return {
                "id": f"p{n}",
                "number": n,
                "created_at": created,
                "vcs": {"branch": "main", "revision": f"commit{n}"},
                "trigger": {"type": trigger},
            }

        def workflow(n: int) -> dict[str, Any]:
            return {"id": f"w{n}", "name": "build", "status": "running", "created_at": recent}

        # Each page token contains characters that must be escaped in a URL.
        pages = {
            f"{CIRCLECI}/project/gh/org/repo/pipeline": {
                # A scheduled pipeline is never redundant, so its workflows are not read.
                "items": [pipeline(4, recent, "scheduled_pipeline"), pipeline(3, recent)],
                "next_page_token": "a+b/c=",
            },
            f"{CIRCLECI}/project/gh/org/repo/pipeline?page-token=a%2Bb%2Fc%3D": {
                "items": [pipeline(2, recent), pipeline(1, recent), pipeline(0, old)],
                "next_page_token": "older",
            },
            f"{CIRCLECI}/pipeline/p2/workflow": {"items": [workflow(2)], "next_page_token": None},
            f"{CIRCLECI}/pipeline/p1/workflow": {"items": [], "next_page_token": "x+y"},
            f"{CIRCLECI}/pipeline/p1/workflow?page-token=x%2By": {
                "items": [workflow(1)],
                "next_page_token": None,
            },
        }
        # Pipeline 3 was deleted after it was listed.
        deleted = f"{CIRCLECI}/pipeline/p3/workflow"
        requested = []

        def http(_method: str, url: str, *_: Any, **_kwargs: Any) -> bytes:
            requested.append(url)
            if url not in pages:
                raise urllib.error.HTTPError(url, 404, "Not Found", Message(), io.BytesIO())
            return json.dumps(pages[url]).encode()

        with (
            mock.patch.object(request_util, "http", http),
            mock.patch.object(ci_build, "circleci_token", return_value="token"),
            mock.patch.object(
                cancel_blocked_ci,
                "checks",
                return_value=[("completed", "ci", "https://app.circleci.com/workflow/x")],
            ),
        ):
            result = cancel_blocked_ci.redundant_circleci_workflows("repo", "org/repo")
        self.assertEqual(sorted(requested), sorted([*pages, deleted]))
        self.assertEqual(
            [(identifier, reason) for identifier, _, _, reason in result],
            [(("circleci", "w1"), ", made redundant by workflow w2")],
        )


if __name__ == "__main__":
    unittest.main()
