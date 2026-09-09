#!/bin/sh

# Tests for the `compile-project` script.
#
# Usage:
#   tests/test-compile-project.sh
#
# The exit status is 0 if all tests pass, 1 otherwise.

SCRIPT_NAME="$(basename -- "$0")"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMPILE_PROJECT="${SCRIPT_DIR}/../compile-project"

status=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  status=1
}

# Do not let the invoking environment change what the script under test does.
# These flag variables are passed to the build tool, so they could keep
# `compile-project` from writing the log lines that the tests look for.
# `CLEAN` is deliberately not unset:  the last test below checks that
# `compile-project` ignores it.
unset MAKE_FLAGS
unset GRADLE_ASSEMBLE_FLAGS
unset MVN_COMPILE_FLAGS
unset ERR_IF_NO_BUILDFILE

if ! tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")" || [ -z "${tmpdir}" ]; then
  echo "${SCRIPT_NAME}: cannot create a temporary directory" >&2
  exit 1
fi
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${tmpdir}"' EXIT
trap 'rm -rf "${tmpdir}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${tmpdir}"; trap - TERM; kill -s TERM "$$"' TERM

# On macOS, $TMPDIR ends with "/", so the template above contains "//" and
# macOS `mktemp` echoes the duplicated "/" back.  `cd` collapses it, so a path
# built from ${tmpdir} would not match the paths that `compile-project` prints.
# Normalize the path the same way that `compile-project` does: with `pwd`, not
# `pwd -P`, so that symbolic links (such as /tmp or /var on macOS) are left
# alone here just as they are there.
if ! tmpdir="$(CDPATH='' cd -- "${tmpdir}" && pwd)" || [ -z "${tmpdir}" ]; then
  echo "$0: cannot determine the absolute temporary directory" >&2
  exit 1
fi

# Do not let a repository above ${tmpdir} (say, if TMPDIR is within a working
# copy) affect the top-level directory that `compile-project` discovers.
GIT_CEILING_DIRECTORIES="${tmpdir}"
export GIT_CEILING_DIRECTORIES

# Creates, in the given directory, a Makefile whose "all" target appends
# "built" to a file named "log" and whose "clean" target appends "cleaned"
# to that file and then exits with the status given as the second argument.
make_project() {
  mkdir -p "$1"
  {
    printf 'all:\n\t@echo built >> log\n'
    printf 'clean:\n\t@echo cleaned >> log\n\t@exit %s\n' "$2"
  } > "$1/Makefile"
}

# Without --clean, the project is compiled but not cleaned.
noclean="${tmpdir}/noclean"
make_project "${noclean}"
if ! "${COMPILE_PROJECT}" "${noclean}" > /dev/null; then
  fail "nonzero exit status in ${noclean}"
fi
if [ "$(cat "${noclean}/log")" != "built" ]; then
  fail "without --clean, expected only \"built\" but got: $(cat "${noclean}/log")"
fi

# With --clean, the project is cleaned and then compiled.
withclean="${tmpdir}/withclean"
make_project "${withclean}"
if ! "${COMPILE_PROJECT}" --clean "${withclean}" > /dev/null; then
  fail "nonzero exit status in ${withclean}"
fi
if [ "$(cat "${withclean}/log")" != "cleaned
built" ]; then
  fail "with --clean, expected \"cleaned\" then \"built\" but got: $(cat "${withclean}/log")"
fi

# CLEAN in the environment does not clean the project.
inherited="${tmpdir}/inherited"
make_project "${inherited}"
if ! CLEAN=anything "${COMPILE_PROJECT}" "${inherited}" > /dev/null; then
  fail "nonzero exit status in ${inherited}"
fi
if [ "$(cat "${inherited}/log")" != "built" ]; then
  fail "with CLEAN in the environment, expected only \"built\" but got: $(cat "${inherited}/log")"
fi

# Checks that `compile-project <directory>` exits with status 1 and complains
# on stderr that <directory> is not a directory.
expect_not_a_directory() {
  expect_stderr="$("${COMPILE_PROJECT}" "$1" 2>&1 > /dev/null)"
  expect_status=$?
  if [ "${expect_status}" != 1 ]; then
    fail "exit status ${expect_status}, not 1, for $1"
  fi
  case "${expect_stderr}" in
    *"not a directory: $1"*) ;;
    *) fail "expected \"not a directory: $1\" on stderr, got: ${expect_stderr}" ;;
  esac
}

# A directory that does not exist is an error.
expect_not_a_directory "${tmpdir}/does-not-exist"

# A file that is not a directory is an error.
notadirectory="${tmpdir}/regular-file"
# Without this check, a failure to create the file would leave the test
# indistinguishable from the preceding one, which uses a nonexistent path.
if ! touch "${notadirectory}" || [ ! -f "${notadirectory}" ]; then
  fail "could not create the regular file ${notadirectory}"
fi
expect_not_a_directory "${notadirectory}"

# The error message reports the path as given, without expanding backslash
# sequences in it.
expect_not_a_directory "${tmpdir}/backslash\\tname"

# A directory that contains a buildfile is still compiled.
project="${tmpdir}/project"
mkdir -p "${project}"
printf 'all:\n\t@touch built.txt\n' > "${project}/Makefile"
if ! "${COMPILE_PROJECT}" "${project}" > /dev/null; then
  fail "nonzero exit status for directory ${project}"
fi
if [ ! -f "${project}/built.txt" ]; then
  fail "did not build the project in ${project}"
fi

# A directory within a repository compiles the top level of the repository.
repo="${tmpdir}/repo"
mkdir -p "${repo}/sub/dir"
printf 'all:\n\t@touch built.txt\n' > "${repo}/Makefile"
git -c init.defaultBranch=main init -q "${repo}"
if ! "${COMPILE_PROJECT}" "${repo}/sub/dir" > /dev/null; then
  fail "nonzero exit status for directory ${repo}/sub/dir"
fi
if [ ! -f "${repo}/built.txt" ]; then
  fail "did not build the top level of the repository ${repo}"
fi

# A directory that contains no buildfile is not an error.
nobuildfile="${tmpdir}/no-buildfile"
mkdir -p "${nobuildfile}"
if ! "${COMPILE_PROJECT}" "${nobuildfile}" > /dev/null; then
  fail "nonzero exit status for directory without a buildfile ${nobuildfile}"
fi

# When no buildfile is found, the reported directory is absolute, even if the
# argument was relative.
nobuildfile_stderr="$(cd -- "${tmpdir}" && ERR_IF_NO_BUILDFILE=1 "${COMPILE_PROJECT}" no-buildfile 2>&1 > /dev/null)"
case "${nobuildfile_stderr}" in
  *"did nothing in ${nobuildfile}"*) ;;
  *) fail "expected \"did nothing in ${nobuildfile}\" on stderr, got: ${nobuildfile_stderr}" ;;
esac

# $GIT_DIR and $GIT_WORK_TREE in the environment (as when running under a git
# hook, `git rebase --exec`, `git bisect run`, or `git submodule foreach`) do
# not redirect the build to the caller's repository.
gitdirrepo="${tmpdir}/gitdir-repo"
gitdirtarget="${tmpdir}/gitdir-target"
mkdir -p "${gitdirrepo}" "${gitdirtarget}"
printf 'all:\n\t@touch wrong.txt\n' > "${gitdirrepo}/Makefile"
printf 'all:\n\t@touch built.txt\n' > "${gitdirtarget}/Makefile"
git -c init.defaultBranch=main init -q "${gitdirrepo}"
if ! GIT_DIR="${gitdirrepo}/.git" GIT_WORK_TREE="${gitdirrepo}" \
  "${COMPILE_PROJECT}" "${gitdirtarget}" > /dev/null; then
  fail "nonzero exit status for directory ${gitdirtarget} with GIT_DIR set"
fi
if [ ! -f "${gitdirtarget}/built.txt" ]; then
  fail "did not build ${gitdirtarget} when GIT_DIR was set"
fi
if [ -f "${gitdirrepo}/wrong.txt" ]; then
  fail "built the repository named by GIT_DIR, not the given directory"
fi

# $CDPATH in the environment does not redirect the build to a same-named
# directory elsewhere.
cdpathdecoy="${tmpdir}/cdpath-decoy"
cdpathhere="${tmpdir}/cdpath-here"
mkdir -p "${cdpathdecoy}/proj" "${cdpathhere}/proj"
printf 'all:\n\t@touch wrong.txt\n' > "${cdpathdecoy}/proj/Makefile"
printf 'all:\n\t@touch built.txt\n' > "${cdpathhere}/proj/Makefile"
if ! (cd -- "${cdpathhere}" && CDPATH="${cdpathdecoy}" "${COMPILE_PROJECT}" proj > /dev/null); then
  fail "nonzero exit status for directory proj with CDPATH set"
fi
if [ ! -f "${cdpathhere}/proj/built.txt" ]; then
  fail "did not build ${cdpathhere}/proj when CDPATH was set"
fi
if [ -f "${cdpathdecoy}/proj/wrong.txt" ]; then
  fail "built the directory found through CDPATH, not the given directory"
fi

# A git failure other than "not a git repository" is an error; the directory is
# not treated as its own top level, which would build the wrong project.
badrepo="${tmpdir}/bad-repo"
mkdir -p "${badrepo}/sub"
printf 'all:\n\t@touch built.txt\n' > "${badrepo}/sub/Makefile"
git -c init.defaultBranch=main init -q "${badrepo}"
# Edit the file directly; `git config` would itself reject the repository.
if ! sed -i.bak 's/repositoryformatversion = 0/repositoryformatversion = 99/' "${badrepo}/.git/config"; then
  fail "could not make ${badrepo} unreadable"
fi
badrepo_stderr="$("${COMPILE_PROJECT}" "${badrepo}/sub" 2>&1 > /dev/null)"
badrepo_status=$?
if [ "${badrepo_status}" = 0 ]; then
  fail "zero exit status for the unreadable repository ${badrepo}"
fi
if [ -z "${badrepo_stderr}" ]; then
  fail "no diagnostic for the unreadable repository ${badrepo}"
fi
if [ -f "${badrepo}/sub/built.txt" ]; then
  fail "built ${badrepo}/sub although the top level could not be determined"
fi

# With --clean and a clean that succeeds, the project is cleaned and then compiled.
cleanok="${tmpdir}/clean-ok"
make_project "${cleanok}" 0
if ! "${COMPILE_PROJECT}" --clean "${cleanok}" > /dev/null; then
  fail "nonzero exit status in ${cleanok}"
fi
if [ "$(cat "${cleanok}/log")" != "cleaned
built" ]; then
  fail "with a successful clean, expected \"cleaned\" then \"built\" but got: $(cat "${cleanok}/log")"
fi

# With --clean and a clean that fails, the project is not compiled and the
# exit status is failure.
cleanfails="${tmpdir}/clean-fails"
make_project "${cleanfails}" 3
if "${COMPILE_PROJECT}" --clean "${cleanfails}" > /dev/null 2>&1; then
  fail "zero exit status despite a failing clean in ${cleanfails}"
fi
if [ "$(cat "${cleanfails}/log")" != "cleaned" ]; then
  fail "with a failing clean, expected only \"cleaned\" but got: $(cat "${cleanfails}/log")"
fi

# With --clean and a clean whose exit status is 222, the project is not compiled and
# the exit status is failure.  222 is the internal signal for "not a git repository",
# so a clean that exited with it must not be mistaken for that.
sentinel="${tmpdir}/sentinel"
mkdir -p "${sentinel}"
cat > "${sentinel}/gradlew" << 'EOF'
#!/bin/sh
dir="$(dirname -- "$0")"
for argument in "$@"; do
  if [ "${argument}" = clean ]; then
    echo cleaned >> "${dir}/log"
    exit 222
  fi
done
echo built >> "${dir}/log"
EOF
chmod +x "${sentinel}/gradlew"
"${COMPILE_PROJECT}" --clean "${sentinel}" > /dev/null 2>&1
sentinel_status=$?
if [ "${sentinel_status}" != 222 ]; then
  fail "expected exit status 222 from a clean that exited 222 in ${sentinel}, but got ${sentinel_status}"
fi
if [ "$(cat "${sentinel}/log")" != "cleaned" ]; then
  fail "with a clean that exited 222, expected only \"cleaned\" but got: $(cat "${sentinel}/log")"
fi

if [ "${status}" = 0 ]; then
  echo "${SCRIPT_NAME}: OK"
fi
exit "${status}"
