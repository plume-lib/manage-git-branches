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
      return is_terminator(t) \
        || t ~ /^(!|if|then|elif|else|do|while|until|export|readonly|local|time)$/
    }
    function is_assignment(t) { return t ~ /^[A-Za-z_][A-Za-z0-9_]*=/ }
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
    function report_line(  i, j, k, r, name, at_command) {
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
    END {
      if (depth > 0) {
        # A quotation mark, a command substitution, or a "case" statement
        # within one that never ended.  Either the script is not valid shell
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
    echo "${SCRIPT_NAME}: $1 ends within a quotation or a command substitution" >&2
    echo "${SCRIPT_NAME}: either it is not valid shell, or set_variables_in mis-parsed it" >&2
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
FIXTURE_END
EXPECTED='ARITHMETIC
BACKTICKED
CASE_IN_SUBSTITUTION
CASE_WORD
CONDITIONAL
DUPLICATED_DESCRIPTOR
ESCAPED
EXPORTED
MULTILINE
MULTILINE_CASE
NESTED_ARITHMETIC
PARENTHESIZED_CASE
PIPED_SUBSHELL
PLAIN
QUOTED
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
