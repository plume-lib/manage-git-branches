#!/bin/sh

# Tests that `git-orphaned-branches` warns about, and does not list or remove,
# a directory whose branch still exists in the remote but whose GitHub pull
# requests are all closed or merged.
#
# Usage:
#   tests/test-git-orphaned-branches-closed-prs.sh
#
# The status code is 0 if all the tests pass, and nonzero otherwise.
#
# A fake `gh` stands in for GitHub, and `url.BASE.insteadOf` maps the
# remote's GitHub URL to a local repository, so the test needs no network.

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
GIT_ORPHANED_BRANCHES="${TESTS_DIR}/../git-orphaned-branches"

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

# The fake `gh`.  `gh repo view` prints the base repository, which is
# ${FAKE_GH_PARENT} or, if that is empty, the repository itself, and the
# default branch, ${FAKE_GH_DEFAULT} or "main"; `gh api graphql` prints
# ${FAKE_GH_PRS}, and
# any other `gh api` prints ${FAKE_GH_REST}, the lines that the real `gh`
# would print after applying the `--jq` filter.  All fail if ${FAKE_GH_FAIL}
# is non-empty.  Each call's arguments are appended to ${work}/gh.log.  The
# test of an option among the arguments is literal, but enough for the calls
# that git-orphaned-branches makes.
mkdir -p "${work}/bin"
cat > "${work}/bin/gh" << EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${work}/gh.log"
if [ -n "\${FAKE_GH_FAIL}" ]; then exit 1; fi
case "\$1 \$2" in
  'repo view') printf '%s %s\n' "\${FAKE_GH_PARENT:-someone/proj}" "\${FAKE_GH_DEFAULT:-main}" ;;
  'api graphql') if [ -n "\${FAKE_GH_PRS}" ]; then printf '%s\n' "\${FAKE_GH_PRS}"; fi ;;
  'api -X') if [ -n "\${FAKE_GH_REST}" ]; then printf '%s\n' "\${FAKE_GH_REST}"; fi ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${work}/bin/gh"
PATH="${work}/bin:${PATH}"
export PATH

git init -q --bare -b main "${work}/remote.git"
git config --global "url.${work}/remote.git.insteadOf" 'https://github.com/someone/proj'
git clone -q "${work}/remote.git" "${work}/seed" 2> /dev/null
echo "hello" > "${work}/seed/file.txt"
git -C "${work}/seed" add file.txt
git -C "${work}/seed" commit -q -m "Initial commit"
git -C "${work}/seed" push -q origin main main:refs/heads/feature main:refs/heads/feature2

mkdir -p "${work}/scan"
dir="${work}/scan/proj-branch-feature"
git clone -q -b feature 'https://github.com/someone/proj' "${dir}"
if [ "$(git -C "${dir}" config --get remote.origin.url)" != 'https://github.com/someone/proj' ]; then
  fail "the clone's configured URL is not the GitHub URL"
fi

# Prints the lines of ${FAKE_GH_PRS} for the branch whose GraphQL alias is
# $1:  one "ALIAS MORE STATE NUMBER HEAD" for each "STATE NUMBER HEAD"
# argument after $2, followed by "ALIAS MORE END", where MORE is $2.
prs() {
  prs_alias="$1"
  prs_more="$2"
  shift 2
  for prs_pr in "$@"; do
    printf '%s %s %s\n' "${prs_alias}" "${prs_more}" "${prs_pr}"
  done
  printf '%s %s END\n' "${prs_alias}" "${prs_more}"
}

# Usage: scan [FAKE_GH_NAME=VALUE]... [ARGUMENT]...
# Runs git-orphaned-branches in ${work}/scan with the ARGUMENTs and with the
# environment variables FAKE_GH_NAME set, putting its standard output in
# ${out} and its standard error in ${err}.  The variables are arguments,
# not assignments that precede the call, because some shells, such as bash in
# POSIX mode, which is /bin/sh on macOS, keep such assignments after a
# function returns.
scan() {
  out="$(scan_run "$@")"
  scan_status=$?
  err="$(cat "${work}/err")"
}

# Usage: scan_run [FAKE_GH_NAME=VALUE]... [ARGUMENT]...
# A helper for `scan`, which runs it in a subshell, so that the variables that
# it exports do not outlive the scan:  does the work of `scan`, except that it
# prints the standard output, and writes the standard error to ${work}/err.
# This is a function, rather than code in the command substitution of `scan`,
# because bash 3.2, which is /bin/sh on macOS, ends a command substitution at
# the ")" of a `case` pattern within it.
scan_run() {
  cd "${work}/scan" || return 1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      FAKE_GH_*=*)
        # shellcheck disable=SC2163 # $1 is NAME=VALUE, not a name.
        export "$1"
        shift
        ;;
      *) break ;;
    esac
  done
  "${GIT_ORPHANED_BRANCHES}" "$@" 2> "${work}/err"
}

# Every pull request is closed or merged:  a warning, and nothing listed.
scan FAKE_GH_PARENT='upstream/proj' FAKE_GH_PRS="$(prs b0 false 'CLOSED 7 someone/proj' 'MERGED 9 upstream/proj')"
[ "${scan_status}" -eq 0 ] || fail "status ${scan_status} with closed pull requests"
[ -z "${out}" ] || fail "listed [${out}] with closed pull requests"
case "${err}" in
  *"warning: not listing ${dir}:  every pull request for branch feature of someone/proj is closed or merged (upstream/proj #7 (closed))"*) ;;
  *) fail "unexpected warning with closed pull requests: [${err}]" ;;
esac
if ! grep -q -F -- 'owner=upstream -f name=proj -f b0=feature' "${work}/gh.log"; then
  fail "gh api graphql did not ask the parent repository: $(cat "${work}/gh.log")"
fi
# Every query names github.com, whatever ${GH_HOST} says.
if ! grep -q -F -- 'repo view github.com/someone/proj ' "${work}/gh.log" \
  || ! grep '^api graphql' "${work}/gh.log" | grep -q -F -- '--hostname github.com'; then
  fail "gh was not told the host github.com: $(cat "${work}/gh.log")"
fi

# No pull request was merged, so the warning gives no commands, though the
# directory matches the remote branch:  `git-remove-branch-directory` would
# refuse to remove a directory that held the only copy of the work.
case "${err}" in
  *"to delete the remote branch"*) fail "removal commands for a pull request closed without landing: [${err}]" ;;
esac

# A pull request was merged, and the directory matches the remote branch, so
# the warning gives the commands that delete both.  The deletion holds a lease
# on the directory's HEAD.
head="$(git -C "${dir}" rev-parse HEAD)"
scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 false 'CLOSED 7 someone/proj' 'MERGED 8 someone/proj')"
case "${err}" in
  *"; to delete the remote branch and then the directory, run the following (the second command refuses if the directory would then hold the only copy of some work):
  git -C ${dir} push --force-with-lease=refs/heads/feature:${head} origin --delete refs/heads/feature
  git-remove-branch-directory ${dir}") ;;
  *) fail "no removal commands for a directory that matches the remote branch: [${err}]" ;;
esac

# Usage: expect_no_commands DESCRIPTION
# Scans, with a merged pull request, and fails if the warning gives removal
# commands; DESCRIPTION describes the directory; used for diagnostics.
expect_no_commands() {
  scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 false 'MERGED 7 someone/proj')"
  case "${err}" in
    *"warning: not listing ${dir}:  every pull request for branch feature of someone/proj is closed or merged (someone/proj #7 (merged)), but the branch still exists in the remote") ;;
    *) fail "unexpected warning for $1: [${err}]" ;;
  esac
}

# An untracked file does not prevent the commands.
echo "scratch" > "${dir}/untracked.txt"
scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 false 'MERGED 7 someone/proj')"
case "${err}" in
  *"git-remove-branch-directory ${dir}") ;;
  *) fail "no removal commands for a directory with an untracked file: [${err}]" ;;
esac
rm -f "${dir}/untracked.txt"

# An uncommitted change to a tracked file, staged or not, prevents them.
echo "changed" >> "${dir}/file.txt"
expect_no_commands "a directory with an uncommitted change"
git -C "${dir}" add file.txt
expect_no_commands "a directory with a staged change"
git -C "${dir}" reset -q --hard

# So does a commit that the remote branch lacks.
echo "local" >> "${dir}/file.txt"
git -C "${dir}" commit -q -a -m "Unpushed commit"
expect_no_commands "a directory with an unpushed commit"
git -C "${dir}" reset -q --hard origin/feature

# So does a commit of the remote branch that the directory lacks, which
# deleting the remote branch would lose.
echo "remote" >> "${work}/seed/file.txt"
git -C "${work}/seed" commit -q -a -m "Commit that only the remote has"
git -C "${work}/seed" push -q origin HEAD:refs/heads/feature
expect_no_commands "a directory that lacks a commit of the remote branch"
git -C "${work}/seed" reset -q --hard HEAD^
git -C "${work}/seed" push -q -f origin HEAD:refs/heads/feature

# So does a linked worktree that the directory hosts, because
# `git-remove-branch-directory` refuses, whatever its flags, to remove the
# repository that the worktree depends on.
git -C "${dir}" worktree add -q --detach "${work}/hosted" 2> /dev/null
expect_no_commands "a directory that hosts a linked worktree"
git -C "${dir}" worktree remove "${work}/hosted"

# A pull request from a branch of the same name in the base repository is
# someone else's, so it does not count.
scan FAKE_GH_PARENT='upstream/proj' FAKE_GH_PRS="$(prs b0 false 'MERGED 9 upstream/proj')"
[ -z "${err}" ] || fail "warned about a pull request from the base repository: [${err}]"

# --remove keeps the directory.
scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 false 'MERGED 9 someone/proj')" --remove
[ -d "${dir}" ] || fail "--remove removed ${dir}"
case "${err}" in
  *"warning: not listing ${dir}:"*) ;;
  *) fail "--remove did not warn: [${err}]" ;;
esac

# An open pull request:  no warning.
scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 false 'CLOSED 7 someone/proj' 'OPEN 8 someone/proj')"
[ -z "${err}" ] || fail "warned with an open pull request: [${err}]"

# An open pull request from a branch of the same name in another owner's
# repository does not count.
scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 false 'CLOSED 7 someone/proj' 'OPEN 8 other/proj' 'OPEN 10 -')"
case "${err}" in
  *"warning: not listing ${dir}:  every pull request for branch feature of someone/proj is closed or merged (someone/proj #7 (closed))"*) ;;
  *) fail "unexpected warning with another owner's open pull request: [${err}]" ;;
esac

# GitHub's spelling of the repository may differ in case from the remote
# URL's.
scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 false 'CLOSED 7 SomeOne/Proj')"
case "${err}" in
  *"warning: not listing ${dir}:  every pull request for branch feature of someone/proj is closed or merged (someone/proj #7 (closed))"*) ;;
  *) fail "unexpected warning with the repository in another case: [${err}]" ;;
esac
scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 false 'CLOSED 7 someone/proj' 'OPEN 8 SomeOne/Proj')"
[ -z "${err}" ] || fail "warned though the repository in another case has an open pull request: [${err}]"

# A pull request from a branch of the same name in another repository of the
# same owner, such as the base repository of a fork in one organization, does
# not count.
scan FAKE_GH_PARENT='someone/upstream' FAKE_GH_PRS="$(prs b0 false 'CLOSED 7 someone/proj' 'OPEN 8 someone/upstream')"
case "${err}" in
  *"warning: not listing ${dir}:  every pull request for branch feature of someone/proj is closed or merged (someone/upstream #7 (closed))"*) ;;
  *) fail "unexpected warning with the same owner's open pull request: [${err}]" ;;
esac
scan FAKE_GH_PARENT='someone/upstream' FAKE_GH_PRS="$(prs b0 false 'CLOSED 8 someone/upstream')"
[ -z "${err}" ] || fail "warned about a pull request from the same owner's base repository: [${err}]"

# More pull requests than one GraphQL answer holds:  the REST API, which
# filters by owner, is asked instead, and it finds an open one.
: > "${work}/gh.log"
scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 true 'CLOSED 7 someone/proj')" FAKE_GH_REST='- - OPEN 12 someone/proj'
[ -z "${err}" ] || fail "warned though the REST API found an open pull request: [${err}]"
if ! grep -q -F -- 'api -X GET repos/someone/proj/pulls -f head=someone:feature' "${work}/gh.log"; then
  fail "the REST API was not asked about someone:feature: $(cat "${work}/gh.log")"
fi
if ! grep '^api -X GET' "${work}/gh.log" | grep -q -F -- '--hostname github.com'; then
  fail "the REST API was not told the host github.com: $(cat "${work}/gh.log")"
fi
# The REST API's answer, too, is filtered by head repository.
scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 true 'OPEN 8 other/proj')" \
  FAKE_GH_REST="$(printf '%s\n' '- - MERGED 9 someone/proj' '- - OPEN 12 someone/other' '- - OPEN 13 -')"
case "${err}" in
  *"warning: not listing ${dir}:  every pull request for branch feature of someone/proj is closed or merged (someone/proj #9 (merged))"*) ;;
  *) fail "unexpected warning from the REST API's answer: [${err}]" ;;
esac

# The default branch of the repository is not asked about.
: > "${work}/gh.log"
scan FAKE_GH_PARENT='' FAKE_GH_DEFAULT='feature' FAKE_GH_PRS="$(prs b0 false 'CLOSED 7 someone/proj')"
[ -z "${err}" ] || fail "warned about the default branch: [${err}]"
if grep -q '^api graphql' "${work}/gh.log"; then
  fail "asked about the pull requests of the default branch: $(cat "${work}/gh.log")"
fi

# No pull request:  no warning.
scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 false)"
[ -z "${err}" ] || fail "warned with no pull request: [${err}]"

# A branch whose upstream has another name:  the pull requests asked about
# are those of the upstream.
git -C "${dir}" config branch.feature.merge refs/heads/feature2
: > "${work}/gh.log"
scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 false 'CLOSED 7 someone/proj')"
if ! grep -q -F -- '-f b0=feature2' "${work}/gh.log"; then
  fail "gh api graphql did not ask about the upstream feature2: $(cat "${work}/gh.log")"
fi
case "${err}" in
  *"warning: not listing ${dir}:  every pull request for branch feature2 of someone/proj is closed or merged"*) ;;
  *) fail "unexpected warning for an upstream of another name: [${err}]" ;;
esac
git -C "${dir}" config branch.feature.merge refs/heads/feature

# Two directories of one project:  one query asks about both.
dir2="${work}/scan/proj-branch-feature2"
git clone -q -b feature2 'https://github.com/someone/proj' "${dir2}"
: > "${work}/gh.log"
scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 false 'CLOSED 7 someone/proj'; prs b1 false 'MERGED 9 someone/proj')"
if [ "$(grep -c '^api graphql' "${work}/gh.log")" -ne 1 ]; then
  fail "not one GraphQL query for two directories: $(cat "${work}/gh.log")"
fi
case "${err}" in
  *"not listing ${dir}:  every pull request for branch feature of"*"not listing ${dir2}:  every pull request for branch feature2 of"*) ;;
  *) fail "did not warn about both directories: [${err}]" ;;
esac
rm -rf "${dir2}"

# gh fails:  no warning.
: > "${work}/gh.log"
scan FAKE_GH_FAIL=1 FAKE_GH_PRS="$(prs b0 false 'CLOSED 7 someone/proj')"
[ "${scan_status}" -eq 0 ] || fail "status ${scan_status} when gh fails"
[ -z "${err}" ] || fail "warned when gh fails: [${err}]"
[ -s "${work}/gh.log" ] || fail "did not ask gh, so its failure was not tested"

# A remote that is not on GitHub:  gh is not asked.
: > "${work}/gh.log"
git -C "${dir}" config remote.origin.url "${work}/remote.git"
scan FAKE_GH_PRS="$(prs b0 false 'CLOSED 7 someone/proj')"
[ -z "${err}" ] || fail "warned for a remote that is not on GitHub: [${err}]"
[ ! -s "${work}/gh.log" ] || fail "asked gh about a remote that is not on GitHub: $(cat "${work}/gh.log")"

# Usage: run_commands COMMANDS
# Runs COMMANDS, lines of shell syntax such as a warning gives, with this
# package's commands on the path, and returns the status of the last one.
run_commands() {
  (PATH="${TESTS_DIR}/..:${PATH}" && eval "$1")
}

# The removal commands work, even for a directory whose name the shell must
# quote.
git -C "${dir}" config remote.origin.url 'https://github.com/someone/proj'
quoted_dir="${work}/scan/proj-branch-it's here"
mv "${dir}" "${quoted_dir}"
scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 false 'MERGED 7 someone/proj')"
commands="$(printf '%s\n' "${err}" | sed -n -e 's/^  //p')"
case "${commands}" in
  "git -C '${work}/scan/proj-branch-it'\\''s here' push --force-with-lease=refs/heads/feature:${head} origin --delete refs/heads/feature
git-remove-branch-directory '${work}/scan/proj-branch-it'\\''s here'") ;;
  *) fail "unexpected removal commands for a directory whose name needs quotes: [${err}]" ;;
esac

# The lease makes the deletion refuse if the remote branch has moved since the
# scan.
echo "later" >> "${work}/seed/file.txt"
git -C "${work}/seed" commit -q -a -m "Commit pushed after the scan"
git -C "${work}/seed" push -q origin HEAD:refs/heads/feature
push_command="$(printf '%s\n' "${commands}" | head -n 1)"
if (eval "${push_command}") > /dev/null 2>&1; then
  fail "the deletion succeeded although the remote branch moved: [${push_command}]"
fi
if [ "$(git -C "${work}/remote.git" rev-parse --verify --quiet refs/heads/feature)" \
  != "$(git -C "${work}/seed" rev-parse HEAD)" ]; then
  fail "the refused deletion changed the remote branch feature"
fi
git -C "${work}/seed" reset -q --hard HEAD^
git -C "${work}/seed" push -q -f origin HEAD:refs/heads/feature
# A tag with the name of the branch does not confuse the deletion.
git -C "${work}/seed" push -q origin HEAD:refs/tags/feature
run_commands "${commands}" > /dev/null 2>&1 \
  || fail "the removal commands failed: [${commands}]"
[ ! -e "${quoted_dir}" ] || fail "the removal commands left ${quoted_dir}"
if git -C "${work}/remote.git" rev-parse --verify --quiet refs/heads/feature > /dev/null; then
  fail "the removal commands left the remote branch feature"
fi

# A branch with a commit that nothing else holds, such as one pushed after its
# pull request landed:  the first command deletes the remote branch, and then
# `git-remove-branch-directory` refuses, because the directory holds the only
# copy of that commit.  The fake `gh` reports no landed pull request at that
# commit.
echo "after landing" >> "${work}/seed/file.txt"
git -C "${work}/seed" commit -q -a -m "Commit pushed after the pull request landed"
git -C "${work}/seed" push -q origin HEAD:refs/heads/feature3
dir3="${work}/scan/proj-branch-feature3"
git clone -q -b feature3 'https://github.com/someone/proj' "${dir3}"
scan FAKE_GH_PARENT='' FAKE_GH_PRS="$(prs b0 false 'MERGED 11 someone/proj')"
commands="$(printf '%s\n' "${err}" | sed -n -e 's/^  //p')"
[ -n "${commands}" ] || fail "no removal commands for ${dir3}: [${err}]"
run_commands "${commands}" > /dev/null 2>&1 \
  && fail "the removal commands succeeded for a directory that holds the only copy of a commit"
if git -C "${work}/remote.git" rev-parse --verify --quiet refs/heads/feature3 > /dev/null; then
  fail "the removal commands left the remote branch feature3"
fi
[ -e "${dir3}/file.txt" ] || fail "the removal commands removed ${dir3}, which holds the only copy of a commit"

if [ "${status}" = 0 ]; then
  echo "${SCRIPT_NAME}: OK"
fi
exit "${status}"
