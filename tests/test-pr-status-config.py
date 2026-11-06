"""Tests for pr_status_config, which reads and checks the pr-status config file."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

TOPLEVEL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOPLEVEL))

import pr_status_config  # ruff: ignore[module-import-not-at-top-of-file]


class IsValidFilterTest(unittest.TestCase):
    """Tests for is_valid_filter."""

    def test_valid_filters(self):
        """is_valid_filter accepts each form of filter."""
        for flt in ["all", "unassigned", {"unassigned_or": []}, {"unassigned_or": ["a", "b"]}]:
            with self.subTest(flt=flt):
                self.assertTrue(pr_status_config.is_valid_filter(flt))

    def test_invalid_filters(self):
        """is_valid_filter rejects a misspelled or malformed filter."""
        for flt in [
            "unasigned",
            None,
            ["a"],
            {},
            {"unassigned-or": ["a"]},
            {"unassigned_or": "a"},
            {"unassigned_or": [1]},
            {"unassigned_or": ["a"], "extra": 1},
        ]:
            with self.subTest(flt=flt):
                self.assertFalse(pr_status_config.is_valid_filter(flt))


class ReadConfigFileTest(unittest.TestCase):
    """Tests for read_config_file and dependency_document_name."""

    def write(self, text):
        """Write a config file in a fresh directory, which becomes the current one.

        Args:
            text: the config file's contents.
        """
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.addCleanup(os.chdir, Path.cwd())
        os.chdir(directory.name)
        Path(pr_status_config.CONFIG).write_text(text)

    def read(self, cfg):
        """Return the config that read_config_file reads from a file that holds cfg.

        Args:
            cfg: the config file's contents, as a value that json.dumps accepts.

        Returns:
            The config, as read_config_file returns it.
        """
        self.write(json.dumps(cfg))
        return pr_status_config.read_config_file("pr-status")

    def problems(self, cfg):
        """Return the error message that read_config_file exits with for a file holding cfg.

        Args:
            cfg: the config file's contents, as a value that json.dumps accepts.

        Returns:
            The error message's lines, without their "pr-status: pr-status-config.json: ".
        """
        with self.assertRaises(SystemExit) as cm:
            self.read(cfg)
        prefix = "pr-status: pr-status-config.json: "
        lines = str(cm.exception.code).splitlines()
        for line in lines:
            self.assertTrue(line.startswith(prefix), line)
        return [line.removeprefix(prefix) for line in lines]

    def test_defaults(self):
        """Each omitted optional key that has a default gets it."""
        cfg = self.read({"repos": {"b-c": {"gh": "o/b-c"}, "a": {"gh": "o/a"}}})
        self.assertEqual(cfg["order"], ["b-c", "a"])
        self.assertEqual(cfg["documents"], {"dependencies": "pr-status.md"})
        self.assertEqual(cfg["directories"], [])
        self.assertEqual(
            cfg["repos"]["b-c"],
            {"gh": "o/b-c", "label": "b-c", "prefix": "b-c#", "node_prefix": "b_c_"},
        )
        self.assertEqual(pr_status_config.dependency_document_name(cfg), "pr-status.md")

    def test_defaults_one_repository(self):
        """A lone repository's PRs are referred to as "#N"."""
        cfg = self.read({"repos": {"a": {"gh": "o/a"}}})
        self.assertEqual(cfg["repos"]["a"]["prefix"], "#")
        self.assertEqual(cfg["repos"]["a"]["node_prefix"], "pr")

    def test_given_values(self):
        """Each given key is retained."""
        repo = {
            "gh": "o/a",
            "clone": "a",
            "prefix": "A#",
            "label": "Alpha",
            "node_prefix": "alpha_",
        }
        given = {
            "order": ["a"],
            "repos": {"a": repo},
            "documents": {"dependencies": "status.md", "unblocked": []},
            "directories": [{"dirs": ["x"], "status": "old", "relationship": "none"}],
        }
        cfg = self.read(given)
        self.assertEqual(cfg, given)
        self.assertEqual(pr_status_config.dependency_document_name(cfg), "status.md")

    def test_unblocked_only(self):
        """A documents object that names only unblocked documents gets the default name."""
        cfg = self.read({"repos": {}, "documents": {"unblocked": []}})
        self.assertEqual(cfg["documents"], {"unblocked": [], "dependencies": "pr-status.md"})

    def test_syntax_error(self):
        """A file that is not JSON is reported with the position of the error."""
        self.write('{"repos": {},\n}')
        with self.assertRaises(SystemExit) as cm:
            pr_status_config.read_config_file("pr-status")
        self.assertEqual(
            str(cm.exception.code),
            "pr-status: pr-status-config.json:1:13: Illegal trailing comma before end of object",
        )

    def test_not_an_object(self):
        """A config file that does not hold a JSON object is an error."""
        self.assertEqual(self.problems([]), ["the config is a list, not an object"])

    def test_every_problem_is_reported(self):
        """Every problem is reported, with its config path."""
        cfg = {
            "repo": {},
            "documents": None,
            "directories": [{"dirs": "x", "status": "old"}],
        }
        self.assertEqual(
            self.problems(cfg),
            [
                'the config has no "repos"',
                'repo is not a known key; did you mean "repos"?',
                "documents is null, not an object",
                'directories[0] has no "relationship"',
                'directories[0].dirs is "x", not a list',
            ],
        )

    def test_repository_problems(self):
        """Wrong types, misspelled keys, and PR numbers as strings are reported."""
        repo = {
            "gh": "daikon",
            "node_prefix": "d-",
            "exclude": {"prs": [1]},
            "excluded": {"prs": ["512", True, 0]},
            "extra_dependencies": [[1, 2, 3], [1, "2"]],
            "extra_external_dependencies": {"x": ["o/r#5", "o/r"]},
            "titles": {"527": 5},
            "detail_notes": {"530": "a\nb"},
            "show_author": "yes",
        }
        self.assertEqual(
            self.problems({"repos": {"daikon": repo}}),
            [
                'repos.daikon.gh is "daikon", not a GitHub slug such as "ORG/REPO"',
                'repos.daikon.node_prefix is "d-", not letters, digits, and underscores',
                'repos.daikon.exclude is not a known key; did you mean "excluded"?',
                'repos.daikon.excluded.prs[0] is "512", not a PR number such as 527',
                "repos.daikon.excluded.prs[1] is true, not a PR number such as 527",
                "repos.daikon.excluded.prs[2] is 0, not a PR number such as 527",
                "repos.daikon.extra_dependencies[0] has 3 elements, not 2",
                'repos.daikon.extra_dependencies[1][1] is "2", not a PR number such as 527',
                (
                    "repos.daikon.extra_external_dependencies.x:"
                    '  the key is not a PR number such as "527"'
                ),
                (
                    'repos.daikon.extra_external_dependencies.x[1] is "o/r",'
                    ' not a PR such as "ORG/REPO#95"'
                ),
                'repos.daikon.titles."527" is 5, not a string on one line',
                'repos.daikon.detail_notes."530" is "a\\nb", not a string on one line',
                'repos.daikon.show_author is "yes", not true or false',
            ],
        )

    def test_invalid_filter(self):
        """An unblocked document with an unknown filter is an error."""
        doc = {"file": "unblocked.md", "title": "Unblocked", "filter": "unasigned"}
        self.assertEqual(
            self.problems({"repos": {}, "documents": {"unblocked": [doc]}}),
            [
                (
                    'documents.unblocked[0].filter is "unasigned", not "all", "unassigned", or'
                    ' {"unassigned_or": [LOGIN, ...]}'
                )
            ],
        )

    def test_name(self):
        """A repository's name is its key, so the repository cannot give a name."""
        self.assertEqual(
            self.problems({"repos": {"a": {"gh": "o/a", "name": "a"}}}),
            ['repos.a.name is not permitted:  a repository\'s name is its key in "repos"'],
        )

    def test_order(self):
        """The "order" must list each repository once."""
        cfg = {
            "order": ["a", "c", "a"],
            "repos": {"a": {"gh": "o/a"}, "b": {"gh": "o/b"}},
        }
        self.assertEqual(
            self.problems(cfg),
            [
                'order[1] is "c", which is not a key of "repos"',
                'order[2] repeats "a"',
                'repos.b is not in "order"; add it to "order" or remove it',
            ],
        )

    def test_duplicates(self):
        """Two repositories must not share a GitHub slug, prefix, or node prefix."""
        cfg = {
            "repos": {
                "a": {"gh": "o/a", "prefix": "x#", "node_prefix": "n"},
                "b": {"gh": "O/A", "prefix": "X#", "node_prefix": "n"},
            }
        }
        self.assertEqual(
            self.problems(cfg),
            [
                'repos.a and repos.b have the same "gh", "O/A"',
                'repos.a and repos.b have the same "prefix", "X#"',
                'repos.a and repos.b have the same "node_prefix", "n"',
            ],
        )

    def test_document_files(self):
        """No two documents, and no document and pr-status's own files, share a file."""
        unblocked = [
            {"file": "pr-status.md", "title": "U"},
            {"file": "./pr-status-config.json", "title": "U"},
            {"file": ".pr-status-snapshot.json", "title": "U"},
            {"file": "u.md", "title": "U"},
            {"file": "u.md", "title": "U"},
        ]
        self.assertEqual(
            self.problems({"repos": {}, "documents": {"unblocked": unblocked}}),
            [
                (
                    'documents.unblocked[0].file is "pr-status.md", which is also'
                    " documents.dependencies"
                ),
                (
                    'documents.unblocked[1].file is "./pr-status-config.json", which is also'
                    " the config file, pr-status-config.json"
                ),
                (
                    'documents.unblocked[2].file is ".pr-status-snapshot.json", which is also'
                    " the snapshot file, .pr-status-snapshot.json"
                ),
                'documents.unblocked[4].file is "u.md", which is also documents.unblocked[3].file',
            ],
        )


if __name__ == "__main__":
    unittest.main()
