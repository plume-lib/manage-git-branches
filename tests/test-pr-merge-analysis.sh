#!/bin/sh

# Tests `pr-merge-analysis`:  its report of conflicts and containment, its
# cache, when it prunes the cache and the PR refs, how it handles failures of
# git, and how it handles its arguments.
#
# Usage:
#   tests/test-pr-merge-analysis.sh
#
# A stub `git` fetches from a local repository in place of GitHub, and fails
# or warns on request.  The test passes PR numbers, so `gh` is not run.
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(CDPATH='' cd -- "${TESTS_DIR}/.." && pwd -P)" || exit 1
ANALYSIS="${COMMANDS_DIR}/pr-merge-analysis"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${WORK_DIR}"' EXIT
trap 'rm -rf "${WORK_DIR}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${WORK_DIR}"; trap - TERM; kill -s TERM "$$"' TERM

# shellcheck source=lib-git-test-env.sh
. "${TESTS_DIR}/lib-git-test-env.sh"
sanitize_git_env "${WORK_DIR}"

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

# `pr-merge-analysis` needs Bash 4 or later as the first "bash" on the PATH.
# With an older Bash, check only that it says so.
if [ "$(bash -c 'echo "${BASH_VERSINFO[0]}"')" -lt 4 ]; then
  if output="$("${ANALYSIS}" dir owner/repo 1 2>&1)"; then
    fail "old Bash: pr-merge-analysis succeeded"
  fi
  case "${output}" in
    *"needs Bash 4 or later"*) ;;
    *) fail "old Bash: wrong diagnostic: ${output}" ;;
  esac
  echo "${SCRIPT_NAME}: Bash is older than 4, so only the version check was tested"
  exit 0
fi

## The stub git replaces a GitHub URL by ${STUB_REMOTE}.  If ${STUB_GIT_FAIL}
## is "merge-tree" or "rev-list", that subcommand fails; if it is "warn",
## "merge-tree" prints a warning before it runs.
REAL_GIT="$(command -v git)"
export REAL_GIT
STUB_REMOTE="${WORK_DIR}/remote.git"
export STUB_REMOTE
mkdir "${WORK_DIR}/test-bin"
cat > "${WORK_DIR}/test-bin/git" << 'EOF'
#!/bin/sh
for arg; do
  shift
  case "${arg}" in
    https://github.com/*) arg="${STUB_REMOTE}" ;;
  esac
  set -- "$@" "${arg}"
done
for arg; do
  case "${STUB_GIT_FAIL:-}:${arg}" in
    merge-tree:merge-tree)
      # Exit status 1, which git also uses for a conflict.
      echo "merge-tree: stub failure" >&2
      exit 1
      ;;
    rev-list:rev-list)
      echo "fatal: stub failure" >&2
      exit 128
      ;;
    warn:merge-tree)
      echo "warning: stub warning" >&2
      ;;
  esac
done
exec "${REAL_GIT}" "$@"
EOF
chmod +x "${WORK_DIR}/test-bin/git"

## The remote repository's default branch, "main", and its pull requests:
##  * 1 and 2 change f.txt differently, so they conflict with each other.
##  * 3 is 1 plus a commit, so it contains 1 and conflicts with 2.
##  * 4 changes m.txt, which main also changes afterward, so it conflicts
##    with main.
seed="${WORK_DIR}/seed"
git init -q -b main "${seed}"
printf '%s\n' base > "${seed}/f.txt"
printf '%s\n' base > "${seed}/m.txt"
git -C "${seed}" add f.txt m.txt
git -C "${seed}" commit -q -m "Initial commit"
git init -q --bare -b main "${STUB_REMOTE}"
## Usage: commit_pr N BASE FILE CONTENT
## Commits CONTENT to FILE on top of BASE, and pushes the result as PR N.
commit_pr() {
  git -C "${seed}" checkout -q --detach "$2"
  printf '%s\n' "$4" > "${seed}/$3"
  git -C "${seed}" add "$3"
  git -C "${seed}" commit -q -m "PR $1"
  git -C "${seed}" push -q "${STUB_REMOTE}" "HEAD:refs/pull/$1/head"
}
commit_pr 1 main f.txt one
commit_pr 2 main f.txt two
commit_pr 3 "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/1/head)" g.txt three
commit_pr 4 main m.txt four
git -C "${seed}" checkout -q main
printf '%s\n' main > "${seed}/m.txt"
git -C "${seed}" commit -q -a -m "Change main"
git -C "${seed}" push -q "${STUB_REMOTE}" main

# A clone whose name contains a space.
clone="${WORK_DIR}/my clone"
git clone -q "${STUB_REMOTE}" "${clone}"
run_dir="${WORK_DIR}/run"
mkdir "${run_dir}"
cache="${run_dir}/.pr-merge-analysis-cache.tsv"

expected='## master conflicts
4: m.txt
## containment (A contains all non-merge commits of B)
3 contains 1
## pairwise conflicts
1 vs 2: f.txt
2 vs 3: f.txt'

## Usage: analyze STUB_GIT_FAIL ARGUMENT...
## Runs `pr-merge-analysis ARGUMENT... "${clone}" test/repo` with the stub
## git, in ${run_dir}, with PR numbers ${prs}.  STUB_GIT_FAIL, which can be
## empty, is the stub git's ${STUB_GIT_FAIL}.  Sets ${analysis_status} and
## ${analysis_output}.
##
## STUB_GIT_FAIL is an argument, rather than an assignment before the call,
## because POSIX does not say whether an assignment before a call of a
## function persists after the function returns.
prs='1 2 3 4'
analyze() {
  analyze_stub_git_fail="$1"
  shift
  # shellcheck disable=SC2086 # ${prs} is several words.
  if analysis_output="$(cd "${run_dir}" && PATH="${WORK_DIR}/test-bin:${PATH}" \
    STUB_GIT_FAIL="${analyze_stub_git_fail}" \
    "${ANALYSIS}" "$@" "${clone}" test/repo ${prs} 2>&1)"; then
    analysis_status=0
  else
    analysis_status=$?
  fi
}

## The report, in a clone whose name contains a space.  Without
## --default-branch, the run compares against the remote's default branch,
## "main".
analyze '' --prune
if [ "${analysis_status}" -ne 0 ]; then
  fail "report: pr-merge-analysis failed: ${analysis_output}"
fi
if [ "${analysis_output}" != "${expected}" ]; then
  fail "report: expected [${expected}], got [${analysis_output}]"
fi

## A second run uses the cache:  it runs no merge-tree, so a failing one does
## not matter.  It names the default branch explicitly.
analyze merge-tree --default-branch main --prune
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected}" ]; then
  fail "cache: the second run did not use the cache: ${analysis_output}"
fi

## Another repository's cache lines are not used, and pruning keeps them.  The
## other repository's lines are those of test/repo, relabeled; a run of
## test/repo that uses them would run no merge-tree, but this run must run
## merge-tree, so a failing one is an error.
sed 's|^test/repo	|other/repo	|' "${cache}" > "${cache}.edited"
mv "${cache}.edited" "${cache}"
other_lines="$(cat "${cache}")"
analyze merge-tree --prune
if [ "${analysis_status}" -eq 0 ]; then
  fail "other repository: a run used its cache lines: ${analysis_output}"
fi
case "${analysis_output}" in
  *"merge-tree: stub failure"*) ;;
  *) fail "other repository: wrong diagnostic: ${analysis_output}" ;;
esac
analyze '' --prune
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected}" ]; then
  fail "other repository: wrong report: ${analysis_output}"
fi
if [ "$(grep '^other/repo	' "${cache}")" != "${other_lines}" ]; then
  fail "other repository: pruning changed its cache lines: $(cat "${cache}")"
fi
grep -v '^other/repo	' "${cache}" > "${cache}.edited"
mv "${cache}.edited" "${cache}"

## A PR number that is given twice is reported once.
prs='4 4 3 1 2'
analyze '' --prune
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected}" ]; then
  fail "duplicates: wrong report: ${analysis_output}"
fi

## An argument that is not a PR number is an error.
prs='1 #2'
analyze '' --prune
if [ "${analysis_status}" -eq 0 ]; then
  fail "not a number: pr-merge-analysis succeeded: ${analysis_output}"
fi
case "${analysis_output}" in
  *"not a pull request number: #2"*) ;;
  *) fail "not a number: wrong diagnostic: ${analysis_output}" ;;
esac

## A run on only some PRs, without --prune, keeps the other PRs' cache lines.
sha2="$(git -C "${STUB_REMOTE}" rev-parse refs/pull/2/head)"
prs='1'
analyze ''
if [ "${analysis_status}" -ne 0 ]; then
  fail "partial: pr-merge-analysis failed: ${analysis_output}"
fi
if ! grep -q "${sha2}" "${cache}"; then
  fail "partial: a run without --prune pruned PR 2's cache lines"
fi
if ! git -C "${clone}" rev-parse -q --verify refs/remotes/pr/2 > /dev/null; then
  fail "partial: a run without --prune deleted PR 2's ref"
fi

## With --prune, the run removes the lines about other PRs' commits, and the
## other PRs' refs.  It keeps the cache's permissions.
chmod 664 "${cache}"
analyze '' --prune
if [ "${analysis_status}" -ne 0 ]; then
  fail "prune: pr-merge-analysis failed: ${analysis_output}"
fi
if grep -q "${sha2}" "${cache}"; then
  fail "prune: a run with --prune kept PR 2's cache lines"
fi
if git -C "${clone}" rev-parse -q --verify refs/remotes/pr/2 > /dev/null; then
  fail "prune: a run with --prune kept PR 2's ref"
fi
if ! git -C "${clone}" rev-parse -q --verify refs/remotes/pr/1 > /dev/null; then
  fail "prune: a run with --prune deleted PR 1's ref"
fi
# shellcheck disable=SC2012 # POSIX has no portable "stat"; the file name is known.
cache_mode="$(ls -l "${cache}" | cut -c 1-10)"
if [ "${cache_mode}" != "-rw-rw-r--" ]; then
  fail "prune: the cache's permissions changed to ${cache_mode}"
fi
prs='1 2 3 4'

## Pruning a cache that ${PR_MERGE_ANALYSIS_CACHE} names through a symbolic
## link replaces the link's target, not the link.
mv "${cache}" "${cache}.target"
ln -s "$(basename -- "${cache}").target" "${cache}"
PR_MERGE_ANALYSIS_CACHE="${cache}"
export PR_MERGE_ANALYSIS_CACHE
analyze '' --prune
unset PR_MERGE_ANALYSIS_CACHE
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected}" ]; then
  fail "symbolic link: wrong report: ${analysis_output}"
fi
if [ ! -L "${cache}" ]; then
  fail "symbolic link: pruning replaced the link"
fi
if ! grep -q "${sha2}" "${cache}.target"; then
  fail "symbolic link: the link's target lacks PR 2's cache lines"
fi
rm "${cache}"
mv "${cache}.target" "${cache}"

## A malformed cache line, such as one that another run is still writing, is
## ignored, and pruning removes it.  Here, the line about PRs 1 and 2 is
## truncated within "conflict", and is the only line about them.
pair="$(git -C "${STUB_REMOTE}" rev-parse refs/pull/1/head refs/pull/2/head | sort | tr '\n' '\t')"
grep -v "^test/repo	merge	${pair}" "${cache}" > "${cache}.edited"
printf 'test/repo\tmerge\t%sconfl\n' "${pair}" >> "${cache}.edited"
mv "${cache}.edited" "${cache}"
analyze '' --prune
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected}" ]; then
  fail "malformed: wrong report: ${analysis_output}"
fi
if grep -q "confl$" "${cache}"; then
  fail "malformed: pruning kept a malformed line: $(cat "${cache}")"
fi

## A last line that lacks its newline, such as one that another run is still
## writing, is ignored even if its fields are well-formed, and pruning removes
## it.  Here, this repository's line about PRs 1 and 2 is truncated within its
## file name, "f.txt"; a run that used it would report "1 vs 2: f.tx".  The
## other repository's line is truncated likewise.  Pruning leaves the lines of
## a complete run.
complete_cache="$(sort "${cache}")"
grep -v "^test/repo	merge	${pair}" "${cache}" > "${cache}.edited"
printf 'test/repo\tmerge\t%sconflict\tf.tx' "${pair}" >> "${cache}.edited"
mv "${cache}.edited" "${cache}"
analyze '' --prune
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected}" ]; then
  fail "unterminated: wrong report: ${analysis_output}"
fi
if [ "$(sort "${cache}")" != "${complete_cache}" ]; then
  fail "unterminated: wrong cache after pruning: $(cat "${cache}")"
fi
printf 'other/repo\tmerge\t%sconflict\tsrc/Fo' "${pair}" >> "${cache}"
analyze merge-tree --prune
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected}" ]; then
  fail "unterminated other repository: wrong report: ${analysis_output}"
fi
if [ "$(sort "${cache}")" != "${complete_cache}" ]; then
  fail "unterminated other repository: pruning kept the line: $(cat "${cache}")"
fi

## A warning from merge-tree does not change the report.
: > "${cache}"
analyze warn --prune
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected}" ]; then
  fail "warning: wrong report: ${analysis_output}"
fi

## A failure of merge-tree is an error, and is not cached as a conflict.
: > "${cache}"
analyze merge-tree --prune
if [ "${analysis_status}" -eq 0 ]; then
  fail "merge-tree failure: pr-merge-analysis succeeded: ${analysis_output}"
fi
if grep -q conflict "${cache}"; then
  fail "merge-tree failure: cached a conflict: $(cat "${cache}")"
fi

## A failure of rev-list is an error, and is not cached as a containment
## result.
: > "${cache}"
analyze rev-list --prune
if [ "${analysis_status}" -eq 0 ]; then
  fail "rev-list failure: pr-merge-analysis succeeded: ${analysis_output}"
fi
if grep -q '	contains	' "${cache}"; then
  fail "rev-list failure: cached a containment result: $(cat "${cache}")"
fi

## No run leaves a temporary file behind.
leftovers="$(find "${run_dir}" -name '.pr-merge-analysis-cache.tsv.*')"
if [ -n "${leftovers}" ]; then
  fail "temporary files remain: ${leftovers}"
fi

## An option that lacks its value is a usage error.  If the command
## "timeout" exists, it stops a run that loops rather than reporting the error.
timeout_command=''
if command -v timeout > /dev/null 2>&1; then timeout_command='timeout 10'; fi
# shellcheck disable=SC2086 # ${timeout_command} is zero or two words.
if output="$(${timeout_command} "${ANALYSIS}" --default-branch 2>&1)"; then
  fail "missing value: pr-merge-analysis succeeded"
fi
case "${output}" in
  usage:*) ;;
  *) fail "missing value: wrong diagnostic: ${output}" ;;
esac

echo "${SCRIPT_NAME}: all tests passed"
