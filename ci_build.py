"""Access the builds of CI services:  GitHub Actions, Azure Pipelines, and CircleCI.

This module recognizes the URLs of builds and jobs, finds credentials, and makes
requests of the services' APIs.  GitHub requests go through the `gh` command, which
handles authentication.

Credentials:
  Azure Pipelines: none to read a public project; otherwise a personal access token in
    $AZURE_DEVOPS_EXT_PAT, or else the account that `az login` logged in.
  CircleCI: a personal API token in $CIRCLECI_CLI_TOKEN, or else the one in
    ~/.circleci/cli.yml or (for the snap package) ~/snap/circleci/current/.circleci/cli.yml,
    as written by `circleci setup`.
"""

from __future__ import annotations

import base64
import functools
import gzip
import json
import os
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

# The URL of an Azure Pipelines build or of one of its jobs, such as
# "https://dev.azure.com/checkerframework/4dcb7892-.../_build/results?buildId=24267&view=logs".
# The groups are the organization (for dev.azure.com), the organization (for
# visualstudio.com), the project, and the build.
AZURE_BUILD = re.compile(
    r"https://(?:dev\.azure\.com/([^/?#]+)|([^/.]+)\.visualstudio\.com)/([^/?#]+)"
    r"/_build/results\?(?:[^#]*&)?buildId=(\d+)"
)
# The URL of a CircleCI workflow, such as "https://app.circleci.com/workflow/ecc46ce8-..."
# or "https://app.circleci.com/pipelines/gh/ORG/REPO/7/details?workflowId=ecc46ce8-...".
CIRCLECI_WORKFLOW = re.compile(
    r"circleci\.com/.*(?:\bworkflows?(?:-run)?/|[?&]workflowId=)([0-9a-f-]{36})"
)
# The number of a CircleCI job, in the URL of a job of a workflow, such as
# ".../workflows/ecc46ce8-.../jobs/230602" or ".../details?...&buildNumber=230602".
CIRCLECI_JOB_OF_WORKFLOW = re.compile(r"circleci\.com/.*(?:/jobs/|[?&]buildNumber=)(\d+)")
# The URL of a CircleCI job in a GitHub commit status, such as
# "https://circleci.com/gh/circleci/circleci-docs/230602?utm_campaign=...".
# The groups are the project slug and the job number.
CIRCLECI_JOB = re.compile(r"https://circleci\.com/((?:gh|bb)/[^/]+/[^/?#]+)/(\d+)(?:[?#]|$)")
# The URL of a GitHub Actions workflow run or of one of its jobs, such as
# "https://github.com/ORG/REPO/actions/runs/123/job/456".  The groups are the
# repository, the run, and the job.
GITHUB_ACTIONS_RUN = re.compile(
    r"https://github\.com/([^/]+/[^/]+)/actions/runs/(\d+)(?:/attempts/\d+)?(?:/job/(\d+))?"
)

CIRCLECI_API = "https://circleci.com/api"
# The Azure DevOps resource, for which `az` issues access tokens.
AZURE_DEVOPS_RESOURCE = "499b84ac-1321-427f-aa17-267ca6975798"
# The configuration files of the CircleCI CLI, which `circleci setup` writes.
CIRCLECI_CONFIGS = ("~/.circleci/cli.yml", "~/snap/circleci/current/.circleci/cli.yml")


###########################################################################
### Commands and HTTP requests
###


def run(cmd: list[str]) -> str:
    """Run a command, which must succeed.

    Returns:
        The command's standard output.
    """
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def gh_api(path: str, *, paginate: bool = False) -> Any:
    """Make a GitHub API request with `gh api`.

    Args:
        path: the request, such as "repos/ORG/REPO/actions/runs/123".
        paginate: whether to read every page of the response.

    Returns:
        The response, parsed as JSON; with paginate, a list of the pages.
    """
    if paginate:
        return json.loads(run(["gh", "api", "--paginate", "--slurp", path]))
    return json.loads(run(["gh", "api", path]))


def http(method: str, url: str, headers: dict[str, str] | None = None, body: Any = None) -> bytes:
    """Make an HTTP request.

    Args:
        method: the HTTP method, such as "GET".
        url: the URL.
        headers: the HTTP headers.
        body: the request body, which is sent as JSON, or None for no body.

    Returns:
        The response body, decompressed if the server compressed it.

    Raises:
        urllib.error.HTTPError: if the server refuses the request, or if it responds
            with a sign-in page, as Azure DevOps does to a request that lacks
            the needed credentials.
    """
    headers = dict(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as response:
        if response.status == 203:
            msg = "a sign-in page instead of the requested data"
            raise urllib.error.HTTPError(url, response.status, msg, response.headers, None)
        content = response.read()
        if response.headers.get("Content-Encoding") == "gzip":
            content = gzip.decompress(content)
    return content


def request(method: str, url: str, headers: dict[str, str] | None = None, body: Any = None) -> Any:
    """Make an HTTP request whose response is JSON.

    Returns:
        The response body, parsed as JSON, or None if it is empty.
    """
    content = http(method, url, headers, body)
    return json.loads(content) if content else None


def failure(e: Exception) -> str:
    """Describe a failed command or HTTP request.

    Returns:
        A description of e, including any error output or error response.
    """
    if isinstance(e, subprocess.CalledProcessError):
        return (e.stderr or "").strip() or str(e)
    if isinstance(e, urllib.error.HTTPError):
        body = e.read().decode(errors="replace") if e.fp else ""
        return f"{e} {error_message(body)}".strip()
    return str(e)


def error_message(text: str) -> str:
    """Extract the explanation from the body of an HTTP error response.

    The body can be a long HTML page.

    Returns:
        One line:  the "message" of a JSON body, the title of an HTML body, or else the
        start of the body.
    """
    try:
        body = json.loads(text)
        if isinstance(body, dict) and isinstance(body.get("message"), str):
            text = body["message"]
    except ValueError:
        if match := re.search(r"<title>(.*?)</title>", text, re.DOTALL | re.IGNORECASE):
            text = match[1]
    text = " ".join(text.split())
    return text if len(text) <= 200 else text[:200] + "..."


###########################################################################
### Azure Pipelines
###


@functools.cache
def azure_headers() -> dict[str, str]:
    """Determine how to authenticate to Azure DevOps.

    Returns:
        The HTTP headers that authenticate to Azure DevOps, or no headers if there are
        no credentials.
    """
    pat = os.environ.get("AZURE_DEVOPS_EXT_PAT")
    if pat:
        return {"Authorization": "Basic " + base64.b64encode(f":{pat}".encode()).decode()}
    try:
        token = run(
            [
                "az",
                "account",
                "get-access-token",
                "--resource",
                AZURE_DEVOPS_RESOURCE,
                "--query",
                "accessToken",
                "-o",
                "tsv",
            ]
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return {}
    return {"Authorization": f"Bearer {token}"} if token else {}


def azure_api(org: str, project: str, build: str | int) -> str:
    """Name the API of an Azure Pipelines build.

    Returns:
        The URL of the build in the Azure DevOps API, without a query string.
    """
    return f"https://dev.azure.com/{org}/{project}/_apis/build/builds/{build}"


def azure_get(url: str, *, text: bool = False) -> Any:
    """Get url from Azure DevOps, anonymously if the project permits it.

    A request is first made anonymously, because Azure DevOps refuses a token for one
    organization even when reading a public project of another.

    Args:
        url: the URL.
        text: whether the response is text rather than JSON.

    Returns:
        The response body:  text, or parsed JSON.
    """

    def get(headers: dict[str, str]) -> Any:
        if text:
            return http("GET", url, headers).decode(errors="replace")
        return request("GET", url, headers)

    try:
        return get({})
    except (urllib.error.HTTPError, ValueError):
        # A private project refuses the request or responds with a sign-in page.
        headers = azure_headers()
        if not headers:
            raise
        return get(headers)


def parse_azure_url(url: str) -> tuple[str, str, int] | None:
    """Find the Azure Pipelines build that url shows, which is a build's or a job's URL.

    Returns:
        The organization, project, and number of the build, or None if url is not the
        URL of an Azure Pipelines build.
    """
    if match := AZURE_BUILD.match(url):
        return match[1] or match[2], match[3], int(match[4])
    return None


###########################################################################
### CircleCI
###


@functools.cache
def circleci_token() -> str | None:
    """Find a CircleCI API token.

    Returns:
        The token, or None if there is none.
    """
    token = os.environ.get("CIRCLECI_CLI_TOKEN")
    if token:
        return token
    for config in CIRCLECI_CONFIGS:
        path = Path(config).expanduser()
        if path.exists():
            match = re.search(r"^token:\s*(\S+)", path.read_text(), re.MULTILINE)
            if match:
                return match[1]
    return None


def circleci_headers() -> dict[str, str]:
    """Determine how to authenticate to CircleCI.

    Returns:
        The HTTP headers that authenticate to CircleCI, or no headers if there is no
        token.
    """
    token = circleci_token()
    return {"Circle-Token": token} if token else {}


def circleci_items(path: str) -> list[Any]:
    """Get every page of a paginated response from the CircleCI v2 API.

    Args:
        path: the request, such as "/v2/workflow/ID/job", with no query string.

    Returns:
        The items of every page.
    """
    items = []
    page_token = None
    while True:
        query = f"?page-token={urllib.parse.quote(page_token, safe='')}" if page_token else ""
        page = request("GET", f"{CIRCLECI_API}{path}{query}", circleci_headers())
        items.extend(page["items"])
        page_token = page.get("next_page_token")
        if not page_token:
            return items


def parse_circleci_url(url: str) -> tuple[str | None, str | None, int | None] | None:
    """Find the CircleCI workflow and job that url shows.

    Returns:
        None if url is not a CircleCI URL.  Otherwise, the workflow id (None if url
        does not contain it), the project slug of the job (None if url does not
        contain it), and the job number (None if url names a workflow).
    """
    if "circleci.com/" not in url:
        return None
    if match := CIRCLECI_JOB.match(url):
        return None, match[1], int(match[2])
    workflow = match[1] if (match := CIRCLECI_WORKFLOW.search(url)) else None
    job = int(match[1]) if (match := CIRCLECI_JOB_OF_WORKFLOW.search(url)) else None
    return workflow, None, job


def circleci_workflow_of_job(slug: str, job: int) -> str | None:
    """Find the workflow of a CircleCI job.

    Args:
        slug: the job's project slug, such as "gh/ORG/REPO".
        job: the job number.

    Returns:
        The id of the job's workflow, or None if there is none.
    """
    result = request("GET", f"{CIRCLECI_API}/v2/project/{slug}/job/{job}", circleci_headers())
    return ((result or {}).get("latest_workflow") or {}).get("id")


###########################################################################
### GitHub Actions
###


def parse_github_actions_url(url: str) -> tuple[str, int, int | None] | None:
    """Find the GitHub Actions workflow run and job that url shows.

    Returns:
        The repository (as ORG/REPO), the run id, and the job id (None if url names a
        run), or None if url is not the URL of a GitHub Actions run.
    """
    if match := GITHUB_ACTIONS_RUN.match(url):
        return match[1], int(match[2]), int(match[3]) if match[3] else None
    return None
