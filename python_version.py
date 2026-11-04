"""Exit with a helpful message if the running Python is too old for a program.

A program in this package calls `require` before it imports its implementation,
which might use syntax or library features that an older Python lacks.  This
module therefore uses nothing newer than Python 3.6.
"""

import platform
import sys
from pathlib import Path

# The Python version that the error message suggests; the README suggests it too.
SUGGESTED = "3.15"


def require(minimum):
    """Exit with an error message unless the running Python is at least the given version.

    The message tells how to run the program with a newer Python.

    Args:
        minimum: a Python version, as a tuple of a major and a minor version
            such as (3, 10).
    """
    if sys.version_info >= minimum:
        return
    program = Path(sys.argv[0]).name
    version = ".".join(str(part) for part in minimum)
    readme = Path(__file__).resolve().parent / "README.md"
    sys.exit(
        f"{program}: needs Python {version} or later,"
        f" but {sys.executable or 'python3'} is Python {platform.python_version()}.\n"
        f"Run it with a newer Python, such as:\n"
        f"  uv run --no-project --python {SUGGESTED} {program} ARGS...\n"
        f'For details, see "Python version" in {readme}.'
    )
