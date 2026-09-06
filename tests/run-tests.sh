#!/bin/sh

# Runs every test in this directory.  Exits with status 0 if all tests pass.
#
# Usage:
#   tests/run-tests.sh

TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

status=0
for test_script in "${TESTS_DIR}"/test-*; do
  # Skip editor backup files such as "test-branch-interrupt.sh.~1~".
  case "${test_script}" in
    *~) continue ;;
  esac
  if ! "${test_script}"; then
    echo "FAILURE: ${test_script}" >&2
    status=1
  fi
done
exit "${status}"
