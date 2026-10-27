#!/bin/sh

# Runs every test in this directory.  A test is a file whose name starts with
# `test-`; it passes if it exits with status 0.  A test whose name ends in `.py`
# is run by `python3`; any other test must be executable and is run directly.
#
# Usage:
#   tests/run-tests.sh

TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

status=0

for test_script_absolute in "${TESTS_DIR}"/test-*; do
  # Skips a directory, and the pattern itself when the pattern matches nothing
  # and the shell leaves it unexpanded.
  if [ ! -f "${test_script_absolute}" ]; then continue; fi
  test_script="$(basename -- "${test_script_absolute}")"
  # Skips editor backup files, such as `test-foo~` and `test-foo.~1~`.
  case "${test_script}" in *'~'*) continue ;; esac
  case "${test_script}" in
    # A Python test is run by the interpreter, so it need not be executable.
    *.py) set -- python3 "${test_script_absolute}" ;;
    # Skips a non-executable file, which is not a test.
    *) if [ ! -x "${test_script_absolute}" ]; then continue; fi
       set -- "${test_script_absolute}" ;;
  esac
  echo "Running ${test_script}"
  if ! "$@"; then
    echo "FAILED: ${test_script}"
    status=1
  fi
done

exit "${status}"
