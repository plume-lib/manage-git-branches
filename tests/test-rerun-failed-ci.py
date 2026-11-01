"""Tests for the rerun-failed-ci script.

The tests contact no server:  a fake replaces the HTTP requests and the `gh` commands
that the script makes, serving canned responses and recording the reruns.
"""

from __future__ import annotations

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from email.message import Message
from pathlib import Path
from typing import TYPE_CHECKING, Any
from unittest import mock

TOPLEVEL = Path(__file__).resolve().parent.parent
RERUN = TOPLEVEL / "rerun-failed-ci"
sys.path.insert(0, str(TOPLEVEL))

import ci_build  # ruff: ignore[module-import-not-at-top-of-file]
import request_util  # ruff: ignore[module-import-not-at-top-of-file]

if TYPE_CHECKING:
    import types
    from collections.abc import Mapping


def load_script() -> types.ModuleType:
    """Import rerun-failed-ci, whose name is not a legal module name.

    Returns:
        The imported module.
    """
    loader = importlib.machinery.SourceFileLoader("rerun_failed_ci", str(RERUN))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


rerun_failed_ci = load_script()

GRADLE_429 = (
    "   > Could not GET 'https://repo.maven.apache.org/x.pom'. Received status code 429"
    " from server: Too Many Requests"
)

CIRCLECI = "https://circleci.com/api"
AZURE = "https://dev.azure.com/org/proj/_apis/build/builds"


def uuid(n: int) -> str:
    """Return the CircleCI workflow id that ends with the given number.

    Args:
        n: a workflow's number, such as 2.

    Returns:
        A UUID that ends with n, such as "00000000-0000-0000-0000-000000000002".
    """
    return f"00000000-0000-0000-0000-{n:012d}"


class FakeServer:
    """Serves canned responses to HTTP requests and `gh` commands, and records reruns.

    Attributes:
        urls: a map from a URL, without its query string except for a CircleCI page
            token, to the response body (which is converted to JSON unless it is a
            string).
        gh: a map from the path of a `gh api` request to its response.
        gh_logs: a map from a GitHub Actions job id to the `--log-failed` output.
        pr_checks: a map from a pull request to its checks.
        reruns: the rerun requests, as strings.
    """

    def __init__(self) -> None:
        """Create a FakeServer that serves nothing."""
        self.urls: dict[str, Any] = {}
        self.gh: dict[str, Any] = {}
        self.gh_logs: dict[int, str] = {}
        self.pr_checks: dict[str, list[dict[str, str]]] = {}
        self.reruns: list[str] = []

    def http(
        self,
        method: str,
        url: str,
        headers: dict[str, str] | None = None,
        body: Any = None,
        *,
        refusals: Mapping[int, str] | None = None,  # ruff: ignore[unused-method-argument]
    ) -> bytes:
        """Serve the given HTTP request, as request_util.http does.

        A request other than a GET, which reruns jobs, requires credentials.

        Returns:
            The response body.
        """
        if method != "GET":
            if not headers:
                raise urllib.error.HTTPError(url, 401, "Unauthorized", Message(), None)
            self.reruns.append(f"{method} {url} {json.dumps(body)}")
            return b'{"workflow_id": "new-workflow"}' if "circleci" in url else b"{}"
        path, _, query = url.partition("?")
        if "page-token=" in query:
            path += "#" + query.split("page-token=")[1].split("&")[0]
        if path not in self.urls:
            raise urllib.error.HTTPError(url, 404, "Not Found", Message(), None)
        response = self.urls[path]
        return (response if isinstance(response, str) else json.dumps(response)).encode()

    def run(self, cmd: list[str]) -> str:
        """Run the given `gh` command, as request_util.run does.

        Returns:
            The command's output.
        """
        if cmd[:2] == ["gh", "api"]:
            path = cmd[-1]
            if path not in self.gh:
                raise subprocess.CalledProcessError(1, cmd, "", "gh: Not Found (HTTP 404)")
            return json.dumps(self.gh[path])
        if cmd[:3] == ["gh", "run", "view"]:
            job = int(cmd[cmd.index("--job") + 1])
            if job not in self.gh_logs:
                raise subprocess.CalledProcessError(1, cmd, "", "log not found")
            return self.gh_logs[job]
        if cmd[:3] == ["gh", "run", "rerun"]:
            self.reruns.append(" ".join(cmd))
            return ""
        if cmd[:3] == ["gh", "pr", "checks"]:
            return json.dumps(self.pr_checks[cmd[3]])
        msg = f"unsupported command: {cmd}"
        raise AssertionError(msg)

    ###########################################################################
    ### Azure Pipelines
    ###

    def azure_build(self, build: int, status: str, result: str | None) -> None:
        """Serve the given Azure Pipelines build.

        Args:
            build: the id of a build.
            status: the build's status, such as "completed".
            result: the build's result, such as "failed", or None if it has none.
        """
        self.urls[f"{AZURE}/{build}"] = {
            "definition": {"name": "pipeline"},
            "status": status,
            "result": result,
        }

    def azure_timeline(
        self,
        build: int,
        *jobs: tuple[str, int, str, str, str | None],
        issue: dict[str, str] | None = None,
    ) -> None:
        """Serve the timeline of the given Azure Pipelines build.

        Args:
            build: the id of a build.
            jobs: for each job, its stage, the stage's attempts, the job's name, the
                job's result, and the log of its only task (None for an unreadable log).
                A job's id is its name.
            issue: an issue that each job's task reports, in addition to an error.
        """
        self.urls = {
            url: response
            for url, response in self.urls.items()
            if not url.startswith(f"{AZURE}/{build}/logs/")
        }
        records: list[dict[str, Any]] = [
            {"id": "other", "parentId": None, "type": "Checkpoint", "result": "failed"}
        ]
        for n, (stage, attempt, job, result, log) in enumerate(jobs, start=1):
            records += [
                {
                    "id": f"stage-{stage}",
                    "parentId": None,
                    "type": "Stage",
                    "identifier": stage,
                    "attempt": attempt,
                    "result": result,
                },
                {
                    "id": f"phase-{job}",
                    "parentId": f"stage-{stage}",
                    "type": "Phase",
                    "attempt": attempt,
                    "result": result,
                },
                {
                    "id": job,
                    "parentId": f"phase-{job}",
                    "type": "Job",
                    "name": job,
                    "attempt": attempt,
                    "result": result,
                    "log": {"id": 99},
                },
                {
                    "id": f"task-{job}",
                    "parentId": job,
                    "type": "Task",
                    "result": result,
                    "log": {"id": n},
                    "issues": [
                        {"type": "error", "message": "Bash exited with code '1'."},
                        *([issue] if issue else []),
                    ],
                },
            ]
            if log is not None:
                self.urls[f"{AZURE}/{build}/logs/{n}"] = f"﻿2026-10-31T13:39:57.3265176Z {log}\r\n"
        self.urls[f"{AZURE}/{build}/timeline"] = {"records": records}

    ###########################################################################
    ### CircleCI
    ###

    def circleci_workflow(
        self, n: int, status: str, workflows: list[tuple[int, str]] | None = None
    ) -> None:
        """Serve the given CircleCI workflow, which is named "build".

        Args:
            n: a workflow's number, from which uuid makes its id.
            status: the workflow's status.
            workflows: the number and creation date of each workflow of the pipeline;
                by default, only this workflow.
        """
        self.urls[f"{CIRCLECI}/v2/workflow/{uuid(n)}"] = {
            "name": "build",
            "status": status,
            "project_slug": "gh/org/repo",
            "pipeline_id": f"pipe-{n}",
            "pipeline_number": 7,
        }
        self.urls[f"{CIRCLECI}/v2/pipeline/pipe-{n}/workflow"] = {
            "items": [
                {"id": uuid(w), "name": "build", "created_at": created}
                for w, created in (workflows or [(n, "2026-01-01")])
            ]
            + [{"id": uuid(999), "name": "other", "created_at": "2026-01-09"}],
        }

    def circleci_jobs(self, n: int, *pages: list[tuple[int, str]]) -> None:
        """Serve the jobs of the given CircleCI workflow.

        Args:
            n: a workflow's number, from which uuid makes its id.
            pages: the pages of jobs; each job is a job number and a status.
        """
        path = f"{CIRCLECI}/v2/workflow/{uuid(n)}/job"
        for i, jobs in enumerate(pages):
            self.urls[path + (f"#page{i}" if i else "")] = {
                "items": [
                    {"job_number": j, "id": f"id{j}", "status": s, "name": f"job{j}"}
                    for j, s in jobs
                ],
                "next_page_token": f"page{i + 1}" if i + 1 < len(pages) else None,
            }

    def circleci_job(self, job: int, log: str) -> None:
        """Serve the given CircleCI job, whose failed step printed log.

        Args:
            job: a job's number.
            log: the output of the job's failed step.
        """
        self.urls[f"{CIRCLECI}/v1.1/project/github/org/repo/{job}"] = {
            "steps": [
                {"actions": [{"status": "success", "output_url": f"https://logs/ok-{job}"}]},
                {"actions": [{"status": "failed", "output_url": f"https://logs/out-{job}"}]},
            ]
        }
        self.urls[f"https://logs/out-{job}"] = [{"message": log}]
        self.urls[f"https://logs/ok-{job}"] = [{"message": "Connection reset, but it succeeded"}]

    ###########################################################################
    ### GitHub Actions
    ###

    def gha_run(
        self, status: str, conclusion: str | None, jobs: list[tuple[int, str, str]]
    ) -> None:
        """Serve GitHub Actions run 100, whose latest attempt has the given jobs.

        Args:
            status: the run's status.
            conclusion: the run's conclusion.
            jobs: the id, name, and conclusion of each job of the latest attempt.
        """
        self.gh["repos/org/repo/actions/runs/100"] = {
            "name": "CI",
            "status": status,
            "conclusion": conclusion,
            "run_attempt": 1,
        }
        page = [{"jobs": [{"id": i, "name": n, "conclusion": c} for i, n, c in jobs]}]
        self.gh["repos/org/repo/actions/runs/100/jobs?filter=latest&per_page=100"] = page
        self.gh["repos/org/repo/actions/runs/100/jobs?filter=all&per_page=100"] = page

    def gha_job(
        self, job: int, log: str | None, annotation: str = "Exit code 1.", level: str = "failure"
    ) -> None:
        """Serve the log and the annotation of the given GitHub Actions job.

        Args:
            job: a job's id.
            log: the log of the job's failed steps, or None for none.
            annotation: the message of the job's annotation.
            level: the level of the annotation, such as "failure" or "warning".
        """
        if log is not None:
            self.gh_logs[job] = "".join(
                f"job\tstep\t﻿2026-10-31T13:39:57.3265176Z {line}\n" for line in log.splitlines()
            )
        self.gh[f"repos/org/repo/check-runs/{job}/annotations?per_page=100"] = [
            [{"message": annotation, "annotation_level": level}]
        ]


class RerunTestCase(unittest.TestCase):
    """A test of rerun-failed-ci against a FakeServer."""

    def setUp(self) -> None:
        """Create the FakeServer and install it in place of the real servers."""
        self.server = FakeServer()
        for patcher in [
            mock.patch.object(request_util, "http", self.server.http),
            mock.patch.object(request_util, "run", self.server.run),
            mock.patch.object(ci_build, "circleci_token", return_value="token"),
            mock.patch.object(
                ci_build, "azure_headers", return_value={"Authorization": "Basic token"}
            ),
            mock.patch.object(rerun_failed_ci.shutil, "which", return_value="/usr/bin/gh"),
        ]:
            patcher.start()
            self.addCleanup(patcher.stop)

    def rerun(self, *args: str, status: int = 0) -> str:
        """Run rerun-failed-ci with the given arguments.

        Args:
            args: the command-line arguments.
            status: the expected exit status.

        Returns:
            The output (standard output and standard error).
        """
        self.server.reruns.clear()
        output = io.StringIO()
        with (
            mock.patch.object(sys, "argv", ["rerun-failed-ci", *args]),
            contextlib.redirect_stdout(output),
            contextlib.redirect_stderr(output),
        ):
            actual_status = rerun_failed_ci.main()
        self.assertEqual(actual_status, status, output.getvalue())
        return output.getvalue()

    def assert_reruns(self, expected: list[str], *args: str, status: int = 0) -> str:
        """Check that rerun-failed-ci with the given arguments makes the expected reruns.

        Returns:
            The output.
        """
        output = self.rerun(*args, status=status)
        self.assertEqual(self.server.reruns, expected, output)
        return output


###########################################################################
### --classify
###


class ClassifyTest(unittest.TestCase):
    """Tests for --classify, which run the script."""

    def classify(self, log: str) -> tuple[int, str]:
        """Run rerun-failed-ci --classify on a log containing the given text.

        Returns:
            The exit status, and the output after the file name.
        """
        with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as f:
            f.write(log + "\n")
        self.addCleanup(Path(f.name).unlink)
        result = subprocess.run(
            [RERUN, "--classify", f.name], capture_output=True, text=True, check=False
        )
        return result.returncode, result.stdout.removeprefix(f"{f.name}: ").rstrip("\n")

    def test_transient(self) -> None:
        """A log that shows a transient failure yields the line that shows it."""
        for log, reason in [
            (f"BUILD FAILED\n{GRADLE_429}", GRADLE_429.lstrip()),
            (
                (
                    "2026-10-31T13:39:57.3265176Z fatal: unable to access"
                    " 'https://github.com/a/b/': Could not resolve host: github.com"
                ),
                (
                    "fatal: unable to access 'https://github.com/a/b/': Could not resolve host:"
                    " github.com"
                ),
            ),
            (
                "\033[31mCaused by: java.net.SocketTimeoutException: Read timed out\033[0m\r",
                "Caused by: java.net.SocketTimeoutException: Read timed out",
            ),
            ("We stopped hearing from agent Azure Pipelines 3.", None),
            ("The runner has received a shutdown signal.", None),
            # The transient line follows a script that GitHub Actions echoed.
            ("##[group]Run ./gradlew build\n  shell: bash\n##[endgroup]\nConnection reset", None),
        ]:
            with self.subTest(log=log):
                self.assertEqual(self.classify(log), (0, reason or log.splitlines()[-1]))

    def test_not_transient(self) -> None:
        """A log that does not show a transient failure yields nothing."""
        for log in [
            "Execution failed for task ':spotlessJavaCheck'.\nBUILD FAILED in 28s",
            (
                "Could not GET 'https://repo.maven.apache.org/x.pom'. Received status code 404"
                " from server: Not Found"
            ),
            # A shell trace line, as from a script that looks for network errors itself.
            (
                "+ grep -q -E 'Connection (reset|refused)|Read timed out' /tmp/log\n"
                "2026-10-31T13:41:49.6228534Z ++ echo 'Connection reset'"
            ),
            # A script that Azure Pipelines echoes before running it.
            (
                "Generating script.\nScript contents:\ngrep -q 'Connection reset' build.log\n"
                "========================== Starting Command Output ===========================\n"
                "error: cannot find symbol"
            ),
            # A script that GitHub Actions echoes before running it.
            (
                "##[group]Run ./gradlew build || grep -q 'Connection reset' build.log\n"
                "  shell: /usr/bin/bash -e {0}\n##[endgroup]\nerror: cannot find symbol"
            ),
        ]:
            with self.subTest(log=log):
                self.assertEqual(self.classify(log), (1, ""))

    def test_standard_input(self) -> None:
        """--classify reads standard input when no file is given."""
        result = subprocess.run(
            [RERUN, "--classify"],
            input="Connection reset\n",
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "(standard input): Connection reset\n")

    def test_errors(self) -> None:
        """Bad files and bad options are rejected."""
        for args in [
            ["--classify", "/no/such/file"],
            ["--max-attempts", "0"],
            ["--no-such-option"],
        ]:
            with self.subTest(args=args):
                result = subprocess.run([RERUN, *args], capture_output=True, check=False)
                self.assertNotEqual(result.returncode, 0)


###########################################################################
### Azure Pipelines
###


class AzureTest(RerunTestCase):
    """Tests for Azure Pipelines builds."""

    BUILD = "https://dev.azure.com/org/proj/_build/results?buildId=500"
    RETRY = f"PATCH {AZURE}/500?retry=true&api-version=7.1 {{}}"

    def stage_retry(self, stage: str, host: str = AZURE) -> str:
        """Describe the request that retries the given stage of build 500.

        Args:
            stage: a stage's identifier, such as "s1".
            host: the URL of the builds of the build's project in the Azure DevOps API.

        Returns:
            The description.
        """
        body = '{"state": "retry", "forceRetryAllJobs": false}'
        return f"PATCH {host}/500/stages/{stage}?api-version=7.1 {body}"

    def setUp(self) -> None:
        """Serve build 500, whose failed jobs all failed transiently."""
        super().setUp()
        self.server.azure_build(500, "completed", "failed")
        self.server.azure_timeline(
            500,
            ("s1", 1, "a", "failed", GRADLE_429),
            ("s1", 1, "b", "succeeded", ""),
            ("s2", 1, "c", "failed", "We stopped hearing from agent Azure Pipelines 3."),
        )

    def test_all_transient(self) -> None:
        """If every failed job failed transiently, the build's failed jobs are rerun."""
        output = self.assert_reruns([self.RETRY], f"{self.BUILD}&view=logs&jobId=a")
        self.assertIn("Reran the failed jobs.", output)
        output = self.assert_reruns([], "--dry-run", self.BUILD)
        self.assertIn("Would rerun the failed jobs", output)

    def test_some_transient(self) -> None:
        """A stage whose failed jobs all failed transiently is rerun."""
        self.server.azure_timeline(
            500,
            ("s1", 1, "a", "failed", "Connection reset"),
            ("s1", 1, "b", "failed", "Test failed"),
            ("s2", 3, "c", "failed", "Read timed out"),
            ("s3", 1, "d", "failed", "Could not resolve host: github.com"),
            ("s4", 1, "e", "failed", "Could not resolve host: github.com"),
            ("s5", 1, "f", "failed", "Test failed"),
        )
        output = self.assert_reruns([self.stage_retry("s3")], self.BUILD)
        for message in [
            "Not rerunning stage s1:  it has a failed job that did not fail transiently",
            "Not rerunning stage s2:  it has already been run 3 times.",
            "rerun the other stages",
        ]:
            self.assertIn(message, output)

    def test_unreadable_log(self) -> None:
        """A stage that has a job whose log cannot be read is not rerun."""
        self.server.azure_timeline(
            500,
            ("s1", 1, "a", "failed", "Connection reset"),
            ("s1", 1, "b", "failed", None),
            ("s2", 1, "c", "failed", "Read timed out"),
        )
        output = self.assert_reruns([self.stage_retry("s2")], self.BUILD, status=1)
        self.assertIn("Not rerunning stage s1:  it has a failed job whose log could not", output)

    def test_warning_issue(self) -> None:
        """A warning that a task reports does not make a job transient."""
        self.server.azure_timeline(
            500,
            ("s1", 1, "a", "failed", "Test failed"),
            issue={"type": "warning", "message": "Retrying after 503 Service Unavailable"},
        )
        output = self.assert_reruns([], self.BUILD)
        self.assertIn("a: not transient", output)

    def test_visualstudio_url(self) -> None:
        """A URL whose host is ORGANIZATION.visualstudio.com is supported."""
        self.server.urls = {
            url.replace("dev.azure.com/org/", "dev.azure.com/myorg/"): response
            for url, response in self.server.urls.items()
        }
        self.assert_reruns(
            [self.RETRY.replace("dev.azure.com/org/", "dev.azure.com/myorg/")],
            "https://myorg.visualstudio.com/proj/_build/results?buildId=500",
        )

    def test_not_rerun(self) -> None:
        """A build that is in progress or that has reached the limit is not rerun."""
        self.server.azure_build(500, "inProgress", None)
        self.assert_reruns([], self.BUILD)
        self.server.azure_build(500, "completed", "failed")
        self.server.azure_timeline(500, ("s1", 3, "a", "failed", "Connection reset"))
        self.assert_reruns([], self.BUILD)

    def test_no_credentials(self) -> None:
        """Rerunning requires credentials."""
        with mock.patch.object(ci_build, "azure_headers", dict):
            output = self.assert_reruns([], self.BUILD, status=1)
        self.assertIn("AZURE_DEVOPS_EXT_PAT is not set", output)


###########################################################################
### CircleCI
###


class CircleciTest(RerunTestCase):
    """Tests for CircleCI workflows."""

    def setUp(self) -> None:
        """Serve workflow 1, whose failed jobs all failed transiently, and workflow 2."""
        super().setUp()
        s = self.server
        s.circleci_workflow(1, "failed")
        s.circleci_jobs(1, [(11, "failed"), (12, "success"), (13, "infrastructure_fail")])
        s.circleci_job(11, GRADLE_429)
        s.circleci_workflow(2, "failed")
        s.circleci_jobs(2, [(21, "failed"), (22, "failed"), (23, "failed")])
        s.circleci_job(21, "Connection reset")
        s.circleci_job(22, "Test failed")
        s.circleci_job(23, "Could not resolve host: github.com")

    def test_all_transient(self) -> None:
        """If every failed job failed transiently, the failed jobs are rerun."""
        rerun = f'POST {CIRCLECI}/v2/workflow/{uuid(1)}/rerun {{"from_failed": true}}'
        url = f"https://app.circleci.com/workflow/{uuid(1)}?utm_source=github-checks-link"
        output = self.assert_reruns([rerun], url)
        self.assertIn(
            "Reran the failed jobs: https://app.circleci.com/pipelines/gh/org/repo/7/workflows/new-workflow",
            output,
        )
        output = self.assert_reruns([], "--dry-run", url)
        self.assertIn("Would rerun the failed jobs", output)

    def test_some_transient(self) -> None:
        """If only some failed jobs failed transiently, only they are rerun."""
        self.assert_reruns(
            [f'POST {CIRCLECI}/v2/workflow/{uuid(2)}/rerun {{"jobs": ["id21", "id23"]}}'],
            f"https://app.circleci.com/pipelines/gh/org/repo/7/workflows/{uuid(2)}",
        )

    def test_job_url(self) -> None:
        """A URL that names one job reruns only that job, if it failed transiently."""
        details = f"https://app.circleci.com/pipelines/gh/org/repo/7/details?workflowId={uuid(2)}"
        self.assert_reruns(
            [f'POST {CIRCLECI}/v2/workflow/{uuid(2)}/rerun {{"jobs": ["id23"]}}'],
            f"{details}&job=id23&buildNumber=23&jobType=build#step-107-",
        )
        self.assert_reruns([], f"{details}&buildNumber=22")
        output = self.assert_reruns([], f"{details}&buildNumber=12")
        self.assertIn("Job 12 is not a failed job of the workflow.", output)

    def test_commit_status_url(self) -> None:
        """A job URL from a GitHub commit status names the job's workflow."""
        s = self.server
        s.urls[f"{CIRCLECI}/v2/project/gh/org/repo/job/21"] = {"latest_workflow": {"id": uuid(2)}}
        self.assert_reruns(
            [f'POST {CIRCLECI}/v2/workflow/{uuid(2)}/rerun {{"jobs": ["id21"]}}'],
            "https://circleci.com/gh/org/repo/21?utm_campaign=vcs-integration-link",
        )

    def test_paginated_jobs(self) -> None:
        """The jobs on every page are examined."""
        self.server.circleci_jobs(1, [(11, "failed")], [(22, "failed")])
        self.assert_reruns(
            [f'POST {CIRCLECI}/v2/workflow/{uuid(1)}/rerun {{"jobs": ["id11"]}}'],
            f"https://app.circleci.com/workflow/{uuid(1)}",
        )

    def test_not_rerun(self) -> None:
        """A workflow that is running, has been rerun, or has reached the limit is not rerun."""
        s = self.server
        url = f"https://app.circleci.com/workflow/{uuid(3)}"
        s.circleci_workflow(3, "failing")
        s.circleci_jobs(3, [(31, "failed")])
        s.circleci_job(31, "Connection reset")
        self.assert_reruns([], url)
        s.circleci_workflow(3, "failed", [(4, "2026-01-02"), (3, "2026-01-01")])
        self.assertIn("It has been rerun", self.assert_reruns([], url))
        s.circleci_workflow(3, "failed", [(3, "2026-01-03"), (5, "2026-01-01")])
        self.assert_reruns([], "--max-attempts", "2", url)
        self.assert_reruns(
            [f'POST {CIRCLECI}/v2/workflow/{uuid(3)}/rerun {{"from_failed": true}}'], url
        )


###########################################################################
### GitHub Actions
###


class GithubActionsTest(RerunTestCase):
    """Tests for GitHub Actions workflow runs."""

    RUN = "https://github.com/org/repo/actions/runs/100"

    def setUp(self) -> None:
        """Serve run 100, whose failed jobs all failed transiently."""
        super().setUp()
        s = self.server
        s.gha_run("completed", "failure", [(101, "a", "failure"), (102, "b", "success")])
        s.gha_run(
            "completed",
            "failure",
            [(101, "a", "failure"), (102, "b", "success"), (103, "c", "failure")],
        )
        s.gha_job(101, GRADLE_429)
        s.gha_job(103, "Connection reset")

    def test_all_transient(self) -> None:
        """If every failed job failed transiently, the failed jobs are rerun."""
        self.assert_reruns(["gh run rerun --repo org/repo --failed 100"], self.RUN)

    def test_some_transient(self) -> None:
        """If only some failed jobs failed transiently, one of them is rerun."""
        s = self.server
        s.gha_run(
            "completed",
            "failure",
            [(101, "a", "failure"), (103, "c", "failure"), (104, "d", "failure")],
        )
        s.gha_job(103, "Test failed")
        s.gha_job(104, "Read timed out")
        output = self.assert_reruns(["gh run rerun --repo org/repo --job 101"], self.RUN)
        self.assertIn("rerun the other", output)
        # A URL that names one job reruns only that job, if it failed transiently.
        self.assert_reruns(["gh run rerun --repo org/repo --job 104"], f"{self.RUN}/job/104")
        self.assert_reruns([], f"{self.RUN}/job/103")
        # A job that the latest attempt does not include has been rerun.
        self.assert_reruns([], f"{self.RUN}/job/999")

    def test_lost_runner(self) -> None:
        """A job whose log cannot be read failed transiently if an annotation says so."""
        self.server.gh_logs.pop(103)
        self.server.gha_job(103, None, "The runner has received a shutdown signal.")
        self.assert_reruns(["gh run rerun --repo org/repo --failed 100"], self.RUN)
        # Without such an annotation, the log is reported as unreadable, as is an empty log.
        for log in [None, ""]:
            with self.subTest(log=log):
                self.server.gha_job(103, log)
                output = self.assert_reruns(
                    ["gh run rerun --repo org/repo --job 101"], self.RUN, status=1
                )
                self.assertIn(
                    "cannot read the log of the failed steps of GitHub Actions job c", output
                )

    def test_cancelled(self) -> None:
        """A cancelled job is rerun if it failed transiently, and is ignored otherwise."""
        s = self.server
        s.gha_run("completed", "cancelled", [(101, "a", "failure"), (103, "c", "cancelled")])
        s.gh_logs.pop(103)
        s.gha_job(103, None, "The runner has received a shutdown signal.")
        self.assert_reruns(["gh run rerun --repo org/repo --failed 100"], self.RUN)
        self.assert_reruns(["gh run rerun --repo org/repo --job 103"], f"{self.RUN}/job/103")
        # A job that a user or the failure of another job cancelled.
        s.gha_job(103, None, "The operation was canceled.")
        output = self.assert_reruns(["gh run rerun --repo org/repo --failed 100"], self.RUN)
        self.assertIn("c: cancelled, not transient", output)
        s.gha_run("completed", "cancelled", [(103, "c", "cancelled")])
        self.assert_reruns([], self.RUN)

    def test_normalize_log_failure(self) -> None:
        """If normalize-log cannot be run, the command reports it and exits."""
        with (
            mock.patch.object(rerun_failed_ci, "NORMALIZE_LOG", TOPLEVEL / "no-such-command"),
            self.assertRaises(SystemExit) as cm,
        ):
            self.rerun(self.RUN)
        self.assertIn("cannot run", str(cm.exception.code))

    def test_warning_annotation(self) -> None:
        """A warning annotation does not make a job transient."""
        self.server.gha_job(
            103, "Test failed", "Failed to save: 503 Service Unavailable", "warning"
        )
        self.assert_reruns(["gh run rerun --repo org/repo --job 101"], self.RUN)

    def test_unreadable_annotations(self) -> None:
        """A job whose log can be read is classified even if its annotations cannot be read."""
        self.server.gha_job(103, "Test failed")
        del self.server.gh["repos/org/repo/check-runs/103/annotations?per_page=100"]
        output = self.assert_reruns(["gh run rerun --repo org/repo --job 101"], self.RUN)
        self.assertIn("c: not transient", output)

    def test_echoed_script(self) -> None:
        """A message in the script that GitHub Actions echoes does not make a job transient."""
        self.server.gha_job(
            103,
            "##[group]Run ./gradlew build || grep -q 'Connection reset' build.log\n"
            "##[endgroup]\nerror: cannot find symbol",
        )
        self.assert_reruns(["gh run rerun --repo org/repo --job 101"], self.RUN)

    def test_not_rerun(self) -> None:
        """A run that is in progress is not rerun."""
        self.server.gha_run("in_progress", None, [(101, "a", "")])
        self.assert_reruns([], self.RUN)
        output = self.assert_reruns([], f"{self.RUN}/job/101")
        self.assertIn("Its status is in_progress.", output)

    def test_attempts_of_each_job(self) -> None:
        """The attempt limit counts each job's runs, not the run's attempts."""
        self.server.gh["repos/org/repo/actions/runs/100/jobs?filter=all&per_page=100"] = [
            {"jobs": [{"id": i, "name": "a", "conclusion": "failure"} for i in (1, 2, 101)]},
            {"jobs": [{"id": 103, "name": "c", "conclusion": "failure"}]},
        ]
        output = self.assert_reruns(["gh run rerun --repo org/repo --job 103"], self.RUN)
        self.assertIn("Not rerunning a:  it has already been run 3 times.", output)


###########################################################################
### Pull requests
###


class PullRequestTest(RerunTestCase):
    """Tests for the failed checks of a pull request."""

    def test_checks(self) -> None:
        """Each build, workflow, or run is examined once, and its failed jobs rerun together."""
        s = self.server
        s.azure_build(500, "completed", "failed")
        s.azure_timeline(500, ("s1", 1, "p", "failed", "Connection reset"))
        azure = "https://dev.azure.com/org/proj/_build/results?buildId=500&view=logs&jobId="
        s.circleci_workflow(2, "failed")
        s.circleci_jobs(2, [(21, "failed"), (22, "failed"), (23, "failed")])
        s.circleci_job(21, "Connection reset")
        s.circleci_job(22, "Test failed")
        s.circleci_job(23, "Could not resolve host: github.com")
        for job in (21, 22, 23):
            s.urls[f"{CIRCLECI}/v2/project/gh/org/repo/job/{job}"] = {
                "latest_workflow": {"id": uuid(2)}
            }
        s.gha_run("completed", "failure", [(101, "a", "failure"), (104, "d", "failure")])
        s.gha_job(101, GRADLE_429)
        s.gha_job(104, "Read timed out")
        s.pr_checks["5"] = [
            {"name": "p1", "bucket": "fail", "link": f"{azure}p"},
            {"name": "p2", "bucket": "fail", "link": f"{azure}q"},
            # CircleCI commit statuses, which name jobs of one workflow.
            {"name": "c21", "bucket": "fail", "link": "https://circleci.com/gh/org/repo/21"},
            {"name": "c22", "bucket": "fail", "link": "https://circleci.com/gh/org/repo/22"},
            {"name": "c23", "bucket": "fail", "link": "https://circleci.com/gh/org/repo/23"},
            {"name": "a", "bucket": "fail", "link": "https://github.com/org/repo/actions/runs/100/job/101"},
            {"name": "d", "bucket": "fail", "link": "https://github.com/org/repo/actions/runs/100/job/104"},
            {"name": "e", "bucket": "pass", "link": "https://github.com/org/repo/actions/runs/200/job/201"},
            {"name": "other", "bucket": "fail", "link": "https://example.com/build/1"},
            {"name": "approve", "bucket": "fail", "state": "ACTION_REQUIRED", "link": "https://github.com/org/repo/pull/5"},
        ]  # fmt: skip
        output = self.assert_reruns(
            [
                f"PATCH {AZURE}/500?retry=true&api-version=7.1 {{}}",
                f'POST {CIRCLECI}/v2/workflow/{uuid(2)}/rerun {{"jobs": ["id21", "id23"]}}',
                "gh run rerun --repo org/repo --failed 100",
            ],
            "5",
        )
        self.assertIn("other: skipping a check from an unsupported CI service", output)
        self.assertIn("approve: skipping a check that requires action, such as approval", output)

    def test_cancelled_check(self) -> None:
        """A cancelled check is examined, because its runner might have shut down."""
        s = self.server
        s.gha_run("completed", "cancelled", [(101, "a", "cancelled")])
        s.gha_job(101, None, "The runner has received a shutdown signal.")
        s.pr_checks["6"] = [
            {"name": "a", "bucket": "cancel", "link": "https://github.com/org/repo/actions/runs/100/job/101"},
        ]  # fmt: skip
        self.assert_reruns(["gh run rerun --repo org/repo --failed 100"], "6")


if __name__ == "__main__":
    unittest.main()
