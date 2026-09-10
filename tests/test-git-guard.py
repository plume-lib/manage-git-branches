#!/usr/bin/env python3

"""Test `.claude/hooks/git-guard-one-branch-per-directory.py`.

That hook forbids changing the branch of a working copy, and approves a command that
only reads a repository.

Usage:
  tests/test-git-guard.py
"""

from __future__ import annotations

import fnmatch
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
REPOSITORY_DIR = TESTS_DIR.parent
GUARD = REPOSITORY_DIR / ".claude" / "hooks" / "git-guard-one-branch-per-directory.py"
SETTINGS = REPOSITORY_DIR / ".claude" / "settings.json"

# Commands that the hook must deny.
FORBIDDEN = (
    # Creating a branch, in every form that names it positionally.
    "git branch newbranch",
    "git branch -- newbranch",
    "git branch -v newbranch",
    "git branch newbranch origin/main",
    "git -C /some/dir branch newbranch",
    "git --no-pager branch newbranch",
    "git -c color.ui=always -C /some/dir branch newbranch",
    # Other modifications of branches.
    "git branch -d oldbranch",
    "git branch -D oldbranch",
    "git branch -m oldname newname",
    "git branch --track newbranch origin/newbranch",
    "git branch --set-upstream-to=origin/main",
    "git branch --edit-description",
    "git -C /some/dir branch --delete oldbranch",
    # Stashing, including the forms that push a stash entry implicitly.
    "git stash",
    "git stash --",
    "git stash -- README.md",
    "git stash --keep-index",
    "git stash push -m message",
    "git stash pop",
    "git -C /some/dir stash",
    "git -C /some/dir stash -- README.md",
    # Switching branches.
    "git checkout main",
    "git switch main",
    "git checkout -b newbranch",
    "git -c core.pager=cat -C /some/dir checkout main",
    "git --git-dir=/some/dir/.git switch main",
    # Hidden inside a larger command.
    "git status && git branch newbranch",
    "git log --oneline; git stash",
    "cat README.md | grep -q stash || git stash",
    "sh -c 'git checkout main'",
    "GIT_PAGER=cat git branch newbranch",
    "sudo -u nobody git checkout main",
    "timeout 300 git stash",
    # A shell's command option may be part of a cluster.
    "bash -lc 'git checkout main'",
    "sh -xc 'git stash'",
    "sh -cx 'git branch newbranch'",
    # A newline separates one command from the next, so a later line is a command too.
    "git status\ngit checkout main",
    "git status\ngit branch newbranch",
    "git log --oneline\n\ngit stash",
    "cd /some/dir\ngit switch main\nmake",
    # A `#` comment ends at the newline, so the next line is still a command.
    "git status # check state\ngit switch main",
    "cd /some/dir # go there\ngit checkout -b newbranch",
    "git log --oneline -1 #\ngit branch newbranch",
    "cd /some/dir # go there\ngit checkout main",
    "ls  #\ngit switch main",
    "make test # build the project\ngit branch newbranch",
    "echo a#b\ngit stash",
    "git status # check\ngit checkout main",
    "sh <<'EOF'\n# Switch to main.\ngit checkout main\nEOF",
    # A `<<EOF` inside a comment does not introduce a here-document, so the line after
    # the comment is a command rather than that here-document's body.
    "echo hi # <<EOF\ngit checkout main\nEOF",
    "echo hi # <<'EOF'\ngit checkout main\nEOF",
    # A here-document body is data, so an unmatched quote in one, as in `user's`, opens
    # no quotation that could hide the comment on a later line.
    "cat > notes.md <<'EOF'\nThe user's rules.\nEOF\n# <<EOF\ngit checkout main\nEOF",
    "cat > notes.md <<EOF\nIt isn't run.\nEOF\n# write the notes <<EOF\ngit stash\nEOF",
    # A line continuation is no word boundary:  the shell joins the lines, so a `#`
    # that follows one still begins a comment, and a `<<EOF` in that comment introduces
    # no here-document that could swallow the command on the line after it.
    "echo hi \\\n# <<EOF\ngit checkout main\nEOF",
    "echo hi \\\n# write the notes <<EOF\ngit stash\nEOF",
    # A `)` that closes a command substitution stands inside a word, so a `#` after it
    # is an ordinary character rather than the start of a comment.
    "git log $(echo x)#; git checkout main",
    "git log `echo x`#; git checkout main",
    "cat <(echo x)#; git checkout main",
    "# A backslash in a comment does not continue the comment. \\\ngit checkout main",
    # A `#` that does not start a word does not start a comment, so what follows the
    # `;` is a command.
    "echo a#b; git checkout main",
    "echo \\ # ignored; git checkout main",
    # A here-document that feeds a shell is a script.
    "sh <<'EOF'\ngit checkout main\nEOF",
    "bash <<EOF\ngit stash\nEOF",
    "bash <<'EOF'\ngit status\ngit checkout main\nEOF",
    # What follows a here-document's delimiter word on that line is not the body.
    "cat > notes.md <<EOF && git checkout main\nnotes\nEOF",
    "cat > notes.md <<'EOF'; git switch main\nnotes\nEOF",
    "cat > notes.md <<-EOF | git stash\n\tnotes\n\tEOF",
    # A here-document's delimiter word ends where any word ends, so the `#` of
    # `<<EOF#x` stands inside the word rather than beginning a comment, and what
    # follows the delimiter word on that line is shell syntax that still runs.
    "cat <<EOF#x; git checkout main\nnotes\nEOF#x",
    "cat <<E#F && git switch main\nnotes\nE#F",
    "cat <<'EOF'#x; git stash\nnotes\nEOF#x",
    # A `<<<` here-string is not a here-document:  its own word is the data, so the
    # lines after it are commands rather than a body.
    "cat <<<EOF\ngit checkout main\nEOF",
    "grep -q yes <<<yes && git switch main",
    # A here-string that feeds a shell is a script, just as a here-document is.
    "sh <<<'git checkout main'",
    # A line continuation joins the lines it separates, so the words after one continue
    # the command, and a command after one on the next line still runs.
    "git \\\n  checkout main",
    "echo hi && \\\ngit checkout main",
    "echo hi \\\n && git stash",
    # A redirection does not separate one command from the next, and it may stand
    # before the command it belongs to.  Its target is not that command's name, and
    # neither is a file descriptor written before the operator.
    "> out.txt git checkout main",
    "2> out.txt git switch main",
    "< /dev/null git stash",
    "git status\n> out.txt git branch newbranch",
    # A command that receives `git` as data and then runs it.
    "eval git checkout main",
    'eval "git checkout main"',
    "eval 'git stash; git status'",
    "echo main | xargs git checkout",
    "echo main | xargs -n 1 git switch",
    "find . -name '*.java' -exec git checkout main \\;",
    "find . -type d -execdir git stash \\;",
    "find . -name x -exec git branch newbranch +",
    "ssh host git checkout main",
    "ssh -p 22 host git branch newbranch",
    "ssh -p22 host git switch main",
    "ssh -vp 22 host git checkout main",
    "env xargs git switch main",
    # `env -S` gives the whole command as one argument, and appends what follows it.
    "env -S 'git checkout main'",
    "env -S 'git checkout' main",
    "env -S git branch newbranch",
    "/usr/bin/env -S 'git stash'",
    "env --split-string='git switch main'",
    "env --split-string 'git branch newbranch'",
    "env --split='git checkout main'",
    "env -i -S 'git checkout main'",
    "env -iS 'git checkout main'",
    "env -uFOO -S 'git checkout main'",
    "env -C /some/dir -S 'git stash pop'",
    "env -S \"sh -c 'git checkout main'\"",
    # An `ssh` option can name a command that runs on the local host.
    "ssh -o ProxyCommand='git checkout main' host true",
    "ssh -oProxyCommand='git checkout main' host true",
    "ssh -o 'ProxyCommand git stash' host true",
    "ssh -o proxycommand='git switch main' host true",
    "ssh -o LocalCommand='git branch newbranch' host true",
    # A `#` that does not begin a word is not a comment, so what follows it runs.
    "git status a#; git checkout main",
    "git log --grep=x#; git stash",
    # Unparsable, but it mentions a forbidden operation.
    "git checkout 'main",
)

# Commands that the hook must not deny.
PERMITTED = (
    # Listing branches.
    "git branch",
    "git branch -v",
    "git branch -vv",
    "git branch -av",
    "git branch -a",
    "git branch -r",
    "git branch --all",
    "git branch --remotes",
    "git branch --show-current",
    "git branch --list",
    "git branch --list 'wpi-*'",
    "git branch -l 'wpi-*'",
    "git branch --contains HEAD",
    "git branch --merged",
    "git branch --no-merged main",
    "git branch --points-at HEAD",
    "git branch --sort=-committerdate -r",
    "git branch --format=%(refname:short)",
    "git branch --color=never --column",
    # Listing forms in which an operand is a pattern, not a branch to create.
    # `git branch` itself refuses `-a` and `-r` with an operand unless `--list` is
    # also given, so neither form can create a branch.
    "git branch -r 'origin/wpi-*'",
    "git branch -a 'wpi-*'",
    "git branch --all 'wpi-*'",
    "git branch --remotes 'origin/wpi-*'",
    "git branch -a --list 'wpi-*'",
    "git branch --contains HEAD 'wpi-*'",
    "git branch --no-contains HEAD 'wpi-*'",
    "git branch --merged main 'wpi-*'",
    "git branch --no-merged=main 'wpi-*'",
    "git branch --points-at HEAD 'wpi-*'",
    "git -C /some/dir branch",
    "git -C /some/dir branch --show-current",
    "git --no-pager branch -a",
    # Reading the stash.
    "git stash list",
    "git stash show -p",
    # Other git commands, including ones that merely name a forbidden subcommand.
    "git status",
    "git log --oneline",
    "git log --grep checkout HEAD",
    "git log --grep stash",
    "git commit -m 'Do not stash or checkout'",
    "git diff --stat",
    "git rev-parse --abbrev-ref HEAD",
    # This repository's own scripts, which do the forbidden operations in a fresh
    # working copy.
    "git-new-branch newbranch",
    "git-checkout-branch existingbranch",
    "./git-new-branch newbranch",
    # Every line of a multi-line command, and only the commands.
    "git status\ngit log --oneline",
    "git commit -m 'first line\nsecond line'",
    # A shell option that is not a command option.
    "bash -s < script.sh",
    "sh -n script.sh",
    # A `#` comment mentions a forbidden operation without running it, whether it
    # occupies the whole line or trails a command.
    "# git checkout main",
    "git status # git checkout main",
    "echo hi # git branch newbranch",
    "# ; git checkout main",
    "git status # && git checkout main",
    # A `)` that closes a subshell separates one word from the next, so a `#` after it
    # begins a comment, which hides the rest of the line from the shell as well.
    "(echo x)#; git checkout main",
    # Commands that merely mention a forbidden operation.
    "echo 'git branch newbranch'",
    "grep -n 'git checkout' README.md",
    "cat .claude/hooks/git-guard-one-branch-per-directory.py",
    # A here-document body that no shell runs is data, not commands, even when an
    # apostrophe in it makes the whole command unparsable as shell words.
    "cat > notes.md <<'EOF'\nDo not run `git branch NEWBRANCH` here.\nEOF",
    "cat > notes.md <<'EOF'\nThe user's rules deny `git checkout`.\nEOF",
    "python3 - <<'EOF'\nprint('git stash')\nEOF",
    "cat > notes.md <<'EOF' && echo done\ngit checkout main\nEOF",
    # A here-document body is data even when a `#` stands inside the delimiter word,
    # and what follows the delimiter word on that line is a comment if it begins one.
    "cat > notes.md <<EOF#x\ngit checkout main\nEOF#x",
    "cat > notes.md <<'E#F'\ngit stash\nE#F",
    "cat > notes.md <<\\EOF\ngit checkout main\nEOF",
    "cat > notes.md <<EOF#x # git checkout main\nnotes\nEOF#x",
    # A command that receives a forbidden operation as data but does not run it.
    "find . -name '*.md' -exec grep 'git checkout' {} +",
    "echo '*.md' | xargs grep 'git stash'",
    "eval git status",
    "ssh host git branch --show-current",
    "ssh -o ProxyCommand='nc %h %p' host true",
    "ssh -o ProxyCommand='git branch --show-current' host true",
    "ssh -o StrictHostKeyChecking=no host git status",
    "env -S 'git branch --show-current'",
    "env -S 'echo git checkout main'",
    "env -uS git status",
    "find . -name '*.py' -type f",
    # A comment is not a command, even when it names a forbidden operation, and even
    # when an apostrophe in it would not parse as shell words.
    "git status # do not checkout main",
    "ls # don't run git checkout here",
    "git status # about stash\ngit log --oneline",
    "git log --grep a#b",
    # Unparsable, and mentioning nothing forbidden.
    "echo 'unterminated",
)

# Commands that the hook must approve, so that they run without a permission prompt.
# No `allow` pattern can express these, because a pattern that admits a global option
# or `-C DIR` before the subcommand also admits `-c core.pager=CMD`.
APPROVED = (
    # Subcommands that only read, with no global option at all.
    "git status",
    "git log --oneline",
    "git log --grep checkout HEAD",
    "git diff --stat",
    "git show HEAD",
    "git rev-parse --abbrev-ref HEAD",
    "git branch",
    "git branch -av",
    "git branch --list 'wpi-*'",
    "git branch --sort=-committerdate -r",
    "git stash list",
    "git stash show -p",
    # The same, in another working copy.
    "git -C /some/dir branch",
    "git -C /some/dir branch --show-current",
    "git -C /some/dir log --oneline",
    "git -C /some/dir diff",
    "git -C /some/dir stash list",
    # `-C` takes its value attached as well as separately.
    "git -Cdir log",
    # Global options that cannot run another program.
    "git --no-pager branch -a",
    "git --no-pager -C /some/dir log",
    "git --no-optional-locks status",
    # A line continuation joins the lines of a single command.
    "git log \\\n  --oneline",
    # One read-only command after another.
    "git status && git -C /some/dir log",
    "git status; git branch",
    "git status\ngit log --oneline",
    "git log --oneline | git -C /some/dir log --oneline",
    # A comment is not shell syntax, so an expansion character in one expands nothing
    # and does not withhold approval.
    "git status # check state",
    "git status # see `git log`",
    "git log --oneline # costs $0",
)

# Commands that the hook must neither deny nor approve, leaving them to the `allow`
# and `deny` lists of `.claude/settings.json` and to a permission prompt.
UNAPPROVED = (
    # A global option that names a program to run, or that this hook does not know.
    "git -c core.pager=cat log",
    "git -c color.ui=always -C /some/dir log",
    "git --exec-path=/some/dir log",
    "git --git-dir=/some/dir/.git log",
    "git --config-env=core.pager=PAGER log",
    # A subcommand that writes, even though nothing about it is forbidden.
    "git add .",
    "git commit -m message",
    "git tag v1.0",
    "git -C /some/dir tag v1.0",
    "git remote -v",
    # No subcommand at all.
    "git",
    "git -C /some/dir",
    "git --no-pager",
    # A command that is not git, running before or after one that is.
    "git log && rm -rf /some/dir",
    "git status && make",
    "git log | head",
    "git log --oneline\nmake",
    "echo 'git branch newbranch'",
    "git-new-branch newbranch",
    # A path-qualified program that merely has git's file name is not git.
    "./git status",
    "/tmp/git log --oneline",
    # A wrapper or an indirection: git must be the command itself.
    "sudo git log",
    "timeout 300 git log",
    "GIT_PAGER=cat git log",
    "xargs git log",
    "ssh host git branch --show-current",
    # A `#` that does not begin a word is not a comment, so what follows it runs.
    "git log a#; rm /some/file",
    # Shell syntax that this hook does not interpret.
    "git log `rm -rf /some/dir`",
    "git log $(echo HEAD)",
    "git log ${SOMEREF}",
    "git log > out.txt",
    "> out.txt git status",
    "git status <<EOF\nnotes\nEOF",
    "(git log)",
    "if true; then git log; fi",
    # Unparsable, and mentioning nothing forbidden.
    "echo 'unterminated",
)


def run_guard(hook_input: str) -> subprocess.CompletedProcess[str]:
    """Run the hook.

    Args:
        hook_input: what to write to the hook's standard input.

    Returns:
        The completed hook process.
    """
    return subprocess.run(
        [str(GUARD)],
        input=hook_input,
        capture_output=True,
        text=True,
        check=False,
    )


def decision(command: str) -> str | None:
    """Run the hook on a shell command.

    Args:
        command: the command that the Bash tool was asked to run.

    Returns:
        The hook's permission decision, or None if the hook made no decision.
    """
    request = {
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": command},
    }
    completed = run_guard(json.dumps(request))
    if completed.returncode != 0:
        message = (
            f"{GUARD} exited with status {completed.returncode} on {command!r}: {completed.stderr}"
        )
        sys.exit(message)
    if completed.stdout.strip() == "":
        return None
    output = json.loads(completed.stdout)
    return output["hookSpecificOutput"]["permissionDecision"]


def deny_pattern_matches(pattern: str, command: str) -> bool:
    """Tell whether a `deny` permission pattern of `.claude/settings.json` matches.

    A pattern that ends in `:*` is a literal command prefix.  Any other pattern is a
    glob for the whole command, whose `*` spans words; one that ends in a space and a
    star is tried both with and without that suffix.  A pattern with both an interior
    `*` and a trailing `:*` matches nothing at all.

    Args:
        pattern: the text between `Bash(` and `)` of a permission pattern.
        command: the command that the Bash tool was asked to run.

    Returns:
        True if the pattern matches the command.
    """
    if pattern.endswith(":*"):
        prefix = pattern[: -len(":*")]
        if "*" in prefix:
            return False
        return command == prefix or command.startswith(prefix + " ")
    if fnmatch.fnmatchcase(command, pattern):
        return True
    return pattern.endswith(" *") and fnmatch.fnmatchcase(command, pattern[: -len(" *")])


def bash_deny_patterns(settings: dict) -> list[str]:
    """Find the `Bash` patterns of the `deny` permission list.

    Args:
        settings: the parsed contents of `.claude/settings.json`.

    Returns:
        The text between `Bash(` and `)` of each `deny` pattern for the Bash tool.
    """
    return [
        pattern[len("Bash(") : -len(")")]
        for pattern in settings.get("permissions", {}).get("deny", [])
        if pattern.startswith("Bash(") and pattern.endswith(")")
    ]


def main() -> int:
    """Test the hook on forbidden and on permitted commands.

    Returns:
        The exit status: 1 if any test failed, otherwise 0.
    """
    failures = 0

    for command in FORBIDDEN:
        if decision(command) != "deny":
            print(f"FAILED: not denied: {command}")
            failures += 1

    for command in PERMITTED:
        if decision(command) == "deny":
            print(f"FAILED: denied: {command}")
            failures += 1

    for command in APPROVED:
        result = decision(command)
        if result != "allow":
            print(f"FAILED: {result} instead of allow: {command}")
            failures += 1

    for command in UNAPPROVED:
        result = decision(command)
        if result is not None:
            print(f"FAILED: {result} instead of no decision: {command}")
            failures += 1

    # A tool other than Bash is ignored.
    request = {
        "hook_event_name": "PreToolUse",
        "tool_name": "Read",
        "tool_input": {"file_path": "git branch newbranch"},
    }
    completed = run_guard(json.dumps(request))
    if completed.returncode != 0 or completed.stdout.strip() != "":
        print("FAILED: made a decision about a tool other than Bash")
        failures += 1

    # A tool input of an unexpected shape is ignored rather than crashing the hook.
    for tool_input in ("git branch newbranch", ["git", "branch"], None, {"command": 3}):
        request = {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": tool_input,
        }
        completed = run_guard(json.dumps(request))
        if completed.returncode != 0 or completed.stdout.strip() != "":
            print(f"FAILED: not ignored: tool_input {tool_input!r}: {completed.stderr}")
            failures += 1

    # Malformed input is reported, but does not block the tool call.
    for hook_input in ("not json", "null"):
        completed = run_guard(hook_input)
        if completed.returncode != 1 or completed.stdout.strip() != "":
            print(f"FAILED: not a non-blocking error: {hook_input!r}")
            failures += 1

    # The hook is wired up in the settings that this repository ships.
    settings = json.loads(SETTINGS.read_text(encoding="UTF-8"))
    commands = [
        hook.get("command", "")
        for matcher in settings.get("hooks", {}).get("PreToolUse", [])
        for hook in matcher.get("hooks", [])
    ]
    if not any(GUARD.name in command for command in commands):
        print(f"FAILED: no PreToolUse hook in {SETTINGS} runs {GUARD}")
        failures += 1

    # A shell runs the hook command, so `${CLAUDE_PROJECT_DIR}` must be quoted:  a
    # project directory whose path contains a space must remain one word.
    directory = "/parent directory/project"
    for command in commands:
        if GUARD.name not in command:
            continue
        expanded = command.replace("${CLAUDE_PROJECT_DIR}", directory)
        expanded = expanded.replace("$CLAUDE_PROJECT_DIR", directory)
        words = shlex.split(expanded)
        if words[:1] != [f"{directory}/.claude/hooks/{GUARD.name}"]:
            print(f"FAILED: hook command splits into {words} for project directory {directory}")
            failures += 1
    if not os.access(GUARD, os.X_OK):
        print(f"FAILED: {GUARD} is not executable")
        failures += 1

    # `deny` wins over `allow`, so no `deny` pattern may reject a command that this
    # hook permits or approves.  Only the hook can distinguish those commands.
    deny_patterns = bash_deny_patterns(settings)
    for command in PERMITTED + APPROVED:
        for pattern in deny_patterns:
            if deny_pattern_matches(pattern, command):
                print(f"FAILED: deny pattern Bash({pattern}) rejects: {command}")
                failures += 1

    # A pattern with both an interior `*` and a trailing `:*` matches nothing, so
    # writing one silently states no policy at all.
    for pattern in deny_patterns:
        if pattern.endswith(":*") and "*" in pattern[: -len(":*")]:
            print(f"FAILED: deny pattern Bash({pattern}) matches nothing")
            failures += 1

    if failures:
        return 1
    print(f"{Path(__file__).name}: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
