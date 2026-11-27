"""Rerun each failed CI job whose failure appears to be transient.

A transient failure is one such as a network error or a rate limit, rather than a
problem with the code.

Usage:
  rerun-failed-ci [--dry-run] [--max-attempts N] [--exit-3-if-reran] [PR | BRANCH | URL]...
  rerun-failed-ci --classify [LOG-FILE]...

With no PR, BRANCH, or URL, this command examines the GitHub pull request for the
current branch.  A PR (a number or URL) or BRANCH names a pull request, as for
`gh pr checks`.  If `gh` finds no pull request for a branch (the given BRANCH or the
current branch), and the clone's GitHub repository (as `gh` resolves it) is a fork, then
this command examines the open pull request of the fork's parent whose head is that
branch of the fork.  For the current branch, that branch of the fork is the one that
`git push` updates, whose name can differ.  For example, in a clone whose only remote
is ME/REPO, a fork of ORG/REPO, it examines the pull request in ORG/REPO whose head is
ME:BRANCH.  For each failed check of that pull request, this command examines every
failed job of the check's build, workflow, or workflow run, so that the jobs of
one workflow are rerun together.  A URL of an Azure Pipelines build or of one of its
jobs names every failed job of the build.  A URL of a CircleCI job or workflow, or of a
GitHub Actions job or workflow run, names the failed jobs to examine:  the given job,
or every failed job of the given workflow or run.

The supported CI services are Azure Pipelines, CircleCI, and GitHub Actions.  A failed
check from any other service is reported and skipped.

A job's failure is transient if the log of its failed steps contains a message that
TRANSIENT_PATTERNS below lists, such as a message about a network problem, an overloaded
or rate-limited server, or a lost CI runner.  A job's failure is also transient if
Gradle did not find an artifact and the Gradle Plugin Portal is the only location that
Gradle searched for it, or if Gradle did not find some artifacts and, for each one, some
location where Gradle searched for it serves it, or if javac failed only because of
-Werror and a Checker Framework warning that type-checking was too slow.  A location
serves an artifact if the `gradlew-retry` script of plume-lib/plume-scripts reported
that it does, or if it serves the artifact when this command requests it.  If the log
shows that `gradlew-retry` ran Gradle again, then only the output of the last run of
Gradle is examined, except for the reports of `gradlew-retry` about locations that
serve artifacts.  The log of an Azure Pipelines or GitHub Actions job also contains the errors
that the CI service reports for the job, which describe failures, such as a lost runner
or a job that no runner picked up, that leave no log.  Shell trace lines, which start
with `+ `, and the scripts that Azure Pipelines and GitHub Actions echo before running a
step, are ignored, because a script that itself looks for such messages, in order to
retry a command, contains them.  Shell comment lines, which a shell echoes under `set -o
verbose`, are ignored too, because a comment can mention such a message, as in `This
can avoid "403 rate limit exceeded" failures.`  A line is taken to be a shell comment
if it starts with `#` followed by whitespace or by the end of the line, so a comment
such as `#Retry on Connection reset` is examined, as are the commands that a shell
echoes under `set -o verbose`.  Two kinds of tool output also start with `#` and are
examined:  the diagnostics that follow a failed test (`not ok`) in TAP output, as from
Bats or Perl's `prove`, and the first lines of a Java virtual machine's fatal error
report, which name the signal that crashed the JVM.  An Azure Pipelines job that was
abandoned, such as one whose agent stopped responding, is examined like a failed one.  A
CircleCI job whose status is `infrastructure_fail` is transient.  A cancelled GitHub
Actions job is examined too, because GitHub Actions cancels a job whose runner shuts
down.  A GitHub Actions job also failed transiently if
the concurrency group of its workflow run cancelled the run in favor of a waiting
request, as an annotation of the job such as "Canceling since a higher priority waiting
request for CI-8598 exists" shows, and the repository has no newer workflow run for the
same branch, so that the waiting request never became a run and the branch was left
with no CI result.  (A run of another workflow for the same commit is not considered
newer.)  So did a job of such a run that started after the cancellation, such as a job
that runs `if: always()` and fails because the jobs that it needs were cancelled.  A
cancelled job that did not fail transiently, such as one that a user or the failure of
another job cancelled, is ignored.

For each build (Azure Pipelines), workflow (CircleCI), or workflow run (GitHub
Actions) that has a job that failed transiently, this command reruns:
 * every failed job, if every failed job failed transiently, or
 * otherwise, only the jobs that failed transiently.  Azure Pipelines reruns only all
   the failed jobs of a stage together, so this command reruns a stage only if every
   failed job of the stage failed transiently, and it reruns only one stage at a time.
   GitHub Actions does not permit a job to be rerun while its workflow run is in
   progress, so this command reruns only one of them; run this command again after
   the workflow run completes.
Rerunning a job also reruns the jobs that depend on it.  A GitHub Actions job that
failed transiently because it started after its run was cancelled failed because the
jobs that it needs were cancelled, and rerunning a job does not rerun the jobs that it
needs, so for such a job this command reruns every failed job of its run.

This command does nothing to a build, workflow, or workflow run that is still in
progress or that has been rerun since the failure.  It also does not rerun an Azure
Pipelines stage, a CircleCI workflow, or a GitHub Actions job that has already been run
N times in total, where N is given by `--max-attempts` (default 3).  The limit keeps
this command, when it is run repeatedly, from rerunning a job forever whose failure
resembles a transient one but is not.

With `--dry-run`, this command reports what it would rerun but does not rerun anything.

The exit status is 1 if some build could not be examined or rerun, and 0 otherwise.
With `--exit-3-if-reran`, the exit status is instead 3 if this command reran some job,
even if some other build could not be examined or rerun.  A caller can use it to tell
that some check of a pull request is about to run again, which GitHub might not show
until some time after the rerun.

With `--classify`, this command reruns nothing and contacts no server other than the
locations where Gradle searched for an artifact that it did not find.  It reads each
LOG-FILE (or standard input), and for each one that shows a transient failure, it
prints the line that shows it.  It does not recognize a run that its concurrency group
cancelled, because that requires asking GitHub about newer runs.  The exit status is 0
if every LOG-FILE shows a transient failure, and 1 otherwise.

This command requires `gh`, authenticated to GitHub.  Rerunning an Azure Pipelines
build or a CircleCI job requires credentials, as described in `ci_build.py`.  The Azure
DevOps token needs the "Build (Read & execute)" scope.  Reading the logs of a public
project's jobs does not require credentials.
"""

from __future__ import annotations

import argparse
import functools
import json
import operator
import re
import shutil
import subprocess
import sys
import urllib.parse
from pathlib import Path
from typing import TYPE_CHECKING, Any, NamedTuple

import ci_build
import request_util

if TYPE_CHECKING:
    from collections.abc import Callable

PROGRAM = Path(sys.argv[0]).name

# The `normalize-log` command, which is in the same directory as this script.
NORMALIZE_LOG = Path(__file__).resolve().parent / "normalize-log"

# Regular expressions, each of which matches a line of a log that shows a transient
# failure.  They are matched without regard to case.
TRANSIENT_PATTERNS = [
    *request_util.TRANSIENT_NETWORK_PATTERNS,
    # A runner that was lost or stopped responding.
    r"We stopped hearing from agent",
    r"agent did not renew the lock",
    r"runner has received a shutdown signal",
    r"lost communication with the server",
    # A Java virtual machine that crashed with a segmentation fault, as the JVM reports it
    # in a line such as "#  SIGSEGV (0xb) at pc=0x000074a6b3df9d00, pid=10859, tid=...".
    # A rerun often avoids such a crash.  The pattern does not check where the crash
    # happened, so it also matches a crash that recurs on every run, such as one in the
    # project's own native (JNI) code or one from a JIT-compiler bug that the same code
    # always triggers.  Only `--max-attempts` limits the reruns of such a crash.
    r"#\s+SIGSEGV \(0xb\) at pc=",
    # An artifact that Maven Central refused to serve, as Maven reports it in a line such
    # as "Could not transfer artifact org.apache.felix:maven-bundle-plugin:pom:5.1.8
    # from/to central (https://repo.maven.apache.org/maven2): HTTP Status: 403" or, in
    # some versions of Maven, "...: status code: 403, reason phrase: Forbidden (403)".
    # Maven Central sometimes responds with status 403 (Forbidden) to a request for a file
    # that it holds; for a file that it does not hold, it responds with status 404.  Maven
    # Central also responds with status 403 to a client that it blocks, such as one from a
    # blocked IP address; that failure recurs on every run, and only `--max-attempts`
    # limits its reruns.  Status 403 from another repository is not transient (neither
    # this pattern nor any other matches it), because the usual cause is missing or wrong
    # credentials.  A failure to transfer metadata, such as "Could not transfer metadata
    # /.meta/prefixes.txt", is not matched, because Maven reports it only as a warning.
    (
        r"Could not transfer artifact .* \(https://repo1?\.maven(\.apache)?\.org/maven2/?\):"
        r" (HTTP Status|status code): 403\b"
    ),
    # A GitHub-hosted runner that never picked up the job.  A job that waited for a runner
    # until it timed out ("while awaiting a runner") is not transient, because the usual
    # cause is a `runs-on` label that matches no runner or a self-hosted runner that is
    # offline.
    r"job was not acquired by Runner of type hosted",
]
# Matches a line of a log that shows a transient failure.
TRANSIENT_RE = re.compile("|".join(f"(?:{p})" for p in TRANSIENT_PATTERNS), re.IGNORECASE)

# Matches a line that contains the Checker Framework's warning that type-checking one
# method or class took too long, as in "Foo.java:201: warning:
# [compilermessages:slow.typechecking] typechecking took 48 seconds; consider making
# inferred type variables explicit".  The key "slow.typechecking" is in square brackets,
# with a prefix such as "compilermessages:" or "[nullness, allcheckers]:" if the
# Checker Framework shows one.  The rest of the line differs among the Checker
# Framework's message formats:  under `-Anomsgtext`, nothing follows the key, and under
# `-Adetailedmsgtext`, fields separated by " $$ " follow it.
SLOW_TYPECHECKING_RE = re.compile(r"[\[:]slow\.typechecking\]")
# Matches the line in which javac reports that it failed because it issued a warning and
# the -Werror command-line option was given, as in "error: warnings found and -Werror
# specified" or, from Maven, "[ERROR] warnings found and -Werror specified".
WERROR_RE = re.compile(r"warnings found and -Werror specified")
# Matches a line that contains a javac warning or error, such as "Foo.java:5: error:
# cannot find symbol", "[WARNING] /a/b/Foo.java:[5,13] [deprecation] ...", as Maven
# reports a diagnostic, or "warning: [options] source value 8 is obsolete", which names
# no source file.
COMPILER_DIAGNOSTIC_RE = re.compile(
    r"\.java:(?:\d+: (?:error|warning):|\[\d+,\d+\] )|^\s*(?:\[\w+\] )?warning: \["
)

# Matches the line that starts Gradle's list of the locations where it searched for an
# artifact that it did not find.  The line follows one that names the artifact, such as
# "> Could not find org.slf4j:slf4j-api:1.7.36.".
SEARCHED_LOCATIONS_RE = re.compile(r"\s*Searched in the following locations:")
# Matches an item of that list.  Group 1 is the location, a URL such as
# "https://repo.maven.apache.org/maven2/org/slf4j/slf4j-api/1.7.36/slf4j-api-1.7.36.pom".
SEARCHED_LOCATION_RE = re.compile(r"\s*- (\S+)")
# The prefix of every location in the Gradle Plugin Portal.  The portal serves the Maven
# Central artifacts that plugins depend on, such as slf4j-api, and it sometimes fails to
# find them.  A Gradle failure to find an artifact is transient only if the portal is
# the only location searched, because Gradle lists every repository that it searched,
# and an artifact that no repository has, such as a misspelled one, is not transient.
PLUGIN_PORTAL_URL = "https://plugins.gradle.org/m2/"
# Matches the line in which Gradle reports a plugin that it did not find, such as
# "Plugin [id: 'org.example.x', version: '1.0'] was not found in any of the following
# sources:".  Gradle does not list the URLs where it searched for the plugin.
PLUGIN_NOT_FOUND_RE = re.compile(r"Plugin \[id: .*\] was not found")

# The `gradlew-retry` script of plume-lib/plume-scripts runs Gradle, and if Gradle fails
# in a way that a retry might fix, then it prints a line about the failure, prints a line
# that matches GRADLEW_RETRY_RETRYING_RE, and runs Gradle again.  These expressions match
# the messages of `gradlew-retry`, so a change to their wording requires a change here.
#
# Matches the line that `gradlew-retry` prints just before it runs Gradle again, such as
# "gradlew-retry: Gradle could not resolve a dependency; retrying in 60 seconds.".
GRADLEW_RETRY_RETRYING_RE = re.compile(r"gradlew-retry: .*; retrying in ")
# Matches the line in which `gradlew-retry` reports that a URL serves a file, such as
# "gradlew-retry: https://repo.maven.apache.org/maven2/org/example/x/1.0/x-1.0.pom
# exists." or "gradlew-retry: https://repo.maven.apache.org/maven2/.../x-1.0.pom exists
# on a mirror of Maven Central.".  Group 1 is the URL.  The URL is either one that Gradle
# listed as a location where it did not find an artifact, or one that `gradlew-retry`
# constructed for a plugin that Gradle did not find.  `gradlew-retry` considers a URL to
# serve a file if the URL yields a 2xx status code, so the line is wrong for a server
# that yields one for a file that it does not hold.
GRADLEW_RETRY_EXISTS_RE = re.compile(
    r"gradlew-retry: (\S+) exists(?: on a mirror of Maven Central)?\.$"
)

# Matches a shell trace line, as `set -x` prints it.
TRACE_LINE_RE = re.compile(r"\++ ")
# Matches a line that starts with "#" followed by whitespace or by the end of the line.
# Such a line is a shell comment, as `set -o verbose` prints it when a shell reads a
# script, such as `# calls.  This can avoid "403 rate limit exceeded" failures.`, or a
# line of a tool's output, such as a TAP diagnostic or a line of a Java virtual machine's
# fatal error report.  It does not match a comment with no whitespace after "#", such as
# "#Retry on Connection reset", an Azure Pipelines logging command, such as
# "##[error]Bash exited with code '1'.", or a line of Docker BuildKit's output, such as
# "#12 0.345 curl: (56) Recv failure: Connection reset by peer".
COMMENT_LINE_RE = re.compile(r"\s*#+(\s|$)")
# Matches a TAP line that reports a failed test, such as "not ok 1 downloads the file".
# The diagnostics that follow it start with "#", as in "# curl: (56) Recv failure:
# Connection reset by peer".
TAP_NOT_OK_RE = re.compile(r"\s*not ok\b")
# Matches the line that starts a Java virtual machine's fatal error report, such as
# "# A fatal error has been detected by the Java Runtime Environment:" or, from older
# JVMs, "# An unexpected error has been detected by Java Runtime Environment:".  The
# lines of the report all start with "#".  The line that names the signal that crashed
# the JVM, such as "#  SIGSEGV (0xb) at pc=0x000074a6b3df9d00", comes soon after it.
JVM_FATAL_ERROR_RE = re.compile(
    r"\s*#\s*An? (fatal|unexpected) error has been detected by (the )?Java Runtime Environment"
)
# Matches the line of a Java virtual machine's fatal error report that follows the line
# that names the signal, such as "# JRE version: OpenJDK Runtime Environment (8.0_482-b08)"
# or, from older JVMs, "# Java VM: Java HotSpot(TM) Server VM (1.6.0-b105 mixed mode)".
JVM_FATAL_ERROR_VERSION_RE = re.compile(r"\s*#\s*(JRE version|Java VM):")
# For Azure Pipelines and for GitHub Actions, regular expressions that match the start
# and the end of the script that the CI service echoes before running a step.
ECHOED_SCRIPTS = [
    (re.compile(r"Script contents:"), re.compile(r".*Starting Command Output")),
    (re.compile(r"##\[group\]Run "), re.compile(r"##\[endgroup\]")),
]

# The results of a failed Azure Pipelines job or task.  Azure Pipelines abandons a job
# whose agent stops responding.
AZURE_FAILED = ("failed", "abandoned")
# The statuses of a failed CircleCI job.
CIRCLECI_FAILED = ("failed", "infrastructure_fail", "timedout")
# The conclusions of a failed GitHub Actions job.
GITHUB_FAILED = ("failure", "timed_out")
# The conclusion of a cancelled GitHub Actions job, such as one whose runner shut down.
GITHUB_CANCELLED = "cancelled"
# The `gh pr checks` buckets of a check that failed or was cancelled.
PR_CHECK_FAILED = ("fail", "cancel")
# Matches the failure annotation of a GitHub Actions job whose workflow run its
# concurrency group cancelled in favor of a waiting request, such as "Canceling since a
# higher priority waiting request for CI-8598 exists", in which "CI-8598" is the group.
GHA_CONCURRENCY_CANCEL_RE = re.compile(
    r"Canceling since a higher priority waiting request for .* exists"
)


###########################################################################
### Classifying logs
###


def normalize_log(log: str) -> str:
    """Return the given log without the formatting that a CI service or a terminal adds.

    If `normalize-log` cannot be run or fails, this exits the program, because then it
    would fail for every log.

    Args:
        log: a log of a CI job.

    Returns:
        The log, as `normalize-log` prints it.
    """
    try:
        return subprocess.run(
            [NORMALIZE_LOG],
            input=log,
            capture_output=True,
            check=True,
            encoding="utf-8",
            errors="replace",
        ).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        sys.exit(f"{PROGRAM}: cannot run {NORMALIZE_LOG}: {request_util.failure(e)}")


def examined_lines(log: str) -> list[str]:
    """Return the lines of the given log that are examined for a transient failure.

    Shell trace lines in the log are omitted, as are the scripts that Azure Pipelines
    (between "Script contents:" and "Starting Command Output") and GitHub Actions
    (between "##[group]Run" and "##[endgroup]") echo before running a step.  The lines
    that COMMENT_LINE_RE matches, such as shell comments, are omitted too, except for two
    kinds of tool output:  the diagnostics that immediately follow a TAP line that reports
    a failed test ("not ok"), up to the next line that COMMENT_LINE_RE does not match, and
    a Java virtual machine's fatal error report up to the line that gives the JVM's
    version, which follows the line that names the signal that crashed the JVM.  Other
    lines, such as another process's output, can come between the lines of the report.

    Args:
        log: a log of the failed steps of a CI job.

    Returns:
        The examined lines, as `normalize-log` prints them.
    """
    result = []
    end_of_echo = None
    # True if the line follows a TAP line that reports a failed test, and every line since
    # that one matches COMMENT_LINE_RE.
    in_tap_diagnostics = False
    # True if the line follows the start of a Java virtual machine's fatal error report
    # but does not follow the line that gives the JVM's version.
    in_jvm_report = False
    for line in normalize_log(log).splitlines():
        if end_of_echo:
            if end_of_echo.match(line):
                end_of_echo = None
            continue
        end_of_echo = next((end for start, end in ECHOED_SCRIPTS if start.match(line)), None)
        is_comment = bool(COMMENT_LINE_RE.match(line))
        in_tap_diagnostics = is_comment and in_tap_diagnostics
        if JVM_FATAL_ERROR_RE.match(line):
            in_jvm_report = True
        is_output = in_tap_diagnostics or in_jvm_report
        if JVM_FATAL_ERROR_VERSION_RE.match(line):
            in_jvm_report = False
        if TAP_NOT_OK_RE.match(line):
            in_tap_diagnostics = True
        if not (end_of_echo or TRACE_LINE_RE.match(line) or (is_comment and not is_output)):
            result.append(line)
    return result


def searched_locations(lines: list[str]) -> list[str]:
    """Return the locations that the given lines start with.

    Args:
        lines: the lines of a log that follow a "Searched in the following locations:"
            line.

    Returns:
        The locations, each a URL, in the lines before the first line that is not a
        location.
    """
    locations = []
    for line in lines:
        match = SEARCHED_LOCATION_RE.match(line)
        if not match:
            break
        locations.append(match[1])
    return locations


def serves_file(url: str) -> bool:
    """Return True if the given URL serves a file now.

    Args:
        url: a URL, such as
            "https://repo.maven.apache.org/maven2/org/slf4j/slf4j-api/1.7.36/slf4j-api-1.7.36.pom".

    Returns:
        True if the server responds to a HEAD request of the URL with a successful status,
        after following redirects; False if it responds with an error status or cannot
        be reached.
    """
    try:
        request_util.http("HEAD", url)
    except request_util.REQUEST_ERRORS:
        return False
    return True


def missing_artifacts_reason(lines: list[str], last_run: list[str]) -> str | None:
    """Return the line that shows that the artifacts that Gradle did not find exist.

    The result shows a transient failure only if the last run of Gradle failed only
    because it did not find artifacts, and for each such artifact, some location where
    Gradle searched for it serves it.  A location serves an artifact if `gradlew-retry`
    reported that it does, in a line that matches GRADLEW_RETRY_EXISTS_RE, or if
    serves_file returns True for it.  A repository such as Maven Central sometimes fails,
    for a minute or more, to serve an artifact that it holds.  An artifact that no
    location serves, such as a misspelled one, prevents a transient failure.  So does a
    plugin that Gradle did not find, because Gradle does not report where it searched
    for the plugin.  The locations are requested only for an artifact for which
    `gradlew-retry` reported no location.

    Args:
        lines: the lines of a log of the failed steps of a CI job.
        last_run: the lines of the log from the last run of Gradle, a suffix of lines.

    Returns:
        For the first artifact that the last run did not find, the line in which
        `gradlew-retry` reported a location that serves it or, if there is none, the line
        in which Gradle reported that it did not find it, such as "> Could not find
        org.slf4j:slf4j-api:1.7.36.".  The line is without leading whitespace and
        truncated to 200 characters.  The result is None if the log does not show such a
        transient failure.
    """
    if any(PLUGIN_NOT_FOUND_RE.search(line) for line in last_run):
        return None
    # Maps each URL that `gradlew-retry` reported to serve a file, to the first line that
    # reported it.
    existing: dict[str, str] = {}
    for line in lines:
        match = GRADLEW_RETRY_EXISTS_RE.search(line)
        if match:
            existing.setdefault(match[1], line.lstrip()[:200])
    result = None
    for i, line in enumerate(last_run):
        if i > 0 and SEARCHED_LOCATIONS_RE.match(line):
            locations = searched_locations(last_run[i + 1 :])
            reason = next((existing[loc] for loc in locations if loc in existing), None)
            if reason is None and any(serves_file(loc) for loc in locations):
                reason = last_run[i - 1].lstrip()[:200]
            if reason is None:
                return None
            result = result or reason
    return result


def slow_typechecking_reason(lines: list[str]) -> str | None:
    """Return the line of the given log that shows that type-checking was too slow.

    The result is a line that matches SLOW_TYPECHECKING_RE.  It shows a transient failure
    only if javac failed because the Checker Framework warned that type-checking was too
    slow and the -Werror command-line option was given, and javac reported no other
    warning or error.  The time that type-checking takes depends on how busy the CI
    machine is, so a rerun often avoids the warning.  Code that is slow to type-check on
    every run also yields the warning; only `--max-attempts` limits the reruns of such a
    failure.  A failure other than javac's, such as a test failure in another project of
    a Gradle build that runs with `--continue`, is not detected.

    Args:
        lines: the lines of a log of the failed steps of a CI job.

    Returns:
        The first line that shows that type-checking was too slow, without leading
        whitespace and truncated to 200 characters, or None if the log does not show such
        a transient failure.
    """
    result = None
    found_werror = False
    for line in lines:
        if SLOW_TYPECHECKING_RE.search(line):
            result = result or line.lstrip()[:200]
        elif COMPILER_DIAGNOSTIC_RE.search(line):
            return None
        found_werror = found_werror or bool(WERROR_RE.search(line))
    return result if found_werror else None


def transient_reason(log: str) -> str | None:
    """Return the first line of the given log that shows a transient failure.

    Only the lines from the last run of Gradle by `gradlew-retry` are examined, if the log
    shows that `gradlew-retry` ran Gradle again.  An earlier run's failure did not cause
    the job's failure, even if it was transient, because `gradlew-retry` ran Gradle again.
    Of those lines, one shows a transient failure if it matches TRANSIENT_RE, or if it
    names an artifact that Gradle did not find and the Gradle Plugin Portal is the only
    location that Gradle searched for it.  Otherwise, the result is as for
    slow_typechecking_reason or, if that is None, as for missing_artifacts_reason.  The
    lines that `examined_lines` omits are ignored.

    Args:
        log: a log of the failed steps of a CI job.

    Returns:
        The first line that shows a transient failure, without leading whitespace and
        truncated to 200 characters, or None if there is none.
    """
    lines = examined_lines(log)
    last_retry = max(
        (i for i, line in enumerate(lines) if GRADLEW_RETRY_RETRYING_RE.search(line)), default=-1
    )
    last_run = lines[last_retry + 1 :]
    for i, line in enumerate(last_run):
        if TRANSIENT_RE.search(line):
            return line.lstrip()[:200]
        if i > 0 and SEARCHED_LOCATIONS_RE.match(line):
            locations = searched_locations(last_run[i + 1 :])
            if locations and all(loc.startswith(PLUGIN_PORTAL_URL) for loc in locations):
                return last_run[i - 1].lstrip()[:200]
    return slow_typechecking_reason(last_run) or missing_artifacts_reason(lines, last_run)


def classify(files: list[str]) -> int:
    """Print the line of each log file that shows a transient failure.

    Args:
        files: a list of the names of log files, in which "-" means standard input; an
            empty list means standard input.

    Returns:
        The exit status:  0 if every log shows a transient failure, and 1 otherwise.
    """
    status = 0
    for file in files or ["-"]:
        if file == "-":
            name, log = "(standard input)", sys.stdin.buffer.read()
        else:
            name = file
            try:
                log = Path(file).read_bytes()
            except OSError as e:
                sys.exit(f"{PROGRAM}: cannot read {file}: {e.strerror}")
        reason = transient_reason(log.decode(errors="replace"))
        if reason is None:
            status = 1
        else:
            print(f"{name}: {reason}")
    return status


###########################################################################
### Rerunning
###


class Rerunner:
    """Reruns the transiently failed jobs of CI builds.

    A Rerunner represents one invocation of this command:  the command-line options,
    the builds that the invocation has examined so far, and the exit status so far.

    Attributes:
        dry_run: True if the reruns should be printed rather than made.
        max_attempts: the most times that a job can have been run before this reruns it.
        status: the exit status so far:  1 if some build could not be examined or
            rerun, and 0 otherwise.
        reran: True if some job has been rerun.
        examined: the keys, as for record_if_unexamined, of the builds that have been
            examined, so that a build that a pull request has several failed checks for
            is examined only once.
    """

    def __init__(self, dry_run: bool, max_attempts: int) -> None:
        """Create a Rerunner."""
        self.dry_run = dry_run
        self.max_attempts = max_attempts
        self.status = 0
        self.reran = False
        self.examined: set[tuple[Any, ...]] = set()

    def warn(self, message: str) -> None:
        """Print the given warning and make the exit status a failure.

        Args:
            message: a warning, without the name of this program.
        """
        print(f"{PROGRAM}: {message}", file=sys.stderr)
        self.status = 1

    def record_if_unexamined(self, key: tuple[Any, ...]) -> bool:
        """Record that the build with the given key is examined, unless it already was.

        Args:
            key: a build's key, a tuple of the CI service and the build's ids, such as
                ("gha", "ORG/REPO", 123).

        Returns:
            True if the build had not been examined, so that this recorded it.
        """
        if key in self.examined:
            return False
        self.examined.add(key)
        return True

    def rerun(self, what: str, rerunning: Callable[[], str | None]) -> None:
        """Rerun the given jobs and print that it did, or with --dry-run print that it would.

        If rerunning raises an exception, this raises it too.

        Args:
            what: a description of some jobs, such as "the failed jobs".
            rerunning: a function of no arguments that reruns the jobs, and that returns
                the URL of the rerun jobs, or None if it does not know it.
        """
        if self.dry_run:
            print(f"  Would rerun {what}.")
            return
        url = rerunning()
        self.reran = True
        print(f"  Reran {what}: {url}" if url else f"  Reran {what}.")

    ###########################################################################
    ### Azure Pipelines
    ###

    def azure_rerun_failed(self, org: str, project: str, build: int) -> None:
        """Rerun the failed jobs of the given Azure Pipelines build that failed transiently.

        Args:
            org: an Azure DevOps organization.
            project: a project of the organization.
            build: the id of a build of the project, an integer such as 24267 in
                ".../_build/results?buildId=24267" (not its build number, such as
                "20261031.1").
        """
        build_url = f"https://dev.azure.com/{org}/{project}/_build/results?buildId={build}"
        api = ci_build.azure_api(org, project, build)
        try:
            build_json = ci_build.azure_get(f"{api}?api-version=7.1")
        except request_util.REQUEST_ERRORS as e:
            self.warn(f"cannot read Azure Pipelines build {build_url}: {request_util.failure(e)}")
            return
        print(f"Azure Pipelines build {build_json['definition']['name']}: {build_url}")
        if build_json["status"] != "completed":
            print(
                f"  Its status is {build_json['status']}.  Run {PROGRAM} again after it finishes."
            )
            return
        if build_json["result"] != "failed":
            print(f"  Its result is {build_json['result']}.")
            return

        try:
            records = ci_build.azure_get(f"{api}/timeline?api-version=7.1")["records"]
        except request_util.REQUEST_ERRORS as e:
            self.warn(
                f"cannot read the timeline of Azure Pipelines build {build_url}:"
                f" {request_util.failure(e)}"
            )
            return

        # For each stage that has a failed job:  whether each of its failed jobs failed
        # transiently, could not be read, or did not fail transiently.
        stage_results: dict[str, set[str]] = {}
        stage_attempts: dict[str, int] = {}
        by_id = {r["id"]: r for r in records}
        for job in (r for r in records if r["type"] == "Job" and r["result"] in AZURE_FAILED):
            stage = azure_stage(job, by_id)
            name = stage.get("identifier") or ""
            stage_attempts[name] = max(
                stage_attempts.get(name, 0), stage.get("attempt") or job.get("attempt") or 1
            )
            log = azure_job_log(api, job, records)
            reason = transient_reason(log.text)
            if reason is not None:
                print(f"  {job['name']}: transient: {reason}")
                result = "transient"
            elif log.read:
                print(f"  {job['name']}: not transient")
                result = "not transient"
            else:
                self.warn(f"cannot read the log of Azure Pipelines job {job['name']} ({job['id']})")
                result = "unreadable"
            stage_results.setdefault(name, set()).add(result)

        if not any("transient" in results for results in stage_results.values()):
            return
        if all(results == {"transient"} for results in stage_results.values()):
            attempts = max(stage_attempts.values())
            if attempts >= self.max_attempts:
                print(f"  Not rerunning:  the build has already been run {attempts} times.")
                return
            url, body, what = f"{api}?retry=true&api-version=7.1", {}, "the failed jobs"
        else:
            stages = []
            for name, results in sorted(stage_results.items()):
                if "transient" not in results:
                    continue
                if "not transient" in results:
                    print(
                        f"  Not rerunning stage {name or 'of the build'}:  it has a failed job"
                        " that did not fail transiently, and Azure Pipelines reruns all the"
                        " failed jobs of a stage."
                    )
                elif "unreadable" in results:
                    print(
                        f"  Not rerunning stage {name or 'of the build'}:  it has a failed job"
                        " whose log could not be read, and Azure Pipelines reruns all the"
                        " failed jobs of a stage."
                    )
                elif stage_attempts[name] >= self.max_attempts:
                    print(
                        f"  Not rerunning stage {name}:  it has already been run"
                        f" {stage_attempts[name]} times."
                    )
                else:
                    stages.append(name)
            if not stages:
                return
            url = f"{api}/stages/{stages[0]}?api-version=7.1"
            body = {"state": "retry", "forceRetryAllJobs": False}
            what = f"the failed jobs of stage {stages[0]}"
            if len(stages) > 1:
                what += " (rerun the other stages after the build finishes)"

        def rerunning() -> None:
            ci_build.azure_request("PATCH", url, ci_build.azure_headers(), body)

        try:
            self.rerun(what, rerunning)
        except request_util.REQUEST_ERRORS as e:
            hint = (
                "do the credentials have the Build (Read & execute) scope?"
                if ci_build.azure_headers()
                else "AZURE_DEVOPS_EXT_PAT is not set and `az login` has not been run"
            )
            self.warn(
                f"cannot rerun Azure Pipelines build {build_url}: {request_util.failure(e)}; {hint}"
            )

    def azure_rerun_failed_url(self, url: str) -> None:
        """Rerun the transiently failed jobs of the Azure Pipelines build that url names.

        Args:
            url: a URL of an Azure Pipelines build, or of one of its jobs.
        """
        parsed = ci_build.AzureBuildUrlParts.from_url(url)
        if parsed is None:
            self.warn(f"cannot find an Azure Pipelines build in {url}")
            return
        if self.record_if_unexamined(("azure", parsed.org, parsed.project, parsed.build)):
            self.azure_rerun_failed(parsed.org, parsed.project, parsed.build)

    ###########################################################################
    ### CircleCI
    ###

    def circleci_rerun_failed(self, workflow: str, only_job: int | None = None) -> None:
        """Rerun the transiently failed jobs of the given CircleCI workflow, or only the given one.

        Args:
            workflow: a workflow's id, a UUID such as "ecc46ce8-..." in
                "https://app.circleci.com/workflow/ecc46ce8-...".
            only_job: the number of a job of the workflow to examine, an integer such as
                230602 in ".../workflows/ecc46ce8-.../jobs/230602", or None to examine
                every job.
        """
        api = f"{ci_build.CIRCLECI_API}/v2"
        try:
            wf = request_util.request_object(
                "GET", f"{api}/workflow/{workflow}", ci_build.circleci_headers()
            )
        except request_util.REQUEST_ERRORS as e:
            self.warn(f"cannot read CircleCI workflow {workflow}: {request_util.failure(e)}")
            return
        pipeline = (
            f"https://app.circleci.com/pipelines/{wf['project_slug']}/{wf['pipeline_number']}"
        )
        print(f"CircleCI workflow {wf['name']}: {pipeline}/workflows/{workflow}")

        # The workflows of the pipeline that have the same name, oldest first.
        # Rerunning a workflow creates another one in the same pipeline.
        try:
            same_name = sorted(
                (
                    w
                    for w in ci_build.circleci_items(f"/v2/pipeline/{wf['pipeline_id']}/workflow")
                    if w["name"] == wf["name"]
                ),
                key=operator.itemgetter("created_at"),
            )
        except request_util.REQUEST_ERRORS as e:
            self.warn(
                f"cannot read the workflows of CircleCI pipeline {wf['pipeline_id']}:"
                f" {request_util.failure(e)}"
            )
            return
        if same_name and same_name[-1]["id"] != workflow:
            print(f"  It has been rerun, as {pipeline}/workflows/{same_name[-1]['id']}")
            return
        attempts = len(same_name)

        if wf["status"] in {"success", "canceled", "unauthorized", "not_run"}:
            print(f"  Its status is {wf['status']}.")
            return
        if wf["status"] not in {"failed", "error"}:
            print(f"  Its status is {wf['status']}.  Run {PROGRAM} again after it finishes.")
            return

        try:
            failed_jobs = [
                j
                for j in ci_build.circleci_items(f"/v2/workflow/{workflow}/job")
                if j["status"] in CIRCLECI_FAILED
            ]
        except request_util.REQUEST_ERRORS as e:
            self.warn(
                f"cannot read the jobs of CircleCI workflow {workflow}: {request_util.failure(e)}"
            )
            return
        if only_job is not None:
            failed_jobs = [j for j in failed_jobs if j.get("job_number") == only_job]
            if not failed_jobs:
                print(f"  Job {only_job} is not a failed job of the workflow.")
                return

        rerun_ids = []
        all_transient = True
        for job in failed_jobs:
            if job["status"] == "infrastructure_fail":
                reason = "CircleCI infrastructure failure"
            else:
                try:
                    log = circleci_job_log(wf["project_slug"], job["job_number"])
                except request_util.REQUEST_ERRORS as e:
                    self.warn(
                        f"cannot read the log of CircleCI job {job['name']}"
                        f" ({job['job_number']}): {request_util.failure(e)}"
                    )
                    all_transient = False
                    continue
                reason = transient_reason(log)
                if reason is None:
                    print(f"  {job['name']}: not transient")
                    all_transient = False
                    continue
            print(f"  {job['name']}: transient: {reason}")
            rerun_ids.append(job["id"])

        if not rerun_ids:
            return
        if attempts >= self.max_attempts:
            print(f"  Not rerunning:  the workflow has already been run {attempts} times.")
            return
        if all_transient and only_job is None:
            body, what = {"from_failed": True}, "the failed jobs"
        else:
            body, what = {"jobs": rerun_ids}, "the transiently failed jobs"

        def rerunning() -> str | None:
            result = request_util.request_object(
                "POST", f"{api}/workflow/{workflow}/rerun", ci_build.circleci_headers(), body
            )
            new_workflow = result.get("workflow_id")
            return f"{pipeline}/workflows/{new_workflow}" if new_workflow else None

        try:
            self.rerun(what, rerunning)
        except request_util.REQUEST_ERRORS as e:
            hint = "" if ci_build.circleci_token() else "; there is no CircleCI token"
            self.warn(f"cannot rerun CircleCI workflow {workflow}: {request_util.failure(e)}{hint}")

    def circleci_rerun_failed_url(self, url: str, whole_workflow: bool = False) -> None:
        """Rerun the transiently failed jobs that the given CircleCI URL names.

        Args:
            url: a URL of a CircleCI workflow, or of a job.
            whole_workflow: True if a URL that names a job names the jobs of its workflow.
        """
        parsed = ci_build.CircleciUrlParts.from_url(url)
        try:
            workflow = parsed.lookup_workflow() if parsed else None
        except request_util.REQUEST_ERRORS as e:
            self.warn(f"cannot read CircleCI job {url}: {request_util.failure(e)}")
            return
        if parsed is None or workflow is None:
            self.warn(f"cannot find a CircleCI workflow in {url}")
            return
        job = None if whole_workflow else parsed.job
        if job is not None:
            self.circleci_rerun_failed(workflow, job)
        elif self.record_if_unexamined(("circleci", workflow)):
            self.circleci_rerun_failed(workflow)

    ###########################################################################
    ### GitHub Actions
    ###

    def gha_rerun_failed(self, repo: str, run: int, only_job: int | None = None) -> None:
        """Rerun the transiently failed jobs of the given GitHub Actions run, or only the given one.

        Args:
            repo: a repository's GitHub slug, such as "ORG/REPO".
            run: the id of a workflow run of the repository, an integer such as 123 in
                "https://github.com/ORG/REPO/actions/runs/123".
            only_job: the id of a job of the run to examine, an integer such as 456 in
                ".../actions/runs/123/job/456", or None to examine every job.
        """
        try:
            run_json = request_util.gh_api(f"repos/{repo}/actions/runs/{run}")
        except request_util.REQUEST_ERRORS as e:
            self.warn(f"cannot read GitHub Actions workflow run {run}: {request_util.failure(e)}")
            return
        print(
            f"GitHub Actions workflow run {run_json['name']}:"
            f" https://github.com/{repo}/actions/runs/{run}"
        )
        if run_json["status"] != "completed":
            print(f"  Its status is {run_json['status']}.  Run {PROGRAM} again after it finishes.")
            return
        if run_json["conclusion"] not in {"failure", GITHUB_CANCELLED}:
            print(f"  Its conclusion is {run_json['conclusion']}.")
            return

        # The jobs of the latest attempt of the run, and the jobs of every attempt.
        try:
            latest_jobs = gha_jobs(repo, run, "latest")
            all_jobs = gha_jobs(repo, run, "all")
        except request_util.REQUEST_ERRORS as e:
            self.warn(
                f"cannot read the jobs of GitHub Actions workflow run {run}:"
                f" {request_util.failure(e)}"
            )
            return
        # The failure annotations of each job whose annotations have been read, or None
        # for a job whose annotations cannot be read.
        annotations: dict[int, list[str] | None] = {}

        def job_annotations(job_id: int) -> list[str] | None:
            if job_id not in annotations:
                try:
                    annotations[job_id] = gha_failure_annotations(repo, job_id)
                except request_util.REQUEST_ERRORS:
                    annotations[job_id] = None
            return annotations[job_id]

        # The annotation that shows that the run's concurrency group cancelled the run, as
        # for gha_concurrency_cancellation.  It is computed only if some job needs it,
        # because it reads the newer runs.
        concurrency_cancellation = functools.cache(
            lambda: self.gha_concurrency_cancellation(repo, run_json, latest_jobs, job_annotations)
        )
        failed_jobs = [
            j for j in latest_jobs if j["conclusion"] in {*GITHUB_FAILED, GITHUB_CANCELLED}
        ]
        if only_job is not None:
            failed_jobs = [j for j in failed_jobs if j["id"] == only_job]
            if not failed_jobs:
                print(f"  Job {only_job} is not a failed job of the latest attempt.")
                return

        # How many times each job has been run.  Rerunning one job starts a new attempt
        # of the whole run, so the run's attempt count is not the job's.  Each attempt
        # lists every job of the run, with a new id even for a job that the attempt did
        # not rerun; such a job keeps the start time of the run that it repeats.  So a
        # job's runs are its distinct start times, not its ids.
        runs_of_job: dict[str, set[str]] = {}
        for j in all_jobs:
            runs_of_job.setdefault(j["name"], set()).add(j.get("started_at") or str(j["id"]))

        # When the run was cancelled, if it was:  the earliest time at which a cancelled
        # job of the run completed, a timestamp such as "2026-11-24T23:36:11Z", or None if
        # GitHub provides no such time.  A job that was running when the run was cancelled
        # can complete much later.
        cancel_time = min(
            (
                j["completed_at"]
                for j in latest_jobs
                if j["conclusion"] == GITHUB_CANCELLED and j.get("completed_at")
            ),
            default=None,
        )

        rerun_ids = []
        all_transient = True
        # The first job to rerun that failed because the jobs that it needs were cancelled.
        needs_cancelled = None
        for job in failed_jobs:
            log = gha_job_log(repo, job["id"], job_annotations(job["id"]))
            reason = transient_reason(log.text)
            started_after = False
            if reason is None and job["conclusion"] == GITHUB_CANCELLED:
                if GHA_CONCURRENCY_CANCEL_RE.search(log.text):
                    reason = concurrency_cancellation()
            elif (
                reason is None
                and cancel_time is not None
                and (job.get("started_at") or "") >= cancel_time
            ):
                cancellation = concurrency_cancellation()
                if cancellation is not None:
                    reason = f"started after the run was cancelled: {cancellation}"
                    started_after = True
            if reason is None:
                if job["conclusion"] == GITHUB_CANCELLED:
                    # A cancelled job has no failed steps, so the only part of its log
                    # is its failure annotations, and an empty log is not a problem.
                    print(f"  {job['name']}: cancelled, not transient")
                    continue
                if log.read:
                    print(f"  {job['name']}: not transient")
                else:
                    self.warn(
                        f"cannot read the log of the failed steps of GitHub Actions job"
                        f" {job['name']} ({job['id']})"
                    )
                all_transient = False
                continue
            print(f"  {job['name']}: transient: {reason}")
            attempts = len(runs_of_job.get(job["name"], ()))
            if attempts >= self.max_attempts:
                print(f"  Not rerunning {job['name']}:  it has already been run {attempts} times.")
                all_transient = False
                continue
            rerun_ids.append(job["id"])
            if started_after and needs_cancelled is None:
                needs_cancelled = job["name"]

        if not rerun_ids:
            return
        if all_transient and only_job is None:
            args, what = ["--failed", str(run)], "the failed jobs"
        elif needs_cancelled is not None:
            args = ["--failed", str(run)]
            what = (
                f"the failed jobs (rerunning job {needs_cancelled} alone would not rerun"
                " the cancelled jobs that it needs)"
            )
        else:
            args, what = ["--job", str(rerun_ids[0])], f"job {rerun_ids[0]}"
            if len(rerun_ids) > 1:
                what += " (rerun the other transiently failed jobs after the workflow run finishes)"

        def rerunning() -> None:
            request_util.run(["gh", "run", "rerun", "--repo", repo, *args])

        try:
            self.rerun(what, rerunning)
        except request_util.REQUEST_ERRORS as e:
            self.warn(f"cannot rerun GitHub Actions workflow run {run}: {request_util.failure(e)}")

    def gha_concurrency_cancellation(
        self,
        repo: str,
        run_json: dict[str, Any],
        jobs: list[dict[str, Any]],
        annotations_of: Callable[[int], list[str] | None],
    ) -> str | None:
        """Return the annotation that shows that the given run's concurrency group cancelled it.

        The cancellation is transient, and the annotation is returned, only if
        gha_newer_run finds no newer run, so that the waiting request in whose favor the
        run was cancelled never became a run.

        Args:
            repo: a repository's GitHub slug, such as "ORG/REPO".
            run_json: a workflow run of the repository, as a dict parsed from the GitHub
                API's JSON, with keys such as "id", "workflow_id", and "head_branch".
            jobs: the jobs of the latest attempt of the run, as for gha_jobs.
            annotations_of: a function that returns the failure annotations of a job,
                given its id, as gha_failure_annotations does, or None if they cannot be
                read.

        Returns:
            The failure annotation of a cancelled job of the run, such as "Canceling
            since a higher priority waiting request for CI-8598 exists", or None if the
            concurrency group did not cancel the run, or gha_newer_run finds a newer run,
            or the newer runs cannot be read.
        """
        if run_json["conclusion"] != GITHUB_CANCELLED:
            return None
        cancelled = [j for j in jobs if j["conclusion"] == GITHUB_CANCELLED]
        reason = next(
            (
                a
                for j in cancelled
                for a in annotations_of(j["id"]) or []
                if GHA_CONCURRENCY_CANCEL_RE.search(a)
            ),
            None,
        )
        if reason is None:
            return None
        try:
            newer = gha_newer_run(repo, run_json)
        except request_util.REQUEST_ERRORS as e:
            self.warn(
                f"cannot read the newer runs for the branch of GitHub Actions workflow run"
                f" {run_json['id']}: {request_util.failure(e)}"
            )
            return None
        if newer is not None:
            print(f"  Its concurrency group cancelled it in favor of a newer run: {newer}")
            return None
        return reason

    def gha_rerun_failed_url(self, url: str, whole_run: bool = False) -> None:
        """Rerun the transiently failed jobs that the given GitHub Actions URL names.

        Args:
            url: a URL of a GitHub Actions workflow run, or of a job.
            whole_run: True if a URL that names a job names the jobs of its run.
        """
        parsed = ci_build.GithubActionsRunUrlParts.from_url(url)
        if parsed is None:
            self.warn(f"cannot find a GitHub Actions workflow run in {url}")
            return
        job = None if whole_run else parsed.job
        if job is not None:
            self.gha_rerun_failed(parsed.repo, parsed.run, job)
        elif self.record_if_unexamined(("gha", parsed.repo, parsed.run)):
            self.gha_rerun_failed(parsed.repo, parsed.run)

    ###########################################################################
    ### Dispatching
    ###

    def url_rerun_failed(self, url: str, whole_workflow: bool = False) -> bool:
        """Rerun the transiently failed jobs that the given CI URL names.

        Args:
            url: a URL of a build, workflow, workflow run, or job.
            whole_workflow: True if a URL that names a job names the jobs of its
                build, workflow, or workflow run.

        Returns:
            True if url is the URL of a supported CI service.
        """
        if ci_build.AzureBuildUrlParts.from_url(url) is not None:
            self.azure_rerun_failed_url(url)
        elif ci_build.CircleciUrlParts.from_url(url) is not None:
            self.circleci_rerun_failed_url(url, whole_workflow)
        elif ci_build.GithubActionsRunUrlParts.from_url(url) is not None:
            self.gha_rerun_failed_url(url, whole_workflow)
        else:
            return False
        return True

    def pr_rerun_failed(self, pr: str | None = None) -> None:
        """Rerun the transiently failed checks of the given pull request.

        Args:
            pr: a pull request (a number, URL, or branch), or None for the pull request
                of the current branch.
        """
        description = pr or "for the current branch"
        try:
            checks = request_util.run(
                ["gh", "pr", "checks", *([pr] if pr else []), "--json", "name,bucket,state,link"]
            )
            failed = [c for c in json.loads(checks) if c["bucket"] in PR_CHECK_FAILED]
        except request_util.REQUEST_ERRORS as e:
            if is_no_pr_error(e):
                try:
                    parent_pr = fork_parent_pr(pr)
                except request_util.REQUEST_ERRORS as parent_error:
                    self.warn(
                        f"cannot read the checks of pull request {description}:"
                        f" {request_util.failure(e)}; cannot look for one in the parent"
                        f" repository: {request_util.failure(parent_error)}"
                    )
                    return
                if parent_pr is not None:
                    branch_description = f"branch {pr}" if pr else "the current branch"
                    print(f"Pull request for {branch_description}: {parent_pr}")
                    self.pr_rerun_failed(parent_pr)
                    return
            self.warn(
                f"cannot read the checks of pull request {description}: {request_util.failure(e)}"
            )
            return
        if not failed:
            print(f"No failed checks for pull request {description}.")
            return
        for check in failed:
            if check.get("state") == "ACTION_REQUIRED":
                print(
                    f"{check['name']}: skipping a check that requires action, such as approval:"
                    f" {check['link']}"
                )
                continue
            # A check's link can name one job.  Examine the whole build, workflow, or
            # workflow run, so that its failed jobs are rerun together:  rerunning one job
            # of a CircleCI workflow creates a new workflow, so a later job of the old
            # workflow would appear to have been rerun already.
            if not self.url_rerun_failed(check["link"], whole_workflow=True):
                print(
                    f"{check['name']}: skipping a check from an unsupported CI service:"
                    f" {check['link']}"
                )


def is_no_pr_error(error: BaseException) -> bool:
    """Return True if the given error shows that `gh` found no pull request for a branch.

    Args:
        error: an error that a `gh pr` command raised.

    Returns:
        True if error is the failure of a `gh` command that reported, as in
        'no pull requests found for branch "BRANCH"', that the branch has no pull request.
    """
    return isinstance(error, subprocess.CalledProcessError) and "no pull requests found" in (
        error.stderr or ""
    )


def pushed_branch() -> str:
    """Return the name of the remote branch that `git push` updates from the current branch.

    For example, for a local branch "wip" whose push destination is the remote-tracking
    branch "origin/fix-timeout", this is "fix-timeout".  It is the name that `gh` uses to
    find the pull request of the current branch.

    If a command fails, this raises one of request_util.REQUEST_ERRORS.

    Returns:
        The name of the remote branch, such as "fix-timeout"; the name of the current
        branch if git does not know where the current branch is pushed; or "" if no branch
        is checked out.
    """
    branch = request_util.run(["git", "branch", "--show-current"]).strip()
    if not branch:
        return ""
    # A remote's name cannot contain a tab.
    remote, _, push = (
        request_util.run(
            ["git", "for-each-ref", "--format=%(push:remotename)%09%(push)", f"refs/heads/{branch}"]
        )
        .rstrip("\n")
        .partition("\t")
    )
    prefix = f"refs/remotes/{remote}/"
    return push[len(prefix) :] if remote and push.startswith(prefix) else branch


def fork_parent_pr(branch: str | None = None) -> str | None:
    """Return the URL of the open pull request in the parent repository for the given branch.

    The parent repository is the one that the current clone's GitHub repository, as `gh`
    resolves it, is a fork of.  For example, in a clone whose only remote is the fork
    ME/REPO of ORG/REPO, the pull request is one in ORG/REPO whose head is the branch of
    ME/REPO.

    If a command fails, this raises one of request_util.REQUEST_ERRORS.

    Args:
        branch: a branch of the current clone's GitHub repository, such as "feature", or
            None for the branch that the current branch is pushed to.

    Returns:
        The URL of the pull request, such as "https://github.com/ORG/REPO/pull/123", or
        None if the current clone's GitHub repository is not a fork, if branch is None
        and no branch is checked out, or if the parent repository has no such open pull
        request.
    """
    if branch is None:
        branch = pushed_branch()
    if not branch:
        return None
    repo = json.loads(request_util.run(["gh", "repo", "view", "--json", "owner,parent"]))
    parent = repo.get("parent")
    if not parent:
        return None
    parent_slug = f"{parent['owner']['login']}/{parent['name']}"
    # The head filter "OWNER:BRANCH" selects only this fork's pull requests, so pull
    # requests from other forks' branches of the same name cannot crowd this one out of
    # the first page of results.
    head = urllib.parse.quote(f"{repo['owner']['login']}:{branch}", safe="")
    prs = request_util.gh_api(f"repos/{parent_slug}/pulls?head={head}&state=open")
    return prs[0]["html_url"] if prs else None


###########################################################################
### Reading logs
###


class JobLog(NamedTuple):
    """The log of the failed steps of a CI job, and the errors that the CI service reports.

    Attributes:
        text: the log, followed by the errors that the CI service reports for the job.
            The errors describe failures, such as a lost runner or a job that no runner
            picked up, that leave no log.
        read: True if the log could be read.  If it could not, text contains only the
            errors.
    """

    text: str
    read: bool


def azure_stage(record: dict[str, Any], by_id: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """Return the stage that contains the given record of an Azure Pipelines timeline.

    A record's parent is a stage, a phase, or a job.

    Args:
        record: a record of a timeline, as a dict parsed from the Azure DevOps API's
            JSON, with keys such as "id", "type" (such as "Stage" or "Job"), and
            "parentId".
        by_id: the map from the id of each record of the timeline to the record.

    Returns:
        The stage's record, or an empty dict if there is none.
    """
    while record.get("type") != "Stage":
        record = by_id.get(record.get("parentId"), {})
        if not record:
            return {}
    return record


def azure_job_log(api: str, job: dict[str, Any], records: list[dict[str, Any]]) -> JobLog:
    """Return the logs of the failed tasks of the given Azure Pipelines job, and its errors.

    The errors in the result are the ones that the job and its tasks report.  Warnings
    are omitted, because a task that succeeded can report them.  The result's log is
    unreadable if the log of some failed task cannot be read.

    Args:
        api: the URL of the job's build in the Azure DevOps API.
        job: a job's record in the timeline, as for azure_stage.
        records: the timeline of the job's build, a list of records.

    Returns:
        The logs and the errors.
    """
    failed_tasks = [
        r for r in records if r.get("parentId") == job["id"] and r["result"] in AZURE_FAILED
    ]
    parts = []
    read = True
    for task in failed_tasks:
        if (task.get("log") or {}).get("id") is None:
            continue
        try:
            parts.append(
                ci_build.azure_get(f"{api}/logs/{task['log']['id']}?api-version=7.1", text=True)
            )
        except request_util.REQUEST_ERRORS:
            read = False
    parts.extend(
        issue["message"]
        for r in [job, *failed_tasks]
        for issue in r.get("issues") or []
        if issue.get("type") == "error" and issue.get("message")
    )
    return JobLog("\n".join(parts), read)


def circleci_job_log(slug: str, job: int) -> str:
    """Return the output of the failed steps of the given CircleCI job.

    Args:
        slug: the job's project slug, such as "gh/ORG/REPO".
        job: a job's number, an integer such as 230602 in ".../jobs/230602".

    Returns:
        The output.
    """
    vcs, _, project = slug.partition("/")
    v1_vcs = ci_build.CIRCLECI_VCS_NAMES.get(vcs)
    if v1_vcs is None:
        msg = f"cannot read the log of a job of CircleCI project {slug}"
        raise ValueError(msg)
    details = request_util.request_object(
        "GET",
        f"{ci_build.CIRCLECI_API}/v1.1/project/{v1_vcs}/{project}/{job}",
        ci_build.circleci_headers(),
    )
    output = []
    for step in details["steps"]:
        for action in step["actions"]:
            if action.get("status") in {"failed", "timedout"} and action.get("output_url"):
                output.extend(
                    m["message"] for m in request_util.request("GET", action["output_url"])
                )
    return "\n".join(output)


def gha_jobs(repo: str, run: int, which: str) -> list[dict[str, Any]]:
    """Return the jobs of the given GitHub Actions workflow run.

    Args:
        repo: a repository's GitHub slug, such as "ORG/REPO".
        run: the id of a workflow run of the repository, an integer such as 123 in
            "https://github.com/ORG/REPO/actions/runs/123".
        which: "latest" for the jobs of the latest attempt, or "all" for the jobs of
            every attempt.

    Returns:
        The jobs, each a dict parsed from the GitHub API's JSON, with keys such as "id",
        "name", and "conclusion".
    """
    pages = request_util.gh_api(
        f"repos/{repo}/actions/runs/{run}/jobs?filter={which}&per_page=100", paginate=True
    )
    return [job for page in pages for job in page["jobs"]]


def gha_job_log(repo: str, job: int, annotations: list[str] | None) -> JobLog:
    """Return the log of the given GitHub Actions job's failed steps, and the given annotations.

    The errors in the result are the job's failure annotations.  Warning and notice
    annotations are omitted, because a step that succeeded can produce them.  The log is
    unreadable if `gh` fails or prints nothing, as it does for a job that has no failed
    step or whose log it cannot find.

    Args:
        repo: a repository's GitHub slug, such as "ORG/REPO".
        job: the id of a job of the repository, an integer such as 456 in
            "https://github.com/ORG/REPO/actions/runs/123/job/456".
        annotations: the job's failure annotations, as gha_failure_annotations returns
            them, or None if they cannot be read.

    Returns:
        The log and the failure annotations.
    """
    try:
        log = request_util.run(
            ["gh", "run", "view", "--repo", repo, "--job", str(job), "--log-failed"]
        )
    except request_util.REQUEST_ERRORS:
        log = ""
    # Each line starts with the job name and the step name, each followed by a tab.
    parts = [line.split("\t", 2)[-1] for line in log.splitlines()]
    read = any(part.strip() for part in parts)
    parts.extend(annotations or [])
    return JobLog("\n".join(parts), read)


def gha_failure_annotations(repo: str, job: int) -> list[str]:
    """Return the messages of the failure annotations of the given GitHub Actions job.

    Warning and notice annotations are omitted.  If `gh` fails, this raises one of
    request_util.REQUEST_ERRORS.

    Args:
        repo: a repository's GitHub slug, such as "ORG/REPO".
        job: the id of a job of the repository, as for gha_job_log.

    Returns:
        The messages, such as "The runner has received a shutdown signal.".
    """
    pages = request_util.gh_api(
        f"repos/{repo}/check-runs/{job}/annotations?per_page=100", paginate=True
    )
    return [a["message"] for page in pages for a in page if a.get("annotation_level") == "failure"]


def gha_newer_run(repo: str, run_json: dict[str, Any]) -> str | None:
    """Return the URL of a newer workflow run of the given run's repository, for the same branch.

    The newer run can be of any workflow and for any event, because a concurrency group
    can span workflows and events, except that a run of another workflow for the same
    commit is not considered newer:  the event that started the given run usually started
    it too.  The branch is the run's head branch in the run's head repository, which for
    a pull request from a fork is the fork.  If `gh` fails, this raises one of
    request_util.REQUEST_ERRORS.

    Args:
        repo: a repository's GitHub slug, such as "ORG/REPO".
        run_json: a workflow run of the repository, as for
            Rerunner.gha_concurrency_cancellation.

    Returns:
        The URL of the newer run, such as "https://github.com/ORG/REPO/actions/runs/124",
        or None if the repository has no newer run for the branch.
    """
    head_repo = (run_json.get("head_repository") or {}).get("full_name")
    query = {
        **({"branch": run_json["head_branch"]} if run_json.get("head_branch") else {}),
        "created": f">={run_json['created_at']}",
        "per_page": 100,
    }
    pages = request_util.gh_api(
        f"repos/{repo}/actions/runs?{urllib.parse.urlencode(query)}", paginate=True
    )
    return next(
        (
            r["html_url"]
            for page in pages
            for r in page["workflow_runs"]
            if (r["created_at"], r["id"]) > (run_json["created_at"], run_json["id"])
            and r.get("head_branch") == run_json.get("head_branch")
            and (r.get("head_repository") or {}).get("full_name") == head_repo
            and (
                r["workflow_id"] == run_json["workflow_id"]
                or r.get("head_sha") != run_json.get("head_sha")
            )
        ),
        None,
    )


###########################################################################
### Main routine
###


def positive_integer(text: str) -> int:
    """Return the positive integer that the given text denotes, for argparse.

    If text does not denote a positive integer, this raises argparse.ArgumentTypeError.

    Args:
        text: a command-line argument, such as "3".

    Returns:
        The integer.
    """
    try:
        value = int(text)
    except ValueError:
        value = 0
    if value < 1:
        msg = f"requires a positive number: {text}"
        raise argparse.ArgumentTypeError(msg)
    return value


def main() -> int:
    """Rerun, or with --classify classify, according to the command line.

    Returns:
        The exit status.
    """
    parser = argparse.ArgumentParser(
        prog=PROGRAM,
        description=__doc__.splitlines()[0] if __doc__ else None,
    )
    parser.add_argument("-n", "--dry-run", action="store_true", help="report but do not rerun")
    parser.add_argument(
        "--max-attempts", type=positive_integer, default=3, help="the most runs of a job"
    )
    parser.add_argument(
        "--exit-3-if-reran", action="store_true", help="exit with status 3 if a job was rerun"
    )
    parser.add_argument(
        "--classify", action="store_true", help="classify log files; contact no CI server"
    )
    parser.add_argument("args", nargs="*", metavar="PR | BRANCH | URL | LOG-FILE")
    args = parser.parse_args()

    if args.classify:
        return classify(args.args)

    if shutil.which("gh") is None:
        sys.exit(f"{PROGRAM}: requires the gh command")
    rerunner = Rerunner(args.dry_run, args.max_attempts)
    if not args.args:
        rerunner.pr_rerun_failed()
    for arg in args.args:
        if not rerunner.url_rerun_failed(arg):
            rerunner.pr_rerun_failed(arg)
    if args.exit_3_if_reran and rerunner.reran:
        return 3
    return rerunner.status


if __name__ == "__main__":
    sys.exit(main())
