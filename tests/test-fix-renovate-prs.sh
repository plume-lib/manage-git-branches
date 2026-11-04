#!/bin/sh

# Tests that `fix-renovate-prs` runs Claude for each failing Renovate pull
# request, pushes Claude's fixes, comments when Claude reports that the CI
# cannot pass, skips the pull requests that it should skip, and lists, last,
# the pull requests that it acted on.  It also tests how `fix-renovate-prs`
# brings an existing directory to a pull request's head commit, and that it
# does not pull in the clone where it makes a new directory.
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
oid_rewritten="$(renovate_branch rewritten)"
oid_resumed="$(renovate_branch resumed)"
oid_untracked="$(renovate_branch untracked)"

scan="${work}/scan"
mkdir "${scan}"
git clone -q https://github.com/someone/proj "${scan}/proj"
# A branch directory of the same repository, which is not chosen to make new
# branch directories in.
git -C "${scan}/proj" worktree add -q -b feature "${scan}/proj-branch-feature"
# Usage: branch_directory NAME
# Makes the directory for the branch renovate/NAME, at the pull request's
# head commit.
branch_directory() {
  git -C "${scan}/proj" worktree add -q --track -b "renovate/$1" \
    "${scan}/proj-branch-renovate-$1" "origin/renovate/$1"
}
# A directory for the branch renovate/diverged whose HEAD has diverged from
# the pull request, with a commit that the pull request never had.
branch_directory diverged
git -C "${scan}/proj-branch-renovate-diverged" reset -q --hard origin/main
git -C "${scan}/proj-branch-renovate-diverged" commit -q --allow-empty -m "Local commit"
# A directory for the branch renovate/rewritten at a commit that Renovate then
# replaced, so that the directory has no commit that the branch never had.
branch_directory rewritten
git -C "${seed}" checkout -q renovate/rewritten
git -C "${seed}" commit -q --amend -m "Update dependencies for rewritten, again"
git -C "${seed}" push -q -f origin renovate/rewritten
oid_rewritten="$(git -C "${seed}" rev-parse HEAD)"
# A directory for the branch renovate/resumed with a commit, on top of the pull
# request's head, that an earlier run did not push.
branch_directory resumed
git -C "${scan}/proj-branch-renovate-resumed" commit -q --allow-empty -m "Earlier fix"
# A commit on main that the clone proj does not have, which a pull in proj
# would bring in.
git -C "${seed}" checkout -q main
echo "news" > "${seed}/news"
git -C "${seed}" add news
git -C "${seed}" commit -q -m "News"
git -C "${seed}" push -q origin main
proj_head="$(git -C "${scan}/proj" rev-parse HEAD)"

# Usage: check_run CONCLUSION NAME
# Prints a check run named NAME, as the GitHub API's JSON describes it, whose
# conclusion is CONCLUSION, or that has not finished if CONCLUSION is "null".
check_run() {
  if [ "$1" = null ]; then
    status=IN_PROGRESS
    conclusion=null
  else
    status=COMPLETED
    conclusion="\"$1\""
  fi
  echo "{\"__typename\": \"CheckRun\", \"name\": \"$2\", \"detailsUrl\": \"https://example.com/$2\", \"status\": \"${status}\", \"conclusion\": ${conclusion}}"
}
success="$(check_run SUCCESS lint)"
failure="$(check_run FAILURE build)"
startup_failure="$(check_run STARTUP_FAILURE setup)"
approval="$(check_run ACTION_REQUIRED deploy)"
running="$(check_run null build)"
cancelled="$(check_run CANCELLED deploy)"
error_status='{"__typename": "StatusContext", "context": "legacy", "targetUrl": "https://example.com/legacy", "state": "ERROR"}'

# Usage: pr NUMBER NAME OID CHECKS [CROSS]
# Prints a pull request, as the GitHub API's JSON describes it, from the
# branch renovate/NAME, whose head is OID and whose checks are CHECKS, a
# comma-separated list.  CROSS is "true" if the pull request is from a fork.
pr() {
  echo "{\"url\": \"https://github.com/someone/proj/pull/$1\", \"headRefName\": \"renovate/$2\", \"headRefOid\": \"$3\", \"isCrossRepository\": ${5:-false}, \"statusCheckRollup\": [$4]}"
}
mkdir -p "${work}/bin" "${work}/pr" "${work}/posted"
# Usage: pr_list
# Writes the list of pull requests for `gh pr list`.
pr_list() {
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
    echo ","
    pr 10 rewritten "${oid_rewritten}" "${failure}"
    echo ","
    pr 11 resumed "${oid_resumed}" "${failure}"
    echo ","
    pr 12 approval 0000000000000000000000000000000000000000 "${failure}, ${approval}"
    echo ","
    pr 13 untracked "${oid_untracked}" "${failure}"
    echo "]"
  } > "${work}/pr-list.json"
}
pr_list
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
pr_view 1 "${success}, ${failure}, ${startup_failure}"
pr_view 2 "${error_status}" "An unrelated comment"
pr_view 3 "${failure}" "Explanation
<!-- fix-renovate-prs: CI cannot pass at ${oid_reported} -->"
# GitHub does not yet show the rerun of pull request 6's failed check.
pr_view 6 "${failure}"
pr_view 7 "${failure}"
pr_view 8 "${failure}"
pr_view 10 "${failure}"
pr_view 11 "${failure}"
pr_view 13 "${failure}"

# The fake `gh` appends its arguments to ${work}/gh.log.  `gh pr list` prints
# ${work}/pr-list.json and `gh pr view URL` prints ${work}/pr/NUMBER.json,
# each filtered by the `--jq` filter, if any.  `gh repo view` reports that
# someone/proj is not a fork and that its default branch is "main".
# `gh pr comment URL --body-file FILE` copies FILE to ${work}/posted/NUMBER.
#
# The rest serves `rerun-failed-ci`.  `gh pr checks URL` prints no checks,
# except for pull request 6, whose failed check is GitHub Actions workflow
# run 60.  Its one job, 61, failed transiently.  `gh run rerun` appends its
# arguments to ${work}/reruns.
cat > "${work}/bin/gh" << EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${work}/gh.log"
case "\$1" in
  api)
    for arg; do path="\${arg}"; done
    case "\${path}" in
      */actions/runs/60) echo '{"name": "ci", "status": "completed", "conclusion": "failure"}' ;;
      */actions/runs/60/jobs*) echo '[{"jobs": [{"id": 61, "name": "build", "conclusion": "failure", "started_at": "2026-01-01T00:00:00Z"}]}]' ;;
      */check-runs/61/annotations*) echo '[[]]' ;;
      *) echo "unexpected gh api request: \${path}" >&2; exit 1 ;;
    esac
    exit 0
    ;;
  run)
    case "\$2" in
      view) printf 'build\tstep\tConnection reset by peer\n' ;;
      rerun) printf '%s\n' "\$*" >> "${work}/reruns" ;;
      *) echo "unexpected gh command: \$*" >&2; exit 1 ;;
    esac
    exit 0
    ;;
esac
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
    if [ "\${number}" = 6 ]; then
      json='[{"name": "build", "bucket": "fail", "state": "FAILURE", "link": "https://github.com/someone/proj/actions/runs/60/job/61"}]'
    else
      json='[]'
    fi
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
# renovate/NAME:  for "fixable" and "rewritten", it commits a fix and reports
# FIXED; for "impossible", it commits a partial fix and reports IMPOSSIBLE;
# for "nocommit" and "resumed", it reports FIXED without committing; for
# "untracked", it commits a fix but not the new file that the fix needs, and
# reports FIXED.  It reports with Markdown
# emphasis, blank lines, and a carriage return, as Claude might.
cat > "${work}/bin/claude" << EOF
#!/bin/sh
dir="\$(basename -- "\$(pwd)")"
echo "\${dir} \$*" >> "${work}/claude.log"
cat > "${work}/prompt.\${dir}"
outcome="\$(sed -n -e 's/^\* Finally, write the file \(.*\)\.  Its first line.*/\1/p' "${work}/prompt.\${dir}")"
case "\$(git symbolic-ref --short HEAD)" in
  renovate/fixable | renovate/rewritten)
    echo "fixed" >> deps
    git commit -q -a -m "Fix the build"
    printf '\n**FIXED** \r\nThe build needed a fix.\n' > "\${outcome}"
    ;;
  renovate/impossible)
    echo "partly fixed" >> deps
    git commit -q -a -m "Partial fix"
    printf '\n# IMPOSSIBLE\nThe new version has a bug.\n' > "\${outcome}"
    ;;
  renovate/untracked)
    echo "fixed" >> deps
    echo "needed" > needed
    git commit -q -a -m "Fix the build"
    printf 'FIXED\nThe build needed a new file.\n' > "\${outcome}"
    ;;
  renovate/nocommit | renovate/resumed)
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
proj-branch-renovate-nocommit -p --permission-mode bypassPermissions --session-id
proj-branch-renovate-rewritten -p --permission-mode bypassPermissions --session-id
proj-branch-renovate-resumed -p --permission-mode bypassPermissions --session-id
proj-branch-renovate-untracked -p --permission-mode bypassPermissions --session-id"
actual="$(sed -e 's/ [0-9a-f-]*$//' "${work}/claude.log")"
if [ "${actual}" != "${expected}" ]; then
  fail "claude ran:
${actual}
not:
${expected}"
fi
case "$(cat "${work}/prompt.proj-branch-renovate-fixable")" in
  *"https://github.com/someone/proj/pull/1"*"  build: https://example.com/build
  setup: https://example.com/setup
"*) ;;
  *) fail "the instructions do not name the pull request and its failed checks: $(cat "${work}/prompt.proj-branch-renovate-fixable")" ;;
esac
case "$(cat "${work}/prompt.proj-branch-renovate-fixable")" in
  *"lint"* | *"earlier attempt"*) fail "the instructions name a check that passed, or earlier commits" ;;
esac
case "$(cat "${work}/prompt.proj-branch-renovate-resumed")" in
  *"earlier attempt"*"git log ${oid_resumed}..HEAD"*) ;;
  *) fail "the instructions do not mention the earlier commits: $(cat "${work}/prompt.proj-branch-renovate-resumed")" ;;
esac

# The transient failure is rerun, and the pull request is then skipped,
# although GitHub still shows the failure.
if [ "$(cat "${work}/reruns" 2> /dev/null)" != "run rerun --repo someone/proj --failed 60" ]; then
  fail "the reruns are: $(cat "${work}/reruns" 2> /dev/null)"
fi

# The new directory was made without pulling in proj.
if [ "$(git -C "${scan}/proj" rev-parse HEAD)" != "${proj_head}" ]; then
  fail "proj was pulled"
fi

# The fixes are pushed, on top of the pull requests' head commits; nothing
# else is.
for name in fixable rewritten; do
  oid="$(eval "printf '%s' \"\${oid_${name}}\"")"
  if [ "$(git -C "${remote}" log -1 --format='%s %P' "renovate/${name}")" != "Fix the build ${oid}" ]; then
    fail "the fix of renovate/${name} was not pushed on top of ${oid}"
  fi
done
if [ "$(git -C "${remote}" log -1 --format='%s %P' renovate/resumed)" != "Earlier fix ${oid_resumed}" ]; then
  fail "the earlier fix of renovate/resumed was not pushed"
fi
for name in impossible nocommit diverged untracked; do
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
  *"skipping https://github.com/someone/proj/pull/12, whose CI waits for a human to act"*) ;;
  *) fail "the output does not report the pull request that waits for approval: ${output}" ;;
esac
case "${output}" in
  *"pull/5"* | *"pull/9"*) fail "the output mentions a passing pull request or one from a fork: ${output}" ;;
esac

# The report is last, and lists each pull request in its group.
expected="Reran transient CI failures; run fix-renovate-prs again after CI finishes:
https://github.com/someone/proj/pull/6  ${scan}/proj-branch-renovate-rerun (not made yet)
Could not handle; a human must look:
https://github.com/someone/proj/pull/7  ${scan}/proj-branch-renovate-diverged has diverged from the pull request's head commit ${oid_diverged}, and it has commits that the pull request's branch never had; move them onto ${oid_diverged}, or remove ${scan}/proj-branch-renovate-diverged with git-remove-branch-directory
https://github.com/someone/proj/pull/8  claude reported a fix but committed nothing in ${scan}/proj-branch-renovate-nocommit
https://github.com/someone/proj/pull/13  claude reported a fix but left new files uncommitted in ${scan}/proj-branch-renovate-untracked:
needed
Commented that CI cannot pass; review the comments:
https://github.com/someone/proj/pull/2  ${scan}/proj-branch-renovate-impossible (1 unpushed commits)
Pushed fixes; review them:
https://github.com/someone/proj/pull/1  ${scan}/proj-branch-renovate-fixable
https://github.com/someone/proj/pull/10  ${scan}/proj-branch-renovate-rewritten
https://github.com/someone/proj/pull/11  ${scan}/proj-branch-renovate-resumed"
if [ "$(printf '%s\n' "${output}" | tail -n 13)" != "${expected}" ]; then
  fail "the report is:
$(printf '%s\n' "${output}" | tail -n 13)
not:
${expected}"
fi

# The ref refs/fix-renovate-prs/BRANCH keeps the commits that were not pushed,
# and no others.
if [ "$(git -C "${scan}/proj" rev-parse --verify --quiet refs/fix-renovate-prs/renovate/impossible)" \
  != "$(git -C "${scan}/proj-branch-renovate-impossible" rev-parse HEAD)" ]; then
  fail "refs/fix-renovate-prs/renovate/impossible does not keep the partial fix"
fi
for name in fixable rewritten resumed; do
  if git -C "${scan}/proj" rev-parse --verify --quiet "refs/fix-renovate-prs/renovate/${name}" > /dev/null; then
    fail "refs/fix-renovate-prs/renovate/${name} remains after the push"
  fi
done

# The command to continue a failed session is written in the directory that
# holds the working copy directories, not in the branch directory.
case "$(cat "${scan}/AGENT-TODO.md" 2> /dev/null)" in
  *"cd ${scan}/proj-branch-renovate-nocommit && claude --resume "*) ;;
  *) fail "${scan}/AGENT-TODO.md does not have the command: $(cat "${scan}/AGENT-TODO.md" 2> /dev/null)" ;;
esac
if [ -e "${scan}/proj-branch-renovate-nocommit/AGENT-TODO.md" ]; then
  fail "AGENT-TODO.md was written in the branch directory"
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

# After Renovate rewrites a branch, the directory that holds a partial fix that
# was not pushed is reset to the new head commit, and Claude is told about the
# partial fix.
git -C "${seed}" checkout -q renovate/impossible
git -C "${seed}" commit -q --amend -m "Update dependencies for impossible, again"
git -C "${seed}" push -q -f origin renovate/impossible
oid_impossible="$(git -C "${seed}" rev-parse HEAD)"
partial="$(git -C "${scan}/proj-branch-renovate-impossible" rev-parse HEAD)"
{
  echo "["
  pr 2 impossible "${oid_impossible}" "${failure}"
  echo "]"
} > "${work}/pr-list.json"
pr_view 2 "${failure}"
if ! output="$("${FIX_RENOVATE_PRS}" -C "${scan}" < /dev/null 2>&1)"; then
  fail "the run after the rewrite fails: ${output}"
fi
case "$(cat "${work}/prompt.proj-branch-renovate-impossible")" in
  *"An earlier attempt"*"  ${partial} Partial fix"*) ;;
  *) fail "the instructions do not mention the partial fix: $(cat "${work}/prompt.proj-branch-renovate-impossible")" ;;
esac
if [ "$(git -C "${scan}/proj-branch-renovate-impossible" rev-parse HEAD~1)" != "${oid_impossible}" ]; then
  fail "the directory was not reset to the new head commit: ${output}"
fi

# For a pull request whose CI jobs were rerun, the report names the directory
# that `git push` in it pushes to the pull request's branch, with no note.  A
# pull request whose comments cannot be read is reported with its directory.
oid_unreadable="$(renovate_branch unreadable)"
git -C "${scan}/proj" fetch -q origin
branch_directory rerun
branch_directory unreadable
{
  echo "["
  pr 6 rerun "${oid_rerun}" "${failure}"
  echo ","
  pr 14 unreadable "${oid_unreadable}" "${failure}"
  echo "]"
} > "${work}/pr-list.json"
output="$("${FIX_RENOVATE_PRS}" -C "${scan}" < /dev/null 2>&1)"
expected="Reran transient CI failures; run fix-renovate-prs again after CI finishes:
https://github.com/someone/proj/pull/6  ${scan}/proj-branch-renovate-rerun
Could not handle; a human must look:
https://github.com/someone/proj/pull/14  cannot read its comments, so claude did not run in ${scan}/proj-branch-renovate-unreadable"
if [ "$(printf '%s\n' "${output}" | tail -n 4)" != "${expected}" ]; then
  fail "the report is:
$(printf '%s\n' "${output}" | tail -n 4)
not:
${expected}"
fi

# For a pull request whose CI jobs were rerun, the report notes that something
# that is not a working copy directory for the pull request's branch is in
# the way of the directory that a later run would make.
git -C "${scan}/proj" worktree remove --force "${scan}/proj-branch-renovate-rerun"
mkdir "${scan}/proj-branch-renovate-rerun"
{
  echo "["
  pr 6 rerun "${oid_rerun}" "${failure}"
  echo "]"
} > "${work}/pr-list.json"
output="$("${FIX_RENOVATE_PRS}" -C "${scan}" < /dev/null 2>&1)"
expected="Reran transient CI failures; run fix-renovate-prs again after CI finishes:
https://github.com/someone/proj/pull/6  ${scan}/proj-branch-renovate-rerun (exists, but does not push to the pull request's branch)"
if [ "$(printf '%s\n' "${output}" | tail -n 2)" != "${expected}" ]; then
  fail "the report is:
$(printf '%s\n' "${output}" | tail -n 2)
not:
${expected}"
fi

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
