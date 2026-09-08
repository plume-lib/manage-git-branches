#!/usr/bin/env python3

"""A Claude Code PreToolUse hook that enforces one-branch-per-directory work style.

README.md forbids switching the branch of a working copy and forbids stashing.  The
permission patterns of `.claude/settings.json` cannot express that policy.  A pattern is
a literal command prefix or a whole-command glob (one that ends in a space and a star is
tried both ways), so a pattern that rejects `git branch NEWBRANCH` (which creates a
branch) also rejects `git branch --show-current` (which is read-only); and a pattern that
has both an interior `*` and a trailing `:*`, which is what covering
`git -c core.pager=cat -C DIR checkout BRANCH` would take, matches nothing at all.  This
hook parses the command instead, and denies:

  * `git checkout` and `git switch` in any form.
  * `git stash` in any form except `list` and `show`.
  * `git branch` in any form other than listing, including the positional forms
    `git branch NEWBRANCH` and `git branch -- NEWBRANCH`.

The hook inspects the `git` invocations of a command: those of a command list, of a
shell's `-c` argument, of a here-document that feeds a shell, of `eval`, of `xargs`, of
`find -exec`, and of `ssh`.  It does not follow command substitution, nor a command that
is built at run time, such as `echo "git $operation main" | sh`.  A command that cannot
be split into words is denied if it mentions a restricted subcommand.

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

# This script's name, for its messages on standard error.
PROGRAM = "git-guard-one-branch-per-directory.py"

# Shells whose `-c` argument is itself parsed as a command.
SHELLS = frozenset({"bash", "dash", "ksh", "sh", "zsh"})

# Programs that run a command on another host, as `ssh HOST git checkout main` does.
REMOTE_SHELLS = frozenset({"rsh", "ssh"})

# Programs that receive a command as data and then run it.  `eval` and a remote shell
# run shell text; `xargs` and `find -exec` run an argument list.
INDIRECT_PROGRAMS = frozenset({"eval", "find", "xargs"}) | REMOTE_SHELLS

# Programs whose arguments this hook parses.
PARSED_PROGRAMS = frozenset({"git"}) | SHELLS | INDIRECT_PROGRAMS

# Commands that run another command given as their trailing arguments.
WRAPPERS = frozenset(
    {"command", "env", "exec", "nice", "nohup", "stdbuf", "sudo", "time", "timeout"}
)

# Characters that make up a shell operator token, such as `;` or `&&`.  A newline
# separates one command from the next, so it is an operator rather than whitespace.
OPERATOR_CHARACTERS = "();<>|&\n"
OPERATOR_CHARS = frozenset(OPERATOR_CHARACTERS)

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
FORBIDDEN_MENTION = re.compile(r"\bgit\s+((-{1,2}\S+|\S+=\S+)\s+)*(branch|checkout|stash|switch)\b")

# A here-document: the redirection operator, the delimiter word, the rest of the line
# that holds them, the body, and the line that holds the delimiter alone.  A `<<-`
# here-document permits leading tabs on that line.  The body starts at the next line,
# not just after the delimiter word, because what follows the delimiter word on its own
# line is shell syntax rather than data, as in `cat <<EOF && git checkout main`.
HEREDOC = re.compile(
    r"<<-?[ \t]*(?P<quote>['\"]?)(?P<delimiter>\w+)(?P=quote)"
    r"(?P<rest>[^\n]*)\n(?P<body>.*?)^[\t]*(?P=delimiter)[ \t]*$",
    re.DOTALL | re.MULTILINE,
)

# Git options that precede the subcommand and take a separate value, as in
# `git -C DIR branch`.  The `--option=value` form is handled separately, and so is an
# option such as `--exec-path`, whose value is optional and therefore must be written
# with `=`; treating it as taking a separate value would skip the subcommand.
GIT_GLOBAL_OPTIONS_WITH_VALUE = frozenset(
    {
        "--attr-source",
        "--config-env",
        "--git-dir",
        "--namespace",
        "--work-tree",
        "-C",
        "-c",
    }
)

# `xargs` options that take a separate value.
XARGS_OPTIONS_WITH_VALUE = frozenset(
    {
        "--arg-file",
        "--delimiter",
        "--eof",
        "--max-args",
        "--max-chars",
        "--max-lines",
        "--max-procs",
        "--process-slot-var",
        "--replace",
        "-E",
        "-I",
        "-L",
        "-P",
        "-a",
        "-d",
        "-n",
        "-s",
    }
)

# `find` primaries that run a command, and the arguments that end that command.
FIND_COMMAND_PRIMARIES = frozenset({"-exec", "-execdir", "-ok", "-okdir"})
FIND_COMMAND_TERMINATORS = frozenset({"+", ";"})

# Single-letter `ssh` options that take a separate value.  `ssh` has no long options.
SSH_OPTION_LETTERS_WITH_VALUE = frozenset("BbcDEeFIiJLlmOopQRSWw")

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
    lexer = shlex.shlex(command, posix=True, punctuation_chars=OPERATOR_CHARACTERS)
    # A newline is an operator, per OPERATOR_CHARACTERS, so it is not also whitespace.
    lexer.whitespace = " \t\r"
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


def _remove_heredoc_bodies(command: str) -> tuple[str, list[str]]:
    """Take the here-document bodies out of a shell command.

    A here-document body is data, not shell syntax, so parsing it as a command would
    misread the text that a command such as `cat > file <<EOF` merely writes.  The rest
    of the line that introduces the here-document is shell syntax, so it is kept.

    Args:
        command: a shell command.

    Returns:
        The command without its here-document bodies, and those bodies.
    """
    bodies: list[str] = []

    def take(match: re.Match[str]) -> str:
        bodies.append(match.group("body"))
        # Keeps what follows the delimiter word on its own line, which is shell syntax.
        return "<<" + match.group("rest")

    return HEREDOC.sub(take, command), bodies


def _is_shell_command_option(token: str) -> bool:
    """Tell whether a shell option introduces a command, as `-c` and the cluster `-lc` do.

    Args:
        token: an argument of a shell.

    Returns:
        True if the shell runs the following argument as a command.
    """
    return token.startswith("-") and not token.startswith("--") and "c" in token[1:]


def _xargs_command(argv: list[str]) -> list[str]:
    """Find the command that an `xargs` invocation runs.

    Args:
        argv: the argument list of an `xargs` invocation.

    Returns:
        The words of the command, or an empty list if there is none.  The words that
        `xargs` appends from its own input are not known here, so they are absent.
    """
    index = 1
    while index < len(argv):
        token = argv[index]
        if token == "-" or not token.startswith("-"):
            return argv[index:]
        if "=" not in token and token in XARGS_OPTIONS_WITH_VALUE:
            index += 2
        else:
            index += 1
    return []


def _find_commands(argv: list[str]) -> Iterator[list[str]]:
    """Find the commands that a `find` invocation runs, as in `find . -exec CMD ;`.

    Args:
        argv: the argument list of a `find` invocation.

    Yields:
        The words of each command.
    """
    index = 1
    while index < len(argv):
        if argv[index] not in FIND_COMMAND_PRIMARIES:
            index += 1
            continue
        index += 1
        words: list[str] = []
        while index < len(argv) and argv[index] not in FIND_COMMAND_TERMINATORS:
            words.append(argv[index])
            index += 1
        yield words


def _remote_shell_command(argv: list[str]) -> list[str]:
    """Find the command that an `ssh` invocation runs on another host.

    Args:
        argv: the argument list of an `ssh` or `rsh` invocation.

    Returns:
        The words of the command, or an empty list if there is none.
    """
    index = 1
    while index < len(argv):
        token = argv[index]
        if token == "-" or not token.startswith("-"):
            # This operand is the destination host, and the rest is the command.
            return argv[index + 1 :]
        if len(token) == 2 and token[1] in SSH_OPTION_LETTERS_WITH_VALUE:
            index += 2
        else:
            index += 1
    return []


def _git_invocations(command: str) -> Iterator[list[str]]:
    """Find the git invocations in a shell command.

    Args:
        command: a shell command.

    Yields:
        The argument list of each `git` invocation.
    """
    without_bodies, bodies = _remove_heredoc_bodies(command)
    programs = set()
    for words in _simple_commands(_tokenize(without_bodies)):
        argv = _strip_prefixes(words)
        if not argv:
            continue
        programs.add(PurePath(argv[0]).name)
        yield from _invocations_of(argv)
    if programs & SHELLS:
        # A here-document that feeds a shell is a script, as in `sh <<'EOF'`.
        for body in bodies:
            yield from _git_invocations(body)


def _invocations_of(argv: list[str]) -> Iterator[list[str]]:
    """Find the git invocations that a single command runs.

    A command that receives another command as data runs git without being git, so
    this function looks inside it.

    Args:
        argv: the nonempty words of a single command, its prefixes already removed.

    Yields:
        The argument list of each `git` invocation.
    """
    program = PurePath(argv[0]).name
    if program == "git":
        yield argv
    elif program in SHELLS:
        # Parses the argument of `-c`, as in `sh -c 'git checkout main'`.
        for index in range(1, len(argv) - 1):
            if _is_shell_command_option(argv[index]):
                yield from _git_invocations(argv[index + 1])
                break
    elif program == "eval":
        # `eval` joins its arguments and runs the result as a shell command.
        yield from _git_invocations(" ".join(argv[1:]))
    elif program in REMOTE_SHELLS:
        # `ssh` also joins its arguments, and a shell on the host runs the result.
        yield from _git_invocations(" ".join(_remote_shell_command(argv)))
    elif program == "xargs":
        yield from _indirect_invocations(_xargs_command(argv))
    elif program == "find":
        for words in _find_commands(argv):
            yield from _indirect_invocations(words)


def _indirect_invocations(argv: list[str]) -> Iterator[list[str]]:
    """Find the git invocations of a command that another command runs.

    The words are already split, as `xargs` and `find -exec` receive them, so they
    are not shell syntax to be parsed again.

    Args:
        argv: the words of the command, or an empty list if there is none.

    Yields:
        The argument list of each `git` invocation.
    """
    words = _strip_prefixes(argv)
    if words:
        yield from _invocations_of(words)


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


def _unanalyzable_denial(command: str) -> str | None:
    """Decide about a command that this hook could not analyze.

    Args:
        command: the command that the Bash tool was asked to run.

    Returns:
        Why the command is forbidden, or None if it mentions nothing forbidden.
    """
    if FORBIDDEN_MENTION.search(command):
        return (
            "This command could not be analyzed, and it might change the branch of"
            " this working copy."
        )
    return None


def _denials(command: str) -> Iterator[str]:
    """Find the reasons that a shell command is forbidden.

    Args:
        command: the command that the Bash tool was asked to run.

    Yields:
        Why each forbidden git invocation of the command is forbidden.
    """
    for argv in _git_invocations(command):
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
            yield reason


def denial(command: str) -> str | None:
    """Decide whether a shell command changes the branch of a working copy.

    Args:
        command: the command that the Bash tool was asked to run.

    Returns:
        Why the command is forbidden, or None if it is permitted.
    """
    try:
        return next(_denials(command), None)
    except UnparsableCommandError:
        return _unanalyzable_denial(command)
    except Exception as exception:  # ruff: ignore[blind-except]
        # The catch is deliberately blind: a defect in this hook must report itself
        # rather than permit a command that changes the branch of this working copy.
        print(f"{PROGRAM}: cannot analyze {command!r}: {exception!r}", file=sys.stderr)
        return _unanalyzable_denial(command)


def main() -> int:
    """Read a PreToolUse hook request from standard input and decide about it.

    Returns:
        The exit status: 1 if the request could not be read, otherwise 0.
    """
    try:
        request = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError) as exception:
        print(f"{PROGRAM}: cannot parse hook input: {exception}", file=sys.stderr)
        return 1
    if not isinstance(request, dict):
        print(f"{PROGRAM}: hook input is not an object: {request!r}", file=sys.stderr)
        return 1
    if request.get("tool_name") != "Bash":
        return 0
    tool_input = request.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
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
