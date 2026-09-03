#!/bin/sh

# Checks that every environment variable that the scripts read is documented
# in README.md.  A variable that a script reads but never sets is part of the
# user-visible interface, so the README must describe it.
#
# Usage:
#   tests/env-vars-documented.sh
#
# The exit status is 0 if every such variable is documented, and 1 otherwise.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
TOPLEVEL="$(dirname -- "${SCRIPT_DIR}")"
SCRIPT_NAME="$(basename -- "$0")"

README="${TOPLEVEL}/README.md"

SCRIPTS="compile-project git-checkout-branch git-new-branch git-orphaned-branches git-pull-from git-push-to is-deleted-branch"

# Variables that the shell or the operating system sets, which are therefore
# not part of the interface of these scripts.
STANDARD_VARIABLES="CDPATH HOME IFS LANG LC_ALL PATH PWD TMPDIR"

status=0

for script in ${SCRIPTS}; do
  file="${TOPLEVEL}/${script}"
  if [ ! -f "${file}" ]; then
    echo "${SCRIPT_NAME}: no such file: ${file}" >&2
    exit 2
  fi
  # Remove comments, so that documentation and commented-out code do not
  # affect which variables are considered set or read.  A "#" that follows a
  # non-blank character, as in "$#", does not start a comment.
  code="$(sed -E 's/(^|[[:space:]])#.*/\1/' "${file}")"
  set_variables="$(printf '%s\n' "${code}" \
    | grep -oE '(^|[^A-Za-z0-9_$])[A-Z][A-Z0-9_]*=' \
    | grep -oE '[A-Z][A-Z0-9_]*' | sort -u)"
  read_variables="$(printf '%s\n' "${code}" \
    | grep -oE '\$\{?[A-Z][A-Z0-9_]*' \
    | grep -oE '[A-Z][A-Z0-9_]*' | sort -u)"
  for variable in ${read_variables}; do
    if printf '%s\n' "${set_variables}" | grep -qx "${variable}"; then
      continue
    fi
    case " ${STANDARD_VARIABLES} " in
      *" ${variable} "*) continue ;;
    esac
    if ! grep -qF "${variable}" "${README}"; then
      echo "${SCRIPT_NAME}: ${script} reads ${variable}, which README.md does not document" >&2
      status=1
    fi
  done
done

if [ "${status}" -eq 0 ]; then
  echo "${SCRIPT_NAME}: all environment variables are documented"
fi

exit "${status}"
