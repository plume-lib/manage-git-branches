#!/bin/sh

# Tests the `git-orphaned-branches` script.
#
# Usage:
#   tests/test-git-orphaned-branches
#
# The status code is 0 if all the tests pass, and nonzero otherwise.
#
# The test creates its own scratch git repositories under a temporary
# directory; it does not touch any repository outside that directory.

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
TOPLEVEL="$(CDPATH='' cd -- "${TESTS_DIR}/.." && pwd -P)"
GIT_ORPHANED_BRANCHES="${TOPLEVEL}/git-orphaned-branches"

. "${TESTS_DIR}/lib-git-test-env.sh"

if [ "$#" -ne 0 ]; then
  echo "Usage: ${SCRIPT_NAME}" >&2
  exit 1
fi

status=0

if ! work="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")" || [ -z "${work}" ]; then
  echo "${SCRIPT_NAME}: cannot create a temporary directory" >&2
  exit 1
fi

# Restores the permissions of the deliberately unlistable directory created
# below, so that `rm -rf` can remove it.
# shellcheck disable=SC2329 # Is called from traps.
cleanup() {
  chmod 755 "${work}/dot-project/p-branch-unlistable" 2> /dev/null
  rm -rf "${work}"
}
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'cleanup' EXIT
trap 'cleanup; trap - INT; kill -s INT "$$"' INT
trap 'cleanup; trap - TERM; kill -s TERM "$$"' TERM

if ! work="$(CDPATH='' cd -- "${work}" && pwd -P)" || [ -z "${work}" ]; then
  echo "${SCRIPT_NAME}: cannot resolve the temporary directory" >&2
  exit 1
fi

sanitize_git_env "${work}"

fail() {
  echo "${SCRIPT_NAME}: FAILED: $1" >&2
  exit 1
}

# Prints the absolute path of directory $1, with symbolic links resolved.
# `realpath` would be simpler, but POSIX added it only in 2024 and some
# systems still lack it, whereas `cd` and `pwd -P` are portable.
absolute_path() {
  (CDPATH='' cd -- "$1" && pwd -P)
}

###########################################################################
## Directories that contain nothing but a `.project` file.
###########################################################################

mkdir -p "${work}/dot-project"

# Contains nothing but a `.project` file.
mkdir -p "${work}/dot-project/p-branch-only-project"
touch "${work}/dot-project/p-branch-only-project/.project"

# Contains a `.project` file and a regular file.
mkdir -p "${work}/dot-project/p-branch-plus-file"
touch "${work}/dot-project/p-branch-plus-file/.project" "${work}/dot-project/p-branch-plus-file/other"

# Contains a `.project` file and a hidden file.
mkdir -p "${work}/dot-project/p-branch-plus-hidden"
touch "${work}/dot-project/p-branch-plus-hidden/.project" "${work}/dot-project/p-branch-plus-hidden/.other"

# Contains a `.project` file and a subdirectory.
mkdir -p "${work}/dot-project/p-branch-plus-subdir/sub"
touch "${work}/dot-project/p-branch-plus-subdir/.project"

# Contains a `.project` file and a symbolic link with no target.
mkdir -p "${work}/dot-project/p-branch-plus-dangling-symlink"
touch "${work}/dot-project/p-branch-plus-dangling-symlink/.project"
ln -s no-such-file "${work}/dot-project/p-branch-plus-dangling-symlink/dangling"

# Contains nothing.
mkdir -p "${work}/dot-project/p-branch-empty"

# Contains no `.project` file.
mkdir -p "${work}/dot-project/p-branch-no-project"
touch "${work}/dot-project/p-branch-no-project/other"

# Contains nothing but a `.project` file, but is not named `*-branch-*`.
mkdir -p "${work}/dot-project/p-plain-project"
touch "${work}/dot-project/p-plain-project/.project"

# A `*-branch-*` directory inside another one, which the walk has to descend
# into:  a branch directory can hold a clone of another branch.
mkdir -p "${work}/dot-project/p-branch-outer/q-branch-inner"
touch "${work}/dot-project/p-branch-outer/q-branch-inner/.project"

# A `*-branch-*` directory behind a symbolic link to a directory.  The walk
# does not follow such a link, which is what keeps a link to an ancestor from
# sending it around forever.
mkdir -p "${work}/linktarget/p-branch-behind-link"
touch "${work}/linktarget/p-branch-behind-link/.project"
ln -s ../linktarget "${work}/dot-project/link"

# Contains a `.project` file and a regular file, but cannot be listed:  it can
# be searched but not read.  Every glob in such a directory expands to nothing,
# which must not be mistaken for "contains nothing but a `.project` file".
# The superuser can read any directory, so skip this case when running as root.
unlistable=0
if [ "$(id -u)" -ne 0 ]; then
  unlistable=1
  mkdir -p "${work}/dot-project/p-branch-unlistable"
  touch "${work}/dot-project/p-branch-unlistable/.project" "${work}/dot-project/p-branch-unlistable/other"
  chmod 111 "${work}/dot-project/p-branch-unlistable"
fi

if ! output="$(cd "${work}/dot-project" && "${GIT_ORPHANED_BRANCHES}")"; then
  fail "git-orphaned-branches exited with a failure status"
fi

# Checks whether `git-orphaned-branches` listed a directory.
# Arguments: DIRECTORY-NAME  "listed" or "unlisted"
check() {
  if printf '%s\n' "${output}" | grep -q -x -F -- "${work}/dot-project/$1"; then
    actual="listed"
  else
    actual="unlisted"
  fi
  if [ "${actual}" != "$2" ]; then
    echo "FAIL: git-orphaned-branches left $1 ${actual} rather than $2"
    status=1
  fi
}

check "p-branch-only-project" "listed"
check "p-branch-plus-file" "unlisted"
check "p-branch-plus-hidden" "unlisted"
check "p-branch-plus-subdir" "unlisted"
check "p-branch-plus-dangling-symlink" "unlisted"
check "p-branch-empty" "unlisted"
check "p-branch-no-project" "unlisted"
check "p-plain-project" "unlisted"
check "p-branch-outer" "unlisted"
check "p-branch-outer/q-branch-inner" "listed"
if printf '%s\n' "${output}" | grep -q -F -- 'p-branch-behind-link'; then
  echo "FAIL: git-orphaned-branches followed a symbolic link to a directory"
  status=1
fi
if [ "${unlistable}" -eq 1 ]; then
  check "p-branch-unlistable" "unlisted"
fi

###########################################################################
## A directory whose name contains a newline.
###########################################################################

# A newline cannot be held in a variable by `nl="$(printf '\n')"`, because
# command substitution removes trailing newlines.
nl="$(printf '\nx')"
nl="${nl%x}"

mkdir -p "${work}/newline"
newline_dir="${work}/newline/p-branch-a${nl}b"
mkdir -p "${newline_dir}"
touch "${newline_dir}/.project"

# Compare with --print0, because the newline in the directory name makes the
# newline-separated output ambiguous.
printf '%s\0' "$(absolute_path "${newline_dir}")" > "${work}/newline.goal"
(cd "${work}/newline" && "${GIT_ORPHANED_BRANCHES}" --print0) > "${work}/newline.actual"
if ! cmp -s "${work}/newline.goal" "${work}/newline.actual"; then
  echo "FAIL: git-orphaned-branches output differs from ${work}/newline.goal"
  status=1
fi

###########################################################################
## Clones of branches that have been deleted in the remote repository.
###########################################################################

# Create a remote repository with branches "main" and "feat2".
git init -q --bare -b main "${work}/remote.git"
# Redirect stderr to suppress the "you appear to have cloned an empty repository" warning.
git clone -q "${work}/remote.git" "${work}/seed" 2> /dev/null
echo "hello" > "${work}/seed/file.txt"
git -C "${work}/seed" add file.txt
git -C "${work}/seed" commit -q -m "Initial commit"
git -C "${work}/seed" push -q origin main
git -C "${work}/seed" push -q origin main:refs/heads/feat2

# The orphan directory's name, and the name of its parent directory, contain a
# space; the parent's first space-separated component names a sibling
# directory that must not be deleted.
mkdir -p "${work}/scan/my"
mkdir -p "${work}/scan/my dir"
orphan="${work}/scan/my dir/my repo-branch-feat2"
git clone -q -b feat2 "${work}/remote.git" "${orphan}"

# Delete branch "feat2" in the remote, orphaning the clone.
git -C "${work}/seed" push -q origin --delete feat2

orphan_absolute="$(absolute_path "${orphan}")"

# Test 1: --print0 emits the directory names separated by NUL.
printf '%s\0' "${orphan_absolute}" > "${work}/print0.goal"
(cd "${work}/scan" && "${GIT_ORPHANED_BRANCHES}" --print0) > "${work}/print0.actual"
cmp -s "${work}/print0.goal" "${work}/print0.actual" \
  || fail "--print0 output differs from ${work}/print0.goal"
# `-0` is an alias for `--print0`, so it emits the very same bytes.
(cd "${work}/scan" && "${GIT_ORPHANED_BRANCHES}" -0) > "${work}/print0-alias.actual"
cmp -s "${work}/print0.goal" "${work}/print0-alias.actual" \
  || fail "-0 output differs from ${work}/print0.goal"

# Test 2: without --print0, the directory names are separated by newlines.
printf '%s\n' "${orphan_absolute}" > "${work}/print-newline.goal"
(cd "${work}/scan" && "${GIT_ORPHANED_BRANCHES}") > "${work}/print-newline.actual"
cmp -s "${work}/print-newline.goal" "${work}/print-newline.actual" \
  || fail "default output differs from ${work}/print-newline.goal"

# Test 3: the `--print0` pipeline deletes the orphan and nothing else.
(cd "${work}/scan" && "${GIT_ORPHANED_BRANCHES}" --print0) | xargs -0 rm -rf
[ ! -e "${orphan}" ] || fail "cleanup did not delete ${orphan}"
[ -d "${work}/scan/my" ] || fail "cleanup deleted ${work}/scan/my"
[ -d "${work}/scan/my dir" ] || fail "cleanup deleted ${work}/scan/my dir"

###########################################################################
## Working trees whose `.git` is a file rather than a directory.
###########################################################################

# A linked worktree is a working tree, and `is-deleted-branch` answers about
# it correctly, so an orphaned one must be listed.  Before this was fixed,
# such a directory failed the `[ -d "$dir/.git" ]` test, was checked only for
# a lone `.project` file, and was silently ignored.
#
# The main working tree that hosts it must not be listed, even when its own
# branch was deleted as well:  removing it would remove the repository that
# the worktree's `.git` file points into, breaking a working tree that the
# user never named.
git -C "${work}/seed" push -q origin main:refs/heads/host
git -C "${work}/seed" push -q origin main:refs/heads/dependent
mkdir -p "${work}/worktrees"
host="${work}/worktrees/w-branch-host"
dependent="${work}/worktrees/w-branch-dependent"
git clone -q -b host "${work}/remote.git" "${host}"
git -C "${host}" worktree add -q "${dependent}" dependent
host_absolute="$(absolute_path "${host}")"
dependent_absolute="$(absolute_path "${dependent}")"
git -C "${work}/seed" push -q origin --delete host
git -C "${work}/seed" push -q origin --delete dependent

if ! output="$(cd "${work}/worktrees" && "${GIT_ORPHANED_BRANCHES}" \
  2> "${work}/worktrees.stderr")"; then
  fail "git-orphaned-branches exited with a failure status for a linked worktree"
fi
if ! printf '%s\n' "${output}" | grep -q -x -F -- "${dependent_absolute}"; then
  fail "git-orphaned-branches did not list the orphaned worktree ${dependent}"
fi
if printf '%s\n' "${output}" | grep -q -x -F -- "${host_absolute}"; then
  fail "git-orphaned-branches listed ${host}, which hosts a live worktree"
fi
if ! grep -q -F -- "${dependent_absolute}" "${work}/worktrees.stderr"; then
  fail "git-orphaned-branches did not say which worktree ${host} hosts"
fi

# A registration whose directory is gone protects nothing:  removing the host
# cannot break a working tree that does not exist.
rm -rf "${dependent}"
if ! output="$(cd "${work}/worktrees" && "${GIT_ORPHANED_BRANCHES}" 2> /dev/null)"; then
  fail "git-orphaned-branches exited with a failure status for a stale registration"
fi
if ! printf '%s\n' "${output}" | grep -q -x -F -- "${host_absolute}"; then
  fail "git-orphaned-branches did not list ${host} once its worktree was gone"
fi

# A submodule's working tree is a working tree too, and its `.git` is a file
# as well, so the same test decides it.  Its branch can be deleted in the
# submodule's remote like any other, but the directory still must not be
# listed:  it is part of the superproject's working tree, which the user never
# named.
git init -q --bare -b main "${work}/sub-origin.git"
# Redirect stderr to suppress the "you appear to have cloned an empty
# repository" warning.
git clone -q "${work}/sub-origin.git" "${work}/sub-seed" 2> /dev/null
echo "submodule content" > "${work}/sub-seed/sub.txt"
git -C "${work}/sub-seed" add sub.txt
git -C "${work}/sub-seed" commit -q -m "Initial commit"
git -C "${work}/sub-seed" push -q origin main
git -C "${work}/sub-seed" push -q origin main:refs/heads/subfeat
mkdir -p "${work}/submodule"
superproject="${work}/submodule/super-branch-main"
git init -q -b main "${superproject}"
echo "superproject content" > "${superproject}/super.txt"
git -C "${superproject}" add super.txt
git -C "${superproject}" commit -q -m "Initial commit"
# git 2.38.1 and later refuse the "file" transport for a submodule unless
# `protocol.file.allow` permits it.
git -C "${superproject}" -c protocol.file.allow=always submodule add -q \
  -b subfeat "${work}/sub-origin.git" sub-branch-subfeat
git -C "${superproject}" commit -q -m "Add the submodule"
submodule_absolute="$(absolute_path "${superproject}/sub-branch-subfeat")"
git -C "${work}/sub-seed" push -q origin --delete subfeat

superproject_absolute="$(absolute_path "${superproject}")"

if ! output="$(cd "${work}/submodule" && "${GIT_ORPHANED_BRANCHES}" \
  2> "${work}/submodule.stderr")"; then
  fail "git-orphaned-branches exited with a failure status for a submodule"
fi
if printf '%s\n' "${output}" | grep -q -x -F -- "${submodule_absolute}"; then
  fail "git-orphaned-branches listed ${submodule_absolute}, which is part of a live working tree"
fi
if ! grep -q -F -- "${superproject_absolute}" "${work}/submodule.stderr"; then
  fail "git-orphaned-branches did not say which superproject ${submodule_absolute} belongs to"
fi
# The superproject itself is a clone of nothing, so `is-deleted-branch` cannot
# call its branch deleted; the submodule is the only candidate here.
if [ -n "${output}" ]; then
  fail "git-orphaned-branches listed something under a superproject: ${output}"
fi

###########################################################################
## One remote query per remote URL, rather than one per directory.
###########################################################################

# Count the queries with a fake `git` on PATH that logs its arguments and then
# runs the real git.  These tests' remotes are local pathnames that never
# reach SSH, so counting SSH invocations would count nothing.
# shellcheck source=common-functions.sh
. "${TESTS_DIR}/common-functions.sh"
make_counting_git "${work}/fake-bin" "${work}/git-commands.log"

# Usage: scan_with_counted_queries DIRECTORY
# Runs `git-orphaned-branches` in DIRECTORY with the fake `git` on PATH.
# Sets ${scan_output} to what it listed and ${scan_queries} to the number of
# questions it asked a remote.  `ls-remote --get-url` only prints a URL from
# the local configuration, so it asks nothing and does not count.
scan_with_counted_queries() {
  : > "${GIT_COMMAND_LOG}"
  scan_output="$(PATH="${work}/fake-bin:${PATH}" \
    sh -c 'cd "$1" && "$2"' sh "$1" "${GIT_ORPHANED_BRANCHES}" 2> /dev/null)"
  scan_queries="$(count_remote_queries)"
}

# Usage: check_scan EXPECTED-QUERIES DESCRIPTION DIRECTORY...
# Checks that the scan just run asked EXPECTED-QUERIES questions and listed
# exactly the given directories.
check_scan() {
  check_scan_expected_queries="$1"
  check_scan_description="$2"
  shift 2
  if [ "${scan_queries}" -ne "${check_scan_expected_queries}" ]; then
    fail "${check_scan_description}: asked ${scan_queries} question(s), not ${check_scan_expected_queries}"
  fi
  check_scan_expected="$(for check_scan_dir in "$@"; do
    absolute_path "${check_scan_dir}"
  done | sort)"
  check_scan_actual="$(printf '%s\n' "${scan_output}" | grep '.' | sort)"
  if [ "${check_scan_actual}" != "${check_scan_expected}" ]; then
    fail "${check_scan_description}: listed [${check_scan_actual}], expected [${check_scan_expected}]"
  fi
}

# A second remote, so that clones of different upstreams can be told from
# clones of one.
git init -q --bare -b main "${work}/remote2.git"
git -C "${work}/seed" remote add second "${work}/remote2.git"
git -C "${work}/seed" push -q second main
git -C "${work}/seed" tag live-tag
git -C "${work}/seed" push -q origin refs/tags/live-tag
for branch in q1 q2 q3 q5 q6 q7 q8 q9; do
  git -C "${work}/seed" push -q origin "main:refs/heads/${branch}"
done
git -C "${work}/seed" push -q second main:refs/heads/q4

# Three clones of one upstream: one query answers for all three.
mkdir -p "${work}/queries-one"
for branch in q1 q2 q3; do
  git clone -q -b "${branch}" "${work}/remote.git" \
    "${work}/queries-one/p-branch-${branch}"
  git -C "${work}/seed" push -q origin --delete "${branch}"
done
scan_with_counted_queries "${work}/queries-one"
check_scan 1 'three clones of one upstream' \
  "${work}/queries-one/p-branch-q1" "${work}/queries-one/p-branch-q2" \
  "${work}/queries-one/p-branch-q3"

# Clones of different upstreams are asked separately, because a URL is what
# says whether two directories are asking one repository.
mkdir -p "${work}/queries-two"
git clone -q -b q5 "${work}/remote.git" "${work}/queries-two/p-branch-q5"
git clone -q -b q4 "${work}/remote2.git" "${work}/queries-two/p-branch-q4"
git -C "${work}/seed" push -q origin --delete q5
git -C "${work}/seed" push -q second --delete q4
scan_with_counted_queries "${work}/queries-two"
check_scan 2 'clones of two upstreams' \
  "${work}/queries-two/p-branch-q4" "${work}/queries-two/p-branch-q5"

# A directory whose configured upstream ref is not under refs/heads/ asks its
# own question, because `ls-remote --heads` does not report such a ref.  It
# still gets the right answer:  its upstream tag exists, so its branch is not
# orphaned, while its neighbor's branch is.
mkdir -p "${work}/queries-fallback"
git clone -q -b q6 "${work}/remote.git" "${work}/queries-fallback/p-branch-q6"
git clone -q -b q7 "${work}/remote.git" "${work}/queries-fallback/p-branch-q7"
git -C "${work}/queries-fallback/p-branch-q7" config branch.q7.merge \
  refs/tags/live-tag
git -C "${work}/seed" push -q origin --delete q6
git -C "${work}/seed" push -q origin --delete q7
scan_with_counted_queries "${work}/queries-fallback"
check_scan 2 'a clone whose upstream ref is outside refs/heads/' \
  "${work}/queries-fallback/p-branch-q6"

# Two clones of one upstream that reach it through different SSH commands are
# asking different questions, and are asked separately.
mkdir -p "${work}/queries-ssh"
git clone -q -b q8 "${work}/remote.git" "${work}/queries-ssh/p-branch-q8"
git clone -q -b q9 "${work}/remote.git" "${work}/queries-ssh/p-branch-q9"
git -C "${work}/queries-ssh/p-branch-q9" config core.sshCommand 'ssh -v'
git -C "${work}/seed" push -q origin --delete q8
git -C "${work}/seed" push -q origin --delete q9
scan_with_counted_queries "${work}/queries-ssh"
check_scan 2 'two clones that configure SSH differently' \
  "${work}/queries-ssh/p-branch-q8" "${work}/queries-ssh/p-branch-q9"

# Two clones of one upstream that run different programs at the far end are
# asking different questions, and are asked separately.  Both queries succeed,
# so the retry below cannot correct a shared answer:  the second clone's
# `remote.origin.uploadpack` serves another repository entirely, where its
# branch still exists, and reusing the first clone's answer would report a
# live branch as orphaned.
mkdir -p "${work}/queries-uploadpack"
cat > "${work}/fake-upload-pack" << UPLOAD_PACK_END
#!/bin/sh
# Ignore the repository that git names, and serve the other one.
exec git upload-pack "${work}/remote2.git"
UPLOAD_PACK_END
chmod +x "${work}/fake-upload-pack"
for branch in qd qe; do
  git -C "${work}/seed" push -q origin "main:refs/heads/${branch}"
  git clone -q -b "${branch}" "${work}/remote.git" \
    "${work}/queries-uploadpack/p-branch-${branch}"
  git -C "${work}/seed" push -q origin --delete "${branch}"
done
# The branch that the other repository still has.
git -C "${work}/seed" push -q second main:refs/heads/qe
git -C "${work}/queries-uploadpack/p-branch-qe" config \
  remote.origin.uploadpack "${work}/fake-upload-pack"
scan_with_counted_queries "${work}/queries-uploadpack"
check_scan 2 'two clones that configure upload-pack differently' \
  "${work}/queries-uploadpack/p-branch-qd"

# Two clones of one upstream that reach it through different transports are
# asking different questions, and are asked separately.  Both queries succeed,
# so nothing later can correct a shared answer:  the second clone's
# `remote.origin.vcs` names a remote helper that answers in place of git's own
# transport, and reusing the first clone's answer would report a live branch
# as orphaned.
mkdir -p "${work}/queries-vcs"
cat > "${work}/fake-bin/git-remote-fakevcs" << HELPER_END
#!/bin/sh
# Ignore the URL that git names, and serve a fixed list of refs.  Reading the
# list from a file, rather than asking a repository for it, keeps this
# helper's own work out of the query count.
while IFS= read -r fake_helper_command; do
  case "\${fake_helper_command}" in
    capabilities) printf 'fetch\n\n' ;;
    list) cat "${work}/fake-helper-refs"; printf '\n' ;;
    *) exit 0 ;;
  esac
done
HELPER_END
chmod +x "${work}/fake-bin/git-remote-fakevcs"
for branch in qf qg; do
  git -C "${work}/seed" push -q origin "main:refs/heads/${branch}"
  git clone -q -b "${branch}" "${work}/remote.git" \
    "${work}/queries-vcs/p-branch-${branch}"
  git -C "${work}/seed" push -q origin --delete "${branch}"
done
# The branch that the remote helper still reports, in the format that a helper
# answers `list` with:  "SHA<SPACE>refname".
printf '%s refs/heads/qg\n' "$(git -C "${work}/seed" rev-parse HEAD)" \
  > "${work}/fake-helper-refs"
git -C "${work}/queries-vcs/p-branch-qg" config remote.origin.vcs fakevcs
scan_with_counted_queries "${work}/queries-vcs"
check_scan 2 'two clones that configure a remote helper differently' \
  "${work}/queries-vcs/p-branch-qf"

# A directory whose own configuration breaks its query does not answer for the
# rest of its group.  A key names a URL, not a directory, so a failure that
# belongs to one directory would otherwise be remembered for all of them, and
# a scan that should have listed the healthy directories would list nothing.
# `protocol.file.allow` forbids the query that this directory would make,
# which fails it without changing what it would ask -- that is, without
# changing the key -- and it is set on the directory that is scanned first,
# which is the one that would poison the others.
mkdir -p "${work}/queries-broken"
for branch in qa qb qc; do
  git -C "${work}/seed" push -q origin "main:refs/heads/${branch}"
  git clone -q -b "${branch}" "${work}/remote.git" \
    "${work}/queries-broken/p-branch-${branch}"
  git -C "${work}/seed" push -q origin --delete "${branch}"
done
git -C "${work}/queries-broken/p-branch-qa" config protocol.file.allow never
# One failed query, then one that succeeds and answers for the rest.
scan_with_counted_queries "${work}/queries-broken"
check_scan 2 'a directory whose own configuration breaks its query' \
  "${work}/queries-broken/p-branch-qb" "${work}/queries-broken/p-branch-qc"

# The same, with two broken directories:  a healthy directory is asked its own
# question no matter how many of its siblings failed before it.  A budget of
# retries, rather than a failure that is simply never remembered, would spend
# itself on the second broken directory and report nothing at all.
mkdir -p "${work}/queries-broken-two"
for branch in qh qi qj; do
  git -C "${work}/seed" push -q origin "main:refs/heads/${branch}"
  git clone -q -b "${branch}" "${work}/remote.git" \
    "${work}/queries-broken-two/p-branch-${branch}"
  git -C "${work}/seed" push -q origin --delete "${branch}"
done
git -C "${work}/queries-broken-two/p-branch-qh" config protocol.file.allow never
git -C "${work}/queries-broken-two/p-branch-qi" config protocol.file.allow never
# Two failed queries, then one that succeeds.
scan_with_counted_queries "${work}/queries-broken-two"
check_scan 3 'two directories whose own configuration breaks their queries' \
  "${work}/queries-broken-two/p-branch-qj"

###########################################################################
## --remove
###########################################################################

# `--remove` removes each directory that it would otherwise list, by running
# `git-remove-branch-directory`, and prints the ones that it removed.  That
# script refuses a directory that holds work, so `--remove` can leave one
# behind; it says why, and the exit status says that not everything was
# removed.
git -C "${work}/seed" push -q origin main:refs/heads/r1
git -C "${work}/seed" push -q origin main:refs/heads/r2
git -C "${work}/seed" push -q origin main:refs/heads/r3
mkdir -p "${work}/removal"
git clone -q -b r1 "${work}/remote.git" "${work}/removal/c-branch-r1"
git clone -q -b r2 "${work}/remote.git" "${work}/removal/c-branch-r2"
git clone -q -b r3 "${work}/remote.git" "${work}/removal/c-branch-r3"
mkdir -p "${work}/removal/c-branch-project"
touch "${work}/removal/c-branch-project/.project"
echo "an uncommitted change" >> "${work}/removal/c-branch-r2/file.txt"
git -C "${work}/seed" push -q origin --delete r1
git -C "${work}/seed" push -q origin --delete r2

removal_r1="$(absolute_path "${work}/removal/c-branch-r1")"
removal_project="$(absolute_path "${work}/removal/c-branch-project")"
removal_stderr="${work}/removal-stderr"
if output="$(cd "${work}/removal" && "${GIT_ORPHANED_BRANCHES}" --remove \
  2> "${removal_stderr}")"; then
  fail "--remove exited with status 0 although a removal was refused"
fi
removal_expected="$(printf '%s\n%s\n' "${removal_project}" "${removal_r1}" | sort)"
removal_actual="$(printf '%s\n' "${output}" | grep '.' | sort)"
if [ "${removal_actual}" != "${removal_expected}" ]; then
  fail "--remove printed [${removal_actual}], expected [${removal_expected}]"
fi
if [ -e "${work}/removal/c-branch-r1" ]; then
  fail "--remove did not remove ${work}/removal/c-branch-r1"
fi
if [ -e "${work}/removal/c-branch-project" ]; then
  fail "--remove did not remove ${work}/removal/c-branch-project"
fi
if [ ! -d "${work}/removal/c-branch-r2" ]; then
  fail "--remove removed a directory that holds uncommitted changes"
fi
if [ ! -d "${work}/removal/c-branch-r3" ]; then
  fail "--remove removed a directory whose branch still exists"
fi
if ! grep -q -F -- 'uncommitted changes' "${removal_stderr}"; then
  fail "--remove did not say why it left a directory behind: $(cat "${removal_stderr}")"
fi

# None of the force flags is passed through, so a second run refuses again.
if (cd "${work}/removal" && "${GIT_ORPHANED_BRANCHES}" --remove > /dev/null 2>&1); then
  fail "--remove exited with status 0 although a removal was refused again"
fi
if [ ! -d "${work}/removal/c-branch-r2" ]; then
  fail "--remove removed a directory that holds uncommitted changes"
fi

# `--remove --print0` separates the names of the removed directories with NUL,
# as `--print0` alone separates the names of the listed ones.
git -C "${work}/seed" push -q origin main:refs/heads/r4
mkdir -p "${work}/removal0"
git clone -q -b r4 "${work}/remote.git" "${work}/removal0/c-branch-r4"
removal_r4="$(absolute_path "${work}/removal0/c-branch-r4")"
git -C "${work}/seed" push -q origin --delete r4
printf '%s\0' "${removal_r4}" > "${work}/removal0.goal"
(cd "${work}/removal0" && "${GIT_ORPHANED_BRANCHES}" --remove --print0) \
  > "${work}/removal0.actual"
cmp -s "${work}/removal0.goal" "${work}/removal0.actual" \
  || fail "--remove --print0 output differs from ${work}/removal0.goal"
if [ -e "${work}/removal0/c-branch-r4" ]; then
  fail "--remove --print0 did not remove ${work}/removal0/c-branch-r4"
fi

# A reported directory can contain another, which is why the scan descends
# into one.  The inner directory is removed first, through its own checks, and
# the outer one after it.  Removing the outer one first would `rm -rf` the
# inner clone without ever asking whether it held work, and would then fail on
# an inner directory that no longer existed.
git -C "${work}/seed" push -q origin main:refs/heads/n1
git -C "${work}/seed" push -q origin main:refs/heads/n2
mkdir -p "${work}/nested"
git clone -q -b n1 "${work}/remote.git" "${work}/nested/c-branch-outer"
git clone -q -b n2 "${work}/remote.git" \
  "${work}/nested/c-branch-outer/c-branch-inner"
git -C "${work}/seed" push -q origin --delete n1
git -C "${work}/seed" push -q origin --delete n2
nested_outer="$(absolute_path "${work}/nested/c-branch-outer")"
nested_inner="$(absolute_path "${work}/nested/c-branch-outer/c-branch-inner")"
if ! output="$(cd "${work}/nested" && "${GIT_ORPHANED_BRANCHES}" --remove \
  2> "${removal_stderr}")"; then
  fail "--remove exited with a failure status although both nested directories were removable: $(cat "${removal_stderr}")"
fi
nested_expected="$(printf '%s\n%s\n' "${nested_outer}" "${nested_inner}" | sort)"
nested_actual="$(printf '%s\n' "${output}" | grep '.' | sort)"
if [ "${nested_actual}" != "${nested_expected}" ]; then
  fail "--remove printed [${nested_actual}], expected [${nested_expected}]"
fi
if [ -e "${work}/nested/c-branch-outer" ]; then
  fail "--remove did not remove ${work}/nested/c-branch-outer"
fi

# When the inner directory is kept, the outer one is kept as well:  removing
# it would destroy what the inner directory's checks just refused to destroy.
git -C "${work}/seed" push -q origin main:refs/heads/n3
git -C "${work}/seed" push -q origin main:refs/heads/n4
mkdir -p "${work}/nested-kept"
git clone -q -b n3 "${work}/remote.git" "${work}/nested-kept/c-branch-outer"
git clone -q -b n4 "${work}/remote.git" \
  "${work}/nested-kept/c-branch-outer/c-branch-inner"
echo "an uncommitted change" \
  >> "${work}/nested-kept/c-branch-outer/c-branch-inner/file.txt"
git -C "${work}/seed" push -q origin --delete n3
git -C "${work}/seed" push -q origin --delete n4
if (cd "${work}/nested-kept" && "${GIT_ORPHANED_BRANCHES}" --remove \
  > "${work}/nested-kept.out" 2> "${removal_stderr}"); then
  fail "--remove exited with status 0 although a nested removal was refused"
fi
if [ ! -d "${work}/nested-kept/c-branch-outer/c-branch-inner" ]; then
  fail "--remove removed a nested directory that holds uncommitted changes"
fi
if [ ! -d "${work}/nested-kept/c-branch-outer" ]; then
  fail "--remove removed a directory that contains one that was not removed"
fi
if [ -s "${work}/nested-kept.out" ]; then
  fail "--remove printed [$(cat "${work}/nested-kept.out")] although it removed nothing"
fi
if ! grep -q -F -- 'contains a directory that was not removed' \
  "${removal_stderr}"; then
  fail "--remove did not say why it kept the outer directory: $(cat "${removal_stderr}")"
fi

# A scan that finds nothing removes nothing and exits with status 0.
mkdir -p "${work}/removal-empty/not-a-branch-directory"
if ! output="$(cd "${work}/removal-empty" && "${GIT_ORPHANED_BRANCHES}" --remove)"; then
  fail "--remove exited with a failure status although it found nothing"
fi
if [ -n "${output}" ]; then
  fail "--remove printed [${output}] although it found nothing"
fi
if [ ! -d "${work}/removal-empty/not-a-branch-directory" ]; then
  fail "--remove removed a directory that it does not list"
fi

if [ "${status}" = 0 ]; then
  echo "${SCRIPT_NAME}: OK"
fi
exit "${status}"
