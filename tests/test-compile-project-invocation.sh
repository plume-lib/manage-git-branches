#!/bin/sh

# Tests that `git-push-to` and `git-pull-from` run `compile-project` even when
# `compile-project` is not on the PATH.  Both scripts resolve their sibling
# scripts relative to their own location, so invoking them by an absolute
# pathname must work.
#
# Usage:
#   tests/test-compile-project-invocation.sh
#
# The exit status is 0 if the test passes and 1 if it fails.

set -e

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"
REPO_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"

fail() {
  echo "${SCRIPT_NAME}: FAILED: $1" >&2
  exit 1
}

# Build a PATH from which `compile-project` cannot be found, so that the scripts
# under test can run it only by resolving it relative to their own location.
# The user may have an installation of manage-git-branches on the PATH, so drop
# every PATH element that supplies `compile-project`, not just ${REPO_DIR}.
PATH_WITHOUT_COMPILE_PROJECT=''
saved_ifs="${IFS}"
IFS=':'
for path_element in ${PATH}; do
  if [ -x "${path_element}/compile-project" ]; then
    continue
  fi
  PATH_WITHOUT_COMPILE_PROJECT="${PATH_WITHOUT_COMPILE_PROJECT}${PATH_WITHOUT_COMPILE_PROJECT:+:}${path_element}"
done
IFS="${saved_ifs}"

# Use a subshell, because a variable assignment that prefixes a regular builtin
# such as `command` does not necessarily persist in the current shell.
if (PATH="${PATH_WITHOUT_COMPILE_PROJECT}" && export PATH && command -v compile-project > /dev/null); then
  echo "${SCRIPT_NAME}: cannot construct a PATH without compile-project" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT INT TERM

# Do not depend on the invoking user's git identity.
GIT_AUTHOR_NAME='manage-git-branches test'
GIT_AUTHOR_EMAIL='test@example.com'
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# Creates a clone of the test origin repository at $1 and configures it so that
# `git pull` merges, whatever the invoking user's global git configuration says.
make_clone() {
  git clone -q "${work_dir}/origin.git" "$1"
  git -C "$1" config pull.rebase false
}

# Makes a commit in the clone at $1, on the current branch.  The commit adds a
# file named $2; each call must use a name that no prior call has used, so that
# merging any two of these commits succeeds.
commit_in() {
  echo "$2" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "Add $2"
}

## Set up an origin repository whose build system is a Makefile that creates a
## file named "compiled-marker".  The marker shows that `compile-project` ran.

git -c init.defaultBranch=main init -q --bare "${work_dir}/origin.git"
make_clone "${work_dir}/main"
printf 'all:\n\ttouch compiled-marker\n' > "${work_dir}/main/Makefile"
git -C "${work_dir}/main" add Makefile
git -C "${work_dir}/main" commit -q -m 'Add Makefile'
git -C "${work_dir}/main" push -q -u origin main

make_clone "${work_dir}/feature"
git -C "${work_dir}/feature" checkout -q -b feature
commit_in "${work_dir}/feature" feature-1
git -C "${work_dir}/feature" push -q -u origin feature

## Test `git-push-to`.

# Give the main branch a commit of its own, so that the merge is a real merge.
commit_in "${work_dir}/main" main-1

if ! PATH="${PATH_WITHOUT_COMPILE_PROJECT}" "${REPO_DIR}/git-push-to" \
  "${work_dir}/feature" "${work_dir}/main"; then
  fail "git-push-to did not succeed when compile-project is not on the PATH"
fi
if [ ! -f "${work_dir}/main/compiled-marker" ]; then
  fail 'git-push-to did not run compile-project'
fi

## Test `git-pull-from`.

rm -f "${work_dir}/main/compiled-marker"
commit_in "${work_dir}/feature" feature-2
git -C "${work_dir}/feature" push -q

if ! (cd "${work_dir}/main" \
  && PATH="${PATH_WITHOUT_COMPILE_PROJECT}" "${REPO_DIR}/git-pull-from" "${work_dir}/feature"); then
  fail "git-pull-from did not succeed when compile-project is not on the PATH"
fi
if [ ! -f "${work_dir}/main/compiled-marker" ]; then
  fail 'git-pull-from did not run compile-project'
fi

echo "${SCRIPT_NAME}: PASSED"
