#!/bin/sh

# Tests that `compile-project` reports the exit status of the build command,
# even when the build command exits with the status that `compile-project`
# formerly used to mean "no buildfile was found".
#
# Usage:
#   tests/test-compile-project-exit-status.sh
#
# The test creates its directories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(dirname -- "${TESTS_DIR}")"
COMPILE_PROJECT="${COMMANDS_DIR}/compile-project"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT INT TERM

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

## Creates directory $1, containing a `gradlew` that exits with status $2.
create_project() {
  mkdir -p "$1"
  printf '#!/bin/sh\nexit %s\n' "$2" > "$1/gradlew"
  chmod +x "$1/gradlew"
}

## Runs `compile-project` on directory $2 and fails the test unless the exit
## status is $1.  $3 is a description of the directory, for the failure message.
check_status() {
  expected="$1"
  dir="$2"
  description="$3"
  status=0
  "${COMPILE_PROJECT}" "${dir}" > /dev/null 2>&1 || status="$?"
  if [ "${status}" -ne "${expected}" ]; then
    fail "compile-project exited with status ${status} rather than ${expected} on ${description}"
  fi
}

# A build command that exits with status 222 at the top level.
create_project "${WORK_DIR}/toplevel222" 222
check_status 222 "${WORK_DIR}/toplevel222" "a top-level build that exits with status 222"

# A build command that exits with status 222 in a subdirectory.
mkdir "${WORK_DIR}/subdir222"
create_project "${WORK_DIR}/subdir222/sub" 222
check_status 222 "${WORK_DIR}/subdir222" "a subdirectory build that exits with status 222"

# A build command that succeeds.
create_project "${WORK_DIR}/success" 0
check_status 0 "${WORK_DIR}/success" "a build that succeeds"

# A build command that fails with the customary status 1.
create_project "${WORK_DIR}/failure" 1
check_status 1 "${WORK_DIR}/failure" "a build that exits with status 1"

# No buildfile: `compile-project` succeeds, unless ERR_IF_NO_BUILDFILE is set.
mkdir "${WORK_DIR}/nobuildfile" "${WORK_DIR}/nobuildfile/sub"
check_status 0 "${WORK_DIR}/nobuildfile" "a directory with no buildfile"

status=0
ERR_IF_NO_BUILDFILE=1 "${COMPILE_PROJECT}" "${WORK_DIR}/nobuildfile" > /dev/null 2>&1 || status="$?"
if [ "${status}" -eq 0 ]; then
  fail "compile-project succeeded with no buildfile and ERR_IF_NO_BUILDFILE set"
fi

echo "${SCRIPT_NAME}: PASS"
