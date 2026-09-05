#!/bin/sh

# Tests that `git-push-to` and `git-pull-from` run `compile-project` even when
# the manage-git-branches directory is not on the PATH.
#
# Usage:
#   tests/test-compile-project-invocation.sh

set -e

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"
REPO_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $1" >&2
  exit 1
}

# Prints a PATH that contains the utilities the scripts need, but that does not
# contain ${REPO_DIR}.
path_without_repo_dir() {
  result=''
  for tool in basename dirname git grep make realpath sed; do
    toolpath="$(command -v "${tool}")" || fail "cannot find ${tool}"
    tooldir="$(dirname -- "${toolpath}")"
    if [ "${tooldir}" = "${REPO_DIR}" ]; then
      fail "${tool} resolves to ${REPO_DIR}; cannot build a PATH without ${REPO_DIR}"
    fi
    case ":${result}:" in
      *":${tooldir}:"*) ;;
      *) result="${result}${result:+:}${tooldir}" ;;
    esac
  done
  printf '%s\n' "${result}"
}

# Creates a clone of ${remote} at the given directory, configured for merging.
make_clone() {
  git clone -q "${remote}" "$1"
  git -C "$1" config pull.rebase false
}

# Adds a commit to the given clone and pushes it.
commit_and_push() {
  date > "$1/change-$2.txt"
  git -C "$1" add "change-$2.txt"
  git -C "$1" commit -q -m "change $2"
  git -C "$1" push -q
}

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
trap 'rm -rf "${workdir}"; exit 130' INT
trap 'rm -rf "${workdir}"; exit 143' TERM

GIT_AUTHOR_NAME='manage-git-branches test'
GIT_AUTHOR_EMAIL='test@example.com'
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

remote="${workdir}/remote.git"
git init -q --bare -b main "${remote}"

# The Makefile that `compile-project` will run.  Its recipe creates a marker
# file, so a test can detect whether `compile-project` ran.
make_clone "${workdir}/from"
printf 'all:\n\ttouch compile-project-ran\n' > "${workdir}/from/Makefile"
git -C "${workdir}/from" add Makefile
git -C "${workdir}/from" commit -q -m "initial commit"
git -C "${workdir}/from" push -q -u origin main

clean_path="$(path_without_repo_dir)"

## Test git-push-to.

make_clone "${workdir}/to"
commit_and_push "${workdir}/from" 1

if ! PATH="${clean_path}" "${REPO_DIR}/git-push-to" "${workdir}/from" "${workdir}/to"; then
  fail "git-push-to failed when ${REPO_DIR} was not on the PATH"
fi
if [ ! -f "${workdir}/to/compile-project-ran" ]; then
  fail "git-push-to did not run compile-project"
fi

## Test git-pull-from.

make_clone "${workdir}/to2"
commit_and_push "${workdir}/from" 2

if ! (cd "${workdir}/to2" && PATH="${clean_path}" "${REPO_DIR}/git-pull-from" "${workdir}/from"); then
  fail "git-pull-from failed when ${REPO_DIR} was not on the PATH"
fi
if [ ! -f "${workdir}/to2/compile-project-ran" ]; then
  fail "git-pull-from did not run compile-project"
fi

echo "${SCRIPT_NAME}: PASS"
