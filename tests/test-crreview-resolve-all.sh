#!/bin/sh

# Tests that `crreview-resolve-all` runs `crreview-resolve` once for each open
# pull request that is checked out in a working copy directory, and in no
# other directory.
#
# Usage:
#   tests/test-crreview-resolve-all.sh
#
# The status code is 0 if all the tests pass, and nonzero otherwise.
#
# A fake `gh` and a fake `crreview-resolve` stand in for GitHub and for the
# AI agent, so the test needs no network.

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
CRREVIEW_RESOLVE_ALL="${TESTS_DIR}/../crreview-resolve-all"

. "${TESTS_DIR}/lib-git-test-env.sh"

status=0

fail() {
  echo "${SCRIPT_NAME}: FAILED: $*" >&2
  status=1
}

if ! work="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")" || [ -z "${work}" ]; then
  echo "${SCRIPT_NAME}: cannot create a temporary directory" >&2
  exit 1
fi
trap 'rm -rf "${work}"' EXIT
trap 'rm -rf "${work}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${work}"; trap - TERM; kill -s TERM "$$"' TERM
work="$(CDPATH='' cd -- "${work}" && pwd -P)"

sanitize_git_env "${work}"

# The fake `gh api user` prints the user's login, "me".  The fake `gh repo
# view` reports that someone/outer is a repository and that someone/proj is a
# repository whose fork is me/proj; the default branch of each is "main".  The
# fake `gh pr list -R github.com/BASE --head BRANCH` prints, as the real one
# would after applying the `--jq` filter, the lines of ${work}/prs/BRANCH,
# which describe the open pull requests whose head branch, in any repository,
# is BRANCH.  For BRANCH "warns", it also prints a warning on standard error.
# It fails, printing the contents of ${work}/prs/BRANCH.error, if that file
# exists, and it fails if its repository is not named with its host, which
# would let ${GH_REPO} choose the repository.  Each call's arguments are
# appended to ${work}/gh.log.
# The fake `crreview-resolve` appends the name of its directory and its
# arguments to ${work}/runs.log.  If the directory's name ends in "-fails", it
# prints a message on standard error and fails.  In proj-branch-feature, it
# prints a message on standard output.  Elsewhere, it prints nothing, as
# `crreview-resolve --quiet` does when there are no comments to address.
mkdir -p "${work}/bin" "${work}/prs"
cat > "${work}/bin/gh" << EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${work}/gh.log"
case "\$1 \$2" in
  'api user') echo me ;;
  'repo view')
    case "\$3" in
      github.com/someone/outer) echo "someone/outer main" ;;
      github.com/someone/proj | github.com/me/proj) echo "someone/proj main" ;;
      *) exit 1 ;;
    esac
    ;;
  'pr list')
    case "\$3 \$4 \$5" in
      '-R github.com/'*' --head') ;;
      *)
        echo "unexpected arguments: \$*" >&2
        exit 1
        ;;
    esac
    branch="\$6"
    if [ "\${branch}" = warns ]; then
      echo "A new release of gh is available" >&2
    fi
    if [ -f "${work}/prs/\${branch}.error" ]; then
      cat "${work}/prs/\${branch}.error" >&2
      exit 1
    fi
    if [ -f "${work}/prs/\${branch}" ]; then
      cat "${work}/prs/\${branch}"
    fi
    ;;
  *) exit 1 ;;
esac
EOF
cat > "${work}/bin/crreview-resolve" << EOF
#!/bin/sh
dir="\$(basename -- "\$(pwd)")"
echo "\${dir}" "\$@" >> "${work}/runs.log"
case "\${dir}" in
  *-fails)
    echo "crreview-resolve: failing in \${dir}" >&2
    exit 1
    ;;
  proj-branch-feature) echo "crreview-resolve: addressing comments in \${dir}" ;;
esac
exit 0
EOF
chmod +x "${work}/bin/gh" "${work}/bin/crreview-resolve"
PATH="${work}/bin:${PATH}"
export PATH

# The directory that holds the working copy directories is itself a clone,
# whose branch has an open pull request, so that an ordinary directory in it
# is inside a working tree with a pull request.
scan="${work}/scan"
git init -q -b outer "${scan}"
git -C "${scan}" remote add origin https://github.com/someone/outer
git -C "${scan}" commit -q --allow-empty -m "Outer commit"

# Usage: make_clone NAME BRANCH [ORG]
# Creates a clone ${scan}/NAME, whose remote is ORG's repository proj on
# GitHub (by default, someone's), and whose current branch is BRANCH.  Each
# clone's commit differs from every other's.
make_clone() {
  git init -q -b "$2" "${scan}/$1"
  git -C "${scan}/$1" remote add origin "https://github.com/${3:-someone}/proj"
  git -C "${scan}/$1" commit -q --allow-empty -m "Commit of $1"
}

make_clone proj main
make_clone proj-branch-feature feature
make_clone proj-branch-landed landed
make_clone proj-branch-feature-copy feature
make_clone proj-branch-other-fails other
make_clone proj-branch-detached detached
git -C "${scan}/proj-branch-detached" checkout -q --detach
make_clone proj-branch-theirs theirs
make_clone proj-branch-warns warns
make_clone proj-branch-broken broken
make_clone proj-local local
git -C "${scan}/proj-local" remote remove origin
# A clone of the upstream repository on a branch of the same name as a pull
# request's head branch in the fork.
make_clone proj-branch-forked forked
make_clone proj-fork-me-branch-forked forked me
# Two directories hold the same pull request; the second one, in the C
# locale's order, is at its head commit.
make_clone Proj-stale current
make_clone proj-branch-current current
# Two directories hold the same pull request, and neither is at its head
# commit.  "Zed-dup" precedes "alpha-dup" in the C locale's order, but not in
# the order of a locale such as en_US.UTF-8.
make_clone Zed-dup dup
make_clone alpha-dup dup
git -C "${scan}/proj" worktree add -q -b wt "${scan}/proj-branch-wt"
ln -s proj-branch-feature "${scan}/link-to-feature"
mkdir "${scan}/plain"
make_clone .hidden hidden

# Usage: open_pr BRANCH OWNER AUTHOR NUMBER [OID]
# Records the open pull request NUMBER, which AUTHOR opened, from OWNER's
# branch BRANCH, whose head commit is OID (by default, one that no directory
# has).
open_pr() {
  echo "$2 $3 ${5:-0000000000000000000000000000000000000000} https://github.com/someone/proj/pull/$4" \
    >> "${work}/prs/$1"
}
open_pr feature someone me 1
open_pr other someone me 3
open_pr wt someone me 4
open_pr detached someone me 5
# A detached HEAD would be mistaken for a branch named "HEAD".
open_pr HEAD someone me 15
open_pr hidden someone me 6
echo "someone me 0000000000000000000000000000000000000000 https://github.com/someone/outer/pull/7" \
  > "${work}/prs/outer"
open_pr theirs someone alice 8
open_pr warns someone me 9
open_pr local someone me 10
open_pr forked me me 11
open_pr current someone me 12 "$(git -C "${scan}/proj-branch-current" rev-parse HEAD)"
open_pr main someone me 13
open_pr dup someone me 14
echo "HTTP 502: Bad Gateway" > "${work}/prs/broken.error"

# A locale whose order differs from the C locale's, if one is installed.
locale="$(locale -a 2> /dev/null | grep -i -x -m 1 'en_US\.utf-*8')"

# A run in each directory that holds an open pull request, once per pull
# request, despite failures.
: > "${work}/runs.log"
if output="$(CDPATH='' cd -- "${scan}" \
  && LC_ALL="${locale}" GH_REPO=someone/outer "${CRREVIEW_RESOLVE_ALL}" --agent codex < /dev/null 2>&1)"; then
  fail "the exit status is 0 although a crreview-resolve run failed"
fi
expected="Zed-dup --quiet --agent codex
proj-branch-current --quiet --agent codex
proj-branch-feature --quiet --agent codex
proj-branch-other-fails --quiet --agent codex
proj-branch-warns --quiet --agent codex
proj-branch-wt --quiet --agent codex
proj-fork-me-branch-forked --quiet --agent codex"
if [ "$(cat "${work}/runs.log")" != "${expected}" ]; then
  fail "the runs are:
$(cat "${work}/runs.log")
not:
${expected}"
fi
case "${output}" in
  *"skipping proj-branch-feature-copy, whose pull request https://github.com/someone/proj/pull/1 is also in proj-branch-feature"*) ;;
  *) fail "the output does not report the duplicate pull request: ${output}" ;;
esac
case "${output}" in
  *"skipping Proj-stale, whose pull request https://github.com/someone/proj/pull/12 is also in proj-branch-current"*) ;;
  *) fail "the output does not report the stale duplicate: ${output}" ;;
esac
case "${output}" in
  *"skipping alpha-dup, whose pull request https://github.com/someone/proj/pull/14 is also in Zed-dup"*) ;;
  *) fail "the output does not report the duplicate in locale order: ${output}" ;;
esac
case "${output}" in
  *"skipping proj-branch-theirs, whose pull request https://github.com/someone/proj/pull/8 is by alice"*) ;;
  *) fail "the output does not report the pull request by someone else: ${output}" ;;
esac
case "${output}" in
  *"cannot find the pull request of proj-branch-broken:
HTTP 502: Bad Gateway"*) ;;
  *) fail "the output does not report the failure of gh: ${output}" ;;
esac
case "${output}" in
  *"cannot find the pull request of proj-local"*) fail "a clone without a GitHub remote is reported: ${output}" ;;
esac
case "${output}" in
  *"crreview-resolve failed in:
proj-branch-other-fails"*) ;;
  *) fail "the output does not report the failed run: ${output}" ;;
esac
# A header precedes the output of each run that prints something, and only
# such a run.
case "${output}" in
  *"===== proj-branch-feature: https://github.com/someone/proj/pull/1
crreview-resolve: addressing comments in proj-branch-feature"*) ;;
  *) fail "the output of a run is not preceded by its header: ${output}" ;;
esac
case "${output}" in
  *"===== proj-branch-other-fails: https://github.com/someone/proj/pull/3
crreview-resolve: failing in proj-branch-other-fails"*) ;;
  *) fail "the error output of a run is not preceded by its header: ${output}" ;;
esac
case "${output}" in
  *"===== proj-branch-wt:"*) fail "a run that printed nothing has a header: ${output}" ;;
esac
if grep -q -- '--head main' "${work}/gh.log"; then
  fail "the pull requests of the default branch were queried"
fi

# -C, and no --agent.
rm -rf "${scan}/proj-branch-other-fails" "${work}/prs/broken.error"
: > "${work}/runs.log"
if ! output="$("${CRREVIEW_RESOLVE_ALL}" -C "${scan}" 2>&1)"; then
  fail "the exit status is nonzero although every run succeeded: ${output}"
fi
expected="Zed-dup --quiet
proj-branch-current --quiet
proj-branch-feature --quiet
proj-branch-warns --quiet
proj-branch-wt --quiet
proj-fork-me-branch-forked --quiet"
if [ "$(cat "${work}/runs.log")" != "${expected}" ]; then
  fail "with -C, the runs are:
$(cat "${work}/runs.log")
not:
${expected}"
fi

# --dry-run runs nothing.
: > "${work}/runs.log"
if ! output="$("${CRREVIEW_RESOLVE_ALL}" --dry-run -C "${scan}" 2>&1)"; then
  fail "--dry-run fails: ${output}"
fi
if [ -s "${work}/runs.log" ]; then
  fail "--dry-run ran crreview-resolve: $(cat "${work}/runs.log")"
fi
case "${output}" in
  *"Would run crreview-resolve in proj-branch-wt for https://github.com/someone/proj/pull/4"*) ;;
  *) fail "--dry-run does not report a run: ${output}" ;;
esac

# Usage errors.
"${CRREVIEW_RESOLVE_ALL}" --agent gemini -C "${scan}" > /dev/null 2>&1
if [ "$?" -ne 2 ]; then
  fail "the exit status for an unknown agent is not 2"
fi
"${CRREVIEW_RESOLVE_ALL}" --agent= -C "${scan}" > /dev/null 2>&1
if [ "$?" -ne 2 ]; then
  fail "the exit status for an empty agent is not 2"
fi
output="$("${CRREVIEW_RESOLVE_ALL}" -C "${work}/no-such-dir" 2>&1)"
if [ "$?" -ne 2 ]; then
  fail "the exit status for a nonexistent directory is not 2"
fi
case "${output}" in
  *"cannot change to directory ${work}/no-such-dir"*) ;;
  *) fail "the message for a nonexistent directory does not name it: ${output}" ;;
esac

exit "${status}"
