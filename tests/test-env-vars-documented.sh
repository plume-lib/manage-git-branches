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
# Prints, one per line, the variables that FILE assigns in an assignment
# statement, such as `VAR=value` or `export VAR=value`.
#
# An assignment that is an environment prefix of a command, as in
# `VAR=value some-command`, does not count:  it sets the variable only in the
# environment of that command, which does not make the variable internal to
# this package.  For example, `is-deleted-branch` runs
# `GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=... git ls-remote ...`; the SSH
# variables remain part of the user-visible interface and must be documented.
#
# This splits the script into words the way a shell does, so that a value that
# contains whitespace, quotation marks, or a command substitution does not
# affect the result.  Then, at each point where a command may start, it reads
# the run of assignments that begins there:  the run is an assignment
# statement if nothing but a command terminator follows it, and is an
# environment prefix otherwise.
set_variables_in() {
  awk '
    function push_context(c) { stack[++depth] = c }
    function pop_context() { if (depth > 0) depth-- }
    function context() { return (depth > 0) ? stack[depth] : "" }
    function end_word() { if (have_word) { words[++nwords] = word; word = ""; have_word = 0 } }
    function add_word(w) { word = word w; have_word = 1 }
    function add_token(t) { end_word(); words[++nwords] = t }
    # The tokens that end a command, so that a run of assignments before one of
    # them is an assignment statement rather than an environment prefix.
    function is_terminator(t) { return t ~ /^(;|;;|&|&&|\||\|\||\(|\)|\{|\})$/ }
    # The tokens after which a command may start.
    function is_command_start(t) {
      return is_terminator(t) \
        || t ~ /^(!|if|then|elif|else|do|while|until|export|readonly|local|time)$/
    }
    function is_assignment(t) { return t ~ /^[A-Za-z_][A-Za-z0-9_]*=/ }
    # Prints the variables that the current logical line assigns.
    function report_line(  i, j, k, name, at_command) {
      at_command = 1
      i = 1
      while (i <= nwords) {
        if (at_command && is_assignment(words[i])) {
          for (j = i; j <= nwords && is_assignment(words[j]); j++) { }
          if (j > nwords || is_terminator(words[j])) {
            for (k = i; k < j; k++) {
              name = words[k]
              sub(/=.*/, "", name)
              print name
            }
          }
          i = j
          at_command = 0
          continue
        }
        at_command = is_command_start(words[i])
        i++
      }
      nwords = 0
    }
    {
      line = $0
      len = length(line)
      i = 1
      continued = 0
      while (i <= len) {
        c = substr(line, i, 1)
        if (context() == "single") {
          # Within single quotation marks, only a single quotation mark
          # (octal 47) is special.
          if (c == "\047") pop_context()
          add_word(c)
          i++
          continue
        }
        if (c == "\\") {
          if (i == len) { continued = 1; i++; continue }
          add_word(c substr(line, i + 1, 1))
          i += 2
          continue
        }
        if (c == "$" && substr(line, i + 1, 1) == "(") {
          # Quoting starts afresh within a command substitution, even within
          # double quotation marks.
          push_context("subst")
          add_word("$(")
          i += 2
          continue
        }
        if (context() == "double") {
          if (c == "\"") pop_context()
          add_word(c)
          i++
          continue
        }
        if (c == "\047") { push_context("single"); add_word(c); i++; continue }
        if (c == "\"") { push_context("double"); add_word(c); i++; continue }
        if (c == ")" && context() == "subst") { pop_context(); add_word(c); i++; continue }
        if (context() == "subst") { add_word(c); i++; continue }
        # Outside quotation marks and command substitutions.
        if (c == "#" && !have_word) { break }
        if (c == " " || c == "\t") { end_word(); i++; continue }
        if (c == ";" || c == "&" || c == "|" || c == "(" || c == ")") {
          if (substr(line, i + 1, 1) == c && c != "(" && c != ")") {
            add_token(c c)
            i += 2
          } else {
            add_token(c)
            i++
          }
          continue
        }
        add_word(c)
        i++
      }
      # A quotation mark or a command substitution that is still open, or a
      # backslash at the end of the line, continues the logical line.
      if (depth > 0) { add_word("\n"); next }
      if (continued) next
      end_word()
      report_line()
    }
    END { if (depth == 0) { end_word(); report_line() } }
  ' "$1" \
    | grep -xE '[A-Z][A-Z0-9_]*' | sort -u
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
