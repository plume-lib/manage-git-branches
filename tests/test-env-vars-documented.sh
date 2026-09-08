#!/bin/sh

# Checks that every environment variable that the scripts read is documented
# in README.md.  A variable that a script reads but never sets is part of the
# user-visible interface, so the README must describe it.
#
# Usage:
#   tests/test-env-vars-documented.sh
#
# The exit status is 0 if every such variable is documented, and 1 otherwise.

# TODO: If this is generally useful, move it into plume-scripts or elsewhere.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
TOPLEVEL="$(dirname -- "${SCRIPT_DIR}")"
SCRIPT_NAME="$(basename -- "$0")"

README="${TOPLEVEL}/README.md"

SCRIPTS="$(find "${TOPLEVEL}" -maxdepth 1 -type f -perm -u+x ! -name '*~' \
  -exec basename -- {} ';' | sort)"
if [ -z "${SCRIPTS}" ]; then
  echo "${SCRIPT_NAME}: found no scripts in ${TOPLEVEL}" >&2
  exit 2
fi

# Variables that the shell or the operating system sets, which are therefore
# not part of the interface of these scripts.
STANDARD_VARIABLES="CDPATH HOME IFS LANG LC_ALL PATH PWD TMPDIR"

# Usage: script_code FILE
# Prints FILE with comments removed, so that documentation and commented-out
# code do not affect which variables are considered set or read.  A "#" that
# follows a non-blank character, as in "$#", does not start a comment.
script_code() {
  sed -E 's/(^|[[:space:]])#.*/\1/' "$1"
}

# Usage: set_variables_in FILE
# Prints, one per line, the variables that FILE assigns.
set_variables_in() {
  script_code "$1" \
    | grep -oE '(^|[^A-Za-z0-9_$])[A-Z][A-Z0-9_]*=' \
    | grep -oE '[A-Z][A-Z0-9_]*' | sort -u
}

for script in ${SCRIPTS}; do
  file="${TOPLEVEL}/${script}"
  if [ ! -f "${file}" ]; then
    echo "${SCRIPT_NAME}: no such file: ${file}" >&2
    exit 2
  fi
done

# The variables that some script in this package assigns.  One script sets
# such a variable before invoking another that reads it, so it is internal to
# the package rather than part of its user-visible interface.
PACKAGE_SET_VARIABLES=''
for script in ${SCRIPTS}; do
  PACKAGE_SET_VARIABLES="${PACKAGE_SET_VARIABLES}
$(set_variables_in "${TOPLEVEL}/${script}")"
done
PACKAGE_SET_VARIABLES="$(printf '%s\n' "${PACKAGE_SET_VARIABLES}" | sort -u)"

status=0

for script in ${SCRIPTS}; do
  file="${TOPLEVEL}/${script}"
  read_variables="$(script_code "${file}" \
    | grep -oE '\$\{?[A-Z][A-Z0-9_]*' \
    | grep -oE '[A-Z][A-Z0-9_]*' | sort -u)"
  for variable in ${read_variables}; do
    if printf '%s\n' "${PACKAGE_SET_VARIABLES}" | grep -qx "${variable}"; then
      continue
    fi
    case " ${STANDARD_VARIABLES} " in
      *" ${variable} "*) continue ;;
    esac
    if ! grep -qF "\`${variable}\`" "${README}"; then
      echo "${SCRIPT_NAME}: ${script} reads ${variable}, which README.md does not document" >&2
      status=1
    fi
  done
done

if [ "${status}" -eq 0 ]; then
  echo "${SCRIPT_NAME}: OK"
fi

exit "${status}"
