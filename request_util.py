"""Run commands and make HTTP requests, such as of the APIs of web services.

GitHub requests go through the `gh` command, which handles authentication.
"""

from __future__ import annotations

import gzip
import json
import re
import subprocess
import urllib.error
import urllib.request
from http.client import HTTPException
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from collections.abc import Mapping

# How long, in seconds, a command can run before run stops it.
COMMAND_TIMEOUT = 300
# How long, in seconds, http waits for the server to connect or to send data.
HTTP_TIMEOUT = 60

# The errors that a command or an HTTP request can raise.
REQUEST_ERRORS = (
    # A failed connection, such as a urllib.error.URLError, a TimeoutError, or a
    # ConnectionResetError.
    OSError,
    # A failed connection, such as an http.client.IncompleteRead.
    HTTPException,
    # A command that exited with a nonzero status.
    subprocess.CalledProcessError,
    # A command that ran longer than COMMAND_TIMEOUT seconds.
    subprocess.TimeoutExpired,
    # A response that is not JSON, or that is JSON of an unexpected form.
    ValueError,
    # A response that lacks an expected field.
    KeyError,
)


def run(cmd: list[str]) -> str:
    """Run a command.

    If the command fails, this raises subprocess.CalledProcessError.  If it runs longer
    than COMMAND_TIMEOUT seconds, this stops it and raises subprocess.TimeoutExpired.

    Args:
        cmd: the command and its arguments.

    Returns:
        The command's standard output, in which any byte that is not part of a UTF-8
        character is replaced.
    """
    return subprocess.run(
        cmd,
        check=True,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        timeout=COMMAND_TIMEOUT,
    ).stdout


def gh_api(path: str, *, paginate: bool = False) -> Any:
    """Make a GitHub API request with `gh api`.

    Args:
        path: the request, such as "repos/ORG/REPO/actions/runs/123".
        paginate: True if every page of the response should be read.

    Returns:
        The response, parsed as JSON; with paginate, a list of the pages.
    """
    if paginate:
        return json.loads(run(["gh", "api", "--paginate", "--slurp", path]))
    return json.loads(run(["gh", "api", path]))


def http(
    method: str,
    url: str,
    headers: dict[str, str] | None = None,
    body: Any = None,
    *,
    refusals: Mapping[int, str] | None = None,
) -> bytes:
    """Make an HTTP request.

    Args:
        method: the HTTP method, such as "GET".
        url: the URL.
        headers: the HTTP headers.
        body: the request body, which is sent as JSON, or None for no body.
        refusals: a map from each successful status with which the server refuses the
            request, such as one that a sign-in page has, to a description of it.

    Returns:
        The response body, decompressed if the server compressed it.

    Raises:
        urllib.error.HTTPError: if the server refuses the request, with an error status
            or with a status in refusals.
    """
    headers = dict(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as response:
        if refusals and response.status in refusals:
            msg = refusals[response.status]
            raise urllib.error.HTTPError(url, response.status, msg, response.headers, None)
        content = response.read()
        if response.headers.get("Content-Encoding") == "gzip":
            content = gzip.decompress(content)
    return content


def request(
    method: str,
    url: str,
    headers: dict[str, str] | None = None,
    body: Any = None,
    *,
    refusals: Mapping[int, str] | None = None,
) -> Any:
    """Make an HTTP request whose response is JSON.

    Args:
        method: the HTTP method, such as "GET".
        url: the URL.
        headers: the HTTP headers.
        body: the request body, which is sent as JSON, or None for no body.
        refusals: a map from each successful status with which the server refuses the
            request to a description of it, as for http.

    Returns:
        The response body, parsed as JSON, or None if it is empty.
    """
    content = http(method, url, headers, body, refusals=refusals)
    return json.loads(content) if content else None


def failure(e: Exception) -> str:
    """Describe a failed command or HTTP request.

    Args:
        e: the exception that the command or the HTTP request raised.

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
    """Extract the explanation part from the body of an HTTP error response.

    The body can be a long HTML page.

    Args:
        text: the body of the response.

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
