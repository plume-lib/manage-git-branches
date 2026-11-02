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
# or read.

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
STANDARD_VARIABLES="CDPATH HOME IFS LANG LC_ALL PATH PWD TMPDIR"

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
    # The builtins that read input into variables, as in "read VAR".
    function is_reading_builtin(t) { return t ~ /^(mapfile|read|readarray)$/ }
    # An assignment, to a variable or to an element of an array, which may
    # append to the old value, as in "VAR=value", "ARRAY[KEY]=value", or
    # "ARRAY+=".
    function is_assignment(t) { return t ~ /^[A-Za-z_][A-Za-z0-9_]*(\[.*\])?\+?=/ }
    # Prints KIND, which is "statement" or "prefix", and the name of the
    # variable that T, an assignment or a name, sets.
    function print_name(kind, t) { sub(/[[+=].*/, "", t); print kind " " t }
    # The redirection operator that introduces a here-document, whose lines
    # are data rather than code.  A here-string, "<<<", supplies its data on
    # the same line, so it is not one.
    function is_heredoc(t) { return t ~ /^[0-9]*<<-?/ && t !~ /^[0-9]*<<</ }
    # A redirection, which may follow the assignments of an assignment
    # statement, as in "VAR=value > file", without making them an environment
    # prefix of a command.
    function is_redirection(t) { return t ~ /^[0-9]*(<|>)/ }
    # A redirection whose target is the word that follows it, rather than being
    # attached to the operator as in ">file".
    function is_bare_redirection(t) { return t ~ /^[0-9]*(<|>|>>|<>|<<<)$/ }
    # Returns the index of the word that follows the redirection, including
    # its target, that begins at index R of "words".
    function after_redirection(r) {
      if (!is_bare_redirection(words[r])) { return r + 1 }
      # The target is the word that follows the operator.  When the
      # redirection duplicates a file descriptor, as in "2>&1", the tokenizer
      # has split the "&" into a token of its own, so the target is that token
      # and the one after it rather than a single word.
      if (r + 2 <= nwords && words[r + 1] == "&" && words[r + 2] ~ /^([0-9]+-?|-)$/) {
        return r + 3
      }
      return r + 2
    }
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
    # Prints the variables that the current logical line sets, each preceded
    # by "statement" or "prefix".
    #
    # A "case" statement can span logical lines, so "case_nesting", the
    # number of "case" statements that are open, and "case_state" persist
    # from one call to the next.  "case_state" is "subject" between "case"
    # and "in", "pattern" where a pattern may start, and empty elsewhere.
    function report_line(  i, j, k, r, at_command, array, inert, w, named, \
                           option_letters, option_argument, letter) {
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
        if (case_state == "subject") {
          if (words[i] == "in") { case_state = "pattern" }
          i++
          continue
        }
        if (case_state == "pattern") {
          if (words[i] == "esac") {
            case_nesting--
            case_state = ""
            at_command = 0
          } else if (words[i] == ")") {
            # The ")" that ends the pattern.  The pattern is not an assignment
            # even if it looks like one, as "VAR=*)" does.
            case_state = ""
            at_command = 1
          }
          i++
          continue
        }
        if (at_command && words[i] == "case") {
          case_nesting++
          case_state = "subject"
          i++
          continue
        }
        if (at_command && words[i] == "esac" && case_nesting > 0) {
          case_nesting--
          at_command = 0
          i++
          continue
        }
        if (words[i] == ";;" && case_nesting > 0) {
          case_state = "pattern"
          i++
          continue
        }
        if (at_command && is_assignment(words[i])) {
          for (j = i; j <= nwords && is_assignment(words[j]); j++) { }
          # A redirection may come between the assignments and the terminator,
          # so skip it before deciding.  The assignments end at "j"; "r" is
          # only for looking past them.
          r = j
          while (r <= nwords && is_redirection(words[r])) { r = after_redirection(r) }
          if (r > nwords || is_terminator(words[r])) {
            for (k = i; k < j; k++) { print_name("statement", words[k]) }
            i = j
            at_command = 0
          } else {
            # An environment prefix.  The command that it precedes is at "r".
            for (k = i; k < j; k++) { print_name("prefix", words[k]) }
            i = r
            at_command = 1
          }
          continue
        }
        if (at_command && is_declaration(words[i])) {
          # A declaration sets each variable that it assigns, as in
          # "export VAR=value".  It sets a variable that it names without a
          # value only if it makes that variable an array, as
          # "declare -A ARRAY" does; "export VAR" does not set VAR.  An option
          # that makes it print variables, as in "declare -p VAR", or refer to
          # functions, as in "export -f FUNCTION", makes it set nothing.
          array = 0
          inert = 0
          for (i++; i <= nwords && words[i] ~ /^[-+]/; i++) {
            if (words[i] ~ /^-[A-Za-z]*[aA]/) { array = 1 }
            if (words[i] ~ /^-[A-Za-z]*[fFp]/) { inert = 1 }
          }
          for (; i <= nwords && !is_terminator(words[i]); i++) {
            if (!inert && (is_assignment(words[i]) \
                || (array && words[i] ~ /^[A-Za-z_][A-Za-z0-9_]*$/))) {
              print_name("statement", words[i])
            }
          }
          at_command = 0
          continue
        }
        if (at_command && is_reading_builtin(words[i])) {
          # The builtin sets each variable that it names, as in "read VAR" or
          # "mapfile -t ARRAY", and the argument of the "-a" option of "read",
          # as in "read -ra ARRAY".  Without one, "read" sets REPLY and
          # "mapfile" sets MAPFILE.  As "getopts" does, read a word that
          # begins with "-" as a group of option letters; the first letter
          # that takes an argument, as "d" does in "read -d , VAR", takes the
          # rest of the word, or the next word if the rest is empty.
          option_letters = (words[i] == "read") ? "adinNptu" : "CcdnOsu"
          named = 0
          option_argument = ""
          for (i++; i <= nwords && !is_terminator(words[i]); ) {
            w = words[i]
            if (option_argument != "") {
              if (option_argument == "a") { print_name("statement", w); named = 1 }
              option_argument = ""
              i++
            } else if (is_redirection(w)) {
              i = after_redirection(i)
            } else if (w ~ /^-./ && w != "--") {
              for (k = 2; k <= length(w); k++) {
                letter = substr(w, k, 1)
                if (index(option_letters, letter) > 0) {
                  if (k == length(w)) {
                    option_argument = letter
                  } else if (letter == "a") {
                    print_name("statement", substr(w, k + 1))
                    named = 1
                  }
                  break
                }
              }
              i++
            } else {
              if (w != "--") { print_name("statement", w); named = 1 }
              i++
            }
          }
          if (!named) {
            print_name("statement", (option_letters == "adinNptu") ? "REPLY" : "MAPFILE")
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
        if (c == "(" && is_assignment(word) && word ~ /=$/) {
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
      if (depth == 0) {
        end_word()
        report_line()
      }
      if (depth > 0 || case_nesting > 0) {
        # A quotation mark, a command substitution, an array literal, or a
        # "case" statement that never ended.  Either the script is not valid
        # shell or this program lost track of the nesting, in which case it
        # has misread the rest of the script.  Do not guess.
        print "<unclosed>"
      }
    }
  ' "$1")"
  if printf '%s\n' "${assigned}" | grep -qxF '<here-document>'; then
    echo "${SCRIPT_NAME}: $1 contains a here-document, which set_variables_in does not parse" >&2
    echo "${SCRIPT_NAME}: extend set_variables_in to skip the lines of a here-document" >&2
    exit 2
  fi
  if printf '%s\n' "${assigned}" | grep -qxF '<unclosed>'; then
    echo "${SCRIPT_NAME}: $1 ends within a quotation, a command substitution, an array literal, or a \"case\" statement" >&2
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
# uses in the way that KIND, which is "read" or "set", names:
#  * "read":  as in `os.environ.get("VAR")`, `os.environ["VAR"]`,
#    `os.getenv("VAR")`, or `"VAR" in os.environ`.
#  * "set":  as in `os.environ["VAR"] = value`.
# It parses FILE, so that a call that spans lines counts and a string or
# comment that mentions `os.environ` does not.  Fails if FILE is not valid
# Python.
python_variables() {
  if ! names="$(python3 -I -c '
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
    kind = "read"
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
        # A deletion, as in "del os.environ[...]", neither reads nor sets.
        kind = {ast.Load: "read", ast.Store: "set"}.get(type(node.ctx))
    elif (
        isinstance(node, ast.Compare)
        and len(node.ops) == 1
        and isinstance(node.ops[0], (ast.In, ast.NotIn))
        and is_environ(node.comparators[0])
    ):
        name = string_value(node.left)
    # Like the check of shell scripts, consider only upper-case names.
    if (
        kind == sys.argv[2]
        and name is not None
        and re.fullmatch("[A-Z][A-Z0-9_]*", name)
    ):
        names.add(name)
for name in sorted(names):
    print(name)
' "$1" "$2")"; then
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
LOCAL_ARRAY
MAPFILE
MAPPED
MULTILINE
MULTILINE_ARRAY
MULTILINE_CASE
NESTED_ARITHMETIC
NESTED_SUBSCRIPT
ONE_LINE_CASE_BODY
OTHER_DECLARED
OTHER_READ_VARIABLE
PARENTHESIZED_CASE
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
SUBSTITUTED'
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
