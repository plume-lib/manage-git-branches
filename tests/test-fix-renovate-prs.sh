#!/bin/sh

# Tests that `fix-renovate-prs` runs Claude for each failing Renovate pull
# request, pushes Claude's fixes, comments when Claude reports that the CI
# cannot pass, skips the pull requests that it should skip, and lists, last,
# the pull requests that it acted on.
#
# Usage:
#   tests/test-fix-renovate-prs.sh
#
# The status code is 0 if all the tests pass, and nonzero otherwise.
#
# A fake `gh` and a fake `claude` stand in for GitHub and for the AI agent, so
# the test needs no network.  The fake `gh` applies each `--jq` filter with
# `jq`, so that the script's filters are tested too; the test is skipped if
# `jq` is not installed.

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
FIX_RENOVATE_PRS="${TESTS_DIR}/../fix-renovate-prs"

. "${TESTS_DIR}/lib-git-test-env.sh"

if ! command -v jq > /dev/null 2>&1; then
  echo "${SCRIPT_NAME}: skipping, because jq is not installed"
  exit 0
fi

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

# The GitHub repository someone/proj is the bare repository
# ${work}/remote/proj.git.  The clones' remote names GitHub, and
# `url.BASE.insteadOf` maps it to the bare repository.
remote="${work}/remote/proj.git"
git init -q --bare -b main "${remote}"
git config --global url."${remote}".insteadOf https://github.com/someone/proj
seed="${work}/seed"
git init -q -b main "${seed}"
git -C "${seed}" remote add origin https://github.com/someone/proj
echo "version 1" > "${seed}/deps"
git -C "${seed}" add deps
git -C "${seed}" commit -q -m "Initial commit"
git -C "${seed}" push -q origin main

# Usage: renovate_branch NAME
# Pushes a branch renovate/NAME, whose commit updates the dependencies, and
# prints its commit.
renovate_branch() {
  git -C "${seed}" checkout -q -b "renovate/$1" main
  echo "version 2 for $1" > "${seed}/deps"
  git -C "${seed}" commit -q -a -m "Update dependencies for $1"
  git -C "${seed}" push -q origin "renovate/$1"
  git -C "${seed}" rev-parse HEAD
}
oid_fixable="$(renovate_branch fixable)"
oid_impossible="$(renovate_branch impossible)"
oid_reported="$(renovate_branch reported)"
oid_running="$(renovate_branch running)"
oid_passing="$(renovate_branch passing)"
oid_rerun="$(renovate_branch rerun)"
oid_diverged="$(renovate_branch diverged)"
oid_nocommit="$(renovate_branch nocommit)"

scan="${work}/scan"
mkdir "${scan}"
git clone -q https://github.com/someone/proj "${scan}/proj"
# A branch directory of the same repository, which is not chosen to make new
# branch directories in.
git -C "${scan}/proj" worktree add -q -b feature "${scan}/proj-branch-feature"
# A directory for the branch renovate/diverged with a commit that the pull
# request does not have.
git -C "${scan}/proj" worktree add -q --track -b renovate/diverged \
  "${scan}/proj-branch-renovate-diverged" origin/renovate/diverged
git -C "${scan}/proj-branch-renovate-diverged" commit -q --allow-empty -m "Local commit"

# Usage: check_run CONCLUSION
# Prints a check run, as the GitHub API's JSON describes it, whose conclusion
# is CONCLUSION, or that has not finished if CONCLUSION is "null".
check_run() {
  if [ "$1" = null ]; then
    echo '{"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": null}'
  else
    echo "{\"__typename\": \"CheckRun\", \"status\": \"COMPLETED\", \"conclusion\": \"$1\"}"
  fi
}
success="$(check_run SUCCESS)"
failure="$(check_run FAILURE)"
running="$(check_run null)"
cancelled="$(check_run CANCELLED)"
error_status='{"__typename": "StatusContext", "state": "ERROR"}'

# Usage: pr NUMBER NAME OID CHECKS [CROSS]
# Prints a pull request, as the GitHub API's JSON describes it, from the
# branch renovate/NAME, whose head is OID and whose checks are CHECKS, a
# comma-separated list.  CROSS is "true" if the pull request is from a fork.
pr() {
  echo "{\"url\": \"https://github.com/someone/proj/pull/$1\", \"headRefName\": \"renovate/$2\", \"headRefOid\": \"$3\", \"isCrossRepository\": ${5:-false}, \"statusCheckRollup\": [$4]}"
}
mkdir -p "${work}/bin" "${work}/pr" "${work}/posted"
{
  echo "["
  pr 1 fixable "${oid_fixable}" "${success}, ${failure}"
  echo ","
  pr 2 impossible "${oid_impossible}" "${error_status}, ${cancelled}"
  echo ","
  pr 3 reported "${oid_reported}" "${failure}"
  echo ","
  pr 4 running "${oid_running}" "${failure}, ${running}"
  echo ","
  pr 5 passing "${oid_passing}" "${success}, ${cancelled}"
  echo ","
  pr 6 rerun "${oid_rerun}" "${failure}"
  echo ","
  pr 7 diverged "${oid_diverged}" "${failure}"
  echo ","
  pr 8 nocommit "${oid_nocommit}" "${failure}"
  echo ","
  pr 9 forked 0000000000000000000000000000000000000000 "${failure}" true
  echo "]"
} > "${work}/pr-list.json"
# Usage: pr_view NUMBER CHECKS [COMMENT]
# Records what `gh pr view` says about pull request NUMBER:  that it is open,
# that its checks are CHECKS, and that its only comment, if any, is COMMENT.
pr_view() {
  if [ -n "${3:-}" ]; then
    comments="[{\"body\": $(printf '%s' "$3" | jq -R -s .)}]"
  else
    comments="[]"
  fi
  # `printf` rather than `echo`, which in some shells, such as dash, would
  # interpret the backslashes in ${comments}.
  printf '{"state": "OPEN", "statusCheckRollup": [%s], "comments": %s}\n' "$2" "${comments}" \
    > "${work}/pr/$1.json"
}
pr_view 1 "${failure}"
pr_view 2 "${error_status}" "An unrelated comment"
pr_view 3 "${failure}" "Explanation
<!-- fix-renovate-prs: CI cannot pass at ${oid_reported} -->"
pr_view 6 "${running}"
pr_view 7 "${failure}"
pr_view 8 "${failure}"

# The fake `gh` appends its arguments to ${work}/gh.log.  `gh pr list` prints
# ${work}/pr-list.json, `gh pr view URL` prints ${work}/pr/NUMBER.json, and
# `gh pr checks URL` prints one failed check, each filtered by the `--jq`
# filter, if any.  `gh pr checks` without `--jq`, as `rerun-failed-ci` runs
# it, prints no checks.  `gh repo view` reports that someone/proj is not a
# fork and that its default branch is "main".  `gh pr comment URL --body-file
# FILE` copies FILE to ${work}/posted/NUMBER.
cat > "${work}/bin/gh" << EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${work}/gh.log"
cmd="\$1 \$2"
shift 2
filter=""
url=""
body=""
while [ "\$#" -ne 0 ]; do
  case "\$1" in
    --jq) filter="\$2"; shift 2 ;;
    --body-file) body="\$2"; shift 2 ;;
    -R | --app | --state | --limit | --json) shift 2 ;;
    https://*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
number="\${url##*/}"
case "\${cmd}" in
  'repo view') echo "someone/proj main"; exit 0 ;;
  'pr list') json="\$(cat "${work}/pr-list.json")" ;;
  'pr view') json="\$(cat "${work}/pr/\${number}.json")" || exit 1 ;;
  'pr checks')
    if [ -z "\${filter}" ]; then echo '[]'; exit 0; fi
    json='[{"name": "build", "bucket": "fail", "link": "https://example.com/build"}, {"name": "lint", "bucket": "pass", "link": "https://example.com/lint"}]'
    ;;
  'pr comment') cp "\${body}" "${work}/posted/\${number}"; exit 0 ;;
  *) echo "unexpected gh command: \${cmd}" >&2; exit 1 ;;
esac
if [ -n "\${filter}" ]; then
  printf '%s\n' "\${json}" | jq -r "\${filter}"
else
  printf '%s\n' "\${json}"
fi
EOF
# The fake `claude` appends the name of its directory and its arguments to
# ${work}/claude.log, and copies its instructions to
# ${work}/prompt.BRANCHDIR.  What it does depends on its directory's branch,
# renovate/NAME:  for "fixable", it commits a fix and reports FIXED; for
# "impossible", it reports IMPOSSIBLE; for "nocommit", it reports FIXED without
# committing.
cat > "${work}/bin/claude" << EOF
#!/bin/sh
dir="\$(basename -- "\$(pwd)")"
echo "\${dir} \$*" >> "${work}/claude.log"
cat > "${work}/prompt.\${dir}"
outcome="\$(sed -n -e 's/^\* Finally, write the file \(.*\)\.  Its first line.*/\1/p' "${work}/prompt.\${dir}")"
case "\$(git symbolic-ref --short HEAD)" in
  renovate/fixable)
    echo "fixed" >> deps
    git commit -q -a -m "Fix the build"
    printf 'FIXED\nThe build needed a fix.\n' > "\${outcome}"
    ;;
  renovate/impossible)
    printf 'IMPOSSIBLE\nThe new version has a bug.\n' > "\${outcome}"
    ;;
  renovate/nocommit)
    printf 'FIXED\nNothing to do.\n' > "\${outcome}"
    ;;
esac
EOF
chmod +x "${work}/bin/gh" "${work}/bin/claude"
PATH="${work}/bin:${PATH}"
export PATH

if output="$("${FIX_RENOVATE_PRS}" -C "${scan}" < /dev/null 2>&1)"; then
  fail "the exit status is 0 although some pull requests could not be handled: ${output}"
fi

# Claude runs once each for the pull requests that it should handle, in the
# order of the pull requests, with every permission.
expected="proj-branch-renovate-fixable -p --permission-mode bypassPermissions --session-id
proj-branch-renovate-impossible -p --permission-mode bypassPermissions --session-id
proj-branch-renovate-nocommit -p --permission-mode bypassPermissions --session-id"
actual="$(sed -e 's/ [0-9a-f-]*$//' "${work}/claude.log")"
if [ "${actual}" != "${expected}" ]; then
  fail "claude ran:
${actual}
not:
${expected}"
fi
case "$(cat "${work}/prompt.proj-branch-renovate-fixable")" in
  *"https://github.com/someone/proj/pull/1"*"  build: https://example.com/build"*) ;;
  *) fail "the instructions do not name the pull request and its failed check: $(cat "${work}/prompt.proj-branch-renovate-fixable")" ;;
esac
case "$(cat "${work}/prompt.proj-branch-renovate-fixable")" in
  *"lint"*) fail "the instructions name a check that passed" ;;
esac

# The fix is pushed; nothing else is.
if [ "$(git -C "${remote}" log -1 --format=%s renovate/fixable)" != "Fix the build" ]; then
  fail "the fix was not pushed"
fi
for name in impossible nocommit diverged; do
  oid="$(eval "printf '%s' \"\${oid_${name}}\"")"
  if [ "$(git -C "${remote}" rev-parse "renovate/${name}")" != "${oid}" ]; then
    fail "renovate/${name} was pushed"
  fi
done

# Claude's explanation is posted, with the marker, for the impossible one only.
if [ "$(ls "${work}/posted")" != 2 ]; then
  fail "comments were posted on: $(ls "${work}/posted")"
fi
case "$(cat "${work}/posted/2" 2> /dev/null)" in
  *"The new version has a bug."*"<!-- fix-renovate-prs: CI cannot pass at ${oid_impossible} -->") ;;
  *) fail "the comment is: $(cat "${work}/posted/2" 2> /dev/null)" ;;
esac

case "${output}" in
  *"skipping https://github.com/someone/proj/pull/3, whose CI was reported impossible to fix at ${oid_reported}"*) ;;
  *) fail "the output does not report the pull request that was reported impossible: ${output}" ;;
esac
case "${output}" in
  *"skipping https://github.com/someone/proj/pull/4, whose CI is running"*) ;;
  *) fail "the output does not report the running pull request: ${output}" ;;
esac
case "${output}" in
  *"pull/5"* | *"pull/9"*) fail "the output mentions a passing pull request or one from a fork: ${output}" ;;
esac

# The report is last, and lists each pull request in its group.
expected="Reran transient CI failures; run fix-renovate-prs again after CI finishes:
https://github.com/someone/proj/pull/6
Could not handle; a human must look:
https://github.com/someone/proj/pull/7  ${scan}/proj-branch-renovate-diverged has commits that are not in the pull request, perhaps because Renovate rewrote the branch; remove it with git-remove-branch-directory, or push its commits
https://github.com/someone/proj/pull/8  claude reported a fix but committed nothing in ${scan}/proj-branch-renovate-nocommit
Commented that CI cannot pass; review the comments:
https://github.com/someone/proj/pull/2  ${scan}/proj-branch-renovate-impossible
Pushed fixes; review them:
https://github.com/someone/proj/pull/1  ${scan}/proj-branch-renovate-fixable"
if [ "$(printf '%s\n' "${output}" | tail -n 9)" != "${expected}" ]; then
  fail "the report is:
$(printf '%s\n' "${output}" | tail -n 9)
not:
${expected}"
fi

# --dry-run runs nothing.
: > "${work}/claude.log"
rm -f "${work}/posted"/*
pushed_before="$(git -C "${remote}" for-each-ref)"
if ! output="$("${FIX_RENOVATE_PRS}" --dry-run -C "${scan}" < /dev/null 2>&1)"; then
  fail "--dry-run fails: ${output}"
fi
if [ -s "${work}/claude.log" ] || [ -n "$(ls "${work}/posted")" ] \
  || [ "$(git -C "${remote}" for-each-ref)" != "${pushed_before}" ]; then
  fail "--dry-run acted"
fi
case "${output}" in
  *"Would run claude in proj-branch-renovate-fixable for https://github.com/someone/proj/pull/1"*) ;;
  *) fail "--dry-run does not report the existing directory: ${output}" ;;
esac
git -C "${scan}/proj" worktree remove --force "${scan}/proj-branch-renovate-fixable"
if ! output="$("${FIX_RENOVATE_PRS}" --dry-run -C "${scan}" < /dev/null 2>&1)"; then
  fail "--dry-run fails: ${output}"
fi
case "${output}" in
  *"Would run claude in a new directory proj-branch-renovate-fixable, made in proj, for https://github.com/someone/proj/pull/1"*) ;;
  *) fail "--dry-run does not report the new directory: ${output}" ;;
esac

# Usage errors.
"${FIX_RENOVATE_PRS}" --bogus -C "${scan}" > /dev/null 2>&1
if [ "$?" -ne 2 ]; then
  fail "the exit status for an unknown option is not 2"
fi
output="$("${FIX_RENOVATE_PRS}" -C "${work}/no-such-dir" 2>&1)"
if [ "$?" -ne 2 ]; then
  fail "the exit status for a nonexistent directory is not 2"
fi
case "${output}" in
  *"cannot change to directory ${work}/no-such-dir"*) ;;
  *) fail "the message for a nonexistent directory does not name it: ${output}" ;;
esac
output="$(MANAGE_GIT_BRANCHES_RENOVATE_TIMEOUT=soon "${FIX_RENOVATE_PRS}" -C "${scan}" 2>&1)"
if [ "$?" -ne 2 ]; then
  fail "the exit status for a bad time limit is not 2: ${output}"
fi

exit "${status}"
