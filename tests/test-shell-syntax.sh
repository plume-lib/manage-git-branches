#!/bin/sh

# Checks that every shell script in this package, including each test, parses
# under the shell that runs it.  On macOS, that shell is bash 3.2 for a script
# whose "#!" line names /bin/sh, so there this test finds each construct that
# bash 3.2 cannot parse, even in a script that no other test runs.
#
# Usage:
#   tests/test-shell-syntax.sh
#
# The exit status is 0 if every shell script parses, 1 if some script does not,
# and 2 if this test cannot determine which shell runs some script.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
TOPLEVEL="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)" || exit 1
SCRIPT_NAME="$(basename -- "$0")"

# The files in the top-level directory and in this one, other than editor
# backup files.
FILES="$(find "${TOPLEVEL}" "${SCRIPT_DIR}" -maxdepth 1 -type f ! -name '*~' | sort)"
# Split FILES only at newlines, and do not expand a "*" in a file name.
IFS='
'
set -f

status=0
checked=0
for file in ${FILES}; do
  # The shell that runs FILE, or nothing if FILE is not a shell script.  A
  # file whose name ends in ".sh" and that has no "#!" line is sourced by a
  # script whose "#!" line names /bin/sh.
  case "$(head -n 1 -- "${file}")" in
    '#!/bin/sh' | '#!/bin/sh '*) shell=/bin/sh ;;
    '#!/bin/bash' | '#!/bin/bash '*) shell=/bin/bash ;;
    '#!/usr/bin/env sh') shell='sh' ;;
    '#!/usr/bin/env bash') shell='bash' ;;
    '#!'*sh | '#!'*sh' '*)
      echo "${SCRIPT_NAME}: cannot determine which shell runs ${file}" >&2
      echo "${SCRIPT_NAME}: extend the \"case\" statement in ${SCRIPT_NAME}" >&2
      exit 2
      ;;
    '#!'*) shell= ;;
    *) case "${file}" in *.sh) shell=/bin/sh ;; *) shell= ;; esac ;;
  esac
  if [ -z "${shell}" ]; then continue; fi
  checked=$((checked + 1))
  if ! "${shell}" -n "${file}"; then
    echo "${SCRIPT_NAME}: ${shell} cannot parse ${file}" >&2
    status=1
  fi
done

if [ "${checked}" -eq 0 ]; then
  echo "${SCRIPT_NAME}: found no shell scripts in ${TOPLEVEL} or ${SCRIPT_DIR}" >&2
  exit 2
fi

if [ "${status}" -ne 0 ]; then
  echo "${SCRIPT_NAME}: bash 3.2, which is /bin/sh on macOS, reads a comment as code within a \"\$(...)\"" >&2
  echo "${SCRIPT_NAME}: command substitution that is within double quotation marks, or after a \";\", \"&\"," >&2
  echo "${SCRIPT_NAME}: \"|\", or \"(\".  An unmatched quotation mark in such a comment, as in \"# It's\"," >&2
  echo "${SCRIPT_NAME}: or an unmatched \"(\" is a syntax error." >&2
fi

exit "${status}"
