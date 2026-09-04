#!/bin/sh

# Tests that `git-orphaned-branches` and `git-push-to` find the helper script
# `is-deleted-branch`, which sits beside them, even when the script that is
# invoked is a symbolic link to the real script rather than the script itself.

TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
TOPLEVEL="$(CDPATH='' cd -- "${TESTS_DIR}/.." && pwd -P)"

status=0

work="$(realpath "$(mktemp -d)")"
trap 'rm -rf "${work}"' EXIT INT TERM

# `git-orphaned-branches` is reached through a relative symbolic link that
# points to an absolute symbolic link, and `git-push-to` through a single
# absolute symbolic link.
mkdir "${work}/bin" "${work}/stage"
ln -s "${TOPLEVEL}/git-orphaned-branches" "${work}/stage/git-orphaned-branches"
ln -s "../stage/git-orphaned-branches" "${work}/bin/git-orphaned-branches"
ln -s "${TOPLEVEL}/git-push-to" "${work}/bin/git-push-to"

clone_count=0

# Creates, in directory $1, a clone whose upstream branch has been deleted.
# Arguments: DIRECTORY
make_deleted_branch_clone() {
  clone="$1"
  clone_count=$((clone_count + 1))
  remote="${work}/remote-${clone_count}.git"
  git init --bare -q "${remote}" > /dev/null 2>&1
  git clone -q "${remote}" "${clone}" > /dev/null 2>&1
  git -C "${clone}" config user.email "test@example.com"
  git -C "${clone}" config user.name "Test"
  git -C "${clone}" checkout -q -b feature
  echo "hello" > "${clone}/f.txt"
  git -C "${clone}" add f.txt
  git -C "${clone}" commit -qm "initial"
  git -C "${clone}" push -q -u origin feature
  # Delete the branch in the remote, without pruning the clone.
  git -C "${remote}" update-ref -d refs/heads/feature
}

# Checks that `git-push-to` diagnoses a deleted branch, which it can do only
# if it ran `is-deleted-branch`.
# Arguments: GIT_PUSH_TO_COMMAND SLUG DESCRIPTION
check_git_push_to() {
  from="${work}/push-from-$2"
  make_deleted_branch_clone "${from}"
  mkdir "${work}/push-to-$2"
  output="$("$1" "${from}" "${work}/push-to-$2" 2>&1)"
  case "${output}" in
    *"is a deleted branch"*) ;;
    *)
      echo "FAIL: git-push-to invoked as $3 printed '${output}'"
      echo "      rather than reporting a deleted branch"
      status=1
      ;;
  esac
}

# Checks that `git-orphaned-branches` lists a clone whose branch was deleted,
# which it can do only if it ran `is-deleted-branch`.
# Arguments: GIT_ORPHANED_BRANCHES_COMMAND SLUG DESCRIPTION
check_git_orphaned_branches() {
  scan="${work}/scan-$2"
  mkdir "${scan}"
  make_deleted_branch_clone "${scan}/myrepo-branch-feature"
  output="$(cd "${scan}" && "$1" 2>&1)"
  if [ "${output}" != "${scan}/myrepo-branch-feature" ]; then
    echo "FAIL: git-orphaned-branches invoked as $3 printed '${output}'"
    echo "      rather than '${scan}/myrepo-branch-feature'"
    status=1
  fi
}

check_git_push_to "${TOPLEVEL}/git-push-to" direct "itself"
check_git_push_to "${work}/bin/git-push-to" symlink "a symbolic link"

check_git_orphaned_branches "${TOPLEVEL}/git-orphaned-branches" direct "itself"
check_git_orphaned_branches "${work}/bin/git-orphaned-branches" symlink "a symbolic link"

exit "${status}"
