"""Tests for python_version.py."""

import sys
import unittest
from pathlib import Path
from unittest import mock

TOPLEVEL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOPLEVEL))

import python_version  # ruff: ignore[module-import-not-at-top-of-file]


class RequireTest(unittest.TestCase):
    """Tests for require."""

    def test_new_enough(self):
        """A Python at least as new as the minimum does not exit."""
        with mock.patch.object(sys, "version_info", (3, 10, 0, "final", 0)):
            python_version.require((3, 10))
            python_version.require((3, 9))

    def test_too_old(self):
        """A Python older than the minimum exits with a message that tells how to proceed."""
        with (
            mock.patch.object(sys, "version_info", (3, 9, 25, "final", 0)),
            mock.patch.object(sys, "argv", ["/path/to/pr-status", "--check"]),
            self.assertRaises(SystemExit) as raised,
        ):
            python_version.require((3, 10))
        message = str(raised.exception.code)
        self.assertIn("pr-status: needs Python 3.10 or later", message)
        self.assertIn("uv run --no-project --python 3.15 pr-status", message)
        self.assertIn(str(TOPLEVEL / "README.md"), message)


if __name__ == "__main__":
    unittest.main()
