# Removes, from a file AGENT-TODO.md, the entries that no longer apply, as
# `prune_agent_todo` in common-functions.sh describes.  Reads the file on
# standard input.  Writes to standard output one line, "R K", in which R is
# the number of entries removed and K is the number of entries kept, such as
# "2 1", and then the file without those entries.  If no entry is kept, the
# file is the preamble without its final blank lines.
#
# The environment variables, which awk does not process the way it processes
# the backslashes of an assignment given with `-v`:
#   PRUNE_DIRS        the pathnames by which entries can name the working tree,
#                     one per line, such as "/home/me/myrepo-branch-feature"
#   PRUNE_CD_PREFIXES the start of the command that continues an AI agent's
#                     session in the working tree, for each of PRUNE_DIRS in
#                     the same order, one per line, such as
#                     "cd /home/me/myrepo-branch-feature && "
#   PRUNE_MERGE_HEAD  the commit whose merge is in progress in the working
#                     tree, as a full hash, or empty if none is
#   PRUNE_BUILT       1 if the working tree's HEAD was just built
#                     successfully, and 0 otherwise
#   PRUNE_RERUN       "merge" to remove also each entry about the merge in
#                     progress in the working tree, and "build" to remove
#                     also each entry about a failed build of the working
#                     tree, that says that running the script again
#                     suffices; empty otherwise
#   PRUNE_RERUN_END   the end of a line that says that running the script
#                     again suffices, as `agent_rerun_advice` writes it, such
#                     as ", so no person needs to."
#
# A file AGENT-TODO.md consists of a preamble (its title and explanation) and
# then entries.  Each entry starts with a line that starts with "## ".  The
# blank line that precedes a heading ends the previous entry or the preamble,
# so removing an entry leaves one blank line between its neighbors.  A line
# that ends with a carriage return, as in a file with CRLF line endings, is
# compared without the carriage return, and is written unchanged.

BEGIN {
  merge_head = ENVIRON["PRUNE_MERGE_HEAD"]
  built = ENVIRON["PRUNE_BUILT"]
  rerun = ENVIRON["PRUNE_RERUN"]
  rerun_end = ENVIRON["PRUNE_RERUN_END"]
  dir_count = split(ENVIRON["PRUNE_DIRS"], dirs, "\n")
  prefix_count = split(ENVIRON["PRUNE_CD_PREFIXES"], prefixes, "\n")
  merge_start = "The merge of commit "
  merge_middle = " is in progress in "
  # The end of the last line of the paragraph that `merge_in_progress_note`
  # prints, in each of its forms.
  merge_end = "; then delete this entry."
  # The start of the line that `merge_build_note` writes to name the working
  # tree whose build failed:  "The build failed in DIRECTORY."
  build_start = "The build failed in "
  # Matches the heading of an entry that a script of manage-git-branches
  # wrote, which ends with the script's name and a time, as in
  # "## Fix the build after merges (git-push-to, 2026-11-10 07:51:59)".
  # The intervals of an extended regular expression, such as "[0-9]{4}", are
  # spelled out, because some versions of awk, such as mawk 1.3.3, lack them.
  script_heading_re = "^## .* \\([A-Za-z0-9._-]+, [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\)$"
  # Matches the line that `report_agent_session` writes before the command
  # of one of several sessions, as in "Session 2 of 3:".
  session_re = "^Session [0-9]+ of [0-9]+:$"
  # The lines of the preamble, and of the entry being read:  *_lines without
  # a final carriage return, for comparisons, and *_raw as read, for output.
  preamble_count = 0
  entry_count = 0
  # The lines to write.
  output_count = 0
  entries_kept = 0
  entries_removed = 0
}

# Returns 1 if STRING starts with PREFIX, and 0 otherwise.
function starts_with(string, prefix) {
  return substr(string, 1, length(prefix)) == prefix
}

# Returns 1 if STRING ends with SUFFIX, and 0 otherwise.
function ends_with(string, suffix) {
  return length(string) >= length(suffix) &&
    substr(string, length(string) - length(suffix) + 1) == suffix
}

# Returns 1 if LINE says that running the script again suffices, as the
# advice of `agent_rerun_advice` does, and 0 otherwise.
function is_rerun_advice(line) {
  return rerun_end != "" && ends_with(line, rerun_end)
}

# Returns 1 if the entry in entry_lines says that running the script again
# suffices, and 0 otherwise.
function has_rerun_advice(i) {
  for (i = 2; i <= entry_count; i++) {
    if (is_rerun_advice(entry_lines[i])) {
      return 1
    }
  }
  return 0
}

# Returns 1 if DIRECTORY is one of the pathnames in ${PRUNE_DIRS}, and 0
# otherwise.
function is_working_tree(directory, i) {
  for (i = 1; i <= dir_count; i++) {
    if (dirs[i] != "" && directory == dirs[i]) {
      return 1
    }
  }
  return 0
}

# Returns 1 if the entry in entry_lines has a line that no script of
# manage-git-branches writes, as when a person added a note after its
# command, and 0 otherwise.  A script writes, after the heading, blank lines,
# paragraphs that start as `merge_in_progress_note` starts its paragraph,
# lines that name the working tree whose build failed and lines that say
# that running the script again suffices, as `merge_build_note` writes them,
# lines that introduce the command of one of several sessions, and code
# blocks that start with "```sh".  A line that a person added to the
# paragraph of `merge_in_progress_note`, before its last line, is not
# recognized.
function has_added_text(i, line, in_note, in_code) {
  in_note = 0
  in_code = 0
  for (i = 2; i <= entry_count; i++) {
    line = entry_lines[i]
    if (in_code) {
      if (line == "```") {
        in_code = 0
      }
    } else if (line == "") {
      in_note = 0
    } else if (in_note) {
      if (ends_with(line, merge_end)) {
        in_note = 0
      }
    } else if (starts_with(line, merge_start)) {
      in_note = 1
    } else if (line == "```sh") {
      in_code = 1
    } else if (starts_with(line, build_start) || is_rerun_advice(line)) {
      continue
    } else if (line !~ session_re) {
      return 1
    }
  }
  return 0
}

# Returns 1 if the entry in entry_lines no longer applies, and 0 otherwise.
function is_obsolete(i, j, line, rest, middle, commit, directory) {
  if (entry_lines[1] !~ script_heading_re || has_added_text()) {
    return 0
  }
  # An entry that says that a merge is in progress in the working tree, as
  # `merge_in_progress_note` writes:  "The merge of commit HASH is in progress
  # in DIRECTORY."
  for (i = 2; i <= entry_count; i++) {
    line = entry_lines[i]
    if (!starts_with(line, merge_start)) {
      continue
    }
    rest = substr(line, length(merge_start) + 1)
    middle = index(rest, merge_middle)
    if (middle == 0 || substr(rest, length(rest)) != ".") {
      continue
    }
    commit = substr(rest, 1, middle - 1)
    directory = substr(rest, middle + length(merge_middle))
    directory = substr(directory, 1, length(directory) - 1)
    if (is_working_tree(directory)) {
      return commit != merge_head || (rerun == "merge" && has_rerun_advice())
    }
  }
  # An entry that says that running the script again suffices to fix the
  # build of the working tree, as `merge_build_note` writes:  "The build
  # failed in DIRECTORY."
  if ((built == 1 || rerun == "build") && starts_with(entry_lines[1], "## Fix the build ") \
    && has_rerun_advice()) {
    for (i = 2; i <= entry_count; i++) {
      line = entry_lines[i]
      if (starts_with(line, build_start) && substr(line, length(line)) == ".") {
        directory = substr(line, length(build_start) + 1)
        if (is_working_tree(substr(directory, 1, length(directory) - 1))) {
          return 1
        }
      }
    }
  }
  # An entry that gives the command that continues an AI agent's attempt to
  # fix the build of the working tree.
  if (built == 1 && starts_with(entry_lines[1], "## Fix the build ")) {
    for (i = 2; i <= entry_count; i++) {
      for (j = 1; j <= prefix_count; j++) {
        if (prefixes[j] != "" && starts_with(entry_lines[i], prefixes[j])) {
          return 1
        }
      }
    }
  }
  return 0
}

# Moves the entry in entry_lines to the output, unless it no longer applies.
function finish_entry(i) {
  if (entry_count == 0) {
    return
  }
  if (is_obsolete()) {
    entries_removed++
  } else {
    entries_kept++
    for (i = 1; i <= entry_count; i++) {
      output_lines[++output_count] = entry_lines[i]
      output_raw[output_count] = entry_raw[i]
    }
  }
  entry_count = 0
}

{
  line = $0
  sub(/\r$/, "", line)
}

line ~ /^## / {
  finish_entry()
  entry_count = 1
  entry_lines[1] = line
  entry_raw[1] = $0
  next
}

{
  if (entry_count > 0) {
    entry_lines[++entry_count] = line
    entry_raw[entry_count] = $0
  } else {
    preamble_lines[++preamble_count] = line
    preamble_raw[preamble_count] = $0
  }
}

END {
  finish_entry()
  # The removed entries' blank lines are gone, but a removed last entry
  # leaves the blank line that preceded it.
  while (output_count > 0 && output_lines[output_count] == "") {
    output_count--
  }
  last = preamble_count
  if (output_count == 0) {
    while (last > 0 && preamble_lines[last] == "") {
      last--
    }
  }
  print entries_removed, entries_kept
  for (i = 1; i <= last; i++) {
    print preamble_raw[i]
  }
  for (i = 1; i <= output_count; i++) {
    print output_raw[i]
  }
}
