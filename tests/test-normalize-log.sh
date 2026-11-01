#!/bin/sh

# Tests the `normalize-log` script.

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
TOPLEVEL="$(CDPATH='' cd -- "${TESTS_DIR}/.." && pwd -P)"
NORMALIZE_LOG="${TOPLEVEL}/normalize-log"

status=0

if ! work="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")" || [ -z "${work}" ]; then
  echo "${SCRIPT_NAME}: cannot create a temporary directory" >&2
  exit 1
fi
trap 'rm -rf "${work}"' EXIT
trap 'rm -rf "${work}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${work}"; trap - TERM; kill -s TERM "$$"' TERM

fail() {
  echo "FAIL: $*"
  status=1
}

# A log with a byte order mark, timestamps, color codes, and carriage returns.
printf '\357\273\2772026-10-31T13:39:57.3265176Z ##[section]Starting: build\r\n' > "${work}/log1"
printf '2026-10-31T13:39:58Z \033[31mCaused by: \033[1;31mRead timed out\033[0m\r\n' >> "${work}/log1"
printf '  indented 2026-10-31T13:39:58Z not a leading timestamp\n' >> "${work}/log1"
expected1='##[section]Starting: build
Caused by: Read timed out
  indented 2026-10-31T13:39:58Z not a leading timestamp'

printf '\357\273\277+ echo hi\n' > "${work}/log2"
expected2='+ echo hi'

actual="$("${NORMALIZE_LOG}" "${work}/log1")"
if [ "${actual}" != "${expected1}" ]; then
  fail "normalize-log printed
${actual}
rather than
${expected1}"
fi

actual="$("${NORMALIZE_LOG}" "${work}/log1" "${work}/log2")"
if [ "${actual}" != "${expected1}
${expected2}" ]; then
  fail "normalize-log on two files printed
${actual}
rather than
${expected1}
${expected2}"
fi

actual="$("${NORMALIZE_LOG}" < "${work}/log2")"
if [ "${actual}" != "${expected2}" ]; then
  fail "normalize-log on standard input printed '${actual}' rather than '${expected2}'"
fi

if "${NORMALIZE_LOG}" "${work}/no-such-file" > /dev/null 2>&1; then
  fail "normalize-log succeeded on a nonexistent file"
fi

exit "${status}"
