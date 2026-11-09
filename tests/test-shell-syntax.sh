#!/bin/sh

# Checks that every shell script in this package, including each test, parses
# under the shell that runs it.  On macOS, that shell is bash 3.2 for a script
# whose "#!" line names /bin/sh, so there this test finds each construct that
# bash 3.2 cannot parse, even in a script that no other test runs.
#
# Usage:
#   tests/test-shell-syntax.sh
#
# The exit status is 0 if every shell script parses, 2 if this test cannot
# determine which shell runs some script, and 1 otherwise.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
TOPLEVEL="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)" || exit 1
SCRIPT_NAME="$(basename -- "$0")"

# shellcheck source=common-test-functions.sh
. "${SCRIPT_DIR}/common-test-functions.sh"

# The files in the top-level directory and in this one, other than editor
# backup files.
FILES="$(find "${TOPLEVEL}" "${SCRIPT_DIR}" -maxdepth 1 -type f ! -name '*~' | sort)"
# Split FILES only at newlines, and do not expand a "*" in a file name.
IFS='
'
set -f

# True if some script does not parse.
unparsed=0
# True if this test cannot determine which shell runs some script.
undetermined=0
# True if some script that bash 3 runs does not parse.
unparsed_by_bash3=0
checked=0
for file in ${FILES}; do
  # The shell that runs FILE, or nothing if FILE is not a shell script.
  if ! shell="$(script_shell "${file}")"; then
    undetermined=1
    continue
  fi
  if [ -z "${shell}" ]; then continue; fi
  checked=$((checked + 1))
  if ! "${shell}" -n "${file}"; then
    echo "${SCRIPT_NAME}: ${shell} cannot parse ${file}" >&2
    unparsed=1
    # The shell that parsed FILE, not this one, expands BASH_VERSION.
    # shellcheck disable=SC2016
    case "$("${shell}" -c 'echo "${BASH_VERSION:-}"' 2> /dev/null)" in
      3.*) unparsed_by_bash3=1 ;;
    esac
  fi
done

if [ "${checked}" -eq 0 ]; then
  echo "${SCRIPT_NAME}: found no shell scripts in ${TOPLEVEL} or ${SCRIPT_DIR}" >&2
  exit 2
fi

if [ "${unparsed_by_bash3}" -eq 1 ]; then
  echo "${SCRIPT_NAME}: one possible cause:  bash 3.2, which is /bin/sh on macOS, reads a comment as code" >&2
  echo "${SCRIPT_NAME}: within a \"\$(...)\" command substitution that is within double quotation marks, or after a \";\", \"&\"," >&2
  echo "${SCRIPT_NAME}: \"|\", or \"(\".  An unmatched quotation mark in such a comment, as in \"# It's\"," >&2
  echo "${SCRIPT_NAME}: or an unmatched \"(\" is a syntax error." >&2
fi

if [ "${undetermined}" -eq 1 ]; then
  exit 2
fi
exit "${unparsed}"
