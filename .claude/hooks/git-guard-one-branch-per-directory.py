#!/usr/bin/env python3

"""A Claude Code PreToolUse hook that enforces one-branch-per-directory work style.

README.md forbids switching the branch of a working copy and forbids stashing.  The
permission patterns of `.claude/settings.json` cannot express that policy: they match a
command prefix word by word, so a pattern that rejects `git branch NEWBRANCH` (which
creates a branch) also rejects `git branch --show-current` (which is read-only), and no
pattern covers forms such as `git stash -- FILE` or `git -c core.pager=cat -C DIR
checkout BRANCH`.  This hook parses the command instead, and denies:

  * `git checkout` and `git switch` in any form.
  * `git stash` in any form except `list` and `show`.
  * `git branch` in any form other than listing, including the positional forms
    `git branch NEWBRANCH` and `git branch -- NEWBRANCH`.

The hook only ever denies.  A permitted command produces no decision, so the `allow` and
`deny` lists of `.claude/settings.json` still govern it.

This file is shared across multiple repositories.  It must be copied along with the
`.claude/settings.json` that refers to it.

Usage: reads the PreToolUse hook JSON on standard input.  See
https://code.claude.com/docs/en/hooks .
"""

from __future__ import annotations

import json
import re
import shlex
import sys
from pathlib import PurePath
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterator

# Shells whose `-c` argument is itself parsed as a command.
SHELLS = frozenset({"bash", "dash", "ksh", "sh", "zsh"})

# Programs whose arguments this hook parses.
PARSED_PROGRAMS = frozenset({"git"}) | SHELLS

# Commands that run another command given as their trailing arguments.
WRAPPERS = frozenset(
    {"command", "env", "exec", "nice", "nohup", "stdbuf", "sudo", "time", "timeout"}
)

# Characters that make up a shell operator token, such as `;` or `&&`.
OPERATOR_CHARS = frozenset("();<>|&")

# Shell keywords that separate one command from another.
KEYWORDS = frozenset(
    {
        "!",
        "case",
        "do",
        "done",
        "elif",
        "else",
        "esac",
        "fi",
        "if",
        "then",
        "until",
        "while",
        "{",
        "}",
    }
)

# A leading shell variable assignment, as in `GIT_PAGER=cat git ...`.
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z_0-9]*=.*", re.DOTALL)

# A git subcommand that this hook restricts, in a command it could not parse.
FORBIDDEN_MENTION = re.compile(r"\bgit\b.*\b(branch|checkout|stash|switch)\b")

# Git options that precede the subcommand and take a separate value, as in
# `git -C DIR branch`.  The `--option=value` form is handled separately.
GIT_GLOBAL_OPTIONS_WITH_VALUE = frozenset(
    {
        "--attr-source",
        "--config-env",
        "--exec-path",
        "--git-dir",
        "--namespace",
        "--super-prefix",
        "--work-tree",
        "-C",
        "-c",
    }
)

# Read-only `git branch` options that take no value.
BRANCH_READ_ONLY_FLAGS = frozenset(
    {
        "--abbrev",
        "--all",
        "--color",
        "--column",
        "--help",
        "--ignore-case",
        "--list",
        "--no-abbrev",
        "--no-color",
        "--no-column",
        "--omit-empty",
        "--remotes",
        "--show-current",
        "--verbose",
    }
)

# Read-only `git branch` options that take a value, either as `--option=value` or as a
# following argument.
BRANCH_READ_ONLY_OPTIONS_WITH_VALUE = frozenset(
    {
        "--contains",
        "--format",
        "--merged",
        "--no-contains",
        "--no-merged",
        "--points-at",
        "--sort",
    }
)

# Read-only single-letter `git branch` options: --all, --help, --ignore-case, --list,
# --remotes, --verbose.  Clusters such as `-av` are permitted.
BRANCH_READ_ONLY_LETTERS = frozenset("ahilrv")

# `git stash` arguments that neither push a stash entry nor change the working copy.
STASH_READ_ONLY_ARGUMENTS = frozenset({"--help", "-h", "list", "show"})

ALTERNATIVE = (
    "Instead of changing the branch of this working copy, make a new working copy: run"
    " `git-new-branch BRANCH` to create a branch, or `git-checkout-branch BRANCH` to"
    " check out an existing one."
)


class UnparsableCommandError(Exception):
    """A command that could not be split into words."""


def _tokenize(command: str) -> list[str]:
    """Split a shell command into words and operator tokens.

    Args:
        command: a shell command.

    Returns:
        The tokens of the command.
    """
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError as exception:
        message = str(exception)
        raise UnparsableCommandError(message) from exception


def _is_separator(token: str) -> bool:
    """Tell whether a token separates one command from the next.

    Args:
        token: a shell token.

    Returns:
        True if the token is a shell operator or keyword.
    """
    return token in KEYWORDS or (token != "" and frozenset(token) <= OPERATOR_CHARS)


def _simple_commands(tokens: list[str]) -> Iterator[list[str]]:
    """Split a token list at operators and keywords.

    Args:
        tokens: the tokens of a shell command.

    Yields:
        The words of each command in the token list.
    """
    words: list[str] = []
    for token in tokens:
        if _is_separator(token):
            if words:
                yield words
            words = []
        else:
            words.append(token)
    if words:
        yield words


def _strip_prefixes(words: list[str]) -> list[str]:
    """Remove leading variable assignments and command wrappers.

    In `GIT_PAGER=cat sudo -u nobody git branch`, the assignment and the wrapper precede
    the command that is really being run.

    Args:
        words: the words of a single command.

    Returns:
        The words of the command that the prefixes run.
    """
    argv = list(words)
    while argv:
        if ASSIGNMENT.fullmatch(argv[0]):
            del argv[0]
            continue
        if PurePath(argv[0]).name in WRAPPERS:
            # Skips the wrapper and its own arguments, such as `-u nobody`.
            del argv[0]
            while argv and PurePath(argv[0]).name not in PARSED_PROGRAMS:
                del argv[0]
            continue
        break
    return argv


def _git_invocations(command: str) -> Iterator[list[str]]:
    """Find the git invocations in a shell command.

    Args:
        command: a shell command.

    Yields:
        The argument list of each `git` invocation.
    """
    for words in _simple_commands(_tokenize(command)):
        argv = _strip_prefixes(words)
        if not argv:
            continue
        program = PurePath(argv[0]).name
        if program == "git":
            yield argv
        elif program in SHELLS:
            # Parses the argument of `-c`, as in `sh -c 'git checkout main'`.
            for index in range(1, len(argv) - 1):
                if argv[index] == "-c":
                    yield from _git_invocations(argv[index + 1])
                    break


def _subcommand(argv: list[str]) -> tuple[str | None, list[str]]:
    """Find the subcommand of a git invocation, skipping git's own global options.

    Args:
        argv: the argument list of a `git` invocation.

    Returns:
        The subcommand and its arguments, or None and an empty list if the invocation
        has no subcommand.
    """
    index = 1
    while index < len(argv):
        token = argv[index]
        if not token.startswith("-"):
            return token, argv[index + 1 :]
        if "=" not in token and token in GIT_GLOBAL_OPTIONS_WITH_VALUE:
            index += 2
        else:
            index += 1
    return None, []


def _branch_denial(args: list[str]) -> str | None:
    """Decide whether a `git branch` command does more than list branches.

    Args:
        args: the arguments to `git branch`.

    Returns:
        Why the command is forbidden, or None if it only lists branches.
    """
    listing = False
    operands: list[str] = []
    end_of_options = False
    index = 0
    while index < len(args):
        token = args[index]
        index += 1
        if end_of_options or not token.startswith("-") or token == "-":
            operands.append(token)
            continue
        if token == "--":
            end_of_options = True
            continue
        name, _, value = token.partition("=")
        if name in BRANCH_READ_ONLY_FLAGS:
            listing = listing or name == "--list"
            continue
        if name in BRANCH_READ_ONLY_OPTIONS_WITH_VALUE:
            if not value and index < len(args) and not args[index].startswith("-"):
                index += 1
            continue
        if name.startswith("--"):
            return f"`git branch {name}` modifies branches."
        for letter in name[1:]:
            if letter not in BRANCH_READ_ONLY_LETTERS:
                return f"`git branch -{letter}` modifies branches."
            listing = listing or letter == "l"
    if operands and not listing:
        return (
            f"`git branch {operands[0]}` creates a branch."
            "  To list branches without creating one, pass `--list`."
        )
    return None


def _stash_denial(args: list[str]) -> str | None:
    """Decide whether a `git stash` command does more than read stash entries.

    Args:
        args: the arguments to `git stash`.

    Returns:
        Why the command is forbidden, or None if it only reads stash entries.
    """
    if args and args[0] in STASH_READ_ONLY_ARGUMENTS:
        return None
    if not args or args[0].startswith("-"):
        # `git stash`, `git stash -- FILE`, and `git stash --keep-index` all push a
        # stash entry.
        return "`git stash` without a subcommand pushes a stash entry."
    return f"`git stash {args[0]}` changes the stash or the working copy."


def denial(command: str) -> str | None:
    """Decide whether a shell command changes the branch of a working copy.

    Args:
        command: the command that the Bash tool was asked to run.

    Returns:
        Why the command is forbidden, or None if it is permitted.
    """
    try:
        invocations = list(_git_invocations(command))
    except UnparsableCommandError:
        if FORBIDDEN_MENTION.search(command):
            return (
                "This command could not be parsed, and it might change the branch of"
                " this working copy."
            )
        return None
    for argv in invocations:
        name, args = _subcommand(argv)
        if name in ("checkout", "switch"):
            reason = f"`git {name}` switches the branch of this working copy."
        elif name == "branch":
            reason = _branch_denial(args)
        elif name == "stash":
            reason = _stash_denial(args)
        else:
            reason = None
        if reason is not None:
            return reason
    return None


def main() -> int:
    """Read a PreToolUse hook request from standard input and decide about it.

    Returns:
        The exit status: 1 if the request could not be read, otherwise 0.
    """
    try:
        request = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError) as exception:
        print(
            f"git-guard-one-branch-per-directory.py: cannot parse hook input: {exception}",
            file=sys.stderr,
        )
        return 1
    if not isinstance(request, dict):
        print(
            f"git-guard-one-branch-per-directory.py: hook input is not an object: {request!r}",
            file=sys.stderr,
        )
        return 1
    if request.get("tool_name") != "Bash":
        return 0
    command = request.get("tool_input", {}).get("command", "")
    if not isinstance(command, str):
        return 0
    reason = denial(command)
    if reason is None:
        return 0
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": f"{reason}  {ALTERNATIVE}",
            }
        },
        sys.stdout,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
