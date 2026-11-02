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
TOPLEVEL="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)" || exit 1
SCRIPT_NAME="$(basename -- "$0")"

README="${TOPLEVEL}/README.md"

# The commands, which are executable, and the files that they load, which are
# not executable but whose names end in ".sh" or ".py".  A variable that a
# loaded file reads is part of the interface of the commands that load it.
SCRIPTS="$(find "${TOPLEVEL}" -maxdepth 1 -type f ! -name '*~' \
  \( -perm -u+x -o -name '*.sh' -o -name '*.py' \) -exec basename -- {} ';' | sort)"
if [ -z "${SCRIPTS}" ]; then
  echo "${SCRIPT_NAME}: found no scripts in ${TOPLEVEL}" >&2
  exit 2
fi

# Usage: script_language FILE
# Prints "shell" if FILE is a shell (sh or Bash) script and "python" if FILE is
# a Python script, judging by its name and its "#!" line.  Fails if FILE is
# neither, so that a script in another language is not silently unchecked.
script_language() {
  case "$1" in
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
STANDARD_VARIABLES="BASH_VERSINFO BASH_VERSION CDPATH HOME IFS LANG LC_ALL PATH PWD TMPDIR"

# Usage: script_code FILE
# Prints FILE with comments removed, so that documentation and commented-out
# code do not affect which variables are considered set or read.  A "#" that
# follows a non-blank character, as in "$#", does not start a comment.
script_code() {
  sed -E 's/(^|[[:space:]])#.*/\1/' "$1"
}

# Usage: set_variables_in FILE
# Prints, one per line, the variables that FILE, a shell script, assigns in an
# assignment statement, such as `VAR=value`, `export VAR=value`,
# `ARRAY[KEY]=value`, or `ARRAY+=(value)`, or declares as an array, as in
# `declare -A ARRAY`.
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
# statement if nothing but a redirection or a command terminator follows it,
# and is an environment prefix otherwise.
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
      return is_terminator(t) || t ~ /^(!|if|then|elif|else|do|while|until|time)$/
    }
    # The builtins that declare variables, as in "export VAR=value".
    function is_declaration(t) { return t ~ /^(declare|export|local|readonly|typeset)$/ }
    # An assignment, to a variable or to an element of an array, which may
    # append to the old value, as in "VAR=value", "ARRAY[KEY]=value", or
    # "ARRAY+=".
    function is_assignment(t) { return t ~ /^[A-Za-z_][A-Za-z0-9_]*(\[.*\])?\+?=/ }
    # Prints the name of the variable that the assignment or declaration T sets.
    function print_name(t) { sub(/[[+=].*/, "", t); print t }
    # The redirection operator that introduces a here-document, whose lines
    # are data rather than code.  A here-string, "<<<", supplies its data on
    # the same line, so it is not one.
    function is_heredoc(t) { return t ~ /^[0-9]*<<-?/ && t !~ /^[0-9]*<<</ }
    # A redirection, which may follow the assignments of an assignment
    # statement, as in "VAR=value > file", without making them an environment
    # prefix of a command.
    function is_redirection(t) { return t ~ /^[0-9]*(<|>)/ }
    # A redirection whose target is the word that follows it, rather than being
    # attached to the operator as in ">file".  When the target duplicates a
    # file descriptor, as in "2>&1", the tokenizer splits the "&" into a token
    # of its own, so the target is two tokens rather than one; the loop that
    # skips redirections accounts for that.
    function is_bare_redirection(t) { return t ~ /^[0-9]*(<|>|>>|<>|<<<)$/ }
    # Whether the word W begins at position P of S:  the characters there are
    # W, and neither the character before nor the character after them can be
    # part of the same word.
    function word_at(s, p, w,   before, after) {
      if (substr(s, p, length(w)) != w) { return 0 }
      before = (p > 1) ? substr(s, p - 1, 1) : ""
      after = substr(s, p + length(w), 1)
      return before !~ /[A-Za-z0-9_]/ && after !~ /[A-Za-z0-9_]/
    }
    # Whether a command may start at the end of W, which is the text of a
    # command substitution so far.  A command starts at the beginning of the
    # substitution, after a character that separates one command from the
    # next, or after a keyword that introduces one.
    function at_command_in_subst(w) {
      sub(/[ \t]+$/, "", w)
      return w ~ /(\(|;|&|\||\n)$/ \
        || w ~ /(^|[^A-Za-z0-9_])(!|do|elif|else|if|then|until|while)$/
    }
    # Reports that the current logical line contains a here-document.  This
    # awk program does not skip the lines of a here-document, so it would read
    # them as code.  No script in this package uses one; the caller turns this
    # marker into an error rather than reporting the variables that a
    # here-document happens to mention.
    function report_heredoc() {
      if (!heredoc_seen) { print "<here-document>" }
      heredoc_seen = 1
      nwords = 0
      heredoc_in_substitution = 0
    }
    # Prints the variables that the current logical line assigns.
    function report_line(  i, j, k, r, at_command, array) {
      # Within a command substitution, a here-document operator is part of a
      # word rather than a token of its own, so the tokenizer notes it as it
      # goes rather than "is_heredoc" finding it here.
      if (heredoc_in_substitution) { report_heredoc(); return }
      for (i = 1; i <= nwords; i++) {
        if (is_heredoc(words[i])) { report_heredoc(); return }
      }
      at_command = 1
      i = 1
      while (i <= nwords) {
        if (at_command && is_assignment(words[i])) {
          for (j = i; j <= nwords && is_assignment(words[j]); j++) { }
          # A redirection may come between the assignments and the terminator,
          # so skip it before deciding.  The assignments end at "j"; "r" is
          # only for looking past them.
          r = j
          while (r <= nwords && is_redirection(words[r])) {
            if (is_bare_redirection(words[r])) {
              # The target is the word that follows the operator.  When the
              # redirection duplicates a file descriptor, as in "2>&1", the
              # tokenizer has split the "&" into a token of its own, so the
              # target is that token and the one after it rather than a
              # single word.
              if (r + 2 <= nwords && words[r + 1] == "&" \
                  && words[r + 2] ~ /^([0-9]+-?|-)$/) {
                r += 2
              } else {
                r++
              }
            }
            r++
          }
          if (r > nwords || is_terminator(words[r])) {
            for (k = i; k < j; k++) { print_name(words[k]) }
          }
          i = j
          at_command = 0
          continue
        }
        if (at_command && is_declaration(words[i])) {
          # A declaration sets each variable that it assigns, as in
          # "export VAR=value".  It sets a variable that it names without a
          # value only if it makes that variable an array, as
          # "declare -A ARRAY" does; neither "declare -p VAR" nor
          # "export VAR" sets VAR.
          array = 0
          for (i++; i <= nwords && words[i] ~ /^[-+]/; i++) {
            if (words[i] ~ /^-[A-Za-z]*[aA]/) { array = 1 }
          }
          for (; i <= nwords && !is_terminator(words[i]); i++) {
            if (is_assignment(words[i]) \
                || (array && words[i] ~ /^[A-Za-z_][A-Za-z0-9_]*$/)) {
              print_name(words[i])
            }
          }
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
          case_depth[depth] = 0
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
            case_depth[depth] = 0
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
        if (context() == "subst" || context() == "backtick") {
          # A command substitution becomes part of a word, so a here-document
          # operator within one is not a token that "is_heredoc" can find.
          # Note it here instead.  A here-string, "<<<", supplies its data on
          # the same line, so it is not one.
          if (c == "<" && substr(line, i + 1, 1) == "<" \
              && substr(line, i + 2, 1) != "<" \
              && (i == 1 || substr(line, i - 1, 1) != "<")) {
            heredoc_in_substitution = 1
          }
        }
        if (context() == "subst") {
          # A "case" statement within a command substitution ends each of its
          # patterns with ")".  That ")" closes no "(", so count the "case"
          # statements that are open, to keep it from ending the
          # substitution.  Only a "case" or an "esac" where a command may
          # start is the keyword rather than an ordinary word, as the "case"
          # of "$(grep case file)" is.
          if (word_at(line, i, "case") && at_command_in_subst(word)) {
            case_depth[depth]++
          } else if (word_at(line, i, "esac") && at_command_in_subst(word) \
                     && case_depth[depth] > 0) {
            case_depth[depth]--
          }
          # Parentheses nest within a command substitution, as in
          # "$( (cd dir && pwd) )", so count them:  only the one that closes
          # the "$(" ends it.
          if (c == "(") { subst_parens[depth]++; add_word(c); i++; continue }
          if (c == ")") {
            # Within a "case" statement, a ")" that closes no "(" ends a
            # pattern.  A pattern may also begin with "(", as in "(1)", and
            # the count above has already matched that one.
            if (case_depth[depth] > 0 && subst_parens[depth] == 1) {
              add_word(c)
              i++
              continue
            }
            if (--subst_parens[depth] == 0) { pop_context(); add_word(c); i++; continue }
          }
          add_word(c)
          i++
          continue
        }
        if (context() == "backtick") { add_word(c); i++; continue }
        if (context() == "array") {
          # A "#" that begins an element starts a comment, which ends the line.
          if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t(]/)) { break }
          if (c == ")") pop_context()
          add_word(c)
          i++
          continue
        }
        # Outside quotation marks, command substitutions, and array literals.
        if (c == "#" && !have_word) { break }
        if (c == " " || c == "\t") { end_word(); i++; continue }
        if (c == "(" && word ~ /^[A-Za-z_][A-Za-z0-9_]*(\[.*\])?\+?=$/) {
          # An array literal, as in "ARRAY=(one two)".  It is part of the word
          # of the assignment, so an element that contains "=", as in
          # "ARRAY=(VAR=value)", is not an assignment.  It continues the
          # logical line until its ")".
          push_context("array")
          add_word(c)
          i++
          continue
        }
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
      # A quotation mark, a command substitution, or an array literal that is
      # still open, or a backslash at the end of the line, continues the
      # logical line.
      if (depth > 0) { add_word("\n"); next }
      if (continued) next
      end_word()
      report_line()
    }
    END {
      if (depth > 0) {
        # A quotation mark, a command substitution, an array literal, or a
        # "case" statement within a command substitution that never ended.  Either the script is not valid shell
        # or this program lost track of the nesting, in which case it has
        # read the rest of the script as one word.  Do not guess.
        print "<unclosed>"
      } else {
        end_word()
        report_line()
      }
    }
  ' "$1")"
  if printf '%s\n' "${assigned}" | grep -qxF '<here-document>'; then
    echo "${SCRIPT_NAME}: $1 contains a here-document, which set_variables_in does not parse" >&2
    echo "${SCRIPT_NAME}: extend set_variables_in to skip the lines of a here-document" >&2
    exit 2
  fi
  if printf '%s\n' "${assigned}" | grep -qxF '<unclosed>'; then
    echo "${SCRIPT_NAME}: $1 ends within a quotation, a command substitution, or an array literal" >&2
    echo "${SCRIPT_NAME}: either it is not valid shell, or set_variables_in mis-parsed it" >&2
    exit 2
  fi
  printf '%s\n' "${assigned}" | grep -xE '[A-Z][A-Z0-9_]*' | sort -u
}

# Usage: shell_variables_read FILE
# Prints, one per line, the variables that FILE, a shell script, reads, as in
# `$VAR` or `${VAR}`.
shell_variables_read() {
  script_code "$1" | grep -oE '\$\{?[A-Z][A-Z0-9_]*' | grep -oE '[A-Z][A-Z0-9_]*' | sort -u
}

# Usage: python_variables_read FILE
# Prints, one per line, the environment variables that FILE, a Python script,
# reads, as in `os.environ.get("VAR")`, `os.environ["VAR"]`, `os.getenv("VAR")`,
# or `"VAR" in os.environ`.  It parses FILE, so that a call that spans lines
# counts and a string or comment that mentions `os.environ` does not.
python_variables_read() {
  python3 -I -c '
import ast
import re
import sys


def is_environ(node):
    """Return True if the expression is "os.environ" or "environ"."""
    return (isinstance(node, ast.Attribute) and node.attr == "environ") or (
        isinstance(node, ast.Name) and node.id == "environ"
    )


def string_value(node):
    """Return the value of the string literal, or None if it is not one."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    return None


with open(sys.argv[1], encoding="utf-8") as f:
    tree = ast.parse(f.read(), sys.argv[1])
names = set()
for node in ast.walk(tree):
    name = None
    if isinstance(node, ast.Call) and node.args:
        func = node.func
        if (
            isinstance(func, ast.Attribute)
            and func.attr in ("get", "pop", "setdefault")
            and is_environ(func.value)
        ) or (
            (isinstance(func, ast.Attribute) and func.attr == "getenv")
            or (isinstance(func, ast.Name) and func.id == "getenv")
        ):
            name = string_value(node.args[0])
    elif isinstance(node, ast.Subscript) and is_environ(node.value):
        name = string_value(node.slice)
    elif (
        isinstance(node, ast.Compare)
        and len(node.ops) == 1
        and isinstance(node.ops[0], (ast.In, ast.NotIn))
        and is_environ(node.comparators[0])
    ):
        name = string_value(node.left)
    # Like the check of shell scripts, consider only upper-case names.
    if name is not None and re.fullmatch("[A-Z][A-Z0-9_]*", name):
        names.add(name)
for name in sorted(names):
    print(name)
' "$1"
}

# The scripts, partitioned by language.
SHELL_SCRIPTS=''
PYTHON_SCRIPTS=''
for script in ${SCRIPTS}; do
  file="${TOPLEVEL}/${script}"
  if [ ! -f "${file}" ]; then
    echo "${SCRIPT_NAME}: no such file: ${file}" >&2
    exit 2
  fi
  # An assignment, so that "set -e" exits if script_language fails.
  language="$(script_language "${file}")"
  case "${language}" in
    shell) SHELL_SCRIPTS="${SHELL_SCRIPTS} ${script}" ;;
    python) PYTHON_SCRIPTS="${PYTHON_SCRIPTS} ${script}" ;;
  esac
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
FIXTURE_END
EXPECTED='APPENDED
ARITHMETIC
ARRAY
BACKTICKED
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
LOCAL_ARRAY
MULTILINE
MULTILINE_ARRAY
MULTILINE_CASE
NESTED_ARITHMETIC
NESTED_SUBSCRIPT
OTHER_DECLARED
PARENTHESIZED_CASE
PIPED_SUBSHELL
PLAIN
QUOTED
QUOTED_SUBSCRIPT
READONLY_ARRAY
REDIRECTED
STATEMENT_AFTER_CONTINUATION
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

# A here-document whose operator is "<<-" is an error as well.  That operator
# strips leading tabs from its lines, so the fixture contains tabs.
printf 'cat <<- END_OF_TEXT\n\tSOMETHING=1\n\tEND_OF_TEXT\n' > "${FIXTURE}"
if (set_variables_in "${FIXTURE}") > /dev/null 2>&1; then
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
if (set_variables_in "${FIXTURE}") > /dev/null 2>&1; then
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
if (set_variables_in "${FIXTURE}") > /dev/null 2>&1; then
  echo "${SCRIPT_NAME}: set_variables_in accepted an unclosed command substitution" >&2
  exit 2
fi

# A here-string is not a here-document:  its data is on the same line.  That
# holds within a command substitution as well.
cat > "${FIXTURE}" << 'FIXTURE_END'
cat <<<"one two"
HERE_STRING=1
SUBSTITUTED_HERE_STRING=$(cat <<<"one two")
FIXTURE_END
if [ "$(set_variables_in "${FIXTURE}")" != "HERE_STRING
SUBSTITUTED_HERE_STRING" ]; then
  echo "${SCRIPT_NAME}: set_variables_in mistook a here-string for a here-document" >&2
  exit 2
fi

# Check `python_variables_read` on a script that reads environment variables
# in each way that it must recognize, and that mentions some in ways that are
# not reads.
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
FIXTURE_END
EXPECTED='BARE_GETENV
GETENV
GOT
GOT_ACROSS_LINES
IN_ENVIRON
POPPED
SET_DEFAULT
SUBSCRIPTED'
ACTUAL="$(python_variables_read "${FIXTURE}")"
if [ "${ACTUAL}" != "${EXPECTED}" ]; then
  echo "${SCRIPT_NAME}: python_variables_read is broken" >&2
  echo "${SCRIPT_NAME}: expected [${EXPECTED}]" >&2
  echo "${SCRIPT_NAME}: got      [${ACTUAL}]" >&2
  exit 2
fi

# The variables that some shell script in this package assigns.  One script
# sets such a variable before invoking another that reads it, so it is internal
# to the package rather than part of its user-visible interface.
PACKAGE_SET_VARIABLES=''
for script in ${SHELL_SCRIPTS}; do
  PACKAGE_SET_VARIABLES="${PACKAGE_SET_VARIABLES}
$(set_variables_in "${TOPLEVEL}/${script}")"
done
PACKAGE_SET_VARIABLES="$(printf '%s\n' "${PACKAGE_SET_VARIABLES}" | sort -u)"

status=0

# Usage: check_documented SCRIPT VARIABLES
# Reports each of VARIABLES, which SCRIPT reads, that is part of the
# user-visible interface but that README.md does not document, and sets
# "status" to 1 if there is any.
check_documented() {
  for variable in $2; do
    if printf '%s\n' "${PACKAGE_SET_VARIABLES}" | grep -qx "${variable}"; then
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

# Each "read_variables" is an assignment, so that "set -e" exits if the
# command that computes it fails.
for script in ${SHELL_SCRIPTS}; do
  read_variables="$(shell_variables_read "${TOPLEVEL}/${script}")"
  check_documented "${script}" "${read_variables}"
done
for script in ${PYTHON_SCRIPTS}; do
  read_variables="$(python_variables_read "${TOPLEVEL}/${script}")"
  check_documented "${script}" "${read_variables}"
done

if [ "${status}" -eq 0 ]; then
  echo "${SCRIPT_NAME}: OK"
fi

exit "${status}"
