"""Tests for the ci_build and request_util modules.

The tests contact no server:  fakes replace the HTTP requests that the modules make.
"""

from __future__ import annotations

import io
import json
import subprocess
import sys
import time
import unittest
import urllib.error
from email.message import Message
from pathlib import Path
from typing import Any
from unittest import mock

TOPLEVEL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOPLEVEL))

import ci_build  # ruff: ignore[module-import-not-at-top-of-file]
import request_util  # ruff: ignore[module-import-not-at-top-of-file]


class CiBuildTest(unittest.TestCase):
    """Tests for ci_build and request_util."""

    def test_parse_azure_url(self) -> None:
        """The organization, project, and build are found in an Azure Pipelines URL."""
        for url in [
            "https://dev.azure.com/org/proj/_build/results?buildId=500&view=logs&jobId=a",
            "https://org.visualstudio.com/proj/_build/results?buildId=500",
        ]:
            with self.subTest(url=url):
                parsed = ci_build.parse_azure_url(url)
                self.assertEqual(parsed, ci_build.AzureBuildUrl("org", "proj", 500))
                assert parsed is not None
                self.assertEqual((parsed.org, parsed.project, parsed.build), ("org", "proj", 500))
        self.assertIsNone(ci_build.parse_azure_url("https://example.com/build/1"))

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
            ("https://circleci.com/gh/org/repo/230602/", "gh/org/repo"),
            ("http://circleci.com/bitbucket/org/repo/230602", "bb/org/repo"),
            ("https://app.circleci.com/jobs/github/org/repo/123", "gh/org/repo"),
            (f"https://app.circleci.com/workflow/{workflow}", None),
        ]:
            with self.subTest(url=url):
                self.assertEqual(ci_build.circleci_project_of_url(url), expected)

    def test_parse_circleci_url(self) -> None:
        """The workflow, project, and job are found in each kind of CircleCI URL."""
        workflow = "ecc46ce8-0000-0000-0000-000000000000"
        for url, expected in [
            (f"https://app.circleci.com/workflow/{workflow}", (workflow, None, None)),
            (
                f"https://app.circleci.com/pipelines/gh/org/repo/7/workflows/{workflow}/jobs/9",
                (workflow, None, 9),
            ),
            (
                "https://circleci.com/gh/org/repo/230602?utm_campaign=x",
                (None, "gh/org/repo", 230602),
            ),
            ("https://example.com/build/1", None),
        ]:
            with self.subTest(url=url):
                parsed = ci_build.parse_circleci_url(url)
                self.assertEqual(parsed, expected)
                if parsed is not None:
                    self.assertEqual((parsed.workflow, parsed.project, parsed.job), expected)
        self.assertEqual(
            ci_build.circleci_workflow_of_url(f"https://app.circleci.com/workflow/{workflow}"),
            ci_build.CircleciWorkflowAndJob(workflow, None),
        )

    def test_azure_sign_in_page(self) -> None:
        """A response that is not JSON marks the project private, and credentials are used."""
        url = "https://dev.azure.com/org/project/_apis/build/builds"
        calls = []

        def http(
            _method: str, _url: str, headers: dict[str, str] | None, *_: Any, **_kwargs: Any
        ) -> bytes:
            calls.append(bool(headers))
            return b"{}" if headers else b"<html>Sign in</html>"

        with (
            mock.patch.object(request_util, "http", http),
            mock.patch.object(ci_build, "azure_headers", return_value={"Authorization": "x"}),
            mock.patch.object(ci_build, "_azure_private_projects", set()),
        ):
            self.assertEqual(ci_build.azure_get(url), {})
            self.assertEqual(ci_build.azure_get(url), {})
        self.assertEqual(calls, [False, True, True])

    def test_azure_not_found(self) -> None:
        """A 404 that credentials do not fix does not mark the project private."""
        url = "https://dev.azure.com/org/project/_apis/build/builds/1"
        calls = []

        def http(
            _method: str, url: str, headers: dict[str, str] | None, *_: Any, **_kwargs: Any
        ) -> bytes:
            calls.append(bool(headers))
            status = 401 if headers else 404
            raise urllib.error.HTTPError(url, status, "Refused", Message(), io.BytesIO())

        with (
            mock.patch.object(request_util, "http", http),
            mock.patch.object(ci_build, "azure_headers", return_value={"Authorization": "x"}),
            mock.patch.object(ci_build, "_azure_private_projects", set()),
        ):
            for _ in range(2):
                with self.assertRaises(urllib.error.HTTPError):
                    ci_build.azure_get(url)
        self.assertEqual(calls, [False, True, False, True])

    def test_azure_token_expiration(self) -> None:
        """A token from `az` is replaced before it expires, and a failed `az` is retried."""
        now = time.time()
        soon = now + ci_build.AZURE_TOKEN_MARGIN - 1  # too soon to use the token
        later = now + ci_build.AZURE_TOKEN_MARGIN + 3600
        outputs: list[Any] = [
            json.dumps({"accessToken": "t1", "expires_on": soon}),
            json.dumps({"accessToken": "t2", "expires_on": later}),
            subprocess.CalledProcessError(1, "az"),
            subprocess.CalledProcessError(1, "az"),
            json.dumps({"accessToken": "t3", "expires_on": later}),
        ]

        def run(_cmd: list[str]) -> str:
            output = outputs.pop(0)
            if isinstance(output, Exception):
                raise output
            return output

        with (
            mock.patch.dict(ci_build.os.environ, {"AZURE_DEVOPS_EXT_PAT": ""}),
            mock.patch.object(request_util, "run", run),
            mock.patch.object(ci_build, "_azure_token_headers", None),
        ):
            self.assertEqual(ci_build.azure_headers(), {"Authorization": "Bearer t1"})
            self.assertEqual(ci_build.azure_headers(), {"Authorization": "Bearer t2"})
            self.assertEqual(ci_build.azure_headers(), {"Authorization": "Bearer t2"})
            self.assertEqual(len(outputs), 3)
            # Force the token to be replaced, and retry each failed `az` at once.
            ci_build._azure_token_headers = None  # ruff: ignore[private-member-access]
            with mock.patch.object(ci_build, "AZURE_TOKEN_RETRY", 0):
                self.assertEqual(ci_build.azure_headers(), {})
                self.assertEqual(ci_build.azure_headers(), {})
                self.assertEqual(ci_build.azure_headers(), {"Authorization": "Bearer t3"})
        self.assertEqual(outputs, [])

    def test_circleci_items_empty_response(self) -> None:
        """An empty response for a page of items raises an error in REQUEST_ERRORS."""
        with (
            mock.patch.object(request_util, "http", return_value=b""),
            self.assertRaises(request_util.REQUEST_ERRORS),
        ):
            list(ci_build.circleci_items("/v2/workflow/ID/job"))

    def test_azure_request_refusals(self) -> None:
        """A request of Azure DevOps treats a sign-in page as a refusal; another does not."""
        refusals = []

        def http(*_: Any, **kwargs: Any) -> bytes:
            refusals.append(kwargs.get("refusals"))
            return b"{}"

        with mock.patch.object(request_util, "http", http):
            ci_build.azure_request("GET", "https://dev.azure.com/org/p/_apis/build/builds", {})
            request_util.request("GET", "https://example.com/")
        self.assertEqual(refusals, [ci_build.AZURE_SIGN_IN, None])

    def test_command_timeout(self) -> None:
        """A command that runs too long is stopped, with an error in REQUEST_ERRORS."""
        with (
            mock.patch.object(request_util, "COMMAND_TIMEOUT", 0.1),
            self.assertRaises(request_util.REQUEST_ERRORS) as cm,
        ):
            request_util.run(["sleep", "10"])
        self.assertIsInstance(cm.exception, subprocess.TimeoutExpired)

    def test_azure_temporary_failure(self) -> None:
        """A temporary failure of an anonymous request does not mark the project private."""
        url = "https://dev.azure.com/org/project/_apis/build/builds"
        calls = []

        def http(
            _method: str, url: str, headers: dict[str, str] | None, *_: Any, **_kwargs: Any
        ) -> bytes:
            calls.append(bool(headers))
            if len(calls) == 1:
                raise urllib.error.HTTPError(
                    url, 503, "Service Unavailable", Message(), io.BytesIO()
                )
            return b"{}"

        with (
            mock.patch.object(request_util, "http", http),
            mock.patch.object(ci_build, "azure_headers", return_value={"Authorization": "x"}),
            mock.patch.object(ci_build, "_azure_private_projects", set()),
        ):
            with self.assertRaises(urllib.error.HTTPError):
                ci_build.azure_get(url)
            self.assertEqual(ci_build.azure_get(url), {})
        self.assertEqual(calls, [False, False])


if __name__ == "__main__":
    unittest.main()
