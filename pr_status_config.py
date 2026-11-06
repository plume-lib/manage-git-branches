"""Read and check a pr-status config file, and fill in the config's defaults.

The config file, pr-status-config.json, is documented in pr-status-config.md.  The parts of
reading a config that need git or GitHub, such as finding a repository's clone, are in
pr_status.py.
"""

from __future__ import annotations

import difflib
import json
import os
import pathlib
import re
import sys
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from collections.abc import Callable, Iterable, Mapping

# The config file's name.
CONFIG = "pr-status-config.json"
# The dependency document's file name when there is no config file.
DEFAULT_DEPENDENCY_DOCUMENT = "pr-status.md"
# The name of the file in which each run of pr-status records what it found, for the next
# run to compare with.
SNAPSHOT = ".pr-status-snapshot.json"
# The optional sections of the dependency document, which the config's
# "documents": {"optional_sections": [...]} includes.
OPTIONAL_SECTIONS = ("graph", "details", "prerequisites", "independent")


def is_valid_filter(flt: Any) -> bool:
    """Return True if the given value is a valid filter of an unblocked document.

    Args:
        flt: a value parsed from the config file's JSON, such as "unassigned".

    Returns:
        True if flt is "all", "unassigned", or a dict whose only key "unassigned_or" maps
        to a list of GitHub logins, such as {"unassigned_or": ["mernst"]}.
    """
    if flt in ("all", "unassigned"):
        return True
    if not isinstance(flt, dict) or flt.keys() != {"unassigned_or"}:
        return False
    logins = flt["unassigned_or"]
    return isinstance(logins, list) and all(isinstance(w, str) for w in logins)


# Matches a PR number that is a key of a config object, such as "527".
PR_NUMBER_KEY_RE = re.compile(r"[1-9][0-9]*")
# Matches a GitHub slug, such as "codespecs/daikon".
GH_SLUG_RE = re.compile(r"[\w.-]+/[\w.-]+")
# Matches a reference to a PR in a GitHub repository, such as "codespecs/fjalar#95".
EXTERNAL_PR_RE = re.compile(r"[\w.-]+/[\w.-]+#[1-9][0-9]*")
# Matches a Mermaid node id prefix, such as "daikon_".
NODE_PREFIX_RE = re.compile(r"[A-Za-z0-9_]+")
# Matches a key that a config path shows without quotes, such as "detail_notes".
PLAIN_KEY_RE = re.compile(r"[A-Za-z_][\w-]*")
# The most characters of a value that an error message shows.
SHOWN_LENGTH = 40


def key_path(path: str, key: str) -> str:
    """Return the config path of the given key of the object at path.

    A config path names a value in the config, as in "repos.daikon.titles" or
    'repos.daikon.titles."527"' or "order[0]".

    Args:
        path: the config path of an object, such as "repos.daikon", or "" for the config.
        key: a key of the object, such as "titles" or "527".

    Returns:
        The config path of the key's value, such as "repos.daikon.titles".
    """
    shown = key if PLAIN_KEY_RE.fullmatch(key) else json.dumps(key)
    return f"{path}.{shown}" if path else shown


def shown(value: Any) -> str:
    """Return how an error message shows a value parsed from the config's JSON.

    Returns:
        "an object" or "a list" for a JSON object or list; otherwise the value as JSON, such
        as '"512"' or "null", shortened if it is long.
    """
    if isinstance(value, dict):
        return "an object"
    if isinstance(value, list):
        return "a list"
    text = json.dumps(value)
    return text if len(text) <= SHOWN_LENGTH else text[: SHOWN_LENGTH - 3] + "..."


def subject(path: str) -> str:
    """Return how an error message names the value at a config path.

    Returns:
        The path, or "the config" if path is "".
    """
    return path or "the config"


# A checker is a function that, given a value parsed from the config's JSON, its config path,
# and a list of problems, appends to the list a description of each problem with the value,
# such as 'order[0] is 5, not a string'.  The functions named "..._checker" that take other
# arguments, such as type_checker(str, "a string"), return a checker.


def type_checker(kind: type, description: str) -> Callable[[Any, str, list[str]], None]:
    """Return a checker that reports a value that does not have the given JSON type.

    Args:
        kind: a Python type that JSON values parse to, such as str or bool.
        description: what a value of the type is, such as "a string"; used for diagnostics.

    Returns:
        The checker.
    """

    def check(value: Any, path: str, problems: list[str]) -> None:
        # In Python, a bool is an int.
        if not isinstance(value, kind) or (isinstance(value, bool) and kind is not bool):
            problems.append(f"{subject(path)} is {shown(value)}, not {description}")

    return check


def pattern_checker(
    pattern: re.Pattern[str], description: str
) -> Callable[[Any, str, list[str]], None]:
    """Return a checker that reports a value that is not a string that pattern matches.

    Args:
        pattern: a regular expression that a valid string matches in full.
        description: what a valid string is, such as 'a GitHub slug such as "ORG/REPO"';
            used for diagnostics.

    Returns:
        The checker.
    """

    def check(value: Any, path: str, problems: list[str]) -> None:
        if not isinstance(value, str) or not pattern.fullmatch(value):
            problems.append(f"{subject(path)} is {shown(value)}, not {description}")

    return check


def pr_number_checker(value: Any, path: str, problems: list[str]) -> None:
    """Append to problems a description of value if it is not a PR number, such as 527."""
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        problems.append(f"{subject(path)} is {shown(value)}, not a PR number such as 527")


def filter_checker(value: Any, path: str, problems: list[str]) -> None:
    """Append to problems a description of value if it is not a filter of an unblocked document."""
    if not is_valid_filter(value):
        problems.append(
            f'{subject(path)} is {shown(value)}, not "all", "unassigned", or'
            ' {"unassigned_or": [LOGIN, ...]}'
        )


def optional_section_checker(value: Any, path: str, problems: list[str]) -> None:
    """Append to problems a description of value if it is not an optional section's name."""
    if value not in OPTIONAL_SECTIONS:
        names = [json.dumps(s) for s in OPTIONAL_SECTIONS]
        problems.append(
            f"{subject(path)} is {shown(value)}, not {', '.join(names[:-1])}, or {names[-1]}"
        )


def list_checker(
    item_checker: Callable[[Any, str, list[str]], None], length: int | None = None
) -> Callable[[Any, str, list[str]], None]:
    """Return a checker that reports a value that is not a list, and its elements' problems.

    Args:
        item_checker: a checker of each element.
        length: the number of elements that the list must have, or None for any number.

    Returns:
        The checker.
    """

    def check(value: Any, path: str, problems: list[str]) -> None:
        if not isinstance(value, list):
            problems.append(f"{subject(path)} is {shown(value)}, not a list")
            return
        if length is not None and len(value) != length:
            problems.append(f"{subject(path)} has {len(value)} elements, not {length}")
        for i, item in enumerate(value):
            item_checker(item, f"{path}[{i}]", problems)

    return check


def object_checker(
    fields: dict[str, Callable[[Any, str, list[str]], None]],
    required: Iterable[str] = (),
    forbidden: Mapping[str, str] | None = None,
) -> Callable[[Any, str, list[str]], None]:
    """Return a checker that reports a value that is not an object with the given keys.

    Args:
        fields: a map from each key that the object can have to a checker of its value.
        required: the keys that the object must have.
        forbidden: a map from each key that the object must not have, although a user might
            expect it to, to why not, such as 'a repository's name is its key in "repos"'.

    Returns:
        The checker, which reports a missing required key, a forbidden key, and an unknown
        key, which it compares to the known keys to suggest a correction.
    """

    def check(value: Any, path: str, problems: list[str]) -> None:
        if not isinstance(value, dict):
            problems.append(f"{subject(path)} is {shown(value)}, not an object")
            return
        problems.extend(
            f"{subject(path)} has no {json.dumps(key)}" for key in required if key not in value
        )
        for key, item in value.items():
            child = key_path(path, key)
            if key in fields:
                fields[key](item, child, problems)
                continue
            if forbidden and key in forbidden:
                problems.append(f"{child} is not permitted:  {forbidden[key]}")
                continue
            close = difflib.get_close_matches(key, fields, n=1)
            suggestion = f"; did you mean {json.dumps(close[0])}?" if close else ""
            problems.append(f"{child} is not a known key{suggestion}")

    return check


def map_checker(
    item_checker: Callable[[Any, str, list[str]], None], pr_keys: bool
) -> Callable[[Any, str, list[str]], None]:
    """Return a checker that reports a value that is not an object, and its values' problems.

    Args:
        item_checker: a checker of each of the object's values.
        pr_keys: True if each of the object's keys must be a PR number, such as "527".

    Returns:
        The checker.
    """

    def check(value: Any, path: str, problems: list[str]) -> None:
        if not isinstance(value, dict):
            problems.append(f"{subject(path)} is {shown(value)}, not an object")
            return
        for key, item in value.items():
            child = key_path(path, key)
            if pr_keys and not PR_NUMBER_KEY_RE.fullmatch(key):
                problems.append(f'{child}:  the key is not a PR number such as "527"')
            item_checker(item, child, problems)

    return check


# Matches text on one line, such as "needs a review", or "".
ONE_LINE_RE = re.compile(r"[^\n\r]*")
# Matches non-empty text on one line, such as "pr-status.md".
NONEMPTY_LINE_RE = re.compile(r"[^\n\r]+")
LINE_CHECKER = pattern_checker(ONE_LINE_RE, "a string on one line")
NAME_CHECKER = pattern_checker(NONEMPTY_LINE_RE, "a non-empty string on one line")
NOTES_CHECKER = map_checker(LINE_CHECKER, pr_keys=True)
REPO_CHECKER = object_checker(
    {
        "gh": pattern_checker(GH_SLUG_RE, 'a GitHub slug such as "ORG/REPO"'),
        "clone": NAME_CHECKER,
        "prefix": NAME_CHECKER,
        "label": NAME_CHECKER,
        "node_prefix": pattern_checker(NODE_PREFIX_RE, "letters, digits, and underscores"),
        "dir_name": NAME_CHECKER,
        "default_branch": NAME_CHECKER,
        "dependency_keywords": list_checker(NAME_CHECKER),
        "show_author": type_checker(bool, "true or false"),
        "routine_files": list_checker(NAME_CHECKER),
        "excluded": object_checker(
            {"prs": list_checker(pr_number_checker), "reason": LINE_CHECKER}, required=["prs"]
        ),
        "not_prerequisites": list_checker(pr_number_checker),
        "extra_dependencies": list_checker(list_checker(pr_number_checker, length=2)),
        "extra_external_dependencies": map_checker(
            list_checker(pattern_checker(EXTERNAL_PR_RE, 'a PR such as "ORG/REPO#95"')),
            pr_keys=True,
        ),
        "titles": NOTES_CHECKER,
        "labels": NOTES_CHECKER,
        "cluster_names": NOTES_CHECKER,
        "unblocked_notes": NOTES_CHECKER,
        "detail_notes": NOTES_CHECKER,
        "independent_notes": NOTES_CHECKER,
    },
    required=["gh"],
    forbidden={"name": 'a repository\'s name is its key in "repos"'},
)
CONFIG_CHECKER = object_checker(
    {
        "repos": map_checker(REPO_CHECKER, pr_keys=False),
        "order": list_checker(NAME_CHECKER),
        "documents": object_checker(
            {
                "dependencies": NAME_CHECKER,
                "optional_sections": list_checker(optional_section_checker),
                "unblocked": list_checker(
                    object_checker(
                        {"file": NAME_CHECKER, "title": LINE_CHECKER, "filter": filter_checker},
                        required=["file", "title"],
                    )
                ),
            }
        ),
        "directories": list_checker(
            object_checker(
                {
                    "dirs": list_checker(NAME_CHECKER),
                    "status": LINE_CHECKER,
                    "relationship": LINE_CHECKER,
                },
                required=["dirs", "status", "relationship"],
            )
        ),
    },
    required=["repos"],
)


def config_problems(cfg: Any) -> list[str]:
    """Return the problems with a config, before with_defaults fills in its defaults.

    Args:
        cfg: a value parsed from the config file's JSON.

    Returns:
        A description of each problem, such as
        'repos.daikon.excluded.prs[0] is "512", not a PR number such as 527'.
    """
    problems: list[str] = []
    CONFIG_CHECKER(cfg, "", problems)
    repos = cfg.get("repos") if isinstance(cfg, dict) else None
    if not isinstance(repos, dict):
        return problems
    order = cfg.get("order")
    if isinstance(order, list):
        seen = set()
        for i, name in enumerate(order):
            if not isinstance(name, str):
                continue
            if name not in repos:
                problems.append(f'order[{i}] is {json.dumps(name)}, which is not a key of "repos"')
            elif name in seen:
                problems.append(f"order[{i}] repeats {json.dumps(name)}")
            seen.add(name)
        problems.extend(
            f'{key_path("repos", key)} is not in "order"; add it to "order" or remove it'
            for key in repos
            if key not in seen
        )
    return problems


def with_defaults(cfg: dict[str, Any]) -> dict[str, Any]:
    """Set each optional key of cfg that has a computed or constant default, except "clone".

    Args:
        cfg: a config, as a dict parsed from the config file's JSON, with keys such as
            "repos" and "documents", which config_problems accepts.

    Returns:
        cfg, which this function changes.
    """
    repos = cfg["repos"]
    cfg.setdefault("order", list(repos))
    cfg.setdefault("documents", {}).setdefault("dependencies", DEFAULT_DEPENDENCY_DOCUMENT)
    cfg.setdefault("directories", [])
    # With several repositories, a bare "#N" would be ambiguous.
    several = len(repos) > 1
    for key, rc in repos.items():
        rc.setdefault("label", key)
        rc.setdefault("prefix", f"{key}#" if several else "#")
        rc.setdefault("node_prefix", re.sub(r"\W", "_", key) + "_" if several else "pr")
    return cfg


def duplicate_problems(cfg: dict[str, Any]) -> list[str]:
    """Return the problems with a config that with_defaults has filled in:  shared values.

    Two repositories must not have the same GitHub slug, prefix (ignoring case), or node
    prefix.  Two documents must not have the same file, and no document's file can be the
    config file or the snapshot file, because pr-status overwrites each document.

    Returns:
        A description of each value that two repositories or two files share, such as
        'repos.daikon and repos.fjalar have the same "prefix", "#"'.
    """
    problems = []
    docs = cfg["documents"]
    owners = {
        os.path.normpath(CONFIG): f"the config file, {CONFIG}",
        os.path.normpath(SNAPSHOT): f"the snapshot file, {SNAPSHOT}",
    }
    files = [("documents.dependencies", docs["dependencies"])] + [
        (f"documents.unblocked[{i}].file", doc["file"])
        for i, doc in enumerate(docs.get("unblocked", []))
    ]
    for path, file in files:
        normalized = os.path.normpath(file)
        if normalized in owners:
            problems.append(f"{path} is {json.dumps(file)}, which is also {owners[normalized]}")
        else:
            owners[normalized] = path
    for field, normalize in (("gh", str.lower), ("prefix", str.lower), ("node_prefix", str)):
        first: dict[str, str] = {}
        for key, rc in cfg["repos"].items():
            value = normalize(rc[field])
            if value in first:
                problems.append(
                    f"{key_path('repos', first[value])} and {key_path('repos', key)} have the"
                    f" same {json.dumps(field)}, {json.dumps(rc[field])}"
                )
            else:
                first[value] = key
    return problems


def read_config_file(program: str) -> dict[str, Any] | None:
    """Return the config that the config file in the current directory holds.

    Exit with an error message that describes each problem if the file is not valid JSON or
    is not a valid config.

    Args:
        program: the name of a running program; used for diagnostics.

    Returns:
        The config, as a dict parsed from the config file's JSON, with keys such as "repos"
        and "documents", with each default that with_defaults sets; or None if there is no
        config file.
    """
    if not pathlib.Path(CONFIG).exists():
        return None
    with pathlib.Path(CONFIG).open() as f:
        try:
            cfg = json.load(f)
        except json.JSONDecodeError as error:
            sys.exit(f"{program}: {CONFIG}:{error.lineno}:{error.colno}: {error.msg}")
    problems = config_problems(cfg)
    if not problems:
        problems = duplicate_problems(with_defaults(cfg))
    if problems:
        sys.exit("\n".join(f"{program}: {CONFIG}: {p}" for p in problems))
    return cfg


def dependency_document_name(cfg: dict[str, Any] | None) -> str:
    """Return the file name of the dependency document that the given config names.

    Args:
        cfg: a config, as read_config_file returns it, with keys such as "repos" and
            "documents"; or None if there is no config file.

    Returns:
        The file name, such as "pr-status.md", that cfg names, or
        DEFAULT_DEPENDENCY_DOCUMENT if cfg is None.
    """
    return DEFAULT_DEPENDENCY_DOCUMENT if cfg is None else cfg["documents"]["dependencies"]
