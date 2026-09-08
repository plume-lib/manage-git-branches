#!/usr/bin/env python3

"""Test `.claude/hooks/git-guard-one-branch-per-directory.py`.

That hook forbids changing the branch of a working copy.

Usage:
  tests/test-git-guard-one-branch-per-directory.py
"""

from __future__ import annotations

import json
import os
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
    "git -C /some/dir branch",
    "git -C /some/dir branch --show-current",
    "git --no-pager branch -a",
    # Reading the stash.
    "git stash list",
    "git stash show -p",
    # Other git commands.
    "git status",
    "git log --oneline",
    "git commit -m 'Do not stash or checkout'",
    "git diff --stat",
    "git rev-parse --abbrev-ref HEAD",
    # This repository's own scripts, which do the forbidden operations in a fresh
    # working copy.
    "git-new-branch newbranch",
    "git-checkout-branch existingbranch",
    "./git-new-branch newbranch",
    # Commands that merely mention a forbidden operation.
    "echo 'git branch newbranch'",
    "grep -n 'git checkout' README.md",
    "cat .claude/hooks/git-guard-one-branch-per-directory.py",
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
    if not os.access(GUARD, os.X_OK):
        print(f"FAILED: {GUARD} is not executable")
        failures += 1

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
