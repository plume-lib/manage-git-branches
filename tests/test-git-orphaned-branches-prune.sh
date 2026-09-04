#!/bin/sh

# Tests that `git-orphaned-branches` does not descend into a directory that it
# has already matched, nor into git metadata directories.
#
# The `find` command in `git-orphaned-branches` used to descend into every
# match, so a `*-branch-*` directory nested inside another `*-branch-*`
# directory was reported alongside its parent, and a `*-branch-*` directory
# inside `.git` was reported as though it were a working copy.

set -e

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"

testdir="$(mktemp -d "${TMPDIR:-/tmp}/test-git-orphaned-branches-prune.XXXXXX")"
trap 'rm -rf "${testdir}"' EXIT INT TERM

workdir="${testdir}/work"

# A directory whose only content is a `.project` file is reported as orphaned.
# Nest one inside a `*-branch-*` directory that is not itself reported, because
# that directory holds more than just a `.project` file.
mkdir -p "${workdir}/outer-branch-1/inner-branch-2"
: > "${workdir}/outer-branch-1/.project"
: > "${workdir}/outer-branch-1/inner-branch-2/.project"

# The same, inside a git metadata directory.
mkdir -p "${workdir}/.git/metadata-branch-3"
: > "${workdir}/.git/metadata-branch-3/.project"

# `git-orphaned-branches` contacts no remote here, because no directory that it
# reaches contains a `.git` subdirectory.
actual="$(cd "${workdir}" && "${REPO_DIR}/git-orphaned-branches")"

if [ -n "${actual}" ]; then
  echo "FAIL: git-orphaned-branches descended into a directory it had matched." >&2
  echo "Expected no output, but got:" >&2
  echo "${actual}" >&2
  exit 1
fi

echo "PASS: $(basename -- "$0")"
