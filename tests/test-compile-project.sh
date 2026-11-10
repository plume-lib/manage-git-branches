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

. "${SCRIPT_DIR}/lib-git-test-env.sh"

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
# A `make` that inherits these from a `make` that runs this test prints
# "Entering directory" lines, which the checks of the output below do not
# expect.
unset MAKELEVEL
unset MAKEFLAGS
unset MFLAGS

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

sanitize_git_env "${tmpdir}"

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
# tree) affect the top-level directory that `compile-project` discovers.
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
make_project "${noclean}" 0
if ! "${COMPILE_PROJECT}" "${noclean}" > /dev/null; then
  fail "nonzero exit status in ${noclean}"
fi
if [ "$(cat "${noclean}/log")" != "built" ]; then
  fail "without --clean, expected only \"built\" but got: $(cat "${noclean}/log")"
fi

# With --clean, the project is cleaned and then compiled.
withclean="${tmpdir}/withclean"
make_project "${withclean}" 0
if ! "${COMPILE_PROJECT}" --clean "${withclean}" > /dev/null; then
  fail "nonzero exit status in ${withclean}"
fi
if [ "$(cat "${withclean}/log")" != "cleaned
built" ]; then
  fail "with --clean, expected \"cleaned\" then \"built\" but got: $(cat "${withclean}/log")"
fi

# CLEAN in the environment does not clean the project.
inherited="${tmpdir}/inherited"
make_project "${inherited}" 0
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

# A Gradle build that fails while a Gradle daemon runs a deleted Java
# executable is run again after that daemon is stopped.  The daemon is a copy
# of `sh` that is deleted after it starts.  The fake `gradlew` lists that
# daemon alone as idle in its `--status` output, so that the test stops no
# real daemon, and its build fails while the daemon runs.  Only systems with
# /proc can recognize such a daemon.
if [ -d /proc ]; then
  stale="${tmpdir}/stale"
  mkdir -p "${stale}"
  cp "$(command -v sh)" "${stale}/java"
  # The loop's "; :" keeps the shell from replacing itself with `sleep`.  The
  # daemon is started from a subshell that exits, so that it is not a child of
  # this shell, which would keep it as a zombie after it is stopped.
  stale_daemon="$(
    "${stale}/java" -c 'while :; do sleep 1; done; :' < /dev/null > /dev/null 2>&1 &
    echo "$!"
  )"
  # Wait until the shell has replaced its fork with ${stale}/java.
  stale_tries=0
  while [ "$(readlink "/proc/${stale_daemon}/exe" 2> /dev/null)" != "${stale}/java" ] \
    && [ "${stale_tries}" -lt 50 ]; do
    sleep 0.1
    stale_tries=$((stale_tries + 1))
  done
  rm -f "${stale}/java"
  cat > "${stale}/gradlew" << EOF
#!/bin/sh
case " \$* " in
  *" --status "*)
    echo "   PID STATUS   INFO"
    echo "${stale_daemon} IDLE     0.0"
    exit 0
    ;;
esac
if kill -0 ${stale_daemon} 2> /dev/null; then
  echo "error=0, Failed to exec spawn helper: pid: 1, exit value: 1" >&2
  exit 1
fi
echo built >> "${stale}/log"
EOF
  chmod +x "${stale}/gradlew"
  stale_output="$("${COMPILE_PROJECT}" "${stale}" 2>&1)"
  stale_status=$?
  if [ "${stale_status}" != 0 ]; then
    fail "a build that failed because of a stale Gradle daemon was not run again: ${stale_output}"
  fi
  if [ "$(cat "${stale}/log" 2> /dev/null)" != "built" ]; then
    fail "with a stale Gradle daemon, expected \"built\" but got: $(cat "${stale}/log" 2> /dev/null)"
  fi
  case "${stale_output}" in
    *"stopping Gradle daemons whose Java executable was deleted"*"(process ids "*"${stale_daemon}"*) ;;
    *) fail "no notice about stopping the stale Gradle daemon ${stale_daemon}: ${stale_output}" ;;
  esac
  if kill -0 "${stale_daemon}" 2> /dev/null; then
    fail "the stale Gradle daemon ${stale_daemon} is still running"
    kill "${stale_daemon}" 2> /dev/null
  fi

  # A Gradle build that fails with no stale daemon is not run again.
  cat > "${stale}/gradlew" << EOF
#!/bin/sh
echo attempt >> "${stale}/attempts"
exit 1
EOF
  if "${COMPILE_PROJECT}" "${stale}" > /dev/null 2>&1; then
    fail "zero exit status from a failing Gradle build in ${stale}"
  fi
  if [ "$(cat "${stale}/attempts")" != "attempt" ]; then
    fail "a failing Gradle build without a stale daemon was run more than once: $(cat "${stale}/attempts")"
  fi
fi

# `compile-project` gets a temporary directory of its own, so that the checks
# below can tell whether it removes its temporary files.
quiet_tmp="${tmpdir}/quiet-tmp"
mkdir -p "${quiet_tmp}"

# Runs `compile-project` on directory $1, with its standard output in
# ${quiet_stdout}, its standard error in ${quiet_stderr}, and its exit status
# in ${quiet_status}.  Reports a failure if it leaves temporary files behind.
run_quiet() {
  quiet_stdout="$(TMPDIR="${quiet_tmp}" "${COMPILE_PROJECT}" "$1" 2> "${tmpdir}/quiet-stderr")"
  quiet_status=$?
  quiet_stderr="$(cat "${tmpdir}/quiet-stderr")"
  if [ -n "$(ls -A "${quiet_tmp}")" ]; then
    fail "temporary files left behind for $1: $(ls -A "${quiet_tmp}")"
  fi
}

# A successful build that writes only to standard output prints nothing.
quietok="${tmpdir}/quiet-ok"
mkdir -p "${quietok}"
printf 'all:\n\techo building\n' > "${quietok}/Makefile"
run_quiet "${quietok}"
if [ "${quiet_status}" != 0 ]; then
  fail "nonzero exit status ${quiet_status} in ${quietok}: ${quiet_stderr}"
fi
if [ -n "${quiet_stdout}${quiet_stderr}" ]; then
  fail "a successful build printed output in ${quietok}: ${quiet_stdout}${quiet_stderr}"
fi

# A successful build that writes to standard error prints, to standard error,
# where it ran and the build's standard output and standard error together, in
# order.  The build pauses between writes, because the order is exact only for
# writes that are separated in time.
quietstderr="${tmpdir}/quiet-stderr-project"
mkdir -p "${quietstderr}"
printf 'all:\n\t@echo out 1\n\t@sleep 0.3\n\t@echo err 1 >&2\n\t@sleep 0.3\n\t@echo out 2\n' \
  > "${quietstderr}/Makefile"
run_quiet "${quietstderr}"
if [ "${quiet_status}" != 0 ]; then
  fail "nonzero exit status ${quiet_status} in ${quietstderr}: ${quiet_stderr}"
fi
if [ -n "${quiet_stdout}" ]; then
  fail "expected no standard output in ${quietstderr}, got: ${quiet_stdout}"
fi
if [ "${quiet_stderr}" != "Running compile-project in ${quietstderr}
out 1
err 1
out 2" ]; then
  fail "expected the output in order on standard error in ${quietstderr}, got: ${quiet_stderr}"
fi

# A failing build that writes only to standard output prints its output, to
# standard error, and exits with the build's status.
quietfails="${tmpdir}/quiet-fails"
mkdir -p "${quietfails}"
printf 'all:\n\t@echo the reason\n\t@exit 3\n' > "${quietfails}/Makefile"
run_quiet "${quietfails}"
if [ "${quiet_status}" != 2 ]; then
  fail "expected exit status 2, the status of make, in ${quietfails}, got ${quiet_status}"
fi
if [ -n "${quiet_stdout}" ]; then
  fail "expected no standard output in ${quietfails}, got: ${quiet_stdout}"
fi
case "${quiet_stderr}" in
  "Running compile-project in ${quietfails}
the reason"*) ;;
  *) fail "expected the build's output on standard error in ${quietfails}, got: ${quiet_stderr}" ;;
esac

if [ "${status}" = 0 ]; then
  echo "${SCRIPT_NAME}: OK"
fi
exit "${status}"
