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

    def test_options(self) -> None:
        """An unknown option is rejected before anything is examined or cancelled."""
        for args in [["--dryrun"], ["extra"]]:
            with (
                self.subTest(args=args),
                mock.patch.object(sys, "argv", ["cancel-blocked-ci", *args]),
                mock.patch.object(
                    cancel_blocked_ci, "blocked_from_document", side_effect=AssertionError
                ),
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
            result = cancel_blocked_ci.redundant_builds("repo", "org/repo", {})
        self.assertEqual(result, ["workflow"])
        self.assertIn("repo: failed to find redundant Azure Pipelines builds", stderr.getvalue())

    def test_circleci_pagination(self) -> None:
        """Every page of recent pipelines and of their workflows is read, and no older page."""
        now = dt.datetime.now(dt.UTC)
        recent, old = str(now), str(now - 2 * cancel_blocked_ci.CIRCLECI_WINDOW)

        def pipeline(n: int, created: str) -> dict[str, Any]:
            return {
                "id": f"p{n}",
                "number": n,
                "created_at": created,
                "vcs": {"branch": "main"},
                "trigger": {"type": "webhook"},
            }

        def workflow(n: int) -> dict[str, Any]:
            return {"id": f"w{n}", "name": "build", "status": "running", "created_at": recent}

        # Each page token contains characters that must be escaped in a URL.
        pages = {
            f"{CIRCLECI}/project/gh/org/repo/pipeline": {
                "items": [pipeline(2, recent)],
                "next_page_token": "a+b/c=",
            },
            f"{CIRCLECI}/project/gh/org/repo/pipeline?page-token=a%2Bb%2Fc%3D": {
                "items": [pipeline(1, recent), pipeline(0, old)],
                "next_page_token": "older",
            },
            f"{CIRCLECI}/pipeline/p2/workflow": {"items": [workflow(2)], "next_page_token": None},
            f"{CIRCLECI}/pipeline/p1/workflow": {"items": [], "next_page_token": "x+y"},
            f"{CIRCLECI}/pipeline/p1/workflow?page-token=x%2By": {
                "items": [workflow(1)],
                "next_page_token": None,
            },
        }
        requested = []

        def http(_method: str, url: str, *_: Any) -> bytes:
            requested.append(url)
            if url not in pages:
                raise urllib.error.HTTPError(url, 404, "Not Found", Message(), None)
            return json.dumps(pages[url]).encode()

        with (
            mock.patch.object(ci_build, "http", http),
            mock.patch.object(ci_build, "circleci_token", return_value="token"),
        ):
            result = cancel_blocked_ci.redundant_circleci_workflows("repo", "org/repo")
        self.assertEqual(sorted(requested), sorted(pages))
        self.assertEqual(
            [(identifier, reason) for identifier, _, _, reason in result],
            [(("circleci", "w1"), ", made redundant by workflow w2")],
        )


if __name__ == "__main__":
    unittest.main()
