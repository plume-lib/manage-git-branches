"""Tests for the ci_build and request_util modules.

The tests contact no server:  fakes replace the HTTP requests that the modules make.
"""

from __future__ import annotations

import io
import sys
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

    def test_azure_request_refusals(self) -> None:
        """A request of Azure DevOps treats a sign-in page as a refusal; another does not."""
        refusals = []

        def http(*_: Any, refusals_seen: list[Any] = refusals, **kwargs: Any) -> bytes:
            refusals_seen.append(kwargs.get("refusals"))
            return b"{}"

        with mock.patch.object(request_util, "http", http):
            ci_build.azure_request("GET", "https://dev.azure.com/org/p/_apis/build/builds", {})
            request_util.request("GET", "https://example.com/")
        self.assertEqual(refusals, [ci_build.AZURE_SIGN_IN, None])

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
