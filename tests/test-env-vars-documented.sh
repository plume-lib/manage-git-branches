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
#
# It does not handle here-documents, whose lines are data rather than code.
# It fails, rather than reading them as code, if a script contains one.
set_variables_in() {
  assigned="$(awk '
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
    # The redirection operator that introduces a here-document, whose lines
    # are data rather than code.  A here-string, "<<<", supplies its data on
    # the same line, so it is not one.
    function is_heredoc(t) { return t ~ /^[0-9]*<<-?/ && t !~ /^[0-9]*<<</ }
    # Prints the variables that the current logical line assigns.
    function report_line(  i, j, k, name, at_command) {
      for (i = 1; i <= nwords; i++) {
        if (is_heredoc(words[i])) {
          # This awk program does not skip the lines of a here-document, so it
          # would read them as code.  No script in this package uses one; the
          # caller turns this marker into an error rather than reporting the
          # variables that a here-document happens to mention.
          if (!heredoc_seen) { print "<here-document>" }
          heredoc_seen = 1
          nwords = 0
          return
        }
      }
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
        # A backslash (octal 134) quotes the character that follows it.
        if (c == "\134") {
          if (i == len) { continued = 1; i++; continue }
          add_word(c substr(line, i + 1, 1))
          i += 2
          continue
        }
        if (c == "$" && substr(line, i + 1, 2) == "((") {
          # An arithmetic expansion.  Its contents are not a command, and the
          # "))" that ends it is not two operators.  Parentheses nest within
          # it, so count them.
          push_context("arith")
          arith_parens[depth] = 1
          add_word("$((")
          i += 3
          continue
        }
        if (c == "$" && substr(line, i + 1, 1) == "(") {
          # Quoting starts afresh within a command substitution, even within
          # double quotation marks.
          push_context("subst")
          subst_parens[depth] = 1
          add_word("$(")
          i += 2
          continue
        }
        if (c == "`") {
          # A command substitution in the older form.  Quoting starts afresh
          # within it, even within double quotation marks, and one backtick
          # ends what another began.
          if (context() == "backtick") pop_context(); else push_context("backtick")
          add_word(c)
          i++
          continue
        }
        if (context() == "arith") {
          if (c == "(") { arith_parens[depth]++; add_word(c); i++; continue }
          if (c == ")") {
            if (arith_parens[depth] > 1) { arith_parens[depth]--; add_word(c); i++; continue }
            if (substr(line, i + 1, 1) == ")") { pop_context(); add_word("))"); i += 2; continue }
            # Not the "))" that ends an arithmetic expansion, so the "$((" was
            # a command substitution that begins with a subshell, as in
            # "$((cd dir; pwd) | cat)".  This ")" ends the subshell, and the
            # command substitution is still open.
            stack[depth] = "subst"
            subst_parens[depth] = 1
            add_word(c)
            i++
            continue
          }
          add_word(c)
          i++
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
        if (context() == "subst") {
          # Parentheses nest within a command substitution, as in
          # "$( (cd dir && pwd) )", so count them:  only the one that closes
          # the "$(" ends it.
          if (c == "(") { subst_parens[depth]++; add_word(c); i++; continue }
          if (c == ")" && --subst_parens[depth] == 0) { pop_context(); add_word(c); i++; continue }
          add_word(c)
          i++
          continue
        }
        if (context() == "backtick") { add_word(c); i++; continue }
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
  ' "$1")"
  if printf '%s\n' "${assigned}" | grep -qxF '<here-document>'; then
    echo "${SCRIPT_NAME}: $1 contains a here-document, which set_variables_in does not parse" >&2
    echo "${SCRIPT_NAME}: extend set_variables_in to skip the lines of a here-document" >&2
    exit 2
  fi
  printf '%s\n' "${assigned}" | grep -xE '[A-Z][A-Z0-9_]*' | sort -u
}

for script in ${SCRIPTS}; do
  file="${TOPLEVEL}/${script}"
  if [ ! -f "${file}" ]; then
    echo "${SCRIPT_NAME}: no such file: ${file}" >&2
    exit 2
  fi
done

# Check `set_variables_in` itself on a script that contains each construct
# that it must get right.  The distinction that it makes -- an assignment
# statement, whose variable is internal to this package, versus an environment
# prefix of a command, whose variable is not -- is easy to break, and breaking
# it would make this test quietly stop requiring a variable to be documented.
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
if [ "${PLAIN}" -eq 1 ]; then CONDITIONAL=3; fi
# COMMENTED=1
PREFIX_ONE=1 PREFIX_TWO=2 some-command
ARITHMETIC_PREFIX=$((PLAIN * 2)) some-command
SUBSHELL_PREFIX=$( (echo one; echo two) ) some-command
PIPED_SUBSHELL_PREFIX=$((echo one; echo two) | cat) some-command
FIXTURE_END
EXPECTED='ARITHMETIC
BACKTICKED
CONDITIONAL
EXPORTED
NESTED_ARITHMETIC
PIPED_SUBSHELL
PLAIN
QUOTED
SUBSHELL
SUBSTITUTED'
ACTUAL="$(set_variables_in "${FIXTURE}")"
if [ "${ACTUAL}" != "${EXPECTED}" ]; then
  echo "${SCRIPT_NAME}: set_variables_in is broken" >&2
  echo "${SCRIPT_NAME}: expected [${EXPECTED}]" >&2
  echo "${SCRIPT_NAME}: got      [${ACTUAL}]" >&2
  exit 2
fi

# A here-document is an error rather than a wrong answer.
printf '%s\n' 'cat << END_OF_TEXT' 'SOMETHING=1' 'END_OF_TEXT' > "${FIXTURE}"
if (set_variables_in "${FIXTURE}") > /dev/null 2>&1; then
  echo "${SCRIPT_NAME}: set_variables_in read a here-document as code" >&2
  exit 2
fi

# A here-string is not a here-document:  its data is on the same line.
printf '%s\n' 'cat <<<"one two"' 'HERE_STRING=1' > "${FIXTURE}"
if [ "$(set_variables_in "${FIXTURE}")" != "HERE_STRING" ]; then
  echo "${SCRIPT_NAME}: set_variables_in mistook a here-string for a here-document" >&2
  exit 2
fi

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
