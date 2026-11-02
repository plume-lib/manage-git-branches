"""Print the environment variables that a Python script reads or sets.

Usage: python3 -I python-environ-variables.py FILE KIND

Prints, one per line and sorted, the environment variables that FILE, a Python
script, uses in the way that KIND, which is "read" or "set", names:

* "read":  as in `os.environ.get("VAR")`, `os.environ["VAR"]`,
  `os.getenv("VAR")`, or `"VAR" in os.environ`.
* "set":  as in `os.environ["VAR"] = value`.

A deletion, as in `del os.environ["VAR"]`, neither reads nor sets.  This parses
FILE, so that a call that spans lines counts and a string or comment that
mentions `os.environ` does not.  Like the check of shell scripts, it considers
only upper-case names, such as "VAR".  It fails if FILE is not valid Python.
"""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path
from typing import NamedTuple


class VariableUse(NamedTuple):
    """A use of an environment variable."""

    name: str
    """The name of the environment variable, such as "VAR"."""
    kind: str
    """How the variable is used:  "read" or "set"."""


def is_environ(node: ast.expr) -> bool:
    """Return True if the given expression is `os.environ` or `environ`.

    Args:
        node: an expression.

    Returns:
        True if the expression is `os.environ` or `environ`.
    """
    return (isinstance(node, ast.Attribute) and node.attr == "environ") or (
        isinstance(node, ast.Name) and node.id == "environ"
    )


def string_value(node: ast.expr) -> str | None:
    """Return the value of the given string literal.

    Args:
        node: an expression.

    Returns:
        The value of the expression if it is a string literal, or None if it
        is not one.
    """
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    return None


def variable_use(node: ast.AST) -> VariableUse | None:
    """Return the use of an environment variable that the given node makes.

    Args:
        node: a node of a Python syntax tree.

    Returns:
        The use, or None if the node neither reads nor sets an environment
        variable whose name is a string literal.
    """
    if isinstance(node, ast.Call) and node.args:
        func = node.func
        if (
            isinstance(func, ast.Attribute)
            and func.attr in {"get", "pop", "setdefault"}
            and is_environ(func.value)
        ) or (
            (isinstance(func, ast.Attribute) and func.attr == "getenv")
            or (isinstance(func, ast.Name) and func.id == "getenv")
        ):
            name = string_value(node.args[0])
            return None if name is None else VariableUse(name, "read")
    elif isinstance(node, ast.Subscript) and is_environ(node.value):
        name = string_value(node.slice)
        kind = {ast.Load: "read", ast.Store: "set"}.get(type(node.ctx))
        return None if name is None or kind is None else VariableUse(name, kind)
    elif (
        isinstance(node, ast.Compare)
        and len(node.ops) == 1
        and isinstance(node.ops[0], (ast.In, ast.NotIn))
        and is_environ(node.comparators[0])
    ):
        name = string_value(node.left)
        return None if name is None else VariableUse(name, "read")
    return None


def main() -> None:
    """Print the environment variables that the script reads or sets."""
    file, wanted_kind = sys.argv[1], sys.argv[2]
    tree = ast.parse(Path(file).read_text(encoding="utf-8"), file)
    names = set()
    for node in ast.walk(tree):
        use = variable_use(node)
        if (
            use is not None
            and use.kind == wanted_kind
            and re.fullmatch(r"[A-Z][A-Z0-9_]*", use.name)
        ):
            names.add(use.name)
    for name in sorted(names):
        print(name)


if __name__ == "__main__":
    main()
