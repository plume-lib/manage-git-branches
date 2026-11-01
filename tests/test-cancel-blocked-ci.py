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

        A run that waits for a concurrency group makes no older run redundant.
        """

        def run(n: int, event: str, status: str = "queued") -> dict[str, Any]:
            return {
                "id": n,
                "name": "build",
                "status": status,
                "html_url": f"https://github.com/org/repo/actions/runs/{n}",
                "workflow_id": 7,
                "event": event,
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
            ]
        }
        result = cancel_blocked_ci.redundant_runs("repo", "org/repo", runs)
        self.assertEqual(
            [(identifier, subject, reason) for identifier, subject, _, reason in result],
            [(("github", 0), "repo main", ", made redundant by run 1")],
        )

    def test_redundant_azure_builds(self) -> None:
        """A build that waits for a check of a stage makes no older build redundant."""

        def build(n: int) -> dict[str, Any]:
            return {
                "id": n,
                "status": "inProgress",
                "reason": "individualCI",
                "sourceBranch": "refs/heads/main",
                "definition": {"id": 1, "name": "ci"},
                "_links": {
                    "web": {"href": f"https://dev.azure.com/org/p/_build/results?buildId={n}"}
                },
            }

        def azure_get(url: str) -> Any:
            if "/timeline" not in url:
                return {"value": [build(n) for n in (1, 2, 3)]}
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
        pr = {"owner": "org", "headRefName": "main"}
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

    def test_circleci_project_of_url(self) -> None:
        """The project slug is found in each kind of CircleCI URL that contains it."""
        workflow = "ecc46ce8-0000-0000-0000-000000000000"
        for url, expected in [
            (
                f"https://app.circleci.com/pipelines/github/org/repo/7/workflows/{workflow}",
                "gh/org/repo",
            ),
            (
                f"https://app.circleci.com/pipelines/circleci/AbC/dEf/7/workflows/{workflow}/jobs/9",
                "circleci/AbC/dEf",
            ),
            ("https://circleci.com/gh/org/repo/230602?utm_campaign=x", "gh/org/repo"),
            (f"https://app.circleci.com/workflow/{workflow}", None),
        ]:
            with self.subTest(url=url):
                self.assertEqual(ci_build.circleci_project_of_url(url), expected)

    def test_circleci_workflows_of_jobs(self) -> None:
        """The workflows of jobs come from the recent pipelines, or else from job lookups."""
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
        for sha, expected, lookups in [
            ("abc", [("w1", ("running", "build"))], []),
            ("def", [("w9", ("pending", "job1")), ("w9", ("pending", "job2"))], [1, 2]),
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
            ) -> bytes:
                requested.append(url)
                return json.dumps(pages[url]).encode()

            with (
                self.subTest(sha=sha),
                mock.patch.object(ci_build, "http", http),
                mock.patch.object(ci_build, "circleci_token", return_value="token"),
            ):
                cancel_blocked_ci.recent_pipelines.cache_clear()
                cancel_blocked_ci.unfinished_workflows.cache_clear()
                result = cancel_blocked_ci.circleci_workflows_of_jobs("gh/org/repo", sha, jobs)
                self.assertEqual(result, expected)
                self.assertEqual(
                    sorted(requested),
                    sorted(
                        [f"{CIRCLECI}/project/gh/org/repo/pipeline"]
                        + ([f"{CIRCLECI}/pipeline/p1/workflow"] if sha == "abc" else [])
                        + [f"{CIRCLECI}/project/gh/org/repo/job/{n}" for n in lookups]
                    ),
                )

    def test_azure_sign_in_page(self) -> None:
        """A response that is not JSON marks the project private, and credentials are used."""
        url = "https://dev.azure.com/org/project/_apis/build/builds"
        calls = []

        def http(_method: str, _url: str, headers: dict[str, str] | None, *_: Any) -> bytes:
            calls.append(bool(headers))
            return b"{}" if headers else b"<html>Sign in</html>"

        with (
            mock.patch.object(ci_build, "http", http),
            mock.patch.object(ci_build, "azure_headers", return_value={"Authorization": "x"}),
            mock.patch.object(ci_build, "_azure_private_projects", set()),
        ):
            self.assertEqual(ci_build.azure_get(url), {})
            self.assertEqual(ci_build.azure_get(url), {})
        self.assertEqual(calls, [False, True, True])

    def test_azure_temporary_failure(self) -> None:
        """A temporary failure of an anonymous request does not mark the project private."""
        url = "https://dev.azure.com/org/project/_apis/build/builds"
        calls = []

        def http(_method: str, url: str, headers: dict[str, str] | None, *_: Any) -> bytes:
            calls.append(bool(headers))
            if len(calls) == 1:
                raise urllib.error.HTTPError(
                    url, 503, "Service Unavailable", Message(), io.BytesIO()
                )
            return b"{}"

        with (
            mock.patch.object(ci_build, "http", http),
            mock.patch.object(ci_build, "azure_headers", return_value={"Authorization": "x"}),
            mock.patch.object(ci_build, "_azure_private_projects", set()),
        ):
            with self.assertRaises(urllib.error.HTTPError):
                ci_build.azure_get(url)
            self.assertEqual(ci_build.azure_get(url), {})
        self.assertEqual(calls, [False, False])

    def test_circleci_pagination(self) -> None:
        """Every page of recent pipelines and of their workflows is read, and no older page."""
        now = dt.datetime.now(dt.UTC)
        recent, old = str(now), str(now - 2 * cancel_blocked_ci.CIRCLECI_WINDOW)

        def pipeline(n: int, created: str, trigger: str = "webhook") -> dict[str, Any]:
            return {
                "id": f"p{n}",
                "number": n,
                "created_at": created,
                "vcs": {"branch": "main"},
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

        def http(_method: str, url: str, *_: Any) -> bytes:
            requested.append(url)
            if url not in pages:
                raise urllib.error.HTTPError(url, 404, "Not Found", Message(), io.BytesIO())
            return json.dumps(pages[url]).encode()

        with (
            mock.patch.object(ci_build, "http", http),
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
