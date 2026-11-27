#!/bin/sh

# Runs every test in this directory.  A test is a file whose name starts with
# `test-`; it passes if it exits with status 0.  A test whose name ends in `.py`
# is run by `python3`; any other test must be executable and is run directly.
#
# The tests run in parallel, JOBS at a time (by default, the number of
# processors).  As each test finishes, this script prints a line that says
# whether it passed.  After every test has finished, this script prints the
# output of each test, in the order of the tests' names.  The exit status is 0
# if every test passed, and 1 otherwise.
#
# Usage:
#   tests/run-tests.sh [-j JOBS]

set -eu

TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"

jobs="$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 1)"
while getopts j: opt; do
  case "${opt}" in
    j) jobs="${OPTARG}" ;;
    *)
      echo "Usage: ${SCRIPT_NAME} [-j JOBS]" >&2
      exit 2
      ;;
  esac
done
case "${jobs}" in
  '' | *[!0-9]* | 0*)
    echo "${SCRIPT_NAME}: JOBS must be a positive integer, not \"${jobs}\"" >&2
    exit 2
    ;;
esac

# Holds, for each test TEST, its output in TEST.log and its exit status in
# TEST.status.
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "${LOG_DIR}"' EXIT
trap 'rm -rf "${LOG_DIR}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${LOG_DIR}"; trap - TERM; kill -s TERM "$$"' TERM

# The tests, one per line, in the order of their names.
tests=''
for test_script_absolute in "${TESTS_DIR}"/test-*; do
  # Skips a directory, and the pattern itself when the pattern matches nothing
  # and the shell leaves it unexpanded.
  if [ ! -f "${test_script_absolute}" ]; then continue; fi
  test_script="$(basename -- "${test_script_absolute}")"
  # Skips editor backup files, such as `test-foo~` and `test-foo.~1~`.
  case "${test_script}" in *'~'*) continue ;; esac
  # Skips a non-executable file, which is not a test.  A Python test is run by
  # the interpreter, so it need not be executable.
  case "${test_script}" in
    *.py) ;;
    *) if [ ! -x "${test_script_absolute}" ]; then continue; fi ;;
  esac
  tests="${tests}${test_script}
"
done

# A shell script that runs one test.  Its arguments are this directory, the log
# directory, and the test.  It saves the test's output and exit status in the
# log directory, and it prints a line that says whether the test passed.
# shellcheck disable=SC2016 # The shell that xargs starts expands the variables.
RUN_TEST='
  tests_dir="$1"
  log_dir="$2"
  test_script="$3"
  case "${test_script}" in
    *.py) set -- python3 "${tests_dir}/${test_script}" ;;
    *) set -- "${tests_dir}/${test_script}" ;;
  esac
  if "$@" > "${log_dir}/${test_script}.log" 2>&1 < /dev/null; then
    test_status=0
    echo "Passed: ${test_script}"
  else
    test_status=$?
    echo "FAILED: ${test_script}"
  fi
  echo "${test_status}" > "${log_dir}/${test_script}.status"
'

# Starts the largest tests first.  A larger test usually takes longer, and a
# long test that started last would leave the other processors idle while it
# finishes.
printf '%s' "${tests}" | while IFS= read -r test_script; do
  printf '%s %s\n' "$(wc -c < "${TESTS_DIR}/${test_script}")" "${test_script}"
done | sort -k1,1nr -k2 | cut -d ' ' -f 2- \
  | xargs -n 1 -P "${jobs}" sh -c "${RUN_TEST}" sh "${TESTS_DIR}" "${LOG_DIR}" || true

status=0
for test_script in ${tests}; do
  echo "Output of ${test_script}:"
  cat -- "${LOG_DIR}/${test_script}.log" 2> /dev/null || true
  if [ "$(cat -- "${LOG_DIR}/${test_script}.status" 2> /dev/null)" != 0 ]; then
    echo "FAILED: ${test_script}"
    status=1
  fi
done

exit "${status}"
