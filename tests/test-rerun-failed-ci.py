"""Tests for the rerun-failed-ci script.

The tests contact no server:  a fake replaces the HTTP requests and the `gh` commands
that the script makes, serving canned responses and recording the reruns.
"""

from __future__ import annotations

import contextlib
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
import rerun_failed_ci  # ruff: ignore[module-import-not-at-top-of-file]

if TYPE_CHECKING:
    from collections.abc import Mapping


GRADLE_429 = (
    "   > Could not GET 'https://repo.maven.apache.org/x.pom'. Received status code 429"
    " from server: Too Many Requests"
)

# Maven's warning that Maven Central refused to serve metadata.
MAVEN_CENTRAL_METADATA_403 = (
    "[WARNING] Could not transfer metadata /.meta/prefixes.txt from/to central"
    " (https://repo.maven.apache.org/maven2): HTTP Status: 403"
)
# Maven's error that Maven Central refused to serve an artifact that it holds.
MAVEN_CENTRAL_ARTIFACT_403 = (
    "[ERROR] Plugin org.apache.felix:maven-bundle-plugin:5.1.8 or one of its dependencies"
    " could not be resolved: Could not transfer artifact"
    " org.apache.felix:maven-bundle-plugin:pom:5.1.8 from/to central"
    " (https://repo.maven.apache.org/maven2): HTTP Status: 403"
)

# A location in Maven Central of an artifact that Gradle did not find.
OPTIONS_POM = "https://repo.maven.apache.org/maven2/org/plumelib/options/3.0.0/options-3.0.0.pom"
# Gradle's report that it did not find the artifact at OPTIONS_POM.
OPTIONS_NOT_FOUND = (
    "   > Could not find org.plumelib:options:3.0.0.\n"
    "     Searched in the following locations:\n"
    f"       - {OPTIONS_POM}\n"
    "     Required by:\n"
    "         project :"
)
# Gradle's report that it did not find a misspelled artifact.
GUAVA_NOT_FOUND = (
    "   > Could not find com.google.guava:guava:33.9-jr.\n"
    "     Searched in the following locations:\n"
    "       - https://repo.maven.apache.org/maven2/com/google/guava/guava/33.9-jr/"
    "guava-33.9-jr.pom\n"
    "     Required by:\n"
    "         project :"
)
# The report of `gradlew-retry` that OPTIONS_POM is on a mirror of Maven Central.
OPTIONS_EXISTS = f"gradlew-retry: {OPTIONS_POM} exists on a mirror of Maven Central."
# The line that `gradlew-retry` prints before it runs Gradle again.
GRADLEW_RETRYING = "gradlew-retry: Gradle could not resolve a dependency; retrying in 60 seconds."
# The Checker Framework's warning that type-checking a method took too long.
SLOW_TYPECHECKING = (
    "/home/runner/work/a/b/BaseTypeVisitor.java:201: warning:"
    " [compilermessages:slow.typechecking] typechecking took 48 seconds;"
    " consider making inferred type variables explicit"
)

# The annotation of a GitHub Actions job whose run its concurrency group cancelled.
CONCURRENCY_CANCEL = "Canceling since a higher priority waiting request for CI-5 exists"
# The request for the runs of GitHub Actions run 100's branch that are no older than it.
NEWER_RUNS = (
    "repos/org/repo/actions/runs?branch=feature&created=%3E%3D2026-11-24T22%3A40%3A03Z&per_page=100"
)

# The annotation of a GitHub Actions job that ran longer than its time limit.
GHA_TIMEOUT = (
    "The job running on runner GitHub Actions 2 has exceeded the maximum execution time of"
    " 360 minutes."
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
        pr_checks: a map from a pull request to its checks.  The key "" is the pull
            request that `gh` finds for the current branch; if it is absent, `gh` finds
            none.
        branch: the current branch.
        push: the remote-tracking branch that the current branch is pushed to, such as
            "refs/remotes/origin/fix-timeout", or "" if it is unknown.
        repo: the GitHub repository of the current clone, as a dict parsed from the JSON
            of `gh repo view`, with keys "owner" and "parent".
        reruns: the rerun requests, as strings.
        gh_requests: the paths of the `gh api` requests, in order.
        azure_reruns_cancelled: True if a request to rerun an Azure Pipelines build's
            failed jobs, or to retry one of its stages, reruns its cancelled jobs too.
            Such a request reruns each failed job of the build, by increasing its
            attempt number in the build's timeline.
    """

    def __init__(self) -> None:
        """Create a FakeServer that serves nothing."""
        self.urls: dict[str, Any] = {}
        self.gh: dict[str, Any] = {}
        self.gh_logs: dict[int, str] = {}
        self.pr_checks: dict[str, list[dict[str, str]]] = {}
        self.branch = "feature"
        self.push = ""
        self.repo: dict[str, Any] = {"owner": {"login": "org"}, "parent": None}
        self.reruns: list[str] = []
        self.gh_requests: list[str] = []
        self.azure_reruns_cancelled = True

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
            if url.startswith(f"{AZURE}/"):
                build = url.removeprefix(f"{AZURE}/").partition("?")[0].partition("/")[0]
                rerun_results = {"failed", "abandoned"}
                if self.azure_reruns_cancelled:
                    rerun_results.add("canceled")
                for record in self.urls[f"{AZURE}/{build}/timeline"]["records"]:
                    if record["type"] == "Job" and record["result"] in rerun_results:
                        record["attempt"] += 1
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
            self.gh_requests.append(path)
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
            pr = "" if cmd[3].startswith("--") else cmd[3]
            if pr not in self.pr_checks:
                stderr = f'no pull requests found for branch "{pr or self.branch}"'
                raise subprocess.CalledProcessError(1, cmd, "", stderr)
            return json.dumps(self.pr_checks[pr])
        if cmd == ["git", "branch", "--show-current"]:
            return self.branch + "\n"
        if cmd[:2] == ["git", "for-each-ref"] and cmd[-1] == f"refs/heads/{self.branch}":
            return f"{'origin' if self.push else ''}\t{self.push}\n"
        if cmd[:3] == ["gh", "repo", "view"]:
            return json.dumps(self.repo)
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
            "id": 100,
            "name": "CI",
            "status": status,
            "conclusion": conclusion,
            "run_attempt": 1,
            "run_number": 50,
            "workflow_id": 7,
            "event": "pull_request",
            "head_branch": "feature",
            "head_repository": {"full_name": "me/repo"},
            "head_sha": "abc",
            "created_at": "2026-11-24T22:40:03Z",
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
            mock.patch.object(rerun_failed_ci, "AZURE_RERUN_CHECK_INTERVAL", 0),
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
            # A JVM crash, in a test's output that Gradle indents.
            (
                (
                    "    # A fatal error has been detected by the Java Runtime Environment:\n"
                    "    #\n"
                    "    #  SIGSEGV (0xb) at pc=0x000074a6b3df9d00, pid=10859,"
                    " tid=0x000074a68e3fe6c0\n"
                    "    #\n"
                    "    # JRE version: OpenJDK Runtime Environment (8.0_482-b08)"
                ),
                "#  SIGSEGV (0xb) at pc=0x000074a6b3df9d00, pid=10859, tid=0x000074a68e3fe6c0",
            ),
            # A JVM crash, in an older JVM's wording, with another task's output inside the
            # report.
            (
                (
                    "# An unexpected error has been detected by Java Runtime Environment:\n"
                    "#\n"
                    "> Task :other:compileJava\n"
                    "#  SIGSEGV (0xb) at pc=0x000074a6b3df9d00, pid=10859, tid=1234\n"
                    "#\n"
                    "# Java VM: Java HotSpot(TM) Server VM (1.6.0-b105 mixed mode)"
                ),
                "#  SIGSEGV (0xb) at pc=0x000074a6b3df9d00, pid=10859, tid=1234",
            ),
            # The diagnostics of a failed test, in the TAP output of Bats.
            (
                (
                    "ok 1 compiles\n"
                    "not ok 2 downloads the file\n"
                    "# (in test file test/download.bats, line 3)\n"
                    "#   `curl -fsSL https://example.com/x' failed\n"
                    "# curl: (56) Recv failure: Connection reset by peer"
                ),
                "# curl: (56) Recv failure: Connection reset by peer",
            ),
            # Maven Central refused to serve an artifact that it holds.  The result is
            # truncated to 200 characters.
            (
                f"{MAVEN_CENTRAL_METADATA_403}\n{MAVEN_CENTRAL_ARTIFACT_403}",
                MAVEN_CENTRAL_ARTIFACT_403[:200],
            ),
            # Maven Central refused to serve an artifact, in another wording of Maven.
            (
                (
                    "Could not transfer artifact com.example:x:pom:1.0 from/to central"
                    " (https://repo.maven.apache.org/maven2): status code: 403, reason"
                    " phrase: Forbidden (403)"
                ),
                None,
            ),
            # GitHub refused a request, as it does for a client that exceeds its rate limit.
            (
                (
                    "> Could not GET 'https://raw.githubusercontent.com/a/b/main/x.gradle'."
                    " Received status code 403 from server: Forbidden"
                ),
                None,
            ),
            (
                (
                    "java.io.IOException: Server returned HTTP response code: 403 for URL:"
                    " https://api.github.com/repos/a/b/releases"
                ),
                None,
            ),
            (
                (
                    "##[error]The job was abandoned because agent did not renew the lock."
                    "  Ensure agent is running, not sleeping, and has not lost communication"
                    " with the service."
                ),
                None,
            ),
            (
                "The job was not acquired by Runner of type hosted even after multiple attempts",
                None,
            ),
            (
                (
                    "   > Could not find org.slf4j:slf4j-api:1.7.36.\n"
                    "     Searched in the following locations:\n"
                    "       - https://plugins.gradle.org/m2/org/slf4j/slf4j-api/1.7.36/"
                    "slf4j-api-1.7.36.pom"
                ),
                "> Could not find org.slf4j:slf4j-api:1.7.36.",
            ),
            # Maven Central did not serve, in either run of Gradle, an artifact that
            # `gradlew-retry` found on a mirror.
            (
                (
                    f"{OPTIONS_NOT_FOUND}\n{OPTIONS_EXISTS}\n{GRADLEW_RETRYING}\n"
                    f"{OPTIONS_NOT_FOUND}\nBUILD FAILED in 3s"
                ),
                OPTIONS_EXISTS,
            ),
            # The log ends before `gradlew-retry` runs Gradle again.
            (f"{OPTIONS_NOT_FOUND}\n{OPTIONS_EXISTS}", OPTIONS_EXISTS),
            # `gradlew-retry` found the artifact at the location where Gradle searched.
            (
                (
                    f"{OPTIONS_NOT_FOUND}\ngradlew-retry: {OPTIONS_POM} exists.\n"
                    f"{GRADLEW_RETRYING}\n{OPTIONS_NOT_FOUND}"
                ),
                f"gradlew-retry: {OPTIONS_POM} exists.",
            ),
            # The last run of Gradle failed for a network problem.
            (
                f"error: cannot find symbol\n{GRADLEW_RETRYING}\n{GRADLE_429}",
                GRADLE_429.lstrip(),
            ),
            # The Checker Framework took long to type-check a method, on a busy CI machine.
            (
                f"{SLOW_TYPECHECKING}\nerror: warnings found and -Werror specified",
                SLOW_TYPECHECKING,
            ),
            # Likewise, under `-Anomsgtext`, which omits the message text.
            (
                (
                    "Issue301.java:9: warning: [slow.typechecking]\n1 error\n1 warning\n"
                    "error: warnings found and -Werror specified\nBUILD FAILED in 3m"
                ),
                "Issue301.java:9: warning: [slow.typechecking]",
            ),
            # Likewise, as Maven reports it, with a prefix that lists several checkers.
            (
                (
                    "[WARNING] /a/b/Foo.java:[201,13] [[nullness, allcheckers]:slow.typechecking]"
                    " typechecking took 48 seconds; consider making inferred type variables"
                    " explicit\n[ERROR] warnings found and -Werror specified\n"
                    "[ERROR] COMPILATION ERROR"
                ),
                (
                    "[WARNING] /a/b/Foo.java:[201,13] [[nullness, allcheckers]:slow.typechecking]"
                    " typechecking took 48 seconds; consider making inferred type variables"
                    " explicit"
                ),
            ),
            # The transient line follows a script that GitHub Actions echoed.
            ("##[group]Run ./gradlew build\n  shell: bash\n##[endgroup]\nConnection reset", None),
        ]:
            with self.subTest(log=log):
                self.assertEqual(self.classify(log), (0, reason or log.splitlines()[-1]))

    def test_not_transient(self) -> None:
        """A log that does not show a transient failure yields nothing."""
        for log in [
            "Execution failed for task ':spotlessJavaCheck'.\nBUILD FAILED in 28s",
            # Maven Central refused to serve metadata, which Maven reports only as a warning.
            f"{MAVEN_CENTRAL_METADATA_403}\n[ERROR] COMPILATION ERROR",
            # A repository other than Maven Central refused to serve an artifact.
            (
                "Could not transfer artifact com.example:x:pom:1.0 from/to private"
                " (https://maven.example.com/releases): HTTP Status: 403"
            ),
            (
                "Could not transfer artifact com.example:x:pom:1.0 from/to private"
                " (https://maven.example.com/releases): status code: 403, reason phrase:"
                " Forbidden (403)"
            ),
            (
                "   > Could not GET 'https://maven.example.com/x.pom'. Received status code"
                " 403 from server: Forbidden"
            ),
            # GitHub Packages refused a request; the usual cause is missing credentials.
            (
                "   > Could not GET 'https://maven.pkg.github.com/a/b/x.pom'. Received status"
                " code 403 from server: Forbidden"
            ),
            (
                "Could not GET 'https://repo.maven.apache.org/x.pom'. Received status code 404"
                " from server: Not Found"
            ),
            # Gradle searched a repository other than the Gradle Plugin Portal, too.
            (
                "   > Could not find com.google.guava:guava:33.9-jre.\n"
                "     Searched in the following locations:\n"
                "       - https://repo.maven.apache.org/maven2/com/google/guava/guava/33.9-jre/"
                "guava-33.9-jre.pom\n"
                "       - https://plugins.gradle.org/m2/com/google/guava/guava/33.9-jre/"
                "guava-33.9-jre.pom\n"
                "     Required by:"
            ),
            # An artifact that `gradlew-retry` found nowhere, as for a misspelled version.
            (
                f"{GUAVA_NOT_FOUND}\n"
                "gradlew-retry: Not retrying, because no missing artifact exists at a URL that"
                " Gradle\n  reported, on the Gradle Plugin Portal, or on a mirror of Maven Central."
            ),
            # A report of `gradlew-retry` without a failure of Gradle to find an artifact.
            OPTIONS_EXISTS,
            # The last run of Gradle found the artifact that `gradlew-retry` reported, but
            # the build failed for another reason.
            (
                f"{OPTIONS_NOT_FOUND}\n{OPTIONS_EXISTS}\n{GRADLEW_RETRYING}\n"
                "error: cannot find symbol\nBUILD FAILED in 3s"
            ),
            # Likewise, after a network problem in an earlier run of Gradle.
            f"{GRADLE_429}\n{GRADLEW_RETRYING}\nerror: cannot find symbol",
            # The Checker Framework took long to type-check a method, but javac also
            # reported an error.
            (
                f"{SLOW_TYPECHECKING}\nBar.java:5: error: cannot find symbol\n1 error\n"
                "1 warning\nerror: warnings found and -Werror specified"
            ),
            # Likewise, with another warning, which also fails a build under -Werror.
            (
                f"{SLOW_TYPECHECKING}\nwarning: [options] source value 8 is obsolete\n"
                "error: warnings found and -Werror specified"
            ),
            # The Checker Framework took long to type-check a method, without -Werror, and
            # a test failed.
            f"{SLOW_TYPECHECKING}\nFooTest > testBar() FAILED\nBUILD FAILED in 3m",
            # The last run of Gradle also did not find a misspelled artifact, which
            # `gradlew-retry` did not report.
            (
                f"{OPTIONS_NOT_FOUND}\n{GUAVA_NOT_FOUND}\n{OPTIONS_EXISTS}\n{GRADLEW_RETRYING}\n"
                f"{OPTIONS_NOT_FOUND}\n{GUAVA_NOT_FOUND}"
            ),
            # `gradlew-retry` reported a URL that Gradle did not search, for a plugin that
            # Gradle did not find in the repositories that the build names.
            (
                "   > Plugin [id: 'org.example.x', version: '1.0'] was not found in any of the"
                " following sources:\n"
                "gradlew-retry: https://plugins.gradle.org/m2/org/example/x/org.example.x.gradle"
                ".plugin/1.0/org.example.x.gradle.plugin-1.0.pom exists.\n"
                f"{GRADLEW_RETRYING}\n"
                "   > Plugin [id: 'org.example.x', version: '1.0'] was not found in any of the"
                " following sources:"
            ),
            # A job that no runner matches, as for a misspelled `runs-on` label.
            "The job has exceeded the maximum execution time while awaiting a runner for 24h0m0s",
            # A shell trace line, as from a script that looks for network errors itself.
            (
                "+ grep -q -E 'Connection (reset|refused)|Read timed out' /tmp/log\n"
                "2026-10-31T13:41:49.6228534Z ++ echo 'Connection reset'"
            ),
            # A shell comment, as `set -o verbose` prints it when a shell reads a script.
            (
                "# If environment variable GITHUB_PAT or GH_TOKEN is set when this script is\n"
                '# calls.  This can avoid "403 rate limit exceeded" failures.\n'
                '  # Retry if the log contains "Connection reset".\n'
                "#\n"
                "warning: [nullness:argument] incompatible argument\n"
                "##[error]Bash exited with code '1'."
            ),
            # A shell comment that mentions a JVM crash, outside a fatal error report.
            "#  SIGSEGV (0xb) at pc=0x000074a6b3df9d00\nerror: cannot find symbol",
            # A JVM crash that is not transient, followed by a shell comment.
            (
                "# A fatal error has been detected by the Java Runtime Environment:\n"
                "#\n"
                "#  SIGBUS (0x7) at pc=0x000074a6b3df9d00, pid=10859, tid=0x000074a68e3fe6c0\n"
                "#\n"
                "# JRE version: OpenJDK Runtime Environment (8.0_482-b08)\n"
                "#\n"
                '# Retry if the log contains "Connection reset".'
            ),
            # A shell comment that follows a TAP test, but not as the test's diagnostics.
            '1..1\nok 1 compiles\n# Retry if the log contains "Connection reset".',
            (
                "not ok 1 downloads the file\n"
                "# (in test file test/download.bats, line 3)\n"
                "make: *** [Makefile:12: test] Error 1\n"
                '# Retry if the log contains "Connection reset".'
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


class RerunLabelTest(unittest.TestCase):
    """Tests for rerun_label."""

    def test_rerun_label(self) -> None:
        """A transient failure whose log line is "cancelled" is not taken for a cancellation."""
        self.assertEqual(rerun_failed_ci.rerun_label(rerun_failed_ci.CANCELLED), "cancelled")
        self.assertEqual(rerun_failed_ci.rerun_label("cancelled"), "transient: cancelled")


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

    def test_abandoned_job(self) -> None:
        """An abandoned job is examined like a failed one."""
        self.server.azure_timeline(
            500,
            ("s1", 1, "a", "abandoned", ""),
            issue={
                "type": "error",
                "message": (
                    "The job was abandoned because agent did not renew the lock.  Ensure agent"
                    " is running, not sleeping, and has not lost communication with the service."
                ),
            },
        )
        output = self.assert_reruns([self.RETRY], self.BUILD)
        self.assertIn("a: transient: The job was abandoned", output)

    def test_cancelled(self) -> None:
        """A cancelled build's cancelled jobs are rerun, even if their logs cannot be read."""
        self.server.azure_build(500, "completed", "canceled")
        self.server.azure_timeline(
            500, ("s1", 1, "a", "succeeded", ""), ("s2", 1, "b", "canceled", None)
        )
        output = self.assert_reruns([self.RETRY], self.BUILD)
        self.assertIn("b: cancelled", output)
        self.assertNotIn("did not rerun", output)
        # Azure Pipelines does not document whether it reruns a cancelled job.
        self.server.azure_reruns_cancelled = False
        output = self.assert_reruns([self.RETRY], self.BUILD, status=1)
        self.assertIn(
            f"Azure Pipelines did not rerun the cancelled jobs of build {self.BUILD}: b;"
            " rerun them by hand",
            output,
        )
        self.assert_reruns([], "--dry-run", self.BUILD)
        # Only the cancelled jobs of a retried stage are checked.
        self.server.azure_timeline(
            500,
            ("s1", 1, "a", "failed", None),
            ("s2", 1, "b", "canceled", None),
            ("s3", 1, "c", "canceled", None),
        )
        output = self.assert_reruns([self.stage_retry("s2")], self.BUILD, status=1)
        self.assertIn(f"cancelled jobs of build {self.BUILD}: b;", output)
        self.server.azure_reruns_cancelled = True
        self.server.azure_timeline(
            500, ("s1", 1, "a", "failed", "Read timed out"), ("s1", 1, "b", "canceled", None)
        )
        self.assert_reruns([self.RETRY], self.BUILD)
        # A cancelled job is not rerun if some job did not fail transiently.
        self.server.azure_build(500, "completed", "failed")
        self.server.azure_timeline(
            500,
            ("s1", 1, "a", "failed", "Test failed"),
            ("s2", 1, "b", "canceled", None),
            ("s3", 1, "c", "failed", "Read timed out"),
            ("s4", 1, "d", "failed", "Read timed out"),
            ("s4", 1, "e", "canceled", None),
        )
        output = self.assert_reruns([self.stage_retry("s3")], self.BUILD)
        for message in [
            "Not rerunning the cancelled jobs:  some job did not fail transiently.",
            "Not rerunning stage s4:  it has a cancelled job",
        ]:
            self.assertIn(message, output)
        self.assertNotIn("stage s2", output)

    def test_timed_out(self) -> None:
        """A job that ran longer than its time limit is examined like a failed job."""
        s = self.server
        s.azure_timeline(
            500,
            ("s1", 1, "a", "succeeded", ""),
            ("s2", 1, "b", "canceled", None),
            ("s3", 1, "c", "canceled", None),
        )
        job_b = next(r for r in s.urls[f"{AZURE}/500/timeline"]["records"] if r["id"] == "b")
        job_b["issues"] = [
            {
                "type": "error",
                "message": "The job running on agent Azure Pipelines 3 ran longer than the"
                " maximum time of 60 minutes. For more information, see"
                " https://go.microsoft.com/fwlink/?linkid=2077134",
            }
        ]
        output = self.assert_reruns([], self.BUILD)
        self.assertIn("b: not transient", output)
        self.assertIn("c: cancelled", output)
        self.assertIn(
            "Not rerunning the cancelled jobs:  some job did not fail transiently.", output
        )

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

    def test_cancelled(self) -> None:
        """A cancelled workflow's cancelled jobs are rerun."""
        s = self.server
        url = f"https://app.circleci.com/workflow/{uuid(3)}"
        s.circleci_workflow(3, "canceled")
        s.circleci_jobs(3, [(31, "success"), (32, "canceled"), (33, "not_run")])
        output = self.assert_reruns(
            [f'POST {CIRCLECI}/v2/workflow/{uuid(3)}/rerun {{"from_failed": true}}'], url
        )
        self.assertIn("job32: cancelled", output)
        # A cancelled job is not rerun if another job did not fail transiently.
        s.circleci_jobs(3, [(31, "failed"), (32, "canceled"), (33, "failed")])
        s.circleci_job(31, "Test failed")
        s.circleci_job(33, "Connection reset")
        output = self.assert_reruns(
            [f'POST {CIRCLECI}/v2/workflow/{uuid(3)}/rerun {{"jobs": ["id33"]}}'], url
        )
        self.assertIn("Not rerunning the cancelled jobs:  job31 did not fail transiently.", output)
        s.circleci_jobs(3, [(31, "failed"), (32, "canceled")])
        self.assert_reruns([], url)

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

    def test_exit_3_if_reran(self) -> None:
        """With --exit-3-if-reran, the exit status is 3 if and only if a job was rerun."""
        self.assert_reruns(
            ["gh run rerun --repo org/repo --failed 100"], "--exit-3-if-reran", self.RUN, status=3
        )
        self.assert_reruns([], "--exit-3-if-reran", "--dry-run", self.RUN)

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
        """A cancelled job is rerun, whether or not it failed transiently."""
        s = self.server
        s.gha_run("completed", "cancelled", [(101, "a", "failure"), (103, "c", "cancelled")])
        s.gh_logs.pop(103)
        s.gha_job(103, None, "The runner has received a shutdown signal.")
        self.assert_reruns(["gh run rerun --repo org/repo --failed 100"], self.RUN)
        self.assert_reruns(["gh run rerun --repo org/repo --job 103"], f"{self.RUN}/job/103")
        # A job that a user or the failure of another job cancelled.
        s.gha_job(103, None, "The operation was canceled.")
        output = self.assert_reruns(["gh run rerun --repo org/repo --failed 100"], self.RUN)
        self.assertIn("c: cancelled", output)
        self.assert_reruns(["gh run rerun --repo org/repo --job 103"], f"{self.RUN}/job/103")
        s.gha_run("completed", "cancelled", [(103, "c", "cancelled")])
        self.assert_reruns(["gh run rerun --repo org/repo --failed 100"], self.RUN)
        # A cancelled job is not rerun if another job did not fail transiently, as when
        # the failure of that job cancelled it.
        s.gha_job(101, "Test failed")
        s.gha_job(104, "Read timed out")
        s.gha_run(
            "completed",
            "failure",
            [(101, "a", "failure"), (103, "c", "cancelled"), (104, "d", "failure")],
        )
        output = self.assert_reruns(["gh run rerun --repo org/repo --job 104"], self.RUN)
        self.assertIn("a: not transient", output)
        self.assertIn("Not rerunning the cancelled jobs:  a did not fail transiently.", output)
        s.gha_run("completed", "failure", [(101, "a", "failure"), (103, "c", "cancelled")])
        self.assert_reruns([], self.RUN)
        # A URL that names the cancelled job examines only that job.
        self.assert_reruns(["gh run rerun --repo org/repo --job 103"], f"{self.RUN}/job/103")

    def test_user_cancelled(self) -> None:
        """A run that a user cancelled is rerun, including the jobs that started after it."""
        s = self.server

        def job(
            job_id: int, name: str, conclusion: str, started: str, completed: str = ""
        ) -> dict[str, Any]:
            return {
                "id": job_id,
                "name": name,
                "conclusion": conclusion,
                "started_at": started,
                "completed_at": completed,
            }

        # Job canary never got a runner.  Job all_green started after the cancellation,
        # and failed because the jobs that it needs were cancelled.
        s.gha_run("completed", "cancelled", [])
        jobs = [
            job(101, "canary", "cancelled", "2026-11-26T21:16:24Z", "2026-11-26T22:52:49Z"),
            job(102, "all_green", "failure", "2026-11-26T22:52:50Z", "2026-11-26T22:52:53Z"),
        ]
        page = [{"jobs": jobs}]
        s.gh["repos/org/repo/actions/runs/100/jobs?filter=latest&per_page=100"] = page
        s.gh["repos/org/repo/actions/runs/100/jobs?filter=all&per_page=100"] = page
        s.gh_logs.pop(101)
        s.gh["repos/org/repo/check-runs/101/annotations?per_page=100"] = [
            [{"message": "The run was canceled by @someone.", "annotation_level": "failure"}]
        ]
        s.gha_job(
            102,
            "##[error]Process completed with exit code 1.",
            "Process completed with exit code 1.",
        )
        s.gh_requests.clear()
        output = self.assert_reruns(["gh run rerun --repo org/repo --failed 100"], self.RUN)
        self.assertIn("canary: cancelled", output)
        self.assertIn("all_green: transient: started after the run was cancelled\n", output)
        # A run that its concurrency group did not cancel does not read the newer runs.
        self.assertNotIn(NEWER_RUNS, s.gh_requests)
        # The attempt limit applies to a cancelled job.
        self.assert_reruns([], "--max-attempts", "1", self.RUN)

    def user_cancelled_run(self, *extra_jobs: dict[str, Any]) -> None:
        """Serve run 100, which a user cancelled, as in test_user_cancelled.

        Job canary (101) was cancelled, and job all_green (102) started after the
        cancellation.  The newer runs for the run's branch include only the run itself.

        Args:
            extra_jobs: other jobs of the run, each a dict with keys such as "id" and
                "conclusion".
        """
        s = self.server
        s.gha_run("completed", "cancelled", [])
        jobs = [
            {
                "id": 101,
                "name": "canary",
                "conclusion": "cancelled",
                "started_at": "2026-11-26T21:16:24Z",
                "completed_at": "2026-11-26T22:52:49Z",
            },
            {
                "id": 102,
                "name": "all_green",
                "conclusion": "failure",
                "started_at": "2026-11-26T22:52:50Z",
                "completed_at": "2026-11-26T22:52:53Z",
            },
            *extra_jobs,
        ]
        s.gh["repos/org/repo/actions/runs/100/jobs?filter=latest&per_page=100"] = [{"jobs": jobs}]
        s.gh["repos/org/repo/actions/runs/100/jobs?filter=all&per_page=100"] = [{"jobs": jobs}]
        s.gh_logs.pop(101, None)
        s.gha_job(101, None, "The run was canceled by @someone.")
        s.gha_job(
            102,
            "##[error]Process completed with exit code 1.",
            "Process completed with exit code 1.",
        )
        s.gh[NEWER_RUNS] = [{"workflow_runs": [self.newer_run(100)]}]

    @staticmethod
    def newer_run(run_id: int) -> dict[str, Any]:
        """Return a run of run 100's workflow for run 100's branch, no older than run 100.

        Args:
            run_id: a run's id.

        Returns:
            The run, as a dict as for the GitHub API's JSON.
        """
        return {
            "id": run_id,
            "workflow_id": 7,
            "event": "pull_request",
            "head_sha": "abc" if run_id == 100 else "def",
            "created_at": f"2026-11-24T22:40:{run_id - 97:02}Z",
            "head_branch": "feature",
            "head_repository": {"full_name": "me/repo"},
            "html_url": f"https://github.com/org/repo/actions/runs/{run_id}",
        }

    def test_user_cancelled_unreadable_annotations(self) -> None:
        """If a cancelled job's annotations cannot be read, a newer run prevents a rerun."""
        s = self.server
        self.user_cancelled_run()
        del s.gh["repos/org/repo/check-runs/101/annotations?per_page=100"]
        output = self.assert_reruns(["gh run rerun --repo org/repo --failed 100"], self.RUN)
        self.assertIn("canary: cancelled", output)
        # The concurrency group might have cancelled the run in favor of a newer run.
        s.gh[NEWER_RUNS][0]["workflow_runs"].append(self.newer_run(103))
        output = self.assert_reruns([], self.RUN)
        self.assertIn(
            "Its concurrency group might have cancelled it in favor of a newer run, because the"
            " annotations of a cancelled job cannot be read:"
            " https://github.com/org/repo/actions/runs/103",
            output,
        )
        self.assertIn("canary: cancelled, not rerun", output)
        del s.gh[NEWER_RUNS]
        output = self.assert_reruns([], self.RUN, status=1)
        self.assertIn("cannot read the newer runs", output)

    def test_user_cancelled_at_limit(self) -> None:
        """A job that started after a cancellation is not rerun if a failed job is at the limit.

        Rerunning such a job reruns every failed job, including the one at the limit.
        """
        s = self.server
        flaky = {
            "id": 104,
            "name": "flaky",
            "conclusion": "failure",
            "started_at": "2026-11-26T21:16:24Z",
            "completed_at": "2026-11-26T21:20:00Z",
        }
        self.user_cancelled_run(flaky)
        s.gha_job(104, "Connection reset")
        # An earlier attempt ran job flaky too.
        s.gh["repos/org/repo/actions/runs/100/jobs?filter=all&per_page=100"].append(
            {"jobs": [{**flaky, "id": 4, "started_at": "2026-11-26T20:00:00Z"}]}
        )
        output = self.assert_reruns(
            ["gh run rerun --repo org/repo --job 101"], "--max-attempts", "2", self.RUN
        )
        for message in [
            "Not rerunning flaky:  it has already been run 2 times.",
            (
                "Not rerunning job all_green:  only rerunning every failed job would rerun the"
                " cancelled jobs that it needs, and flaky has already been run the maximum"
                " number of times."
            ),
        ]:
            self.assertIn(message, output)

    def test_timed_out(self) -> None:
        """A job that ran longer than its time limit is examined like a failed job."""
        s = self.server
        s.gha_run("completed", "failure", [(101, "a", "failure"), (103, "c", "cancelled")])
        s.gh_logs.pop(103)
        s.gha_job(103, None, GHA_TIMEOUT)
        output = self.assert_reruns(["gh run rerun --repo org/repo --job 101"], self.RUN)
        self.assertIn("c: timed out, not transient", output)
        # It is not a cancellation, so it keeps another cancelled job from being rerun.
        s.gha_run(
            "completed",
            "failure",
            [(102, "b", "cancelled"), (103, "c", "cancelled")],
        )
        s.gha_job(102, None, "The operation was canceled.")
        output = self.assert_reruns([], self.RUN)
        self.assertIn("Not rerunning the cancelled jobs:  c did not fail transiently.", output)

    def test_concurrency_cancelled(self) -> None:
        """A run that its concurrency group cancelled is rerun, unless a newer run exists."""
        s = self.server

        def job(
            job_id: int, name: str, conclusion: str, started: str, completed: str = ""
        ) -> dict[str, Any]:
            return {
                "id": job_id,
                "name": name,
                "conclusion": conclusion,
                "started_at": started,
                "completed_at": completed,
            }

        def serve(*jobs: dict[str, Any]) -> None:
            page = [{"jobs": list(jobs)}]
            s.gh["repos/org/repo/actions/runs/100/jobs?filter=latest&per_page=100"] = page
            s.gh["repos/org/repo/actions/runs/100/jobs?filter=all&per_page=100"] = page

        # Job a was running when the run was cancelled, and took a while to stop.  Job b
        # never started, so it has no annotation.  Job all_green started after the
        # cancellation, and failed because the jobs that it needs were cancelled.
        s.gha_run("completed", "cancelled", [])
        cancelled = [
            job(101, "a", "cancelled", "2026-11-24T22:40:04Z", "2026-11-24T23:38:00Z"),
            job(102, "b", "cancelled", "2026-11-24T23:36:11Z", "2026-11-24T23:36:11Z"),
            job(103, "all_green", "failure", "2026-11-24T23:36:15Z"),
        ]
        serve(*cancelled)
        s.gh_logs.pop(101)
        s.gha_job(101, None, CONCURRENCY_CANCEL)
        s.gh["repos/org/repo/check-runs/102/annotations?per_page=100"] = [[]]
        s.gha_job(
            103,
            "##[error]Process completed with exit code 1.",
            "Process completed with exit code 1.",
        )

        def run(
            run_id: int,
            head_repo: str = "me/repo",
            workflow: int = 7,
            sha: str = "def",
            event: str = "push",
        ) -> dict[str, Any]:
            return {
                "id": run_id,
                "workflow_id": workflow,
                "event": event,
                "head_sha": sha,
                "created_at": f"2026-11-24T22:40:{run_id - 97:02}Z",
                "head_branch": "feature",
                "head_repository": {"full_name": head_repo},
                "html_url": f"https://github.com/org/repo/actions/runs/{run_id}",
            }

        # The run itself, a newer run for a branch of the same name in another fork, and
        # a run of another workflow that the same event started.
        s.gh[NEWER_RUNS] = [
            {
                "workflow_runs": [
                    run(101, head_repo="other/repo"),
                    run(102, workflow=8, sha="abc", event="pull_request"),
                    run(100, sha="abc", event="pull_request"),
                ]
            }
        ]
        output = self.assert_reruns(["gh run rerun --repo org/repo --failed 100"], self.RUN)
        self.assertIn(f"a: transient: {CONCURRENCY_CANCEL}", output)
        self.assertIn(
            f"all_green: transient: started after the run was cancelled: {CONCURRENCY_CANCEL}",
            output,
        )
        # Each job's annotations are read once.
        annotation_requests = [r for r in s.gh_requests if "/annotations" in r]
        self.assertEqual(len(annotation_requests), len(set(annotation_requests)))
        # A URL that names the job that failed because of the cancellation reruns the
        # jobs that it needs too.
        output = self.assert_reruns(
            ["gh run rerun --repo org/repo --failed 100"], f"{self.RUN}/job/103"
        )
        self.assertIn("would not rerun the cancelled jobs that it needs", output)

        # A job that failed before the cancellation did not fail transiently, so the
        # cancelled jobs are not rerun.
        serve(*cancelled, job(104, "d", "failure", "2026-11-24T22:40:04Z"))
        s.gha_job(104, "Test failed")
        output = self.assert_reruns([], self.RUN)
        self.assertIn("d: not transient", output)
        self.assertIn("Not rerunning the cancelled jobs:  d did not fail transiently.", output)
        # A URL that names it does not read the newer runs.
        s.gh_requests.clear()
        self.assert_reruns([], f"{self.RUN}/job/104")
        self.assertNotIn(NEWER_RUNS, s.gh_requests)

        # Without the completion times of the cancelled jobs, no job is known to have
        # started after the cancellation, so job all_green did not fail transiently, and
        # the cancelled jobs are not rerun.
        serve(*[{**j, "completed_at": None} for j in cancelled])
        output = self.assert_reruns([], self.RUN)
        self.assertIn("all_green: not transient", output)

        # A newer run for the same branch, of another workflow and for another event,
        # superseded the run.
        serve(*cancelled)
        s.gh[NEWER_RUNS][0]["workflow_runs"].append(run(103, workflow=8))
        output = self.assert_reruns([], self.RUN)
        self.assertIn(
            "Its concurrency group cancelled it in favor of a newer run:"
            " https://github.com/org/repo/actions/runs/103",
            output,
        )
        self.assertIn("a: cancelled, not rerun", output)
        self.assertIn("b: cancelled, not rerun", output)
        self.assertIn("all_green: not transient", output)

        # The newer runs cannot be read.
        del s.gh[NEWER_RUNS]
        output = self.assert_reruns([], self.RUN, status=1)
        self.assertIn("cannot read the newer runs", output)

        # A run that failed, rather than being cancelled, does not read the newer runs.
        # Its job that started after a job was cancelled did not fail transiently.
        s.gha_run("completed", "failure", [])
        serve(*cancelled)
        s.gh_requests.clear()
        output = self.assert_reruns([], self.RUN)
        self.assertNotIn(NEWER_RUNS, s.gh_requests)
        self.assertIn("all_green: not transient", output)

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
        """The attempt limit counts each job's runs, not the run's attempts or job ids."""

        def job(job_id: int, name: str, started: str) -> dict[str, Any]:
            return {"id": job_id, "name": name, "conclusion": "failure", "started_at": started}

        # Each of three attempts reran only job a.  Each attempt lists job c too, with a
        # new id but with the start time of its only run.
        self.server.gh["repos/org/repo/actions/runs/100/jobs?filter=all&per_page=100"] = [
            {"jobs": [job(1, "a", "T1"), job(3, "c", "T1")]},
            {"jobs": [job(2, "a", "T2"), job(4, "c", "T1")]},
            {"jobs": [job(101, "a", "T3"), job(103, "c", "T1")]},
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

    def test_fork_parent_pr(self) -> None:
        """In a clone of a fork, the pull request for the current branch is in the parent."""
        s = self.server
        s.gha_run("completed", "failure", [(101, "a", "failure")])
        s.gha_job(101, "Read timed out")
        s.repo = {"owner": {"login": "me"}, "parent": {"owner": {"login": "org"}, "name": "repo"}}
        url = "https://github.com/org/repo/pull/7"
        s.gh["repos/org/repo/pulls?head=me%3Afeature&state=open"] = [{"html_url": url}]
        s.pr_checks[url] = [
            {"name": "a", "bucket": "fail", "link": "https://github.com/org/repo/actions/runs/100/job/101"},
        ]  # fmt: skip
        output = self.assert_reruns(["gh run rerun --repo org/repo --failed 100"])
        self.assertIn(f"Pull request for the current branch: {url}", output)

    def test_fork_parent_pr_pushed_branch(self) -> None:
        """In a clone of a fork, the head of the pull request is the branch pushed to."""
        s = self.server
        s.gha_run("completed", "failure", [(101, "a", "failure")])
        s.gha_job(101, "Read timed out")
        s.repo = {"owner": {"login": "me"}, "parent": {"owner": {"login": "org"}, "name": "repo"}}
        s.push = "refs/remotes/origin/fix-timeout"
        url = "https://github.com/org/repo/pull/7"
        s.gh["repos/org/repo/pulls?head=me%3Afix-timeout&state=open"] = [{"html_url": url}]
        s.pr_checks[url] = [
            {"name": "a", "bucket": "fail", "link": "https://github.com/org/repo/actions/runs/100/job/101"},
        ]  # fmt: skip
        output = self.assert_reruns(["gh run rerun --repo org/repo --failed 100"])
        self.assertIn(f"Pull request for the current branch: {url}", output)

    def test_fork_parent_pr_branch_argument(self) -> None:
        """In a clone of a fork, the pull request for a given branch is in the parent."""
        s = self.server
        s.gha_run("completed", "failure", [(101, "a", "failure")])
        s.gha_job(101, "Read timed out")
        s.repo = {"owner": {"login": "me"}, "parent": {"owner": {"login": "org"}, "name": "repo"}}
        url = "https://github.com/org/repo/pull/7"
        s.gh["repos/org/repo/pulls?head=me%3Aother&state=open"] = [{"html_url": url}]
        s.pr_checks[url] = [
            {"name": "a", "bucket": "fail", "link": "https://github.com/org/repo/actions/runs/100/job/101"},
        ]  # fmt: skip
        output = self.assert_reruns(["gh run rerun --repo org/repo --failed 100"], "other")
        self.assertIn(f"Pull request for branch other: {url}", output)

    def test_no_pr(self) -> None:
        """A clone that is not of a fork, and whose current branch has no pull request."""
        output = self.assert_reruns([], status=1)
        self.assertIn('no pull requests found for branch "feature"', output)


if __name__ == "__main__":
    unittest.main()
