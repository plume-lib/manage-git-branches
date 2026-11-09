#!/bin/sh

# Checks that every environment variable that the scripts read is documented
# in README.md.  A variable that a script reads but never sets is part of the
# user-visible interface, so the README must describe it.
#
# Usage:
#   tests/test-env-vars-documented.sh
#
# The exit status is 0 if every such variable is documented, 1 if some variable
# is not, and 2 if this test cannot determine which variables the scripts set
# or read, as when a script contains a construct that bash 3.2, which is
# /bin/sh on macOS, reads differently than later shells do.

# TODO: If this is generally useful, move it into plume-scripts or elsewhere.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
TOPLEVEL="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)" || exit 1
SCRIPT_NAME="$(basename -- "$0")"

README="${TOPLEVEL}/README.md"

# The commands, which are executable, and the files that they load, which are
# not executable but whose names end in ".awk", ".py", or ".sh".  A variable
# that a loaded file reads is part of the interface of the commands that load
# it.
SCRIPTS="$(find "${TOPLEVEL}" -maxdepth 1 -type f ! -name '*~' \
  \( -perm -u+x -o -name '*.awk' -o -name '*.py' -o -name '*.sh' \) \
  -exec basename -- {} ';' | sort)"
if [ -z "${SCRIPTS}" ]; then
  echo "${SCRIPT_NAME}: found no scripts in ${TOPLEVEL}" >&2
  exit 2
fi

# Usage: script_language FILE
# Prints "awk" if FILE is an awk program, "python" if FILE is a Python script,
# and "shell" if FILE is a shell (sh or Bash) script, judging by its name and
# its "#!" line.  Fails if FILE is none of those, so that a script in another
# language is not silently unchecked.
script_language() {
  case "$1" in
    *.awk)
      echo awk
      return
      ;;
    *.sh)
      echo shell
      return
      ;;
    *.py)
      echo python
      return
      ;;
  esac
  case "$(head -n 1 -- "$1")" in
    '#!/bin/sh' | '#!/bin/bash' | '#!/usr/bin/env sh' | '#!/usr/bin/env bash') echo shell ;;
    '#!/usr/bin/python3' | '#!/usr/bin/env python3') echo python ;;
    *)
      echo "${SCRIPT_NAME}: $1 is neither a shell script nor a Python script" >&2
      echo "${SCRIPT_NAME}: extend script_language and the checks that use it" >&2
      exit 2
      ;;
  esac
}

# Variables that the shell or the operating system sets, which are therefore
# not part of the interface of these scripts.
STANDARD_VARIABLES="BASH_VERSINFO BASH_VERSION CDPATH HOME IFS LANG LC_ALL PATH PPID PWD TMPDIR"

# Usage: script_code FILE
# Prints FILE with comments removed, so that documentation and commented-out
# code do not affect which variables are considered set or read.  A "#" that
# follows a non-blank character, as in "$#", does not start a comment.
script_code() {
  sed -E 's/(^|[[:space:]])#.*/\1/' "$1"
}

# Usage: set_variables_in FILE KIND
# Prints, one per line, the variables that FILE, a shell script, sets in the
# way that KIND, which is "statement" or "prefix", names:
#  * "statement":  the variables that FILE assigns in an assignment statement,
#    such as `VAR=value`, `export VAR=value`, `ARRAY[KEY]=value`, or
#    `ARRAY+=(value)`; declares as an array, as in `declare -A ARRAY`; or reads
#    input into, as in `read VAR` or `mapfile ARRAY`.
#  * "prefix":  the variables that FILE assigns in an environment prefix of a
#    command, as in `VAR=value some-command`.
#
# An environment prefix sets the variable only in the environment of that
# command, which does not make the variable internal to this package.  For
# example, `is-deleted-branch` runs
# `GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=... git ls-remote ...`; the SSH
# variables remain part of the user-visible interface and must be documented.
#
# `shell-set-variables.awk` describes how this parses FILE.  It does not
# handle here-documents, whose lines are data rather than code.  It fails,
# rather than reading them as code, if a script contains one.  It also fails,
# after printing the line number of each, if a script contains a comment
# within a command substitution that bash 3.2 reads as code.
set_variables_in() {
  # An assignment, so that "set -e" exits if awk fails.
  assigned="$(awk -f "${SCRIPT_DIR}/shell-set-variables.awk" "$1")"
  if printf '%s\n' "${assigned}" | grep -q '^<comment-in-substitution> '; then
    printf '%s\n' "${assigned}" | sed -n -e 's/^<comment-in-substitution> //p' | while IFS= read -r line_number; do
      echo "${SCRIPT_NAME}: $1:${line_number}: this comment within a command substitution begins a quotation or a parenthesis that it does not end, or ends one that it did not begin" >&2
    done
    echo "${SCRIPT_NAME}: bash 3.2, which is /bin/sh on macOS, reads such a comment as code" >&2
    echo "${SCRIPT_NAME}: rephrase the comment, or move the code out of the command substitution, as into a function" >&2
    exit 2
  fi
  if printf '%s\n' "${assigned}" | grep -qxF '<here-document>'; then
    echo "${SCRIPT_NAME}: $1 contains a here-document, which set_variables_in does not parse" >&2
    echo "${SCRIPT_NAME}: extend set_variables_in to skip the lines of a here-document" >&2
    exit 2
  fi
  if printf '%s\n' "${assigned}" | grep -qxF '<unclosed>'; then
    echo "${SCRIPT_NAME}: $1 ends within a quotation, a command substitution, a parameter expansion, an array literal, or a \"case\" statement" >&2
    echo "${SCRIPT_NAME}: either it is not valid shell, or set_variables_in mis-parsed it" >&2
    exit 2
  fi
  # Sort in the C locale, so that the order does not depend on the user's.
  printf '%s\n' "${assigned}" | sed -n "s/^$2 //p" | grep -xE '[A-Z][A-Z0-9_]*' \
    | LC_ALL=C sort -u
}

# Usage: shell_variables_read FILE
# Prints, one per line, the variables that FILE, a shell script, reads, as in
# `$VAR` or `${VAR}`.
shell_variables_read() {
  script_code "$1" | grep -oE '\$\{?[A-Z][A-Z0-9_]*' | grep -oE '[A-Z][A-Z0-9_]*' | sort -u
}

# Usage: python_variables FILE KIND
# Prints, one per line, the environment variables that FILE, a Python script,
# uses in the way that KIND, which is "read" or "set", names, as
# `python-environ-variables.py` describes.  Fails if FILE is not valid Python.
python_variables() {
  if ! names="$(python3 -I "${SCRIPT_DIR}/python-environ-variables.py" "$1" "$2")"; then
    echo "${SCRIPT_NAME}: python3 could not parse $1" >&2
    exit 2
  fi
  if [ -n "${names}" ]; then
    printf '%s\n' "${names}"
  fi
}

# Usage: awk_variables_read FILE
# Prints, one per line, the environment variables that FILE, an awk program,
# reads, as in `ENVIRON["VAR"]`.
awk_variables_read() {
  script_code "$1" | grep -oE 'ENVIRON\[[[:space:]]*"[A-Z][A-Z0-9_]*"' \
    | grep -oE '"[A-Z][A-Z0-9_]*"' | tr -d '"' | sort -u
}

# Check `set_variables_in` itself on a script that contains each construct
# that it must get right.  The distinction that it makes -- an assignment
# statement, whose variable is internal to this package, versus an environment
# prefix of a command, whose variable is not -- is easy to break, and breaking
# it would make this test quietly stop requiring a variable to be documented.
# The script has no "#!" line, so `set_variables_in` parses it as a POSIX shell
# script, as in the expansion "${PLAIN:-it's}".
FIXTURE="$(mktemp "${TMPDIR:-/tmp}/manage-git-branches-fixture.XXXXXX")"
trap 'rm -f "${FIXTURE}"' EXIT
trap 'rm -f "${FIXTURE}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -f "${FIXTURE}"; trap - TERM; kill -s TERM "$$"' TERM
cat > "${FIXTURE}" << 'FIXTURE_END'
PLAIN=1
export EXPORTED=2
QUOTED="a b; c=d" # A value that contains a terminator and an assignment.
SUBSTITUTED="$(echo one; echo two)"
BACKTICKED=`echo one; echo two`
ARITHMETIC=$((PLAIN * 2))
NESTED_ARITHMETIC=$(((PLAIN + 1) * 2))
SUBSHELL="$( (echo one; echo two) )"
PIPED_SUBSHELL=$((echo one; echo two) | cat)
CASE_IN_SUBSTITUTION=$(case ${PLAIN} in 1) echo one;; *) echo other;; esac)
PARENTHESIZED_CASE=$(case ${PLAIN} in (1) echo one;; esac)
CASE_WORD=$(echo case esac) # Not the keyword, so not a "case" statement.
MULTILINE_CASE=$(case ${PLAIN} in
  1) echo one ;;
  *) echo other ;;
esac)
if [ "${PLAIN}" -eq 1 ]; then CONDITIONAL=3; fi
# COMMENTED=1
ESCAPED="a \" b; c=d" # An escaped quotation mark does not end the value.
MULTILINE="one
two"
REDIRECTED=1 > REDIRECTION_TARGET # The target is not an assignment.
DUPLICATED_DESCRIPTOR=1 2>&1 # The "&1" is part of the redirection target.
CONTINUED=1 \
  some-command
STATEMENT_AFTER_CONTINUATION=1
PREFIX_ONE=1 PREFIX_TWO=2 some-command
ARITHMETIC_PREFIX=$((PLAIN * 2)) some-command
SUBSHELL_PREFIX=$( (echo one; echo two) ) some-command
PIPED_SUBSHELL_PREFIX=$((echo one; echo two) | cat) some-command
CASE_IN_SUBSTITUTION_PREFIX=$(case ${PLAIN} in 1) echo one;; esac) some-command
REDIRECTED_PREFIX=1 >/dev/null some-command # The target is attached.
DUPLICATED_DESCRIPTOR_PREFIX=1 2>&1 some-command
MULTILINE_PREFIX="one
two" some-command
NESTED_QUOTE="${PLAIN#*"it's "}"
NESTED_QUOTE_SUFFIX="${PLAIN%"'"}"
LITERAL_QUOTE="${PLAIN:-it's}"
NESTED_EXPANSION="${PLAIN:-${PLAIN:-it's}}"
PATTERN_QUOTE="${PLAIN#'"'}"
NESTED_PATTERN_QUOTE="${PLAIN#${PLAIN:-'"'}}"
PID_BRACE="$${" # The special parameter "$$", then a literal "{".
UNQUOTED_EXPANSION=${PLAIN:-'a } b'}
ARRAY=(one two)
APPENDED+=(three)
ELEMENT[1]=one
NESTED_SUBSCRIPT[${ELEMENT[1]}]=1
QUOTED_SUBSCRIPT["a b"]=1
ELEMENTS=(NOT_AN_ASSIGNMENT=1 "two words")
MULTILINE_ARRAY=(
  NOT_AN_ASSIGNMENT_EITHER=1 # It's a comment, whose "'" is not a quotation mark.
)
declare -A DECLARED OTHER_DECLARED
declare -r DECLARED_WITH_VALUE=1
declare -p PRINTED_ONLY > /dev/null 2>&1
declare -x EXPORTED_ONLY
export EXPORTED_ONLY_TOO
local -a LOCAL_ARRAY=(one)
readonly -a READONLY_ARRAY
declare -pa PRINTED_ARRAY
declare -ap PRINTED_ARRAY_TOO
declare -p -a PRINTED_ARRAY_AS_WELL
declare -fa FUNCTION_ONLY
case "${PLAIN}" in
  CASE_PATTERN=*) CASE_BODY=1 ;;
  (PARENTHESIZED_PATTERN=* | OTHER_PATTERN=*) echo other ;;
  *)
    LAST_CASE_BODY=1
    ;;
esac
case "${PLAIN}" in ONE_LINE_PATTERN=*) ONE_LINE_CASE_BODY=1 ;; esac
AFTER_CASE=1
read -r READ_VARIABLE OTHER_READ_VARIABLE < /dev/null
IFS= read -r -d '' READ_AFTER_PREFIX < /dev/null
read -p "Prompt: " PROMPTED
read -ra READ_ARRAY
read -aATTACHED_ARRAY
read < /dev/null
mapfile -t MAPPED < /dev/null
mapfile -t < /dev/null
readarray -d , -t -- READ_ARRAY_TOO
FIXTURE_END
EXPECTED='AFTER_CASE
APPENDED
ARITHMETIC
ARRAY
ATTACHED_ARRAY
BACKTICKED
CASE_BODY
CASE_IN_SUBSTITUTION
CASE_WORD
CONDITIONAL
DECLARED
DECLARED_WITH_VALUE
DUPLICATED_DESCRIPTOR
ELEMENT
ELEMENTS
ESCAPED
EXPORTED
LAST_CASE_BODY
LITERAL_QUOTE
LOCAL_ARRAY
MAPFILE
MAPPED
MULTILINE
MULTILINE_ARRAY
MULTILINE_CASE
NESTED_ARITHMETIC
NESTED_EXPANSION
NESTED_PATTERN_QUOTE
NESTED_QUOTE
NESTED_QUOTE_SUFFIX
NESTED_SUBSCRIPT
ONE_LINE_CASE_BODY
OTHER_DECLARED
OTHER_READ_VARIABLE
PARENTHESIZED_CASE
PATTERN_QUOTE
PID_BRACE
PIPED_SUBSHELL
PLAIN
PROMPTED
QUOTED
QUOTED_SUBSCRIPT
READONLY_ARRAY
READ_AFTER_PREFIX
READ_ARRAY
READ_ARRAY_TOO
READ_VARIABLE
REDIRECTED
REPLY
STATEMENT_AFTER_CONTINUATION
SUBSHELL
SUBSTITUTED
UNQUOTED_EXPANSION'
ACTUAL="$(set_variables_in "${FIXTURE}" statement)"
if [ "${ACTUAL}" != "${EXPECTED}" ]; then
  echo "${SCRIPT_NAME}: set_variables_in is broken" >&2
  echo "${SCRIPT_NAME}: expected [${EXPECTED}]" >&2
  echo "${SCRIPT_NAME}: got      [${ACTUAL}]" >&2
  exit 2
fi
EXPECTED='ARITHMETIC_PREFIX
CASE_IN_SUBSTITUTION_PREFIX
CONTINUED
DUPLICATED_DESCRIPTOR_PREFIX
IFS
MULTILINE_PREFIX
PIPED_SUBSHELL_PREFIX
PREFIX_ONE
PREFIX_TWO
REDIRECTED_PREFIX
SUBSHELL_PREFIX'
ACTUAL="$(set_variables_in "${FIXTURE}" prefix)"
if [ "${ACTUAL}" != "${EXPECTED}" ]; then
  echo "${SCRIPT_NAME}: set_variables_in is broken for environment prefixes" >&2
  echo "${SCRIPT_NAME}: expected [${EXPECTED}]" >&2
  echo "${SCRIPT_NAME}: got      [${ACTUAL}]" >&2
  exit 2
fi

# A here-document is an error rather than a wrong answer.
printf '%s\n' 'cat << END_OF_TEXT' 'SOMETHING=1' 'END_OF_TEXT' > "${FIXTURE}"
if (set_variables_in "${FIXTURE}" statement) > /dev/null 2>&1; then
  echo "${SCRIPT_NAME}: set_variables_in read a here-document as code" >&2
  exit 2
fi

# A here-document whose operator is "<<-" is an error as well.  That operator
# strips leading tabs from its lines, so the fixture contains tabs.
printf 'cat <<- END_OF_TEXT\n\tSOMETHING=1\n\tEND_OF_TEXT\n' > "${FIXTURE}"
if (set_variables_in "${FIXTURE}" statement) > /dev/null 2>&1; then
  echo "${SCRIPT_NAME}: set_variables_in read a <<- here-document as code" >&2
  exit 2
fi

# A here-document within a command substitution is an error as well.  The
# substitution is part of a word, so its here-document operator is not a token
# of its own.
cat > "${FIXTURE}" << 'FIXTURE_END'
VALUE=$(cat << END_OF_TEXT
SOMETHING=1
END_OF_TEXT
)
FIXTURE_END
if (set_variables_in "${FIXTURE}" statement) > /dev/null 2>&1; then
  echo "${SCRIPT_NAME}: set_variables_in read a here-document in a command substitution as code" >&2
  exit 2
fi

# A command substitution that never ends is an error rather than a wrong
# answer.  Reading the rest of the script as one word would silently drop
# every variable that follows.
cat > "${FIXTURE}" << 'FIXTURE_END'
UNCLOSED=$(case ${PLAIN} in 1) echo one
DROPPED=1
FIXTURE_END
if (set_variables_in "${FIXTURE}" statement) > /dev/null 2>&1; then
  echo "${SCRIPT_NAME}: set_variables_in accepted an unclosed command substitution" >&2
  exit 2
fi

# A comment within a command substitution that bash 3.2 reads as code, because
# it begins a quotation that it does not end, is an error.
cat > "${FIXTURE}" << 'FIXTURE_END'
VALUE="$(
  # It's a comment.
  echo one
)"
FIXTURE_END
if (set_variables_in "${FIXTURE}" statement) > /dev/null 2>&1; then
  echo "${SCRIPT_NAME}: set_variables_in accepted a comment that bash 3.2 misreads" >&2
  exit 2
fi
# So is one that ends a parenthesis that it did not begin, which bash 3.2
# takes for the end of the command substitution.
cat > "${FIXTURE}" << 'FIXTURE_END'
VALUE="$(
  # A comment:)
  echo one
)"
FIXTURE_END
if (set_variables_in "${FIXTURE}" statement) > /dev/null 2>&1; then
  echo "${SCRIPT_NAME}: set_variables_in accepted a comment whose \")\" bash 3.2 misreads" >&2
  exit 2
fi
# A comment whose quotations and parentheses each end on its line is not, and
# the variables that follow it are found.
cat > "${FIXTURE}" << 'FIXTURE_END'
VALUE="$(
  # A comment's "(" and ")" are quoted, as in the submodule's (one) and (two).
  echo one
)"
AFTER_COMMENT=1
FIXTURE_END
if [ "$(set_variables_in "${FIXTURE}" statement)" != "AFTER_COMMENT
VALUE" ]; then
  echo "${SCRIPT_NAME}: set_variables_in mis-parsed a comment within a command substitution" >&2
  exit 2
fi

# A here-string is not a here-document:  its data is on the same line.  That
# holds within a command substitution as well.
cat > "${FIXTURE}" << 'FIXTURE_END'
cat <<<"one two"
HERE_STRING=1
SUBSTITUTED_HERE_STRING=$(cat <<<"one two")
FIXTURE_END
if [ "$(set_variables_in "${FIXTURE}" statement)" != "HERE_STRING
SUBSTITUTED_HERE_STRING" ]; then
  echo "${SCRIPT_NAME}: set_variables_in mistook a here-string for a here-document" >&2
  exit 2
fi

# Bash, unlike a POSIX shell, treats a "'" in the word of "${VAR:-word}" as a
# quotation mark even within double quotation marks.
cat > "${FIXTURE}" << 'FIXTURE_END'
#!/usr/bin/env bash
BASH_QUOTE="${PLAIN:-'"'}"
AFTER_BASH_QUOTE=1
FIXTURE_END
if [ "$(set_variables_in "${FIXTURE}" statement)" != "AFTER_BASH_QUOTE
BASH_QUOTE" ]; then
  echo "${SCRIPT_NAME}: set_variables_in mis-parsed a parameter expansion in a Bash script" >&2
  exit 2
fi

# Check `python_variables` on a script that reads and sets environment
# variables in each way that it must recognize, and that mentions some in ways
# that are neither.
cat > "${FIXTURE}" << 'FIXTURE_END'
import os
from os import environ, getenv

a = os.environ.get("GOT")
b = os.environ.get(
    "GOT_ACROSS_LINES"
)
c = os.environ["SUBSCRIPTED"]
d = os.getenv("GETENV")
e = getenv( "BARE_GETENV")
f = environ.setdefault("SET_DEFAULT", "value")
g = "IN_ENVIRON" in os.environ
h = os.environ.pop("POPPED", None)
# os.environ.get("COMMENTED")
i = 'os.environ.get("IN_STRING")'
j = os.environ.get("lower_case")
os.environ["WRITTEN"] = "value"
del os.environ["DELETED"]
FIXTURE_END
EXPECTED='BARE_GETENV
GETENV
GOT
GOT_ACROSS_LINES
IN_ENVIRON
POPPED
SET_DEFAULT
SUBSCRIPTED'
ACTUAL="$(python_variables "${FIXTURE}" read)"
if [ "${ACTUAL}" != "${EXPECTED}" ]; then
  echo "${SCRIPT_NAME}: python_variables is broken for reads" >&2
  echo "${SCRIPT_NAME}: expected [${EXPECTED}]" >&2
  echo "${SCRIPT_NAME}: got      [${ACTUAL}]" >&2
  exit 2
fi
ACTUAL="$(python_variables "${FIXTURE}" set)"
if [ "${ACTUAL}" != "WRITTEN" ]; then
  echo "${SCRIPT_NAME}: python_variables is broken for assignments" >&2
  echo "${SCRIPT_NAME}: expected [WRITTEN]" >&2
  echo "${SCRIPT_NAME}: got      [${ACTUAL}]" >&2
  exit 2
fi

# A Python script that is not valid is an error rather than a wrong answer.
echo 'if' > "${FIXTURE}"
if (python_variables "${FIXTURE}" read) > /dev/null 2>&1; then
  echo "${SCRIPT_NAME}: python_variables accepted a script that is not valid Python" >&2
  exit 2
fi

# Check `awk_variables_read` on a program that reads environment variables and
# that mentions one in a comment.
cat > "${FIXTURE}" << 'FIXTURE_END'
{ print ENVIRON["READ"], ENVIRON[ "SPACED" ] }
# ENVIRON["COMMENTED"]
FIXTURE_END
ACTUAL="$(awk_variables_read "${FIXTURE}")"
if [ "${ACTUAL}" != "READ
SPACED" ]; then
  echo "${SCRIPT_NAME}: awk_variables_read is broken" >&2
  echo "${SCRIPT_NAME}: got [${ACTUAL}]" >&2
  exit 2
fi

# The variables that some script in this package sets, in a statement and in
# an environment prefix of a command, respectively.  One script sets such a
# variable before invoking another that reads it, so it is internal to the
# package rather than part of its user-visible interface.
PACKAGE_SET_VARIABLES=''
PACKAGE_PREFIX_VARIABLES=''
for script in ${SCRIPTS}; do
  file="${TOPLEVEL}/${script}"
  if [ ! -f "${file}" ]; then
    echo "${SCRIPT_NAME}: no such file: ${file}" >&2
    exit 2
  fi
  # Each variable is set by an assignment, so that "set -e" exits if the
  # command that computes it fails.
  language="$(script_language "${file}")"
  case "${language}" in
    awk)
      set_variables=''
      prefix_variables=''
      ;;
    python)
      set_variables="$(python_variables "${file}" set)"
      prefix_variables=''
      ;;
    shell)
      set_variables="$(set_variables_in "${file}" statement)"
      prefix_variables="$(set_variables_in "${file}" prefix)"
      ;;
  esac
  PACKAGE_SET_VARIABLES="${PACKAGE_SET_VARIABLES}
${set_variables}"
  PACKAGE_PREFIX_VARIABLES="${PACKAGE_PREFIX_VARIABLES}
${prefix_variables}"
done

status=0

# Usage: check_documented SCRIPT VARIABLES INTERNAL
# Reports each of VARIABLES, which SCRIPT reads, that is part of the
# user-visible interface but that README.md does not document, and sets
# "status" to 1 if there is any.  INTERNAL is the variables, one per line,
# that are internal to this package in addition to PACKAGE_SET_VARIABLES.
check_documented() {
  for variable in $2; do
    if printf '%s\n' "${PACKAGE_SET_VARIABLES}" "$3" | grep -qx "${variable}"; then
      continue
    fi
    case " ${STANDARD_VARIABLES} " in
      *" ${variable} "*) continue ;;
    esac
    if ! grep -qF "\`${variable}\`" "${README}"; then
      echo "${SCRIPT_NAME}: $1 reads ${variable}, which README.md does not document" >&2
      status=1
    fi
  done
}

# An awk program in this package runs only when a script of the package runs
# it, so a variable that a script passes to a command in an environment
# prefix, as `common-functions.sh` passes `CCR_FILE` to
# `check-conflict-resolution.awk`, is internal to the package.
for script in ${SCRIPTS}; do
  file="${TOPLEVEL}/${script}"
  language="$(script_language "${file}")"
  case "${language}" in
    awk)
      read_variables="$(awk_variables_read "${file}")"
      internal="${PACKAGE_PREFIX_VARIABLES}"
      ;;
    python)
      read_variables="$(python_variables "${file}" read)"
      internal=''
      ;;
    shell)
      read_variables="$(shell_variables_read "${file}")"
      internal=''
      ;;
  esac
  check_documented "${script}" "${read_variables}" "${internal}"
done

if [ "${status}" -eq 0 ]; then
  echo "${SCRIPT_NAME}: OK"
fi

exit "${status}"
