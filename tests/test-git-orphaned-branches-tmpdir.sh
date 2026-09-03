#!/bin/sh

# Tests that `git-orphaned-branches` creates its temporary file under
# `${TMPDIR}` rather than always under `/tmp`.
#
# `git-orphaned-branches` used to pass a `/tmp` template to `mktemp`, so it
# wrote to `/tmp` even when the environment asked for a different temporary
# directory.

set -e

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"

testdir="$(mktemp -d "${TMPDIR:-/tmp}/test-git-orphaned-branches.XXXXXX")"
trap 'rm -rf "${testdir}"' EXIT INT TERM

# Do not let the tester's git configuration affect the test.
GIT_CONFIG_GLOBAL="${testdir}/gitconfig"
GIT_CONFIG_SYSTEM=/dev/null
GIT_AUTHOR_NAME="Test"
GIT_AUTHOR_EMAIL="test@example.com"
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
: > "${GIT_CONFIG_GLOBAL}"

# The temporary file exists only while `git-orphaned-branches` runs, so observe
# it from a stub `is-deleted-branch` that `git-orphaned-branches` calls while
# the temporary file is open.  `git-orphaned-branches` runs the
# `is-deleted-branch` that sits beside it, so run a copy of
# `git-orphaned-branches` from a directory that also holds the stub.
bindir="${testdir}/bin"
mkdir "${bindir}"
cp "${REPO_DIR}/git-orphaned-branches" "${bindir}/git-orphaned-branches"
cat > "${bindir}/is-deleted-branch" << 'STUB'
#!/bin/sh
ls -1 "${TMPDIR}" > "${TMPDIR_LISTING}"
exit 1
STUB
chmod +x "${bindir}/is-deleted-branch"

# Create a remote repository and one working copy of it.
workdir="${testdir}/work"
mkdir "${workdir}"
git init -q --bare "${workdir}/origin.git"
git clone -q "${workdir}/origin.git" "${testdir}/seed" 2> /dev/null
: > "${testdir}/seed/file.txt"
git -C "${testdir}/seed" add file.txt
git -C "${testdir}/seed" commit -q -m "Initial commit"
git -C "${testdir}/seed" push -q origin HEAD
git clone -q "${workdir}/origin.git" "${workdir}/myrepo-branch-1"

# Run `git-orphaned-branches` with a temporary directory of the test's choosing.
tmpdir="${testdir}/tmpdir"
mkdir "${tmpdir}"
TMPDIR_LISTING="${testdir}/tmpdir-listing"
export TMPDIR_LISTING
(cd "${workdir}" && TMPDIR="${tmpdir}" "${bindir}/git-orphaned-branches" > /dev/null)

if [ ! -f "${TMPDIR_LISTING}" ]; then
  echo "FAIL: git-orphaned-branches did not run is-deleted-branch." >&2
  exit 1
fi

if ! grep -q '^git-orphaned-branches\.' "${TMPDIR_LISTING}"; then
  echo "FAIL: git-orphaned-branches did not create its temporary file in \${TMPDIR}." >&2
  echo "Contents of \${TMPDIR}:" >&2
  cat "${TMPDIR_LISTING}" >&2
  exit 1
fi

echo "PASS: $(basename -- "$0")"
