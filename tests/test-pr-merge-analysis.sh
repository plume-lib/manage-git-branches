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

# `pr-merge-analysis` needs Bash 4.4 or later as the first "bash" on the PATH.
# With an older Bash, check only that it says so.
if [ "$(bash -c 'echo $((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1]))')" -lt 404 ]; then
  if output="$("${ANALYSIS}" dir owner/repo 1 2>&1)"; then
    fail "old Bash: pr-merge-analysis succeeded"
  fi
  case "${output}" in
    *"needs Bash 4.4 or later"*) ;;
    *) fail "old Bash: wrong diagnostic: ${output}" ;;
  esac
  echo "${SCRIPT_NAME}: Bash is older than 4.4, so only the version check was tested"
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
## containment (A contains all non-merge commits of B, and B'"'"'s changes)
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
if grep -q '	contains	\|	net-changes	' "${cache}"; then
  fail "rev-list failure: cached a containment result: $(cat "${cache}")"
fi

## A PR whose branch contains another PR's commits but not its changes does not
## contain the other PR.  PR 5 is PR 1 plus a commit that reverts PR 1's
## change, as when a branch merges another PR's branch and then removes that
## PR's changes.  PR 6 is PR 1 plus a commit that changes PR 1's file further,
## so it might build on PR 1's change, and it contains PR 1.
pr1="$(git -C "${STUB_REMOTE}" rev-parse refs/pull/1/head)"
commit_pr 5 "${pr1}" f.txt base
commit_pr 6 "${pr1}" f.txt six
prs='1 5 6'
: > "${cache}"
analyze '' --prune
expected_reverted="## master conflicts
## containment (A contains all non-merge commits of B, and B's changes)
6 contains 1
## pairwise conflicts
5 vs 6: f.txt"
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_reverted}" ]; then
  fail "reverted changes: expected [${expected_reverted}], got [${analysis_output}]"
fi
## The second run uses the cache, and gives the same report.
analyze rev-list --prune
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_reverted}" ]; then
  fail "reverted changes: the second run did not use the cache: ${analysis_output}"
fi

## A PR's changes are those of its own commits, not those of a PR that its
## branch was created from.  The PRs merge whole branches, and their merge
## bases with main differ, so that a comparison with main would differ from a
## comparison with a merge base.
##  * 7 is stacked on 1:  it is 1 plus a commit that adds b.txt.
##  * 8 starts from main, merges 7, and deletes b.txt, which reverts 7's own
##    change but keeps 1's.  So 8 contains 1 but not 7.
##  * 9 starts from main and merges 7.  So 9 contains 1 and 7.  Its non-merge
##    commits are the same as 7's, so 7 also contains 9, and 9's commits do not
##    make 7's own commits empty.
##  * 10 starts from the initial commit, merges 4, which changes m.txt, and
##    restores m.txt.  So 10 does not contain 4, although 10's m.txt differs
##    from main's.
commit_pr 7 "${pr1}" b.txt seven
pr7="$(git -C "${STUB_REMOTE}" rev-parse refs/pull/7/head)"
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 8: merge PR 7" "${pr7}"
git -C "${seed}" rm -q b.txt
git -C "${seed}" commit -q -m "PR 8"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/8/head
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 9: merge PR 7" "${pr7}"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/9/head
git -C "${seed}" checkout -q --detach main~1
git -C "${seed}" merge -q --no-ff -m "PR 10: merge PR 4" \
  "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/4/head)"
commit_pr 10 HEAD m.txt base
git -C "${seed}" checkout -q main
prs='1 4 7 8 9 10'
: > "${cache}"
analyze '' --prune
expected_stacked="## master conflicts
4: m.txt
## containment (A contains all non-merge commits of B, and B's changes)
7 contains 1
7 contains 9
8 contains 1
9 contains 1
9 contains 7
## pairwise conflicts
4 vs 8: m.txt
4 vs 9: m.txt"
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_stacked}" ]; then
  fail "stacked PRs: expected [${expected_stacked}], got [${analysis_output}]"
fi
## Pruning keeps the cached results for the current commits.
if ! grep -q '	net-changes	' "${cache}"; then
  fail "stacked PRs: pruning removed the cached changes results: $(cat "${cache}")"
fi
## The second run uses the cache, and gives the same report.
analyze rev-list --prune
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_stacked}" ]; then
  fail "stacked PRs: the second run did not use the cache: ${analysis_output}"
fi

## A PR's changes are those that its own commits still make, not those that a
## later own commit undid.
##  * 11 starts from main, adds c.txt and h.txt, and then removes h.txt, as when
##    a change moves to another PR.  So 11 changes only c.txt.
##  * 12 starts from main, merges 11, removes c.txt, which reverts 11's change,
##    and adds its own h.txt.  So 12 does not contain 11, although 12's h.txt
##    differs from main's.
##  * 13 starts from main, adds e.txt, and then removes it.  So 13 changes
##    nothing.
##  * 14 starts from main, merges 13, and adds its own e.txt.  So 14 does not
##    contain 13, because 13 changes nothing.
git -C "${seed}" checkout -q --detach main
printf '%s\n' eleven > "${seed}/c.txt"
printf '%s\n' eleven > "${seed}/h.txt"
git -C "${seed}" add c.txt h.txt
git -C "${seed}" commit -q -m "PR 11"
git -C "${seed}" rm -q h.txt
git -C "${seed}" commit -q -m "PR 11: move h.txt to another PR"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/11/head
pr11="$(git -C "${STUB_REMOTE}" rev-parse refs/pull/11/head)"
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 12: merge PR 11" "${pr11}"
git -C "${seed}" rm -q c.txt
printf '%s\n' twelve > "${seed}/h.txt"
git -C "${seed}" add h.txt
git -C "${seed}" commit -q -m "PR 12"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/12/head
commit_pr 13 main e.txt thirteen
git -C "${seed}" rm -q e.txt
git -C "${seed}" commit -q -m "PR 13: move e.txt to another PR"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/13/head
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 14: merge PR 13" \
  "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/13/head)"
commit_pr 14 HEAD e.txt fourteen
git -C "${seed}" checkout -q main
prs='11 12 13 14'
: > "${cache}"
analyze '' --prune
expected_undone="## master conflicts
## containment (A contains all non-merge commits of B, and B's changes)
## pairwise conflicts"
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_undone}" ]; then
  fail "undone own change: expected [${expected_undone}], got [${analysis_output}]"
fi

## A stacked PR's changes are those that its own commits still make, compared
## with the PR that it is stacked on, not with main.
##  * 15 starts from main and adds s.txt.
##  * 16 is stacked on 15:  it changes s.txt, adds t.txt, and then restores
##    15's s.txt.  So 16 changes only t.txt, although its s.txt differs from
##    main's.
##  * 17 starts from main, merges 16, and removes t.txt, which reverts 16's
##    change.  So 17 contains 15 but not 16.
##  * 18 is stacked on 15:  it removes s.txt, which reverts 15's change.  So 18
##    changes s.txt, although its s.txt is the same as main's.  18 does not
##    contain 15.
##  * 19 starts from main, merges 18, and changes s.txt further.  So 19
##    contains 15 and 18.
##  * 20 starts from main, merges 18, and adds u.txt.  Its s.txt is main's, so
##    its diff against main contains nothing of 15 or 18, and 20 contains
##    neither.
##  * 21 is stacked on 15:  it changes s.txt.
##  * 22 starts from main, merges 21, and restores 15's s.txt, which reverts
##    21's change but keeps 15's.  So 22 contains 15 but not 21.
commit_pr 15 main s.txt fifteen
pr15="$(git -C "${STUB_REMOTE}" rev-parse refs/pull/15/head)"
commit_pr 16 "${pr15}" s.txt sixteen
printf '%s\n' sixteen > "${seed}/t.txt"
printf '%s\n' fifteen > "${seed}/s.txt"
git -C "${seed}" add s.txt t.txt
git -C "${seed}" commit -q -m "PR 16: restore s.txt"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/16/head
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 17: merge PR 16" \
  "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/16/head)"
git -C "${seed}" rm -q t.txt
git -C "${seed}" commit -q -m "PR 17"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/17/head
git -C "${seed}" checkout -q --detach "${pr15}"
git -C "${seed}" rm -q s.txt
git -C "${seed}" commit -q -m "PR 18"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/18/head
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 19: merge PR 18" \
  "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/18/head)"
commit_pr 19 HEAD s.txt nineteen
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 20: merge PR 18" \
  "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/18/head)"
commit_pr 20 HEAD u.txt twenty
commit_pr 21 "${pr15}" s.txt twentyone
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 22: merge PR 21" \
  "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/21/head)"
commit_pr 22 HEAD s.txt fifteen
git -C "${seed}" checkout -q main
prs='15 16 17 18 19 20 21 22'
: > "${cache}"
analyze '' --prune
expected_stacked_undone="## master conflicts
## containment (A contains all non-merge commits of B, and B's changes)
16 contains 15
17 contains 15
19 contains 15
19 contains 18
21 contains 15
22 contains 15
## pairwise conflicts
18 vs 21: s.txt
19 vs 21: s.txt
20 vs 21: s.txt"
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_stacked_undone}" ]; then
  fail "stacked undone own change: expected [${expected_stacked_undone}], got [${analysis_output}]"
fi

## A PR whose own commits start from more than one commit:  it is stacked on
## other PRs and merged a newer main.
##  * 23 starts from main and adds x.txt.
##  * 24 starts from main and adds y.txt.
##  * Then main changes n.txt.
##  * 25 starts from 23, merges 24 and main, adds q.txt, changes x.txt, and then
##    restores 23's x.txt.  Its own commits start from the merge of 23, 24, and
##    main.  So 25 changes only q.txt.
##  * 26 starts from main, merges 25, and removes q.txt, which reverts 25's
##    change.  So 26 contains 23 and 24 but not 25.
commit_pr 23 main x.txt twentythree
pr23="$(git -C "${STUB_REMOTE}" rev-parse refs/pull/23/head)"
commit_pr 24 main y.txt twentyfour
pr24="$(git -C "${STUB_REMOTE}" rev-parse refs/pull/24/head)"
git -C "${seed}" checkout -q main
printf '%s\n' main > "${seed}/n.txt"
git -C "${seed}" add n.txt
git -C "${seed}" commit -q -m "Change main again"
git -C "${seed}" push -q "${STUB_REMOTE}" main
git -C "${seed}" checkout -q --detach "${pr23}"
git -C "${seed}" merge -q --no-ff -m "PR 25: merge PR 24" "${pr24}"
git -C "${seed}" merge -q --no-ff -m "PR 25: merge main" main
printf '%s\n' twentyfive > "${seed}/q.txt"
printf '%s\n' twentyfive > "${seed}/x.txt"
git -C "${seed}" add q.txt x.txt
git -C "${seed}" commit -q -m "PR 25"
printf '%s\n' twentythree > "${seed}/x.txt"
git -C "${seed}" commit -q -a -m "PR 25: restore x.txt"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/25/head
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 26: merge PR 25" \
  "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/25/head)"
git -C "${seed}" rm -q q.txt
git -C "${seed}" commit -q -m "PR 26"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/26/head
git -C "${seed}" checkout -q main
prs='23 24 25 26'
: > "${cache}"
analyze '' --prune
expected_starts="## master conflicts
## containment (A contains all non-merge commits of B, and B's changes)
25 contains 23
25 contains 24
26 contains 23
26 contains 24
## pairwise conflicts"
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_starts}" ]; then
  fail "several starts: expected [${expected_starts}], got [${analysis_output}]"
fi

## A PR whose own commits start from commits that conflict.  Then its changes
## include each file whose conflict markers it resolves, and they omit the
## other files that its own commits change back.
##  * 27 starts from main and changes k.txt.
##  * Then main changes k.txt differently.
##  * 28 starts from 27, merges main and resolves the conflict, changes k.txt
##    and then restores the resolution, adds r.txt, and adds and then removes
##    j.txt.  Its own commits start from 27 and main, which conflict on k.txt,
##    so 28 changes k.txt and r.txt.
##  * 29 starts from main, merges 28, removes r.txt, and changes k.txt further.
##    So 29 contains 28.
##  * 30 starts from main, merges 28, removes r.txt, restores main's k.txt, and
##    adds its own j.txt.  So 30 contains neither 27 nor 28.
commit_pr 27 main k.txt twentyseven
git -C "${seed}" checkout -q main
printf '%s\n' main > "${seed}/k.txt"
git -C "${seed}" add k.txt
git -C "${seed}" commit -q -m "Change main's k.txt"
git -C "${seed}" push -q "${STUB_REMOTE}" main
git -C "${seed}" checkout -q --detach "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/27/head)"
git -C "${seed}" merge -q -m "PR 28: merge main" main > /dev/null 2>&1 || true
printf '%s\n' resolved > "${seed}/k.txt"
git -C "${seed}" add k.txt
git -C "${seed}" commit -q --no-edit
printf '%s\n' twentyeight > "${seed}/k.txt"
printf '%s\n' twentyeight > "${seed}/r.txt"
printf '%s\n' twentyeight > "${seed}/j.txt"
git -C "${seed}" add k.txt r.txt j.txt
git -C "${seed}" commit -q -m "PR 28"
printf '%s\n' resolved > "${seed}/k.txt"
git -C "${seed}" rm -q j.txt
git -C "${seed}" commit -q -a -m "PR 28: restore k.txt, and move j.txt to another PR"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/28/head
pr28="$(git -C "${STUB_REMOTE}" rev-parse refs/pull/28/head)"
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 29: merge PR 28" "${pr28}"
git -C "${seed}" rm -q r.txt
commit_pr 29 HEAD k.txt twentynine
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 30: merge PR 28" "${pr28}"
git -C "${seed}" rm -q r.txt
printf '%s\n' main > "${seed}/k.txt"
git -C "${seed}" add k.txt
commit_pr 30 HEAD j.txt thirty
git -C "${seed}" checkout -q main
prs='27 28 29 30'
: > "${cache}"
analyze '' --prune
expected_conflicting_starts="## master conflicts
27: k.txt
## containment (A contains all non-merge commits of B, and B's changes)
28 contains 27
29 contains 27
29 contains 28
## pairwise conflicts
29 vs 30: k.txt"
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_conflicting_starts}" ]; then
  fail "conflicting starts: expected [${expected_conflicting_starts}], got [${analysis_output}]"
fi

## A branch that merged a PR and reverted its changes lacks them, even after
## the PR merged a newer main that changes the same file.
##  * Main adds l.txt.
##  * 31 starts from main and changes the first line of l.txt.
##  * 32 starts from main, merges 31, and reverts 31's change.
##  * Then main changes the last line of l.txt, and 31 merges main.  So 31's
##    own commits start from the newer main, which 32 lacks, and 32 does not
##    contain 31.
printf '%s\n' 1 2 3 4 5 > "${seed}/l.txt"
git -C "${seed}" add l.txt
git -C "${seed}" commit -q -m "Add l.txt to main"
git -C "${seed}" push -q "${STUB_REMOTE}" main
git -C "${seed}" checkout -q --detach main
printf '%s\n' thirtyone 2 3 4 5 > "${seed}/l.txt"
git -C "${seed}" commit -q -a -m "PR 31"
pr31_first="$(git -C "${seed}" rev-parse HEAD)"
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 32: merge PR 31" "${pr31_first}"
printf '%s\n' 1 2 3 4 5 > "${seed}/l.txt"
git -C "${seed}" commit -q -a -m "PR 32: revert PR 31"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/32/head
git -C "${seed}" checkout -q main
printf '%s\n' 1 2 3 4 main > "${seed}/l.txt"
git -C "${seed}" commit -q -a -m "Change main's l.txt"
git -C "${seed}" push -q "${STUB_REMOTE}" main
git -C "${seed}" checkout -q --detach "${pr31_first}"
git -C "${seed}" merge -q --no-ff -m "PR 31: merge main" main > /dev/null
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/31/head
git -C "${seed}" checkout -q main
prs='31 32'
: > "${cache}"
analyze '' --prune
expected_newer_main="## master conflicts
## containment (A contains all non-merge commits of B, and B's changes)
## pairwise conflicts"
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_newer_main}" ]; then
  fail "newer main: expected [${expected_newer_main}], got [${analysis_output}]"
fi

## A branch that reverted both a stacked PR and the PR that it is stacked on
## lacks both.
##  * 33 starts from main and adds z.txt.
##  * 34 is stacked on 33:  it changes z.txt.
##  * 35 starts from main, merges 34, and removes z.txt, which reverts 33's and
##    34's changes.  So 35 contains neither 33 nor 34.
commit_pr 33 main z.txt thirtythree
commit_pr 34 "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/33/head)" z.txt thirtyfour
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 35: merge PR 34" \
  "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/34/head)"
git -C "${seed}" rm -q z.txt
git -C "${seed}" commit -q -m "PR 35"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/35/head
git -C "${seed}" checkout -q main
prs='33 34 35'
: > "${cache}"
analyze '' --prune
expected_both_reverted="## master conflicts
## containment (A contains all non-merge commits of B, and B's changes)
34 contains 33
## pairwise conflicts"
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_both_reverted}" ]; then
  fail "both reverted: expected [${expected_both_reverted}], got [${analysis_output}]"
fi

## A PR's changes include the conflicts that its merges resolve.
##  * 36 starts from main and adds aa.txt.
##  * 37 starts from main and adds a different aa.txt.
##  * 38 starts from main, merges 36 and 37, and resolves their conflict.  It
##    also adds and then removes g.txt.  So its own commits change nothing, but
##    it changes aa.txt.
##  * 39 starts from main, merges 38, and adds cc.txt.  So 39 contains 36, 37,
##    and 38.
commit_pr 36 main aa.txt thirtysix
commit_pr 37 main aa.txt thirtyseven
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 38: merge PR 36" \
  "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/36/head)"
git -C "${seed}" merge -q --no-ff -m "PR 38: merge PR 37" \
  "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/37/head)" > /dev/null 2>&1 || true
printf '%s\n' resolved > "${seed}/aa.txt"
git -C "${seed}" add aa.txt
git -C "${seed}" commit -q --no-edit
printf '%s\n' thirtyeight > "${seed}/g.txt"
git -C "${seed}" add g.txt
git -C "${seed}" commit -q -m "PR 38"
git -C "${seed}" rm -q g.txt
git -C "${seed}" commit -q -m "PR 38: move g.txt to another PR"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/38/head
commit_pr 39 HEAD cc.txt thirtynine
git -C "${seed}" checkout -q main
prs='36 37 38 39'
: > "${cache}"
analyze '' --prune
expected_resolution="## master conflicts
## containment (A contains all non-merge commits of B, and B's changes)
38 contains 36
38 contains 37
39 contains 36
39 contains 37
39 contains 38
## pairwise conflicts
36 vs 37: aa.txt"
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_resolution}" ]; then
  fail "resolution: expected [${expected_resolution}], got [${analysis_output}]"
fi

## A PR that resolves a conflict by keeping one side's version does not change
## the file for a branch that merges it, because that branch has the same
## version at one of its merge bases.  The conflict is a text conflict, which
## leaves conflict markers, or a modify/delete conflict, which does not.
##  * 40 starts from main and adds p.txt.
##  * Then main adds a different p.txt.
##  * 41 is stacked on 40:  it merges main, resolves the conflict by keeping
##    40's p.txt, and adds q2.txt.
##  * 42 starts from main, merges 41, and removes q2.txt.  So 42 contains 40,
##    whose p.txt it has, but not 41.
##  * Main adds d.txt.
##  * 46 starts from main and removes d.txt.
##  * Then main changes d.txt.
##  * 47 is stacked on 46:  it merges main, resolves the conflict by removing
##    d.txt, and adds q3.txt.
##  * 48 starts from main, merges 47, and removes q3.txt.  So 48 contains 46,
##    whose removal of d.txt it has, but not 47.
commit_pr 40 main p.txt forty
git -C "${seed}" checkout -q main
printf '%s\n' main > "${seed}/p.txt"
git -C "${seed}" add p.txt
git -C "${seed}" commit -q -m "Add p.txt to main"
git -C "${seed}" push -q "${STUB_REMOTE}" main
git -C "${seed}" checkout -q --detach "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/40/head)"
git -C "${seed}" merge -q -m "PR 41: merge main" main > /dev/null 2>&1 || true
printf '%s\n' forty > "${seed}/p.txt"
git -C "${seed}" add p.txt
git -C "${seed}" commit -q --no-edit
commit_pr 41 HEAD q2.txt fortyone
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 42: merge PR 41" \
  "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/41/head)"
git -C "${seed}" rm -q q2.txt
git -C "${seed}" commit -q -m "PR 42"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/42/head
git -C "${seed}" checkout -q main
printf '%s\n' main > "${seed}/d.txt"
git -C "${seed}" add d.txt
git -C "${seed}" commit -q -m "Add d.txt to main"
git -C "${seed}" push -q "${STUB_REMOTE}" main
git -C "${seed}" checkout -q --detach main
git -C "${seed}" rm -q d.txt
git -C "${seed}" commit -q -m "PR 46"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/46/head
git -C "${seed}" checkout -q main
printf '%s\n' main2 > "${seed}/d.txt"
git -C "${seed}" commit -q -a -m "Change main's d.txt"
git -C "${seed}" push -q "${STUB_REMOTE}" main
git -C "${seed}" checkout -q --detach "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/46/head)"
git -C "${seed}" merge -q -m "PR 47: merge main" main > /dev/null 2>&1 || true
git -C "${seed}" rm -q d.txt
git -C "${seed}" commit -q --no-edit
commit_pr 47 HEAD q3.txt fortyseven
git -C "${seed}" checkout -q --detach main
git -C "${seed}" merge -q --no-ff -m "PR 48: merge PR 47" \
  "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/47/head)"
git -C "${seed}" rm -q q3.txt
git -C "${seed}" commit -q -m "PR 48"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/48/head
git -C "${seed}" checkout -q main
prs='40 41 42 46 47 48'
: > "${cache}"
analyze '' --prune
expected_one_side="## master conflicts
40: p.txt
46: d.txt
## containment (A contains all non-merge commits of B, and B's changes)
41 contains 40
42 contains 40
47 contains 46
48 contains 46
## pairwise conflicts
40 vs 46: p.txt
40 vs 47: p.txt
40 vs 48: p.txt"
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_one_side}" ]; then
  fail "one side: expected [${expected_one_side}], got [${analysis_output}]"
fi

## A branch that is stacked on a PR, merged another PR, and reverted that PR's
## change has only the first PR's version, so it lacks the other PR's change.
##  * 43 starts from main and changes the last line of l.txt.
##  * 44 starts from main and changes the first line of l.txt.
##  * 45 is stacked on 43:  it merges 44 and then reverts 44's change.  So 45
##    contains 43 but not 44.
git -C "${seed}" checkout -q --detach main
printf '%s\n' 1 2 3 4 fortythree > "${seed}/l.txt"
git -C "${seed}" commit -q -a -m "PR 43"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/43/head
git -C "${seed}" checkout -q --detach main
printf '%s\n' fortyfour 2 3 4 main > "${seed}/l.txt"
git -C "${seed}" commit -q -a -m "PR 44"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/44/head
git -C "${seed}" checkout -q --detach "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/43/head)"
git -C "${seed}" merge -q --no-ff -m "PR 45: merge PR 44" \
  "$(git -C "${STUB_REMOTE}" rev-parse refs/pull/44/head)" > /dev/null
printf '%s\n' 1 2 3 4 fortythree > "${seed}/l.txt"
git -C "${seed}" commit -q -a -m "PR 45: revert PR 44"
git -C "${seed}" push -q "${STUB_REMOTE}" HEAD:refs/pull/45/head
git -C "${seed}" checkout -q main
prs='43 44 45'
: > "${cache}"
analyze '' --prune
expected_stacked_revert="## master conflicts
## containment (A contains all non-merge commits of B, and B's changes)
45 contains 43
## pairwise conflicts"
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_stacked_revert}" ]; then
  fail "stacked revert: expected [${expected_stacked_revert}], got [${analysis_output}]"
fi
## The conflicting files are listed by name as it is, except that a control
## character, such as a tab, becomes "?".
##  * Main adds "a b.txt", "c<TAB>d.txt", and "déjà.txt".
##  * 49 and 50 start from main and change those files differently.
git -C "${seed}" checkout -q main
for name in 'a b.txt' "c$(printf '\t')d.txt" 'déjà.txt'; do
  printf '%s\n' main > "${seed}/${name}"
done
git -C "${seed}" add -A
git -C "${seed}" commit -q -m "Add files with unusual names to main"
git -C "${seed}" push -q "${STUB_REMOTE}" main
for n in 49 50; do
  git -C "${seed}" checkout -q --detach main
  for name in 'a b.txt' "c$(printf '\t')d.txt" 'déjà.txt'; do
    printf '%s\n' "${n}" > "${seed}/${name}"
  done
  git -C "${seed}" commit -q -a -m "PR ${n}"
  git -C "${seed}" push -q "${STUB_REMOTE}" "HEAD:refs/pull/${n}/head"
done
git -C "${seed}" checkout -q main
prs='49 50'
: > "${cache}"
analyze '' --prune
expected_names="## master conflicts
## containment (A contains all non-merge commits of B, and B's changes)
## pairwise conflicts
49 vs 50: a b.txt c?d.txt déjà.txt"
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_names}" ]; then
  fail "names: expected [${expected_names}], got [${analysis_output}]"
fi
## The second run uses the cache, and gives the same report.
analyze merge-tree --prune
if [ "${analysis_status}" -ne 0 ] || [ "${analysis_output}" != "${expected_names}" ]; then
  fail "names: the second run did not use the cache: ${analysis_output}"
fi
prs='1 2 3 4'

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
