#!/bin/sh

# Tests for the `compile-project` script.
#
# Usage:
#   tests/test-compile-project.sh
#
# The exit status is 0 if all tests pass, 1 otherwise.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMPILE_PROJECT="${SCRIPT_DIR}/../compile-project"

status=0

fail() {
  echo "FAIL: $*" >&2
  status=1
}

if ! tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")" || [ -z "${tmpdir}" ]; then
  echo "$0: cannot create a temporary directory" >&2
  exit 1
fi
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${tmpdir}"' EXIT
trap 'rm -rf "${tmpdir}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${tmpdir}"; trap - TERM; kill -s TERM "$$"' TERM
# `compile-project` compares its start directory to the output of
# `git rev-parse --show-toplevel`, which is a physical pathname, so the tests
# must use physical pathnames too.  (On macOS, `mktemp -d` returns a pathname
# under /var, which is a symbolic link to /private/var.)
if ! resolved="$(realpath "${tmpdir}")" || [ -z "${resolved}" ]; then
  echo "$0: cannot resolve '${tmpdir}'" >&2
  exit 1
fi
tmpdir="${resolved}"

# Make the tests independent of the user's git configuration, of any git
# environment variables inherited from the caller (such as the GIT_DIR that
# git sets when it runs a hook), and of any git clone that contains $TMPDIR.
GIT_CONFIG_GLOBAL="${tmpdir}/gitconfig"
GIT_CONFIG_SYSTEM=/dev/null
GIT_CEILING_DIRECTORIES="${tmpdir}"
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CEILING_DIRECTORIES
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
if ! printf '[init]\n\tdefaultBranch = main\n' > "${GIT_CONFIG_GLOBAL}"; then
  echo "$0: cannot create '${GIT_CONFIG_GLOBAL}'" >&2
  exit 1
fi

# Writes, to the file $1, a Makefile whose default target creates the file
# whose name is $2, in the directory that contains the Makefile.
make_makefile() {
  if ! printf 'all:\n\t@touch %s\n' "$2" > "$1"; then
    echo "$0: cannot create '$1'" >&2
    exit 1
  fi
}

# Creates a git clone at $1, containing a Makefile whose default target creates
# the file "built.txt", and an empty subdirectory "src".
make_repo() {
  repo="$1"
  if ! mkdir -p "${repo}/src"; then
    echo "$0: cannot create '${repo}/src'" >&2
    exit 1
  fi
  make_makefile "${repo}/Makefile" built.txt
  if ! git init -q "${repo}"; then
    echo "$0: cannot create a git clone at '${repo}'" >&2
    exit 1
  fi
}

# The project is built when the top-level directory is given explicitly.
repo="${tmpdir}/toplevel-argument"
make_repo "${repo}"
if ! output="$("${COMPILE_PROJECT}" "${repo}")"; then
  fail "nonzero exit status for top-level directory ${repo}"
fi
if [ ! -f "${repo}/built.txt" ]; then
  fail "did not build the project in ${repo}"
fi
# The start directory is the top level, so no "called from" is printed.
if [ "${output}" != "Running compile-project in ${repo}" ]; then
  fail "unexpected output for top-level directory ${repo}: ${output}"
fi

# The project is built when a subdirectory of it is given as an argument.
repo="${tmpdir}/subdirectory-argument"
make_repo "${repo}"
if ! output="$("${COMPILE_PROJECT}" "${repo}/src")"; then
  fail "nonzero exit status for subdirectory ${repo}/src"
fi
if [ ! -f "${repo}/built.txt" ]; then
  fail "did not build the project containing ${repo}/src"
fi
if [ "${output}" != "Running compile-project in ${repo}, called from ${repo}/src" ]; then
  fail "unexpected output for subdirectory ${repo}/src: ${output}"
fi

# A trailing "/" in the argument does not affect the output.
repo="${tmpdir}/trailing-slash-argument"
make_repo "${repo}"
if ! output="$("${COMPILE_PROJECT}" "${repo}/")"; then
  fail "nonzero exit status for top-level directory ${repo}/"
fi
if [ "${output}" != "Running compile-project in ${repo}" ]; then
  fail "unexpected output for top-level directory ${repo}/: ${output}"
fi

# The project is built when a subdirectory of it is the current directory.
repo="${tmpdir}/subdirectory-current"
make_repo "${repo}"
if ! (cd "${repo}/src" && "${COMPILE_PROJECT}" > /dev/null); then
  fail "nonzero exit status when run in ${repo}/src"
fi
if [ ! -f "${repo}/built.txt" ]; then
  fail "did not build the project when run in ${repo}/src"
fi

# The top-level project is built, not the nested project that was named.
repo="${tmpdir}/nested-project"
make_repo "${repo}"
make_makefile "${repo}/src/Makefile" nested-built.txt
if ! "${COMPILE_PROJECT}" "${repo}/src" > /dev/null; then
  fail "nonzero exit status for nested project ${repo}/src"
fi
if [ ! -f "${repo}/built.txt" ]; then
  fail "did not build the project containing nested project ${repo}/src"
fi
if [ -f "${repo}/src/nested-built.txt" ]; then
  fail "built the nested project ${repo}/src rather than the project that contains it"
fi

# With --no-discover, the nested project that was named is built.
repo="${tmpdir}/no-discover"
make_repo "${repo}"
make_makefile "${repo}/src/Makefile" nested-built.txt
if ! "${COMPILE_PROJECT}" --no-discover "${repo}/src" > /dev/null; then
  fail "nonzero exit status for --no-discover ${repo}/src"
fi
if [ ! -f "${repo}/src/nested-built.txt" ]; then
  fail "--no-discover did not build the project in ${repo}/src"
fi
if [ -f "${repo}/built.txt" ]; then
  fail "--no-discover built ${repo} rather than ${repo}/src"
fi

# A directory that is not in a clone is used as the top level, as before.
plain="${tmpdir}/plain"
if ! mkdir -p "${plain}"; then
  echo "$0: cannot create '${plain}'" >&2
  exit 1
fi
make_makefile "${plain}/Makefile" built.txt
if ! "${COMPILE_PROJECT}" "${plain}" > /dev/null; then
  fail "nonzero exit status for non-clone directory ${plain}"
fi
if [ ! -f "${plain}/built.txt" ]; then
  fail "did not build the project in non-clone directory ${plain}"
fi

# A nonexistent directory is an error, not a silent success.
if "${COMPILE_PROJECT}" "${tmpdir}/nonexistent" > /dev/null 2>&1; then
  fail "zero exit status for nonexistent directory ${tmpdir}/nonexistent"
fi

# A directory argument that is not a directory is an error.
notadir="${tmpdir}/notadir"
if ! : > "${notadir}"; then
  echo "$0: cannot create '${notadir}'" >&2
  exit 1
fi
if "${COMPILE_PROJECT}" "${notadir}" > /dev/null 2>&1; then
  fail "zero exit status for non-directory argument ${notadir}"
fi

# An empty directory argument is an error, rather than defaulting to the
# current directory's project.
repo="${tmpdir}/empty-argument"
make_repo "${repo}"
if (cd "${repo}/src" && "${COMPILE_PROJECT}" "" > /dev/null 2>&1); then
  fail "zero exit status for empty directory argument"
fi
if [ -f "${repo}/built.txt" ]; then
  fail "built ${repo} for an empty directory argument"
fi

if [ "${status}" = 0 ]; then
  echo "test-compile-project.sh: all tests passed"
fi
exit "${status}"
