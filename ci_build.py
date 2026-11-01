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
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
from pathlib import Path
from typing import TYPE_CHECKING, Any, NamedTuple

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
# Matches the URL of a CircleCI job that names its project but not its workflow, such as
# "https://circleci.com/gh/circleci/circleci-docs/230602?utm_campaign=..." (in a GitHub
# commit status) or "https://app.circleci.com/jobs/github/circleci/circleci-docs/230602".
# The groups are the VCS, the organization, the repository, and the job number.
CIRCLECI_JOB = re.compile(
    r"https?://(?:app\.)?circleci\.com/(?:jobs/)?(gh|bb|github|bitbucket)/([^/?#]+)/([^/?#]+)"
    r"/(\d+)/?(?:[?#]|$)"
)
# Matches the URL of a CircleCI pipeline, or of one of its workflows or jobs, such as
# "https://app.circleci.com/pipelines/github/ORG/REPO/7/workflows/ecc46ce8-..." or, for a
# project that the CircleCI GitHub App connects,
# "https://app.circleci.com/pipelines/circleci/ORG-ID/PROJECT-ID/7/workflows/ecc46ce8-...".
# The groups are the VCS, the organization, and the project.
CIRCLECI_PIPELINE = re.compile(r"app\.circleci\.com/pipelines/([^/?#]+)/([^/?#]+)/([^/?#]+)")
# The VCS slugs that the API uses in place of the ones in the URLs of the CircleCI web app.
CIRCLECI_VCS_SLUGS = {"github": "gh", "bitbucket": "bb"}

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


# How long before a token from `az` expires that azure_headers replaces it, in seconds.
AZURE_TOKEN_MARGIN = 300
# How long after a failed `az` call that azure_headers calls `az` again, in seconds.
AZURE_TOKEN_RETRY = 300


class AzureTokenHeaders(NamedTuple):
    """HTTP headers that authenticate to Azure DevOps, and how long to use them.

    Attributes:
        headers: the headers, such as {"Authorization": "Bearer TOKEN"}, or no headers if
            `az` issues no token.
        use_until: the time, as from time.time(), until which to use the headers.
    """

    headers: dict[str, str]
    use_until: float


# The headers that azure_headers made from the output of `az`, or None if it has made
# none.
_azure_token_headers: AzureTokenHeaders | None = None


def azure_headers() -> dict[str, str]:
    """Return the HTTP headers that authenticate to Azure DevOps.

    Returns:
        The headers, or no headers if there are no credentials.
    """
    global _azure_token_headers
    pat = os.environ.get("AZURE_DEVOPS_EXT_PAT")
    if pat:
        return {"Authorization": "Basic " + base64.b64encode(f":{pat}".encode()).decode()}
    if _azure_token_headers is None or time.time() >= _azure_token_headers.use_until:
        _azure_token_headers = azure_cli_headers()
    return _azure_token_headers.headers


def azure_cli_headers() -> AzureTokenHeaders:
    """Return the HTTP headers that authenticate to Azure DevOps as the account of `az login`.

    Returns:
        The headers, and the time until which to use them.
    """
    try:
        token = json.loads(
            request_util.run(
                ["az", "account", "get-access-token", "--resource", AZURE_DEVOPS_RESOURCE]
            )
        )
        headers = {"Authorization": f"Bearer {token['accessToken']}"}
        return AzureTokenHeaders(headers, float(token["expires_on"]) - AZURE_TOKEN_MARGIN)
    # No `az`, no login, a timeout, or output without a token.
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError):
        return AzureTokenHeaders({}, time.time() + AZURE_TOKEN_RETRY)


def azure_api(org: str, project: str, build: str | int | None = None) -> str:
    """Return the Azure DevOps API URL of the given build, or of the given project's builds.

    Args:
        org: an Azure DevOps organization's name, such as "checkerframework".
        project: a project of the organization, by name, such as "checker-framework", or
            by id, a UUID such as "4dcb7892-...".
        build: the ID of a build of the project, such as 24267 (the buildId in the URL of
            the build, not its build number, such as "20261031.1"), or None for all of the
            project's builds.

    Returns:
        The URL of `build` (or, if build is None, of the project's builds) in the
        Azure DevOps API, without a query string.
    """
    api = f"https://dev.azure.com/{org}/{project}/_apis/build/builds"
    return api if build is None else f"{api}/{build}"


# The Azure DevOps projects, as "ORG/PROJECT", that refused an anonymous request and
# granted the same request with credentials.
_azure_private_projects: set[str] = set()
# The HTTP statuses with which Azure DevOps can refuse an anonymous request to a private
# project.  203 is a sign-in page, which azure_request reports as an HTTPError.  404 is
# also the status of a request for something that does not exist.
AZURE_REFUSALS = {203, 401, 403, 404}
# The successful status with which Azure DevOps responds to a request that lacks the
# needed credentials, with a sign-in page, and a description of it.
AZURE_SIGN_IN = {203: "a sign-in page instead of the requested data"}


def azure_request(method: str, url: str, headers: dict[str, str], body: Any = None) -> Any:
    """Make the given HTTP request of Azure DevOps, and return the response parsed as JSON.

    If Azure DevOps refuses the request with an error status or with a sign-in page whose
    status is 203, this raises urllib.error.HTTPError.  If the response is not JSON, such
    as a sign-in page with another successful status, this raises ValueError.

    Args:
        method: an HTTP method, such as "GET".
        url: a URL in the Azure DevOps API.
        headers: HTTP headers.
        body: a request body, which is sent as JSON, or None for no body.

    Returns:
        The response body, parsed as JSON, or None if it is empty.
    """
    return request_util.request(method, url, headers, body, refusals=AZURE_SIGN_IN)


def azure_get(url: str) -> Any:
    """Get the given URL from Azure DevOps, and return the response parsed as JSON.

    A request is first made anonymously, because Azure DevOps refuses a token for one
    organization even when reading a public project of another.  If Azure DevOps refuses
    the anonymous request, the request is repeated with credentials.  After a project
    refuses an anonymous request and grants the same request with credentials, later
    requests to it are made with credentials only.

    Args:
        url: a URL in the Azure DevOps API.

    Returns:
        The response body, parsed as JSON.
    """
    match = re.match(r"https://dev\.azure\.com/([^/]+/[^/]+)/", url)
    project = match[1] if match else url
    if project not in _azure_private_projects:
        try:
            return azure_request("GET", url, {})
        except (urllib.error.HTTPError, ValueError) as e:
            # A response that is not JSON is a sign-in page.  Another failure, such as a
            # 503, can be temporary and does not indicate a private project.
            refused = not isinstance(e, urllib.error.HTTPError) or e.code in AZURE_REFUSALS
            if not refused or not azure_headers():
                raise
        # A refusal, such as a 404 for a build that does not exist, can come from a public
        # project, so the project is not known to be private until credentials succeed.
        result = azure_request("GET", url, azure_headers())
        _azure_private_projects.add(project)
        return result
    return azure_request("GET", url, azure_headers())


class AzureBuildUrlParts(NamedTuple):
    """The parts of the URL of an Azure Pipelines build or of one of its jobs.

    For example, "https://dev.azure.com/ORG/PROJECT/_build/results?buildId=24267" shows
    build 24267 of project "PROJECT" of organization "ORG".

    Attributes:
        org: an Azure DevOps organization's name, such as "checkerframework".
        project: a project of the organization, by name, such as "checker-framework", or
            by id, a UUID such as "4dcb7892-...".
        build: the ID of a build of the project, such as 24267 (the buildId in the URL of
            the build, not its build number, such as "20261031.1").
    """

    org: str
    project: str
    build: int

    @classmethod
    def from_url(cls, url: str) -> AzureBuildUrlParts | None:
        """Return the parts of the given URL of an Azure Pipelines build.

        Args:
            url: any URL.  This method recognizes the URL of an Azure Pipelines build or
                of one of its jobs, on dev.azure.com or on visualstudio.com, as
                AZURE_BUILD documents.

        Returns:
            The parts, or None if url is not the URL of an Azure Pipelines build.
        """
        if match := AZURE_BUILD.match(url):
            return cls(match[1] or match[2], match[3], int(match[4]))
        return None


###########################################################################
### CircleCI
###


@functools.cache
def circleci_token() -> str | None:
    """Return the user's CircleCI personal API token.

    The token is the value of $CIRCLECI_CLI_TOKEN, or else the one in the first of
    CIRCLECI_CONFIGS that contains a token.

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
    """Return the HTTP headers that authenticate to CircleCI.

    Returns:
        The headers, or no headers if there is no token.
    """
    token = circleci_token()
    return {"Circle-Token": token} if token else {}


def circleci_items(path: str) -> Iterator[Any]:
    """Yield the items of the CircleCI v2 API's paginated response to the given request.

    Each page is requested only when the caller reaches its items, so a caller that
    stops early does not request the remaining pages.

    Args:
        path: a request, such as "/v2/workflow/ID/job", with no query string.

    Yields:
        The items of every page, in order.
    """
    page_token = None
    while True:
        query = f"?page-token={urllib.parse.quote(page_token, safe='')}" if page_token else ""
        page = request_util.request("GET", f"{CIRCLECI_API}{path}{query}", circleci_headers())
        if not isinstance(page, dict):
            msg = f"CircleCI returned {page!r} instead of a page of items for {path}"
            raise ValueError(msg)  # ruff: ignore[type-check-without-type-error]
        yield from page["items"]
        page_token = page.get("next_page_token")
        if not page_token:
            return


class CircleciUrlParts(NamedTuple):
    """The parts of a CircleCI URL:  the workflow, project, and job that it names.

    For example, "https://app.circleci.com/workflow/ecc46ce8-..." names a workflow, and
    "https://circleci.com/gh/ORG/REPO/230602" names job 230602 of project "gh/ORG/REPO".

    Attributes:
        workflow: a workflow's id, a UUID such as "ecc46ce8-...", or None if the URL
            does not contain it.
        project: the project slug, such as "gh/ORG/REPO" or "circleci/ORG-ID/PROJECT-ID",
            or None if the URL does not contain it.
        job: the number of a job, an integer such as 230602, or None if the URL names no
            job, such as the URL of a workflow or of a pipeline.
    """

    workflow: str | None
    project: str | None
    job: int | None

    @classmethod
    def from_url(cls, url: str) -> CircleciUrlParts | None:
        """Return the CircleCI workflow, project, and job that the given URL names.

        This method makes no request of CircleCI.

        Args:
            url: any URL.  This method recognizes a URL that contains "circleci.com/",
                such as the URL of a CircleCI pipeline, of a workflow, of a job of a
                workflow, or of a job that names its project but not its workflow, as
                CIRCLECI_PIPELINE, CIRCLECI_WORKFLOW, CIRCLECI_JOB_OF_WORKFLOW, and
                CIRCLECI_JOB document.

        Returns:
            The workflow, project, and job, or None if url is not a CircleCI URL.  Each
            of them is None if url does not contain it, as for "https://circleci.com/docs/".
        """
        if "circleci.com/" not in url:
            return None
        if match := CIRCLECI_JOB.match(url):
            vcs = CIRCLECI_VCS_SLUGS.get(match[1], match[1])
            return cls(None, f"{vcs}/{match[2]}/{match[3]}", int(match[4]))
        project = None
        if match := CIRCLECI_PIPELINE.search(url):
            project = f"{CIRCLECI_VCS_SLUGS.get(match[1], match[1])}/{match[2]}/{match[3]}"
        workflow = match[1] if (match := CIRCLECI_WORKFLOW.search(url)) else None
        job = int(match[1]) if (match := CIRCLECI_JOB_OF_WORKFLOW.search(url)) else None
        return cls(workflow, project, job)

    def lookup_workflow(self) -> str | None:
        """Return the id of the workflow that this names, or else of the workflow of its job.

        If this names a job and its project but not its workflow, as the URL of a job in
        a GitHub commit status does, this requests the job's workflow from CircleCI; if
        the request fails, this raises an exception in request_util.REQUEST_ERRORS.

        Returns:
            The workflow's id, a UUID such as "ecc46ce8-...", or None if this names
            neither a workflow nor a job and its project, or if CircleCI reports no
            workflow for the job.
        """
        if self.workflow is not None or self.project is None or self.job is None:
            return self.workflow
        result = request_util.request(
            "GET", f"{CIRCLECI_API}/v2/project/{self.project}/job/{self.job}", circleci_headers()
        )
        return ((result or {}).get("latest_workflow") or {}).get("id")


def circleci_project_of_url(url: str) -> str | None:
    """Return the CircleCI project of the pipeline, workflow, or job that url names.

    Args:
        url: any URL.  This function recognizes the CircleCI URLs that
            CircleciUrlParts.from_url recognizes.

    Returns:
        The project slug, such as "gh/ORG/REPO" or "circleci/ORG-ID/PROJECT-ID", or None
        if url does not contain it.
    """
    parsed = CircleciUrlParts.from_url(url)
    return parsed.project if parsed else None
