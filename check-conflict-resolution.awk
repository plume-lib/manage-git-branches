# Usage: CHECK_FILE=FILE CHECK_SCRIPT_NAME=NAME CHECK_W_NEWLINE=yes|no \
#          CHECK_SEPARATOR=yes|no awk -f check-conflict-resolution.awk MERGED RESOLVED
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
#    unchanged and in order, with any text in place of each region;
#  * the text in place of the regions contains no conflict marker, except a
#    line "=======" when CHECK_SEPARATOR is "yes"; and
#  * it ends with a newline if and only if the merged file does, unless the
#    merged file ends with a conflict region.
# A line can also end with a carriage return, as in a file with CRLF line
# endings.
#
# The program reads these environment variables:
#   CHECK_FILE         the file's name; used for diagnostics.
#   CHECK_SCRIPT_NAME  the name of the command; used for diagnostics.
#   CHECK_W_NEWLINE    "yes" if RESOLVED ends with a newline, else "no"
#   CHECK_SEPARATOR    "yes" if a line "=======" can be content, such as a
#                      Markdown heading's underline, else "no"
#
# `check_conflict_resolution`, in common-functions.sh, runs this program.  It
# passes the file in AUTO_MERGE, git's automatic merge, as MERGED, on
# standard input, by giving "-" as the first operand; and it passes the file
# in the working tree as RESOLVED.

function problem(message) {
  printf "%s: %s: %s\n", ENVIRON["CHECK_SCRIPT_NAME"], ENVIRON["CHECK_FILE"], message > "/dev/stderr"
  status = 1
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

FILENAME == ARGV[2] { w[++num_w] = $0; next }
{ a[++num_a] = $0 }

END {
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
  depth = 0
  for (i = 1; i <= num_a; i++) {
    if (a[i] ~ /^<<<<<<<+( |\r?$)/) {
      if (depth == 0) {
        block_len[num_regions] = i - block_start[num_regions]
        num_regions++
      }
      depth++
    } else if (depth > 0 && a[i] ~ /^>>>>>>>+( |\r?$)/) {
      depth--
      if (depth == 0) block_start[num_regions] = i + 1
    }
  }

  if (depth != 0) { problem("the merged file has an unterminated conflict region"); exit 1 }
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
  if (block_len[num_regions] > 0 && a_newline != ENVIRON["CHECK_W_NEWLINE"]) {
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

  # The text in place of the regions has no conflict markers.  A line
  # in a file with CRLF line endings ends with "\r".
  for (k = 1; k <= num_w; k++) {
    if (!clean[k] && (w[k] ~ /^<<<<<<<+( |\r?$)/ || w[k] ~ /^[|][|][|][|][|][|][|]+( |\r?$)/ \
                      || w[k] ~ /^>>>>>>>+( |\r?$)/ \
                      || (ENVIRON["CHECK_SEPARATOR"] != "yes" && w[k] ~ /^=======\r?$/))) {
      problem("line " k " is a conflict marker")
    }
  }
  exit status
}
