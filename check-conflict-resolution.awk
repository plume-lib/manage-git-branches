# Usage: CCR_FILE=FILE CCR_SCRIPT_NAME=NAME CCR_RESOLVED_ENDS_WITH_NEWLINE=yes|no \
#          CCR_CONTAINS_SEPARATOR=yes|no CCR_MARKER_SIZE=N \
#          awk -f check-conflict-resolution.awk MERGED RESOLVED
#   or:  CCR_MARKERS_ONLY=yes awk -f check-conflict-resolution.awk MERGED RESOLVED
#   or:  CCR_PRINT_MARKER_SIZE=yes awk -f check-conflict-resolution.awk MERGED
#   or:  CCR_SCAN=yes [CCR_MARKER_SIZE=N] awk -f check-conflict-resolution.awk SIDE
#
# Checks the resolution of the conflicts in a file.  Exits with status
# 0 if the resolution is acceptable, and exits with status 1 if the
# resolution is not acceptable.  Prints a diagnostic on standard error
# for each problem that it finds.
#
# MERGED holds the merged file, which has the conflict markers, followed by
# one more newline, by which the program tells whether the merged file ends
# with a newline.  RESOLVED is the resolution.  The resolution is acceptable
# if
#  * it consists of the text outside the merged file's conflict regions,
#    unchanged and in order (but any text can take the place of each
#    conflict region);
#  * the text in place of the regions contains no conflict marker, except a
#    separator line when CCR_CONTAINS_SEPARATOR is "yes"; and
#  * it ends with a newline if and only if the merged file does, unless the
#    merged file ends with a conflict region.
# A line can also end with a carriage return, as in a file with CRLF line
# endings.  A separator line consists of 7 or more "=", such as "=======";
# git writes more than 7 for a file whose attribute `conflict-marker-size`
# is larger.
#
# A conflict region of MERGED starts with a line of exactly
# CCR_MARKER_SIZE "<", such as "<<<<<<< HEAD", and ends with the next line
# of exactly CCR_MARKER_SIZE ">", such as ">>>>>>> main".  A longer marker
# line within a region is part of the region's text.  Git writes such lines
# in the merge base's text when the merge has several merge bases, as after
# criss-cross merges:  it merges the merge bases into one, and marks that
# merge's conflicts with longer markers, such as
# "<<<<<<<<< Temporary merge branch 1".  Those longer markers need not be
# balanced, because a side can delete one of them as the other side does,
# which git merges cleanly.
#
# If CCR_MARKERS_ONLY is "yes", the program instead checks only that RESOLVED
# contains no conflict marker line that MERGED lacks:  each conflict marker
# line of RESOLVED must be matched by an identical line of MERGED, a
# different line for each.  MERGED is then any earlier version of the file,
# or /dev/null, so that every conflict marker line of RESOLVED is reported.
# That checks the work of an AI agent, which can change any text.
#
# If CCR_PRINT_MARKER_SIZE is "yes", the program instead reads only MERGED,
# and prints the length of the conflict markers that git wrote in it, such
# as 7 for "<<<<<<<":  the number of "<" that start the first line that
# starts with 7 or more "<" followed by a blank or by the end of the line.
# That line starts the first conflict region, because a longer marker in the
# merge base's text appears only within a region.  It prints 0 if no line
# does, as when the file has a conflict other than a content conflict.
#
# If CCR_SCAN is "yes", the program instead reads only SIDE, a version of
# the file that the merge combined, such as the merge base's, and prints
# "marker" if a line looks like a conflict marker, or else "separator" if a
# line is a separator line, or else nothing.  If CCR_MARKER_SIZE is set, a
# line looks like a conflict marker if it would start or end a conflict
# region, as described above, or if it consists of exactly CCR_MARKER_SIZE
# "|", followed by a blank or by the end of the line.  Otherwise, a line looks
# like a conflict marker if it starts with 7 or more "<", "|", or ">".  That
# is looser than the definition of a conflict marker below, so that it
# finds every line that might be taken for one.
#
# The program reads these environment variables:
#   CCR_FILE                        the file's name; used for diagnostics.
#   CCR_SCRIPT_NAME                 the name of the command; used for
#                                   diagnostics.
#   CCR_RESOLVED_ENDS_WITH_NEWLINE  "yes" if RESOLVED ends with a newline,
#                                   else "no"
#   CCR_CONTAINS_SEPARATOR          "yes" if a side of the merge contains a
#                                   separator line, which can then be
#                                   content, such as a Markdown heading's
#                                   underline; else "no"
#   CCR_MARKERS_ONLY                "yes" to check only for conflict
#                                   markers, as described above; else unset
#                                   or "no"
#   CCR_MARKER_SIZE                 the length of the conflict markers that
#                                   git wrote in MERGED, such as 7 for
#                                   "<<<<<<<", as CCR_PRINT_MARKER_SIZE
#                                   prints it; 7 if unset
#   CCR_PRINT_MARKER_SIZE           "yes" to print the length of the
#                                   conflict markers, as described above;
#                                   else unset or "no"
#   CCR_SCAN                        "yes" to scan a side of the merge, as
#                                   described above; else unset or "no"
#
# `check_conflict_resolution`, in merge-conflict-functions.sh, runs this
# program.  It passes the file in AUTO_MERGE, git's automatic merge, as MERGED;
# and it passes the file in the working tree as RESOLVED.
# `check_conflict_markers` and `check_added_markers` run it with
# CCR_MARKERS_ONLY "yes".
# `conflict_marker_size` runs it with CCR_PRINT_MARKER_SIZE "yes", and
# `resolve_merge_conflicts` runs it with CCR_SCAN "yes".

function problem(message) {
  printf "%s: %s: %s\n", ENVIRON["CCR_SCRIPT_NAME"], ENVIRON["CCR_FILE"], message > "/dev/stderr"
  status = 1
}

BEGIN {
  marker_size = ENVIRON["CCR_MARKER_SIZE"]
  has_marker_size = marker_size ~ /^[1-9][0-9]*$/
  if (!has_marker_size) marker_size = 7
  # A conflict marker has at least min_size characters, which is fewer than 7
  # only if the file's markers are shorter.
  min_size = marker_size < 7 ? marker_size : 7
  # Matches a line that starts or ends a conflict region of MERGED.
  region_start_regex = marker_line_regex("<", marker_size, 0)
  region_end_regex = marker_line_regex(">", marker_size, 0)
  # Matches a line that starts a conflict region of any size of 7 or more.
  any_region_start_regex = marker_line_regex("<", 7, 1)
  # Matches a conflict marker other than a separator line.
  marker_regex = marker_line_regex("<", min_size, 1) "|" marker_line_regex("[|]", min_size, 1) \
    "|" marker_line_regex(">", min_size, 1)
  # Matches a line that CCR_SCAN reports as looking like a conflict marker.
  if (has_marker_size) {
    scan_regex = region_start_regex "|" region_end_regex "|" \
      marker_line_regex("[|]", marker_size, 0)
  } else {
    scan_regex = "^(" repeat("<", 7) "|" repeat("[|]", 7) "|" repeat(">", 7) ")"
  }
}

# Returns a regular expression that matches a line that starts with N
# characters that the regular expression C matches, such as "<" or "[|]", or
# with N or more of them if MORE is 1, followed by a blank or by the end of
# the line.  A line in a file with CRLF line endings ends with "\r".
function marker_line_regex(c, n, more) {
  return "^" repeat(c, n) (more ? c "*" : "") "( |\r?$)"
}

# Returns the string S repeated N times.
function repeat(s, n,   result) {
  result = ""
  while (n-- > 0) result = result s
  return result
}

# Returns 1 if LINE is a conflict marker:  a line that starts with 7 or more
# "<", "|", or ">" (or CCR_MARKER_SIZE or more, if that is smaller) followed
# by a blank or by the end of the line, or a separator line unless
# CCR_CONTAINS_SEPARATOR is "yes".  A line in a file with CRLF line endings
# ends with "\r".
function is_marker(line) {
  return line ~ marker_regex \
    || (ENVIRON["CCR_CONTAINS_SEPARATOR"] != "yes" && line ~ /^=======+\r?$/)
}

# Reports each line of the resolution in place of a conflict region that is
# a conflict marker.
function report_markers(   k) {
  for (k = 1; k <= num_w; k++) {
    if (!clean[k] && is_marker(w[k])) problem("line " k " is a conflict marker")
  }
}

# Returns 1 if the lines of block B, a clean block of the merged file, are
# the lines of the resolution that start at line POS.
function block_at(b, pos,   k) {
  if (pos < 1 || pos + block_len[b] - 1 > num_w) return 0
  for (k = 0; k < block_len[b]; k++) {
    if (w[pos + k] != a[block_start[b] + k]) return 0
  }
  return 1
}

# Describes block B in a diagnostic.
function block_lines(b) {
  if (block_len[b] == 0) return "an empty block"
  return "lines " block_start[b] "-" (block_start[b] + block_len[b] - 1) " of the merged file"
}

# With CCR_PRINT_MARKER_SIZE or CCR_SCAN, the only input is MERGED or SIDE.
ARGC > 2 && FILENAME == ARGV[2] { w[++num_w] = $0; next }
{ a[++num_a] = $0 }

END {
  if (ENVIRON["CCR_PRINT_MARKER_SIZE"] == "yes") {
    for (k = 1; k <= num_a; k++) {
      if (a[k] ~ any_region_start_regex) {
        match(a[k], /^<+/)
        print RLENGTH
        exit 0
      }
    }
    print 0
    exit 0
  }

  if (ENVIRON["CCR_SCAN"] == "yes") {
    separator = 0
    for (k = 1; k <= num_a; k++) {
      if (a[k] ~ scan_regex) { print "marker"; exit 0 }
      if (a[k] ~ /^=======+\r?$/) separator = 1
    }
    if (separator) print "separator"
    exit 0
  }

  if (ENVIRON["CCR_MARKERS_ONLY"] == "yes") {
    for (k = 1; k <= num_a; k++) {
      if (is_marker(a[k])) earlier[a[k]]++
    }
    for (k = 1; k <= num_w; k++) {
      if (!is_marker(w[k])) continue
      if (earlier[w[k]] > 0) earlier[w[k]]--
      else problem("line " k " is a conflict marker")
    }
    exit status
  }

  # The newline that follows the merged file makes the last line empty if
  # and only if the merged file ends with a newline.  An empty file counts as
  # ending with one.
  a_newline = "no"
  if (a[num_a] == "") {
    a_newline = "yes"
    delete a[num_a]
    num_a--
  }

  # Split the merged file into the clean blocks 0..num_regions, between
  # the regions.
  num_regions = 0
  block_start[0] = 1
  in_region = 0
  for (i = 1; i <= num_a; i++) {
    if (!in_region && a[i] ~ region_start_regex) {
      block_len[num_regions] = i - block_start[num_regions]
      num_regions++
      in_region = 1
    } else if (in_region && a[i] ~ region_end_regex) {
      in_region = 0
      block_start[num_regions] = i + 1
    }
  }

  if (in_region) { problem("the merged file has an unterminated conflict region"); exit 1 }
  if (num_regions == 0) { problem("the merged file has no conflict markers"); exit 1 }
  block_len[num_regions] = num_a + 1 - block_start[num_regions]

  # The first block is a prefix of the resolution, and the last block
  # is a suffix that does not overlap it.  Each block between them comes
  # at the earliest place after the previous one, which leaves the most
  # room for the blocks that follow.
  if (!block_at(0, 1)) { problem("the text before the first conflict region changed"); exit 1 }
  last_pos = num_w - block_len[num_regions] + 1
  if (last_pos < block_len[0] + 1 || !block_at(num_regions, last_pos)) {
    problem("the text after the last conflict region changed")
    exit 1
  }

  # The final newline belongs to the last line, which is clean unless the
  # file ends with a conflict region.
  if (block_len[num_regions] > 0 && a_newline != ENVIRON["CCR_RESOLVED_ENDS_WITH_NEWLINE"]) {
    problem("the final newline was added or removed")
    exit 1
  }

  pos = block_len[0] + 1
  for (b = 1; b < num_regions; b++) {
    while (pos + block_len[b] <= last_pos && !block_at(b, pos)) pos++
    if (pos + block_len[b] > last_pos) {
      problem("the text between conflict regions " b " and " (b + 1) " (" block_lines(b) ") changed")
      exit 1
    }
    for (k = 0; k < block_len[b]; k++) clean[pos + k] = 1
    pos += block_len[b]
  }

  for (k = 1; k <= block_len[0]; k++) clean[k] = 1
  for (k = last_pos; k <= num_w; k++) clean[k] = 1

  # The text in place of the regions has no conflict markers.
  report_markers()
  exit status
}
