"""Access the builds of CI services:  GitHub Actions, Azure Pipelines, and CircleCI.

This module recognizes the URLs of builds and jobs, finds credentials, and makes
requests of the services' APIs.

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
import os
import re
import subprocess
import urllib.error
import urllib.parse
from pathlib import Path
from typing import TYPE_CHECKING, Any

import request_util

if TYPE_CHECKING:
    from collections.abc import Iterator

# Matches the URL of an Azure Pipelines build or of one of its jobs, such as
# "https://dev.azure.com/checkerframework/4dcb7892-.../_build/results?buildId=24267&view=logs".
# The groups are the organization (for dev.azure.com), the organization (for
# visualstudio.com), the project, and the build.
AZURE_BUILD = re.compile(
    r"https://(?:dev\.azure\.com/([^/?#]+)|([^/.]+)\.visualstudio\.com)/([^/?#]+)"
    r"/_build/results\?(?:[^#]*&)?buildId=(\d+)"
)
# Matches the URL of a CircleCI workflow, such as "https://app.circleci.com/workflow/ecc46ce8-..."
# or "https://app.circleci.com/pipelines/gh/ORG/REPO/7/details?workflowId=ecc46ce8-...".
CIRCLECI_WORKFLOW = re.compile(
    r"circleci\.com/.*(?:\bworkflows?(?:-run)?/|[?&]workflowId=)([0-9a-f-]{36})"
)
# Matches the number of a CircleCI job, in the URL of a job of a workflow, such as
# ".../workflows/ecc46ce8-.../jobs/230602" or ".../details?...&buildNumber=230602".
CIRCLECI_JOB_OF_WORKFLOW = re.compile(r"circleci\.com/.*(?:/jobs/|[?&]buildNumber=)(\d+)")
# Matches the URL of a CircleCI job in a GitHub commit status, such as
# "https://circleci.com/gh/circleci/circleci-docs/230602?utm_campaign=...".
# The groups are the project slug and the job number.
CIRCLECI_JOB = re.compile(r"https://circleci\.com/((?:gh|bb)/[^/]+/[^/?#]+)/(\d+)(?:[?#]|$)")
# Matches the URL of a CircleCI pipeline, or of one of its workflows or jobs, such as
# "https://app.circleci.com/pipelines/github/ORG/REPO/7/workflows/ecc46ce8-..." or, for a
# project that the CircleCI GitHub App connects,
# "https://app.circleci.com/pipelines/circleci/ORG-ID/PROJECT-ID/7/workflows/ecc46ce8-...".
# The groups are the VCS, the organization, and the project.
CIRCLECI_PIPELINE = re.compile(r"app\.circleci\.com/pipelines/([^/?#]+)/([^/?#]+)/([^/?#]+)")
# The VCS slugs that the API uses in place of the ones in the URLs of the CircleCI web app.
CIRCLECI_VCS_SLUGS = {"github": "gh", "bitbucket": "bb"}
# The URL of a GitHub Actions workflow run or of one of its jobs, such as
# "https://github.com/ORG/REPO/actions/runs/123/job/456".  The groups are the
# repository, the run, and the job.
GITHUB_ACTIONS_RUN = re.compile(
    r"https://github\.com/([^/]+/[^/]+)/actions/runs/(\d+)(?:/attempts/\d+)?(?:/job/(\d+))?"
)

CIRCLECI_API = "https://circleci.com/api"
# The application ID of Azure DevOps in Microsoft Entra ID, which is the same for every
# organization.  `az account get-access-token --resource` issues a token for Azure DevOps
# only when given this ID.
AZURE_DEVOPS_RESOURCE = "499b84ac-1321-427f-aa17-267ca6975798"
# The configuration files of the CircleCI CLI, which `circleci setup` writes.
CIRCLECI_CONFIGS = ("~/.circleci/cli.yml", "~/snap/circleci/current/.circleci/cli.yml")


###########################################################################
### Azure Pipelines
###


@functools.cache
def azure_headers() -> dict[str, str]:
    """Return the HTTP headers that authenticate to Azure DevOps.

    Returns:
        The headers, or no headers if there are no credentials.
    """
    pat = os.environ.get("AZURE_DEVOPS_EXT_PAT")
    if pat:
        return {"Authorization": "Basic " + base64.b64encode(f":{pat}".encode()).decode()}
    try:
        token = request_util.run(
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


def azure_api(org: str, project: str, build: str | int | None = None) -> str:
    """Name the API of an Azure Pipelines build, or of all the builds of a project.

    Args:
        org: the Azure DevOps organization.
        project: the Azure DevOps project, by name or by ID.
        build: the ID of the build, such as 24267 (the buildId in the URL of the build, not
            its build number, such as "20261031.1"), or None for all of the project's builds.

    Returns:
        The URL of `build` (or, if build is None, of the project's builds) in the
        Azure DevOps API, without a query string.
    """
    api = f"https://dev.azure.com/{org}/{project}/_apis/build/builds"
    return api if build is None else f"{api}/{build}"


# The Azure DevOps projects, as "ORG/PROJECT", that refused an anonymous request.
_azure_private_projects: set[str] = set()
# The HTTP statuses with which Azure DevOps refuses an anonymous request to a private
# project.  203 is a sign-in page, as http reports it.
AZURE_REFUSALS = {203, 401, 403, 404}


def azure_get(url: str) -> Any:
    """Get url from Azure DevOps, anonymously if the project permits it.

    A request is first made anonymously, because Azure DevOps refuses a token for one
    organization even when reading a public project of another.  After a project
    refuses an anonymous request, later requests to it are made with credentials only.

    Args:
        url: the URL, in the Azure DevOps API.

    Returns:
        The response body, parsed as JSON.
    """
    match = re.match(r"https://dev\.azure\.com/([^/]+/[^/]+)/", url)
    project = match[1] if match else url
    if project not in _azure_private_projects:
        try:
            return request_util.request("GET", url, {})
        except (urllib.error.HTTPError, ValueError) as e:
            # A response that is not JSON is a sign-in page.  Another failure, such as a
            # 503, can be temporary and does not indicate a private project.
            refused = not isinstance(e, urllib.error.HTTPError) or e.code in AZURE_REFUSALS
            if not refused or not azure_headers():
                raise
            _azure_private_projects.add(project)
    return request_util.request("GET", url, azure_headers())


def parse_azure_url(url: str) -> tuple[str, str, int] | None:
    """Find the Azure Pipelines build that url shows, which is a build's or a job's URL.

    Args:
        url: a URL.

    Returns:
        The organization, project, and ID of the build, or None if url is not the
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


def circleci_items(path: str) -> Iterator[Any]:
    """Get the items of a paginated response from the CircleCI v2 API.

    Each page is requested only when the caller reaches its items, so a caller that
    stops early does not request the remaining pages.

    Args:
        path: the request, such as "/v2/workflow/ID/job", with no query string.

    Yields:
        The items of every page, in order.
    """
    page_token = None
    while True:
        query = f"?page-token={urllib.parse.quote(page_token, safe='')}" if page_token else ""
        page = request_util.request("GET", f"{CIRCLECI_API}{path}{query}", circleci_headers())
        yield from page["items"]
        page_token = page.get("next_page_token")
        if not page_token:
            return


def parse_circleci_url(url: str) -> tuple[str | None, str | None, int | None] | None:
    """Find the CircleCI workflow and job that url shows.

    Args:
        url: a URL.

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


def circleci_project_of_url(url: str) -> str | None:
    """Find the CircleCI project of the pipeline, workflow, or job that url shows.

    Args:
        url: a URL.

    Returns:
        The project slug, such as "gh/ORG/REPO" or "circleci/ORG-ID/PROJECT-ID", or None
        if url does not contain it.
    """
    if match := CIRCLECI_PIPELINE.search(url):
        return f"{CIRCLECI_VCS_SLUGS.get(match[1], match[1])}/{match[2]}/{match[3]}"
    parsed = parse_circleci_url(url)
    return parsed[1] if parsed else None


def circleci_workflow_of_url(url: str) -> tuple[str | None, int | None]:
    """Find the CircleCI workflow and job that url shows.

    If url names a job but not its workflow, as the URL of a job in a GitHub commit
    status does, this looks up the job's workflow; if the lookup fails, this raises an
    exception in request_util.REQUEST_ERRORS.

    Args:
        url: a URL.

    Returns:
        The workflow id (None if there is none) and the job number (None if url names
        a workflow).
    """
    workflow, slug, job = parse_circleci_url(url) or (None, None, None)
    if workflow is None and slug is not None and job is not None:
        result = request_util.request(
            "GET", f"{CIRCLECI_API}/v2/project/{slug}/job/{job}", circleci_headers()
        )
        workflow = ((result or {}).get("latest_workflow") or {}).get("id")
    return workflow, job


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
