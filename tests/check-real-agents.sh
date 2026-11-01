#!/bin/sh

# Checks that `git-push-to` works with the real AI agents:  that each one
# resolves a merge conflict and fixes a build that a merge broke.
#
# Usage:
#   tests/check-real-agents.sh [AGENT...]
#
# Each AGENT is "claude" or "codex"; the default is both.  The agents must be
# installed and logged in.
#
# This script is not part of the regular test suite, which `run-tests.sh`
# runs:  its name does not start with "test-".  It is slow, it uses the
# agents' quota, and its result depends on the agents.
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(CDPATH='' cd -- "${TESTS_DIR}/.." && pwd -P)" || exit 1

if [ "$#" -eq 0 ]; then
  set -- claude codex
fi
for agent; do
  case "${agent}" in
    claude | codex) ;;
    *)
      echo "Usage: ${SCRIPT_NAME} [claude | codex]..." >&2
      exit 1
      ;;
  esac
  if ! command -v "${agent}" > /dev/null; then
    echo "${SCRIPT_NAME}: cannot find ${agent}" >&2
    exit 1
  fi
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${WORK_DIR}"' EXIT
trap 'rm -rf "${WORK_DIR}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${WORK_DIR}"; trap - TERM; kill -s TERM "$$"' TERM

# `sanitize_git_env` puts failing stand-ins for the agents on the PATH; this
# script wants the real ones.
saved_path="${PATH}"
# shellcheck source=lib-git-test-env.sh
. "${TESTS_DIR}/lib-git-test-env.sh"
sanitize_git_env "${WORK_DIR}"
PATH="${saved_path}"
export PATH

failures=0

## Usage: report DESCRIPTION MESSAGE
## Reports a failed check.
report() {
  echo "${SCRIPT_NAME}: FAILURE: $1: $2" >&2
  failures=$((failures + 1))
}

## Usage: setup_case NAME
## Creates a remote under ${WORK_DIR}/NAME with branches "main" and
## "feature", and a clone of each, ${main_dir} and ${feature_dir}.  Sets
## ${remote} to the remote.  The caller commits each branch's changes.
setup_case() {
  case_dir="${WORK_DIR}/$1"
  mkdir "${case_dir}"
  remote="${case_dir}/myrepo.git"
  git init -q --bare -b main "${remote}"
  git init -q -b main "${case_dir}/seed"
  cat > "${case_dir}/seed/Makefile" << 'EOF'
all:
	for f in *.py; do python3 -B "$$f" || exit 1; done
EOF
  cat > "${case_dir}/seed/greetings.py" << 'EOF'
def greet(name):
    return "Hello, " + name


def farewell(name):
    return "Bye, " + name
EOF
  cat > "${case_dir}/seed/app.py" << 'EOF'
import greetings

print(greetings.greet("world"))
EOF
  git -C "${case_dir}/seed" add Makefile greetings.py app.py
  git -C "${case_dir}/seed" commit -q -m "Initial commit"
  git -C "${case_dir}/seed" remote add origin "${remote}"
  git -C "${case_dir}/seed" push -q --set-upstream origin main
  git -C "${case_dir}/seed" push -q origin main:refs/heads/feature
  main_dir="${case_dir}/myrepo-branch-main"
  feature_dir="${case_dir}/myrepo-branch-feature"
  git clone -q -b main "${remote}" "${main_dir}"
  git clone -q -b feature "${remote}" "${feature_dir}"
  git -C "${main_dir}" config pull.rebase false
  git -C "${feature_dir}" config pull.rebase false
}

## Usage: commit_push DIRECTORY MESSAGE
commit_push() {
  git -C "$1" commit -q -a -m "$2"
  git -C "$1" push -q
}

## Usage: push_to AGENT
## Runs `git-push-to --AGENT ${main_dir} ${feature_dir}`, showing its output,
## and sets ${push_status}.
push_to() {
  if "${COMMANDS_DIR}/git-push-to" "--$1" "${main_dir}" "${feature_dir}"; then
    push_status=0
  else
    push_status=$?
  fi
}

## Usage: check_builds DESCRIPTION
## Checks that the pushed feature branch builds.
check_builds() {
  rm -rf "${case_dir}/check"
  git clone -q -b feature "${remote}" "${case_dir}/check"
  if ! make -s -C "${case_dir}/check" > /dev/null 2>&1; then
    report "$1" "the pushed branch does not build"
  fi
}

for agent; do
  ## A conflict:  main adds a parameter to greet(), and feature changes its
  ## body.  Main also changes farewell(), which merges cleanly.
  description="${agent}: conflict"
  echo "${SCRIPT_NAME}: ${description}"
  setup_case "${agent}-conflict"
  cat > "${main_dir}/greetings.py" << 'EOF'
def greet(name, punct="!"):
    return "Hello, " + name + punct


def farewell(name):
    return "Goodbye, " + name
EOF
  commit_push "${main_dir}" "Add punctuation; say Goodbye"
  cat > "${feature_dir}/greetings.py" << 'EOF'
def greet(name):
    return f"Hello, {name.title()}"


def farewell(name):
    return "Bye, " + name
EOF
  commit_push "${feature_dir}" "Use an f-string and title case"
  push_to "${agent}"
  if [ "${push_status}" -ne 0 ]; then
    report "${description}" "git-push-to failed"
  else
    merged="$(git -C "${remote}" show refs/heads/feature:greetings.py)"
    case "${merged}" in
      *'<<<<<<<'* | *'>>>>>>>'*) report "${description}" "conflict markers remain" ;;
    esac
    case "${merged}" in
      *punct*) ;;
      *) report "${description}" "lost main's change to greet()" ;;
    esac
    case "${merged}" in
      *title*) ;;
      *) report "${description}" "lost feature's change to greet()" ;;
    esac
    case "${merged}" in
      *Goodbye*) ;;
      *) report "${description}" "lost main's change to farewell(), which merged cleanly" ;;
    esac
    check_builds "${description}"
  fi

  ## A build that the merge breaks:  main renames greet() to salute(), and
  ## feature adds a new file that calls greet().  The merge has no textual
  ## conflict.
  description="${agent}: build"
  echo "${SCRIPT_NAME}: ${description}"
  setup_case "${agent}-build"
  sed -e 's/def greet(/def salute(/' "${main_dir}/greetings.py" > "${main_dir}/greetings.py.new"
  mv "${main_dir}/greetings.py.new" "${main_dir}/greetings.py"
  sed -e 's/greetings\.greet(/greetings.salute(/' "${main_dir}/app.py" > "${main_dir}/app.py.new"
  mv "${main_dir}/app.py.new" "${main_dir}/app.py"
  commit_push "${main_dir}" "Rename greet() to salute()"
  cat > "${feature_dir}/farewells.py" << 'EOF'
import greetings


def greet_and_leave(name):
    return greetings.greet(name) + " " + greetings.farewell(name)


if __name__ == "__main__":
    print(greet_and_leave("world"))
EOF
  git -C "${feature_dir}" add farewells.py
  commit_push "${feature_dir}" "Add greet_and_leave()"
  push_to "${agent}"
  if [ "${push_status}" -ne 0 ]; then
    report "${description}" "git-push-to failed"
  elif [ "$(git -C "${remote}" rev-list --count refs/heads/feature)" -ne 5 ]; then
    report "${description}" "expected the fix on top of a merge of 2 branches of 1 commit each"
  else
    message="$(git -C "${remote}" log -1 --format=%s refs/heads/feature)"
    if [ "${message}" != "Fix the build after merging branch 'main'" ]; then
      report "${description}" "the pushed branch does not end with the fix: ${message}"
    fi
    check_builds "${description}"
  fi
done

if [ "${failures}" -ne 0 ]; then
  echo "${SCRIPT_NAME}: ${failures} checks failed" >&2
  exit 1
fi
echo "${SCRIPT_NAME}: all checks passed"
