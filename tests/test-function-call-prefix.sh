#!/bin/sh

# Checks that no shell script in this package, including each test, prefixes
# an assignment to a call of a shell function, as in "VAR=value some_function".
# Bash 3.2, which is /bin/sh on macOS, keeps such an assignment after the
# function returns, so it applies to every later command too.  Dash, which is
# /bin/sh on Linux, does not, so no test that runs only on Linux reveals the
# problem.
#
# A function counts if some shell script in this package defines it at the
# start of a line, as in "some_function() {".  A function that is defined in a
# nested scope, as a test defines a function named "git" within a subshell to
# override the command, does not count.  This test does not look within a
# command substitution, as in "$(VAR=value some_function)", whose effects end
# with the substitution.
#
# Usage:
#   tests/test-function-call-prefix.sh
#
# The exit status is 0 if no script prefixes an assignment to a call of a
# function, 2 if this test cannot parse some script, and 1 otherwise.

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

SCRIPTS=''
for file in ${FILES}; do
  # The shell that runs FILE, or nothing if FILE is not a shell script.
  shell="$(script_shell "${file}")" || exit 2
  if [ -n "${shell}" ]; then
    SCRIPTS="${SCRIPTS}${file}
"
  fi
done
if [ -z "${SCRIPTS}" ]; then
  echo "${SCRIPT_NAME}: found no shell scripts in ${TOPLEVEL} or ${SCRIPT_DIR}" >&2
  exit 2
fi

# The functions that the scripts define, one per line.
# shellcheck disable=SC2086 # SCRIPTS is split only at newlines.
FUNCTIONS="$(grep -h -o -E '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' ${SCRIPTS} \
  | sed -E 's/[[:space:]]*\(\)$//' | LC_ALL=C sort -u)"

# Check the parser on a script that prefixes assignments to commands both
# in code and in here-documents, whose lines are data rather than code.
FIXTURE="$(mktemp "${TMPDIR:-/tmp}/manage-git-branches-fixture.XXXXXX")"
trap 'rm -f "${FIXTURE}"' EXIT
trap 'rm -f "${FIXTURE}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -f "${FIXTURE}"; trap - TERM; kill -s TERM "$$"' TERM
cat > "${FIXTURE}" << 'FIXTURE_END'
CODE_ONE=1 first-command "a b"
cat << 'EOF'
DATA_ONE=1 data-command
EOF
cat <<-EOF > /dev/null
	DATA_TWO=1 data-command
	EOF
if CODE_TWO="$(cat << EOF
DATA_THREE=1 data-command
EOF
)" second-command; then :; fi
FIXTURE_END
fixture_parsed="$(awk -v skip_heredocs=1 -f "${SCRIPT_DIR}/shell-set-variables.awk" "${FIXTURE}" \
  | grep -E '^prefix')"
fixture_expected='prefix CODE_ONE
prefixed-command first-command
prefix CODE_TWO
prefixed-command second-command'
if [ "${fixture_parsed}" != "${fixture_expected}" ]; then
  echo "${SCRIPT_NAME}: shell-set-variables.awk misparsed the fixture:" >&2
  printf '%s\n' "${fixture_parsed}" >&2
  exit 2
fi

status=0
for script in ${SCRIPTS}; do
  # An assignment, so that "set -e" exits if awk fails.
  parsed="$(awk -v skip_heredocs=1 -f "${SCRIPT_DIR}/shell-set-variables.awk" "${script}")"
  if printf '%s\n' "${parsed}" | grep -q -x -E '<here-document>|<unclosed>'; then
    echo "${SCRIPT_NAME}: cannot parse ${script}; see shell-set-variables.awk" >&2
    exit 2
  fi
  for command in $(printf '%s\n' "${parsed}" | sed -n 's/^prefixed-command //p' \
    | LC_ALL=C sort -u); do
    if printf '%s\n' "${FUNCTIONS}" | grep -q -x -F -- "${command}"; then
      echo "${SCRIPT_NAME}: ${script} prefixes an assignment to a call of function ${command}" >&2
      status=1
    fi
  done
done

exit "${status}"
