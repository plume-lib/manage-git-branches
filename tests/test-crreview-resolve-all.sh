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

# The fake `gh pr view` prints, as the real one would after applying the
# `--jq` filter, the line in ${work}/prs/BRANCH, where BRANCH is the current
# branch.  It fails as the real one does if HEAD is detached.  If there is no
# such file, it fails as the real one does for a branch with no pull request,
# unless ${work}/gh-error exists, in which case
# it prints that file's contents and fails.
# The fake `crreview-resolve` appends the name of its directory and its
# arguments to ${work}/runs.log, and fails if the directory's name ends in
# "-fails".
mkdir -p "${work}/bin" "${work}/prs"
cat > "${work}/bin/gh" << EOF
#!/bin/sh
branch="\$(git branch --show-current)"
if [ -z "\${branch}" ]; then
  echo "could not determine current branch: not on any branch" >&2
  exit 1
elif [ -f "${work}/prs/\${branch}" ]; then
  cat "${work}/prs/\${branch}"
elif [ -f "${work}/gh-error" ]; then
  cat "${work}/gh-error" >&2
  exit 1
else
  echo "no pull requests found for branch \"\${branch}\"" >&2
  exit 1
fi
EOF
cat > "${work}/bin/crreview-resolve" << EOF
#!/bin/sh
dir="\$(basename -- "\$(pwd)")"
echo "\${dir}" "\$@" >> "${work}/runs.log"
case "\${dir}" in *-fails) exit 1 ;; esac
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

# Usage: make_clone NAME BRANCH
# Creates a clone ${scan}/NAME whose current branch is BRANCH.
make_clone() {
  git init -q -b "$2" "${scan}/$1"
  git -C "${scan}/$1" commit -q --allow-empty -m "Initial commit"
}

make_clone proj main
make_clone proj-branch-feature feature
make_clone proj-branch-landed landed
make_clone proj-branch-feature-copy feature
make_clone proj-branch-other-fails other
make_clone proj-branch-detached detached
git -C "${scan}/proj-branch-detached" checkout -q --detach
git -C "${scan}/proj" worktree add -q -b wt "${scan}/proj-branch-wt"
ln -s proj-branch-feature "${scan}/link-to-feature"
mkdir "${scan}/plain"
mkdir "${scan}/.hidden"
git init -q -b hidden "${scan}/.hidden/repo"

echo "OPEN https://github.com/someone/proj/pull/1" > "${work}/prs/feature"
echo "MERGED https://github.com/someone/proj/pull/2" > "${work}/prs/landed"
echo "OPEN https://github.com/someone/proj/pull/3" > "${work}/prs/other"
echo "OPEN https://github.com/someone/proj/pull/4" > "${work}/prs/wt"
echo "OPEN https://github.com/someone/proj/pull/5" > "${work}/prs/detached"
echo "OPEN https://github.com/someone/proj/pull/6" > "${work}/prs/hidden"
echo "OPEN https://github.com/someone/outer/pull/7" > "${work}/prs/outer"

# A run in each directory that holds an open pull request, once per pull
# request, despite a failure.
: > "${work}/runs.log"
if output="$(CDPATH='' cd -- "${scan}" && "${CRREVIEW_RESOLVE_ALL}" --agent codex < /dev/null 2>&1)"; then
  fail "the exit status is 0 although a crreview-resolve run failed"
fi
expected="proj-branch-feature --agent codex
proj-branch-other-fails --agent codex
proj-branch-wt --agent codex"
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
  *"crreview-resolve failed in:
proj-branch-other-fails"*) ;;
  *) fail "the output does not report the failed run: ${output}" ;;
esac

# -C, and no --agent.
rm -rf "${scan}/proj-branch-other-fails"
: > "${work}/runs.log"
if ! output="$("${CRREVIEW_RESOLVE_ALL}" -C "${scan}" 2>&1)"; then
  fail "the exit status is nonzero although every run succeeded: ${output}"
fi
expected="proj-branch-feature
proj-branch-wt"
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

# An unexpected failure of `gh` is reported, and does not stop the other runs.
echo "HTTP 502: Bad Gateway" > "${work}/gh-error"
: > "${work}/runs.log"
if output="$("${CRREVIEW_RESOLVE_ALL}" -C "${scan}" 2>&1)"; then
  fail "the exit status is 0 although gh failed"
fi
case "${output}" in
  *"cannot find the pull request of proj:
HTTP 502: Bad Gateway"*) ;;
  *) fail "the output does not report the failure of gh: ${output}" ;;
esac
if [ "$(cat "${work}/runs.log")" != "${expected}" ]; then
  fail "after a failure of gh, the runs are:
$(cat "${work}/runs.log")
not:
${expected}"
fi
rm -f "${work}/gh-error"

# A usage error.
"${CRREVIEW_RESOLVE_ALL}" --agent gemini -C "${scan}" > /dev/null 2>&1
if [ "$?" -ne 2 ]; then
  fail "the exit status for an unknown agent is not 2"
fi

exit "${status}"
