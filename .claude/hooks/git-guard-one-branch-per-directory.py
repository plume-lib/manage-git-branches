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
shell's `-c` argument, of a here-document that feeds a shell, of `eval`, of `env -S`, of
`xargs`, of `find -exec`, of `ssh`, and of an `ssh` option such as `-o ProxyCommand=...`
that names a command that runs on the local host.  It does not follow command
substitution, nor a command that is built at run time, such as
`echo "git $operation main" | sh`.  A command that cannot be split into words is denied
if it mentions a restricted subcommand.

The hook also approves a command that only reads a repository, which no `allow` pattern
can safely do.  Such a pattern would need a wildcard before the subcommand, as in
`git -C * log`, and because `*` spans words that also matches an inserted global option
such as `-c core.pager=CMD`, which makes git run an arbitrary command; Claude Code warns
at startup about an `allow` pattern of that shape.  This hook parses the options instead,
and approves a command only when every command in it is a `git` invocation whose global
options cannot run another program and whose subcommand only reads.

A command that is neither denied nor approved produces no decision, so the `allow` and
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

# The `env` option that gives the whole command as one argument, which `env` splits
# into words itself, as in `env -S 'git checkout main'`.  A long option may be
# abbreviated, so `--split-string` is recognized by any unambiguous prefix of it.
ENV_SPLIT_STRING_OPTION = "--split-string"
ENV_SPLIT_STRING_LETTER = "S"

# Other `env` options that take a value, which may be attached, as in `-uNAME`, or a
# separate argument.  An option whose value is optional, such as `--block-signal`, must
# be written with `=`, so it never takes a separate argument.
ENV_OPTION_LETTERS_WITH_VALUE = frozenset("Cu")
ENV_LONG_OPTIONS_WITH_VALUE = frozenset({"--chdir", "--unset"})

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

# Single-letter `ssh` options that take a value, either attached to the letter or as
# the following argument.  `ssh` has no long options.
SSH_OPTION_LETTERS_WITH_VALUE = frozenset("BbcDEeFIiJLlmOopQRSWw")

# `ssh` configuration settings, given by `-o`, whose value is a command that runs on
# the local host rather than on the remote one.  A setting name is case-insensitive,
# as in an `ssh_config` file.
SSH_LOCAL_COMMAND_SETTINGS = frozenset({"localcommand", "proxycommand"})

# The value of an `ssh` `-o` option: a setting name, then `=` or whitespace, then the
# value, as in `-o ProxyCommand=CMD` and `-o "ProxyCommand CMD"`.
SSH_SETTING = re.compile(r"\s*(?P<name>\w+)\s*=?\s*(?P<value>.*)", re.DOTALL)

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

# `git branch` options that put it in list mode, so that an operand is a pattern to
# match rather than the name of a branch to create.  Each filter below selects which
# branches to list, and `git branch` refuses `--all` and `--remotes` with an operand
# unless `--list` is also given, so none of these can create a branch.
# `--format`, `--sort`, and `--verbose` are deliberately absent:  each of
# `git branch --format=%(refname) BRANCH`, `git branch --sort=refname BRANCH`, and
# `git branch -v BRANCH` creates a branch.
BRANCH_LIST_FLAGS = frozenset({"--all", "--list", "--remotes"})

# List-mode `git branch` options that take a value, either as `--option=value` or as
# a following argument.
BRANCH_LIST_OPTIONS_WITH_VALUE = frozenset(
    {
        "--contains",
        "--merged",
        "--no-contains",
        "--no-merged",
        "--points-at",
    }
)

# Single-letter list-mode `git branch` options: --all, --list, --remotes.
BRANCH_LIST_LETTERS = frozenset("alr")

# `git stash` arguments that neither push a stash entry nor change the working copy.
STASH_READ_ONLY_ARGUMENTS = frozenset({"--help", "-h", "list", "show"})

# Git global options that this hook approves, none of which names a program to run.
# An option that is absent here, such as `-c`, `--config-env`, or `--exec-path`, can
# make git run an arbitrary command, so a command that passes one is left to the
# permission system.  `-C`, whose value is attached as in `-Cdir` or separate as in
# `-C dir`, is approved by _reads_only rather than by this set.
APPROVED_GLOBAL_OPTIONS = frozenset(
    {
        "--glob-pathspecs",
        "--icase-pathspecs",
        "--literal-pathspecs",
        "--no-optional-locks",
        "--no-pager",
        "--noglob-pathspecs",
        "--paginate",
        "-P",
    }
)

# Git subcommands that only read a repository, whatever their arguments.  These are
# exactly the read-only subcommands that the `allow` list of `.claude/settings.json`
# permits with any arguments, so approving one here adds only a global option and
# `-C DIR` to what that list already permits.  `branch` and `stash` are absent
# because only some of their forms read: see _branch_denial and _stash_denial.
READ_ONLY_SUBCOMMANDS = frozenset({"diff", "log", "rev-parse", "show", "status"})

# The shell operator characters that may appear in an approved command.  They run one
# command after another, as `;`, `&&`, `||`, `|`, `&`, and a newline do.  An operator
# that is absent here redirects a file or opens a subshell, as `<`, `>`, `(`, and `)`
# do, and a shell keyword such as `if` is absent too, so a command that uses one is
# left to the permission system.
APPROVED_OPERATOR_CHARS = frozenset(";&|\n")

# Shell syntax that this hook does not interpret, and that _tokenize does not report
# as a command of its own: command substitution and parameter expansion.  Either can
# run a command, as a backquoted command in an argument does, so a command that
# contains one is left to the permission system.
UNAPPROVABLE_CHARACTERS = "`$"

# Why an approved command is approved, for the permission decision.
APPROVAL = "This command only reads a git repository."

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
    # A `#` begins a comment only at the start of a word, but shlex would begin a
    # comment at one anywhere and would discard the rest of the line *including its
    # newline*.  That would hide the commands after it on the same line -- a shell
    # runs the `rm` of `git log a#; rm FILE` -- and would append the next line's
    # words to the current command, hiding the `git` that starts that next command.
    # Treating `#` as an ordinary character instead only ever reports more commands
    # than a shell runs, as it does for a real comment, so it cannot hide a
    # forbidden command.
    lexer.commenters = ""
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


def _is_long_option(token: str, option: str) -> bool:
    """Tell whether a token is a long option, possibly abbreviated.

    A long option may be written as any unambiguous prefix of its name, so `--split`
    is `--split-string`.

    Args:
        token: an argument, without any `=value` suffix.
        option: the full name of a long option.

    Returns:
        True if the token names the option.
    """
    return len(token) > 2 and option.startswith(token)


def _env_split_string(argv: list[str]) -> list[str] | None:
    """Find the command that `env -S` runs, which `env` itself splits into words.

    `env -S 'git checkout main'` gives the whole command as one argument, so skipping
    `env` and its arguments would skip the git invocation along with them.

    A command string that cannot be split into words raises UnparsableCommandError, so
    that the caller denies the command rather than letting it through unexamined.

    Args:
        argv: the arguments of an `env` invocation, without the `env` itself.

    Returns:
        The words of the command, or None if there is no split-string option.
    """
    index = 0
    while index < len(argv):
        token = argv[index]
        index += 1
        if token == "--" or not token.startswith("-") or token == "-":
            # `env` stops parsing its own options at its first operand.
            return None
        name, separator, value = token.partition("=")
        if name.startswith("--"):
            if _is_long_option(name, ENV_SPLIT_STRING_OPTION):
                return _env_command(value if separator else None, argv, index)
            if not separator and any(
                _is_long_option(name, option) for option in ENV_LONG_OPTIONS_WITH_VALUE
            ):
                index += 1
            continue
        # A cluster of single-letter options, as in `env -iS 'git checkout main'`.
        for position, letter in enumerate(token[1:], start=2):
            if letter == ENV_SPLIT_STRING_LETTER:
                return _env_command(token[position:] or None, argv, index)
            if letter in ENV_OPTION_LETTERS_WITH_VALUE:
                # The value is the rest of this argument, or the next argument.
                if not token[position:]:
                    index += 1
                break
    return None


def _env_command(value: str | None, argv: list[str], index: int) -> list[str]:
    """Assemble the command of `env -S` from its command string and what follows it.

    `env` splits the command string into words and appends its own remaining
    arguments, so `env -S git branch newbranch` runs `git branch newbranch`.

    Args:
        value: the command string, if it is attached to the option, else None.
        argv: the arguments of the `env` invocation, without the `env` itself.
        index: the index of the argument that follows the split-string option.

    Returns:
        The words of the command.
    """
    if value is None:
        value = _argument(argv, index)
        index += 1
    return _tokenize(value) + argv[index:]


def _argument(argv: list[str], index: int) -> str:
    """Return the argument at an index, or the empty string if there is none.

    Args:
        argv: an argument list.
        index: the index of the wanted argument.

    Returns:
        The argument, or the empty string.
    """
    return argv[index] if index < len(argv) else ""


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
        program = PurePath(argv[0]).name
        if program in WRAPPERS:
            # Skips the wrapper and its own arguments, such as `-u nobody`.
            del argv[0]
            if program == "env":
                # `env -S 'git checkout main'` hides the command in one argument.
                split = _env_split_string(argv)
                if split is not None:
                    argv = split
                    continue
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


def _ssh_arguments(argv: list[str]) -> tuple[list[tuple[str, str]], list[str]]:
    """Split an `ssh` argument list into its options and its operands.

    Args:
        argv: the argument list of an `ssh` or `rsh` invocation.

    Returns:
        Each option letter with its value, which is empty if the option takes none;
        and the operands, which are the destination host and the remote command.
    """
    options: list[tuple[str, str]] = []
    index = 1
    while index < len(argv):
        token = argv[index]
        index += 1
        if token == "-" or not token.startswith("-"):
            return options, [token, *argv[index:]]
        # A cluster of single-letter options, as in `ssh -vp 22 host`.
        for position, letter in enumerate(token[1:], start=2):
            if letter not in SSH_OPTION_LETTERS_WITH_VALUE:
                options.append((letter, ""))
                continue
            value = token[position:]
            if not value:
                value = _argument(argv, index)
                index += 1
            options.append((letter, value))
            break
    return options, []


def _remote_shell_command(argv: list[str]) -> list[str]:
    """Find the command that an `ssh` invocation runs on another host.

    Args:
        argv: the argument list of an `ssh` or `rsh` invocation.

    Returns:
        The words of the command, or an empty list if there is none.
    """
    # The first operand is the destination host, and the rest is the command.
    return _ssh_arguments(argv)[1][1:]


def _local_shell_commands(argv: list[str]) -> Iterator[str]:
    """Find the commands that an `ssh` invocation runs on the local host.

    `ssh -o ProxyCommand=CMD` runs CMD in a shell on the local host, so a `git` in it
    acts on this working copy rather than on one elsewhere.

    Args:
        argv: the argument list of an `ssh` or `rsh` invocation.

    Yields:
        Each local command, as shell text.
    """
    for letter, value in _ssh_arguments(argv)[0]:
        if letter != "o":
            continue
        setting = SSH_SETTING.fullmatch(value)
        if setting is not None and setting.group("name").lower() in SSH_LOCAL_COMMAND_SETTINGS:
            yield setting.group("value")


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
        # An option such as `-o ProxyCommand=CMD` runs CMD on the local host.
        for local in _local_shell_commands(argv):
            yield from _git_invocations(local)
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
            listing = listing or name in BRANCH_LIST_FLAGS
            continue
        if name in BRANCH_READ_ONLY_OPTIONS_WITH_VALUE:
            listing = listing or name in BRANCH_LIST_OPTIONS_WITH_VALUE
            if not value and index < len(args) and not args[index].startswith("-"):
                index += 1
            continue
        if name.startswith("--"):
            return f"`git branch {name}` modifies branches."
        for letter in name[1:]:
            if letter not in BRANCH_READ_ONLY_LETTERS:
                return f"`git branch -{letter}` modifies branches."
            listing = listing or letter in BRANCH_LIST_LETTERS
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


def _reads_only(argv: list[str]) -> bool:
    """Tell whether a git invocation only reads a repository.

    Args:
        argv: the argument list of a `git` invocation.

    Returns:
        True if every global option is harmless and the subcommand only reads.
    """
    index = 1
    while index < len(argv) and argv[index].startswith("-"):
        token = argv[index]
        if token == "-C":
            # The directory is the next argument, which may be absent.
            index += 2
        elif token.startswith("-C"):
            # The directory is attached, as in `git -Cdir log`.
            index += 1
        elif token in APPROVED_GLOBAL_OPTIONS:
            index += 1
        else:
            return False
    if index >= len(argv):
        # No subcommand, as in `git`, `git -C`, and `git --no-pager`.
        return False
    name = argv[index]
    args = argv[index + 1 :]
    if name == "branch":
        return _branch_denial(args) is None
    if name == "stash":
        return _stash_denial(args) is None
    return name in READ_ONLY_SUBCOMMANDS


def _approves(command: str) -> bool:
    """Tell whether every command of a shell command only reads a repository.

    An approval covers the whole command, so one command in it that is not a read-only
    git invocation withholds approval from all of them.  A program that runs a command
    given to it as data, such as `xargs`, and a wrapper such as `sudo` are not
    approved either: `git` must be the command itself.

    Args:
        command: the command that the Bash tool was asked to run.

    Returns:
        True if the command may run without a permission prompt.
    """
    if any(character in command for character in UNAPPROVABLE_CHARACTERS):
        return False
    tokens = _tokenize(command)
    for token in tokens:
        if _is_separator(token) and not frozenset(token) <= APPROVED_OPERATOR_CHARS:
            return False
    commands = list(_simple_commands(tokens))
    # The program must be written as the bare word `git`, which the shell looks up on
    # `PATH`.  A path-qualified form such as `./git` or `/tmp/git` names some other
    # program that merely has git's file name, so it is left to the permission system.
    return bool(commands) and all(argv[0] == "git" and _reads_only(argv) for argv in commands)


def approval(command: str) -> str | None:
    """Decide whether a shell command may run without a permission prompt.

    Args:
        command: the command that the Bash tool was asked to run.

    Returns:
        Why the command is approved, or None if this hook does not approve it.
    """
    try:
        return APPROVAL if _approves(command) else None
    except UnparsableCommandError:
        return None
    except Exception as exception:  # ruff: ignore[blind-except]
        # The catch is deliberately blind: a defect in this hook must report itself
        # rather than approve a command that it did not analyze.
        print(f"{PROGRAM}: cannot analyze {command!r}: {exception!r}", file=sys.stderr)
        return None


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


def _decide(decision: str, reason: str) -> None:
    """Write a permission decision to standard output.

    Args:
        decision: the permission decision, `allow` or `deny`.
        reason: why the hook made that decision.
    """
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )


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
    if reason is not None:
        _decide("deny", f"{reason}  {ALTERNATIVE}")
        return 0
    reason = approval(command)
    if reason is not None:
        _decide("allow", reason)
    return 0


if __name__ == "__main__":
    sys.exit(main())
