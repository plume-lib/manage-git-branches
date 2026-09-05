#!/bin/sh

# Tests that this repository, which contains no Python code, does not carry
# Python packaging files.  Such files declare dependencies that nothing uses,
# and they can disagree with one another: a `.python-version` file pins a
# version that the `requires-python` field of `pyproject.toml` need not permit.
# The prek hooks fetch the tools they need, so they do not read these files.
#
# Usage:
#   tests/test-no-python-packaging.sh
#
# The test inspects the files that git tracks, so it must run within a clone.

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(dirname -- "${TESTS_DIR}")"

# Files that configure a Python package, a Python virtual environment, or a
# Python dependency resolver.
PACKAGING_FILES=".python-version pyproject.toml requirements.txt setup.cfg setup.py uv.lock"

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

python_sources="$(git -C "${COMMANDS_DIR}" ls-files -- '*.py' '*.pyi')"
if [ -n "${python_sources}" ]; then
  echo "${SCRIPT_NAME}: SKIP: the repository now contains Python code"
  exit 0
fi

for packaging_file in ${PACKAGING_FILES}; do
  if [ -n "$(git -C "${COMMANDS_DIR}" ls-files -- "${packaging_file}")" ]; then
    fail "${packaging_file} is tracked, but the repository contains no Python code"
  fi
done

if [ -n "$(git -C "${COMMANDS_DIR}" ls-files -- '.venv')" ]; then
  fail ".venv is tracked, but a virtual environment should not be committed"
fi

echo "${SCRIPT_NAME}: PASS"
