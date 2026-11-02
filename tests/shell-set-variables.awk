# Usage: awk -f shell-set-variables.awk FILE
#
# Prints, one per line, each variable that FILE, a shell script, sets,
# preceded by how it sets it:
#  * "statement", as in "statement VAR", if FILE sets it in an assignment
#    statement, such as "VAR=value", "export VAR=value", "ARRAY[KEY]=value",
#    or "ARRAY+=(value)"; declares it as an array, as in "declare -A ARRAY";
#    or reads input into it, as in "read VAR" or "mapfile ARRAY".
#  * "prefix", as in "prefix VAR", if FILE sets it in an environment prefix of
#    a command, as in "VAR=value some-command".
# A variable can appear more than once.
#
# Instead of a variable, it prints "<here-document>" if FILE contains a
# here-document, whose lines are data rather than code; this program does not
# skip them, so it would read them as code.  It prints "<unclosed>" if FILE
# ends within a quotation, a command substitution, an array literal, or a
# "case" statement.
#
# This splits the script into words the way a shell does, so that a value that
# contains whitespace, quotation marks, or a command substitution does not
# affect the result.  Then, at each point where a command can start, it reads
# the run of assignments that begins there:  the run is an assignment
# statement if nothing but a redirection or a command terminator follows it,
# and is an environment prefix otherwise.

function push_context(kind) { stack[++depth] = kind }
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
  pos = 1
  continued = 0
  while (pos <= len) {
    c = substr(line, pos, 1)
    if (context() == "single") {
      # Within single quotation marks, only a single quotation mark is
      # special.
      if (c == "'") pop_context()
      add_word(c)
      pos++
      continue
    }
    # A backslash quotes the character that follows it.
    if (c == "\\") {
      if (pos == len) { continued = 1; pos++; continue }
      add_word(c substr(line, pos + 1, 1))
      pos += 2
      continue
    }
    if (c == "$" && substr(line, pos + 1, 2) == "((") {
      # An arithmetic expansion.  Its contents are not a command, and the
      # "))" that ends it is not two operators.  Parentheses nest within
      # it, so count them.
      push_context("arith")
      arith_parens[depth] = 1
      add_word("$((")
      pos += 3
      continue
    }
    if (c == "$" && substr(line, pos + 1, 1) == "(") {
      # Quoting starts afresh within a command substitution, even within
      # double quotation marks.
      push_context("subst")
      subst_parens[depth] = 1
      case_depth[depth] = 0
      add_word("$(")
      pos += 2
      continue
    }
    if (c == "`") {
      # A command substitution in the older form.  Quoting starts afresh
      # within it, even within double quotation marks, and one backtick
      # ends what another began.
      if (context() == "backtick") pop_context(); else push_context("backtick")
      add_word(c)
      pos++
      continue
    }
    if (context() == "arith") {
      if (c == "(") { arith_parens[depth]++; add_word(c); pos++; continue }
      if (c == ")") {
        if (arith_parens[depth] > 1) { arith_parens[depth]--; add_word(c); pos++; continue }
        if (substr(line, pos + 1, 1) == ")") { pop_context(); add_word("))"); pos += 2; continue }
        # Not the "))" that ends an arithmetic expansion, so the "$((" was
        # a command substitution that begins with a subshell, as in
        # "$((cd dir; pwd) | cat)".  This ")" ends the subshell, and the
        # command substitution is still open.
        stack[depth] = "subst"
        subst_parens[depth] = 1
        case_depth[depth] = 0
        add_word(c)
        pos++
        continue
      }
      add_word(c)
      pos++
      continue
    }
    if (context() == "double") {
      if (c == "\"") pop_context()
      add_word(c)
      pos++
      continue
    }
    if (c == "'") { push_context("single"); add_word(c); pos++; continue }
    if (c == "\"") { push_context("double"); add_word(c); pos++; continue }
    if (context() == "subst" || context() == "backtick") {
      # A command substitution becomes part of a word, so a here-document
      # operator within one is not a token that "is_heredoc" can find.
      # Note it here instead.  A here-string, "<<<", supplies its data on
      # the same line, so it is not one.
      if (c == "<" && substr(line, pos + 1, 1) == "<" \
          && substr(line, pos + 2, 1) != "<" \
          && (pos == 1 || substr(line, pos - 1, 1) != "<")) {
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
      if (word_at(line, pos, "case") && at_command_in_subst(word)) {
        case_depth[depth]++
      } else if (word_at(line, pos, "esac") && at_command_in_subst(word) \
                 && case_depth[depth] > 0) {
        case_depth[depth]--
      }
      # Parentheses nest within a command substitution, as in
      # "$( (cd dir && pwd) )", so count them:  only the one that closes
      # the "$(" ends it.
      if (c == "(") { subst_parens[depth]++; add_word(c); pos++; continue }
      if (c == ")") {
        # Within a "case" statement, a ")" that closes no "(" ends a
        # pattern.  A pattern may also begin with "(", as in "(1)", and
        # the count above has already matched that one.
        if (case_depth[depth] > 0 && subst_parens[depth] == 1) {
          add_word(c)
          pos++
          continue
        }
        if (--subst_parens[depth] == 0) { pop_context(); add_word(c); pos++; continue }
      }
      add_word(c)
      pos++
      continue
    }
    if (context() == "backtick") { add_word(c); pos++; continue }
    if (context() == "array") {
      # A "#" that begins an element starts a comment, which ends the line.
      if (c == "#" && (pos == 1 || substr(line, pos - 1, 1) ~ /[ \t(]/)) { break }
      if (c == ")") pop_context()
      add_word(c)
      pos++
      continue
    }
    # Outside quotation marks, command substitutions, and array literals.
    if (c == "#" && !have_word) { break }
    if (c == " " || c == "\t") { end_word(); pos++; continue }
    if (c == "(" && is_assignment(word) && word ~ /=$/) {
      # An array literal, as in "ARRAY=(one two)".  It is part of the word
      # of the assignment, so an element that contains "=", as in
      # "ARRAY=(VAR=value)", is not an assignment.  It continues the
      # logical line until its ")".
      push_context("array")
      add_word(c)
      pos++
      continue
    }
    if (c == ";" || c == "&" || c == "|" || c == "(" || c == ")") {
      if (substr(line, pos + 1, 1) == c && c != "(" && c != ")") {
        add_token(c c)
        pos += 2
      } else {
        add_token(c)
        pos++
      }
      continue
    }
    add_word(c)
    pos++
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
