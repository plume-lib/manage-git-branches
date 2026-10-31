#!/bin/sh

# Tests the `rerun-failed-ci` script.  The tests contact no server:  fake `curl`
# and `gh` commands serve canned API responses and record the reruns that the
# script requests.

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
TOPLEVEL="$(CDPATH='' cd -- "${TESTS_DIR}/.." && pwd -P)"
RERUN="${TOPLEVEL}/rerun-failed-ci"

status=0

if ! command -v jq > /dev/null 2>&1; then
  echo "${SCRIPT_NAME}: skipping, because jq is not installed"
  exit 0
fi

if ! work="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")" || [ -z "${work}" ]; then
  echo "${SCRIPT_NAME}: cannot create a temporary directory" >&2
  exit 1
fi
trap 'rm -rf "${work}"' EXIT
trap 'rm -rf "${work}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${work}"; trap - TERM; kill -s TERM "$$"' TERM

fail() {
  echo "FAIL: $*"
  status=1
}

###########################################################################
### --classify
###

# Usage: check_classify EXPECTED-STATUS EXPECTED-OUTPUT LOG-TEXT
# Checks that `rerun-failed-ci --classify` on a log containing LOG-TEXT exits
# with EXPECTED-STATUS and prints EXPECTED-OUTPUT after the file name.
check_classify() {
  printf '%s\n' "$3" > "${work}/log"
  actual="$("${RERUN}" --classify "${work}/log")"
  actual_status=$?
  if [ "${actual_status}" -ne "$1" ]; then
    fail "--classify exited with status ${actual_status}, not $1, for: $3"
  fi
  expected="${2:+${work}/log: $2}"
  if [ "${actual}" != "${expected}" ]; then
    fail "--classify printed '${actual}' rather than '${expected}' for: $3"
  fi
}

gradle_429="   > Could not GET 'https://repo.maven.apache.org/x.pom'. Received status code 429 from server: Too Many Requests"
check_classify 0 "> Could not GET 'https://repo.maven.apache.org/x.pom'. Received status code 429 from server: Too Many Requests" \
  "BUILD FAILED
${gradle_429}"
check_classify 0 "fatal: unable to access 'https://github.com/a/b/': Could not resolve host: github.com" \
  "2026-10-31T13:39:57.3265176Z fatal: unable to access 'https://github.com/a/b/': Could not resolve host: github.com"
check_classify 0 "Caused by: java.net.SocketTimeoutException: Read timed out" \
  "$(printf '\033[31mCaused by: java.net.SocketTimeoutException: Read timed out\033[0m\r')"
check_classify 0 "The runner has received a shutdown signal." \
  "The runner has received a shutdown signal."
check_classify 0 "We stopped hearing from agent Azure Pipelines 3." \
  "We stopped hearing from agent Azure Pipelines 3."
check_classify 1 "" \
  "Execution failed for task ':spotlessJavaCheck'.
BUILD FAILED in 28s"
check_classify 1 "" "Could not GET 'https://repo.maven.apache.org/x.pom'. Received status code 404 from server: Not Found"
# A shell trace line, as from a script that looks for network errors itself.
check_classify 1 "" \
  "+ grep -q -E 'Connection (reset|refused)|Read timed out|UnknownHostException' /tmp/log
2026-10-31T13:41:49.6228534Z ++ echo 'Connection reset'"

if printf 'Connection reset\n' | "${RERUN}" --classify > /dev/null; then :; else
  fail "--classify failed on standard input"
fi
if "${RERUN}" --classify "${work}/no-such-file" > /dev/null 2>&1; then
  fail "--classify succeeded on a nonexistent file"
fi
if "${RERUN}" --max-attempts 0 > /dev/null 2>&1; then
  fail "--max-attempts 0 was accepted"
fi
if "${RERUN}" --no-such-option > /dev/null 2>&1; then
  fail "an unknown option was accepted"
fi

###########################################################################
### Fake servers
###

# The fake commands serve the file ${work}/api/PATH/_ for a request for PATH,
# so that both PATH and PATH/MORE can be served,
# and record each rerun request in ${work}/reruns.
bin="${work}/bin"
api="${work}/api"
mkdir -p "${bin}" || exit 1

# The fake `curl` serves https://circleci.com/PATH and https://HOST/PATH,
# ignoring a query string.  It records the URL and body of a POST or PATCH
# request.
cat > "${bin}/curl" << 'EOF'
#!/bin/sh
body=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d) body="$2"; shift ;;
    -H | -X) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
path="${url#https://}"
path="${path#circleci.com/}"
if [ -n "${body}" ]; then
  printf '%s %s\n' "${path}" "${body}" >> "${FAKE_API}/../reruns"
  printf '{"workflow_id": "new-workflow"}\n'
  exit 0
fi
path="${path%%\?*}"
if [ ! -f "${FAKE_API}/${path}/_" ]; then
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
cat "${FAKE_API}/${path}/_"
EOF

# The fake `gh` supports `gh api PATH [--paginate] [--jq EXPR]`,
# `gh run view --repo REPO --job JOB --log-failed`, `gh run rerun`, and
# `gh pr checks PR --json ...`.
cat > "${bin}/gh" << 'EOF'
#!/bin/sh
case "$1 $2" in
  "api "* | "api --paginate")
    shift
    if [ "$1" = "--paginate" ]; then shift; fi
    path="${1%%\?*}"
    if [ ! -f "${FAKE_API}/${path}/_" ]; then
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    if [ "$2" = "--jq" ]; then
      jq -r "$3" "${FAKE_API}/${path}/_"
    else
      cat "${FAKE_API}/${path}/_"
    fi
    ;;
  "run view")
    cat "${FAKE_API}/gha-log-$6/_"
    ;;
  "run rerun")
    shift 2
    echo "gh run rerun $*" >> "${FAKE_API}/../reruns"
    ;;
  "pr checks")
    cat "${FAKE_API}/pr-$3/_"
    ;;
  *)
    echo "fake gh: unsupported: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${bin}/curl" "${bin}/gh" || exit 1

# Usage: put PATH CONTENT
# Makes the fake server serve CONTENT for PATH.
put() {
  mkdir -p "${api}/$1" || exit 1
  printf '%s\n' "$2" > "${api}/$1/_" || exit 1
}

# Usage: run_rerun EXPECTED-RERUNS ARG...
# Runs rerun-failed-ci ARG... against the fake servers, and checks that the
# reruns it requests are EXPECTED-RERUNS, one per line.
run_rerun() {
  expected="$1"
  shift
  : > "${work}/reruns"
  if ! PATH="${bin}:${PATH}" FAKE_API="${api}" CIRCLECI_CLI_TOKEN=token \
    AZURE_DEVOPS_EXT_PAT=token "${RERUN}" "$@" > "${work}/output" 2>&1; then
    fail "rerun-failed-ci $* failed:"
    cat "${work}/output"
  fi
  actual="$(cat "${work}/reruns")"
  if [ "${actual}" != "${expected}" ]; then
    fail "rerun-failed-ci $* requested reruns
'${actual}'
rather than
'${expected}'
Its output was:"
    cat "${work}/output"
  fi
}

###########################################################################
### CircleCI
###

# Usage: circleci_workflow ID STATUS
circleci_workflow() {
  put "api/v2/workflow/$1" "{\"name\": \"build\", \"status\": \"$2\",
    \"project_slug\": \"gh/org/repo\", \"pipeline_id\": \"pipe-$1\",
    \"pipeline_number\": 7}"
  put "api/v2/pipeline/pipe-$1/workflow" \
    "{\"items\": [{\"id\": \"$1\", \"name\": \"build\", \"created_at\": \"2026-01-01\"}]}"
}

# Usage: circleci_job NUMBER LOG-TEXT
# Makes the fake server serve a job whose failed step printed LOG-TEXT.
circleci_job() {
  put "api/v1.1/project/github/org/repo/$1" \
    "{\"steps\": [{\"actions\": [{\"status\": \"success\", \"output_url\": \"https://logs/ok-$1\"}]},
                 {\"actions\": [{\"status\": \"failed\", \"output_url\": \"https://logs/out-$1\"}]}]}"
  put "logs/out-$1" "$(jq -n --arg m "$2" '[{"message": $m}]')"
  put "logs/ok-$1" '[{"message": "Connection reset, but this step succeeded"}]'
}

# Every failed job failed transiently:  rerun from failed.
circleci_workflow wf1 failed
put api/v2/workflow/wf1/job '{"items": [
  {"job_number": 11, "id": "id11", "status": "failed", "name": "a"},
  {"job_number": 12, "id": "id12", "status": "success", "name": "b"},
  {"job_number": 13, "id": "id13", "status": "infrastructure_fail", "name": "c"}]}'
circleci_job 11 "${gradle_429}"
run_rerun 'api/v2/workflow/wf1/rerun {"from_failed": true}' \
  https://app.circleci.com/workflow/wf1?utm_source=github-checks-link
run_rerun '' --dry-run https://app.circleci.com/workflow/wf1
if ! grep -q 'Would rerun the failed jobs' "${work}/output"; then
  fail "--dry-run did not report the rerun"
  cat "${work}/output"
fi

# Only some failed jobs failed transiently:  rerun those jobs.
circleci_workflow wf2 failed
put api/v2/workflow/wf2/job '{"items": [
  {"job_number": 21, "id": "id21", "status": "failed", "name": "a"},
  {"job_number": 22, "id": "id22", "status": "failed", "name": "b"},
  {"job_number": 23, "id": "id23", "status": "failed", "name": "c"}]}'
circleci_job 21 "Connection reset"
circleci_job 22 "Test failed"
circleci_job 23 "Could not resolve host: github.com"
run_rerun 'api/v2/workflow/wf2/rerun {"jobs": ["id21","id23"]}' \
  https://app.circleci.com/pipelines/gh/org/repo/7/workflows/wf2

# A URL that names one job reruns only that job.
run_rerun 'api/v2/workflow/wf2/rerun {"jobs": ["id23"]}' \
  'https://app.circleci.com/pipelines/gh/org/repo/7/details?workflowId=wf2&job=id23&buildNumber=23&jobType=build#step-107-'
run_rerun '' 'https://app.circleci.com/pipelines/gh/org/repo/7/details?workflowId=wf2&job=id22&buildNumber=22'

# A job URL from a GitHub commit status.
put api/v2/project/gh/org/repo/job/21 '{"latest_workflow": {"id": "wf2"}}'
run_rerun 'api/v2/workflow/wf2/rerun {"jobs": ["id21"]}' \
  'https://circleci.com/gh/org/repo/21?utm_campaign=vcs-integration-link'

# A workflow that is still running, or that has been rerun, or that has
# reached the attempt limit, is not rerun.
circleci_workflow wf3 failing
put api/v2/workflow/wf3/job '{"items": [
  {"job_number": 31, "id": "id31", "status": "failed", "name": "a"}]}'
circleci_job 31 "Connection reset"
run_rerun '' https://app.circleci.com/workflow/wf3
circleci_workflow wf3 failed
put api/v2/pipeline/pipe-wf3/workflow '{"items": [
  {"id": "wf3-rerun", "name": "build", "created_at": "2026-01-02"},
  {"id": "wf3", "name": "build", "created_at": "2026-01-01"},
  {"id": "other", "name": "other", "created_at": "2026-01-03"}]}'
run_rerun '' https://app.circleci.com/workflow/wf3
put api/v2/pipeline/pipe-wf3/workflow '{"items": [
  {"id": "wf3", "name": "build", "created_at": "2026-01-03"},
  {"id": "wf3-first", "name": "build", "created_at": "2026-01-01"},
  {"id": "other", "name": "other", "created_at": "2026-01-04"}]}'
run_rerun '' --max-attempts 2 https://app.circleci.com/workflow/wf3
run_rerun 'api/v2/workflow/wf3/rerun {"from_failed": true}' \
  https://app.circleci.com/workflow/wf3

###########################################################################
### GitHub Actions
###

# Usage: gha_run ID STATUS CONCLUSION ATTEMPT
gha_run() {
  put "repos/org/repo/actions/runs/$1" "{\"name\": \"CI\", \"status\": \"$2\",
    \"conclusion\": \"$3\", \"run_attempt\": $4}"
}

# Usage: gha_job ID LOG-TEXT
gha_job() {
  put "gha-log-$1" "$(printf 'job\tstep\t\357\273\2772026-10-31T13:39:57.3265176Z %s' "$2")"
  put "repos/org/repo/check-runs/$1/annotations" '[{"message": "Process completed with exit code 1."}]'
}

gha_run 100 completed failure 1
put repos/org/repo/actions/runs/100/jobs '{"jobs": [
  {"id": 101, "name": "a", "conclusion": "failure"},
  {"id": 102, "name": "b", "conclusion": "success"},
  {"id": 103, "name": "c", "conclusion": "failure"}]}'
gha_job 101 "${gradle_429}"
gha_job 103 "Connection reset"
run_rerun 'gh run rerun --repo org/repo --failed 100' \
  https://github.com/org/repo/actions/runs/100

# Only some failed jobs failed transiently:  rerun one of them.
gha_job 103 "Test failed"
put repos/org/repo/actions/runs/100/jobs '{"jobs": [
  {"id": 101, "name": "a", "conclusion": "failure"},
  {"id": 103, "name": "c", "conclusion": "failure"},
  {"id": 104, "name": "d", "conclusion": "failure"}]}'
gha_job 104 "Read timed out"
run_rerun 'gh run rerun --repo org/repo --job 101' \
  https://github.com/org/repo/actions/runs/100
if ! grep -q 'rerun the other' "${work}/output"; then
  fail "the output does not mention the other jobs to rerun"
  cat "${work}/output"
fi

# A URL that names one job reruns only that job.
run_rerun 'gh run rerun --repo org/repo --job 104' \
  https://github.com/org/repo/actions/runs/100/job/104
run_rerun '' https://github.com/org/repo/actions/runs/100/job/103
# A job that the latest attempt does not include has been rerun.
run_rerun '' https://github.com/org/repo/actions/runs/100/job/999

# A run that is in progress, or that has reached the attempt limit, is not
# rerun.
gha_run 100 in_progress null 1
run_rerun '' https://github.com/org/repo/actions/runs/100
gha_run 100 completed failure 3
run_rerun '' https://github.com/org/repo/actions/runs/100

###########################################################################
### Azure Pipelines
###

azure=dev.azure.com/org/proj/_apis/build/builds

# Usage: azure_build ID STATUS RESULT
azure_build() {
  put "${azure}/$1" "{\"definition\": {\"name\": \"pipeline\"}, \"status\": \"$2\",
    \"result\": \"$3\"}"
}

# Usage: azure_timeline BUILD-ID [STAGE ATTEMPT JOB-NAME RESULT LOG-TEXT]...
# Makes the fake server serve the timeline of a build.  Each stage has one
# job, which has one task, whose log is LOG-TEXT.  A job's ID is its name.
azure_timeline() {
  build_id="$1"
  shift
  records='{"id": "other", "parentId": null, "type": "Checkpoint", "result": "failed"}'
  n=0
  while [ "$#" -gt 0 ]; do
    n=$((n + 1))
    records="${records},
      {\"id\": \"stage-$1\", \"parentId\": null, \"type\": \"Stage\",
       \"identifier\": \"$1\", \"attempt\": $2, \"result\": \"$4\"},
      {\"id\": \"phase-$3\", \"parentId\": \"stage-$1\", \"type\": \"Phase\",
       \"identifier\": \"$1.$3\", \"attempt\": $2, \"result\": \"$4\"},
      {\"id\": \"$3\", \"parentId\": \"phase-$3\", \"type\": \"Job\",
       \"name\": \"$3\", \"attempt\": $2, \"result\": \"$4\", \"log\": {\"id\": 99}},
      {\"id\": \"task-$3\", \"parentId\": \"$3\", \"type\": \"Task\",
       \"result\": \"$4\", \"log\": {\"id\": ${n}},
       \"issues\": [{\"message\": \"Bash exited with code '1'.\"}]}"
    put "${azure}/${build_id}/logs/${n}" \
      "$(printf '\357\273\2772026-10-31T13:39:57.3265176Z %s\r' "$5")"
    shift 5
  done
  put "${azure}/${build_id}/timeline" "{\"records\": [${records}]}"
}

# Every failed job failed transiently:  rerun the failed jobs of the build.
azure_build 500 completed failed
azure_timeline 500 \
  s1 1 a failed "${gradle_429}" \
  s1 1 b succeeded "" \
  s2 1 c failed "We stopped hearing from agent Azure Pipelines 3."
run_rerun "${azure}/500?retry=true&api-version=7.1 {}" \
  'https://dev.azure.com/org/proj/_build/results?buildId=500&view=logs&jobId=a'
run_rerun '' --dry-run 'https://dev.azure.com/org/proj/_build/results?buildId=500'
if ! grep -q 'Would rerun the failed jobs' "${work}/output"; then
  fail "--dry-run did not report the Azure Pipelines rerun"
  cat "${work}/output"
fi

# Only some failed jobs failed transiently:  rerun a stage whose failed jobs
# all failed transiently.
azure_build 600 completed failed
azure_timeline 600 \
  s1 1 a failed "Connection reset" \
  s1 1 b failed "Test failed" \
  s2 1 c failed "Read timed out" \
  s3 1 d failed "Could not resolve host: github.com" \
  s4 1 e failed "Test failed"
run_rerun "${azure}/600/stages/s2?api-version=7.1 {\"state\": \"retry\", \"forceRetryAllJobs\": false}" \
  'https://dev.azure.com/org/proj/_build/results?buildId=600'
for message in 'Not rerunning stage s1' 'rerun the other stages'; do
  if ! grep -q "${message}" "${work}/output"; then
    fail "the output does not contain '${message}'"
    cat "${work}/output"
  fi
done
# A stage that has reached the attempt limit is not rerun.
azure_timeline 600 \
  s2 3 c failed "Read timed out" \
  s3 1 d failed "Could not resolve host: github.com" \
  s4 1 e failed "Test failed"
run_rerun "${azure}/600/stages/s3?api-version=7.1 {\"state\": \"retry\", \"forceRetryAllJobs\": false}" \
  'https://dev.azure.com/org/proj/_build/results?buildId=600'
# A URL whose host is ORGANIZATION.visualstudio.com.
mkdir -p "${api}/myorg.visualstudio.com" || exit 1
cp -R "${api}/dev.azure.com/org/proj" "${api}/myorg.visualstudio.com/" || exit 1
run_rerun "myorg.visualstudio.com/proj/_apis/build/builds/600/stages/s3?api-version=7.1 {\"state\": \"retry\", \"forceRetryAllJobs\": false}" \
  'https://myorg.visualstudio.com/proj/_build/results?buildId=600'

# A build that is in progress, or that has reached the attempt limit, is not
# rerun.
azure_build 500 inProgress null
run_rerun '' 'https://dev.azure.com/org/proj/_build/results?buildId=500'
azure_build 500 completed failed
azure_timeline 500 s1 3 a failed "Connection reset"
run_rerun '' 'https://dev.azure.com/org/proj/_build/results?buildId=500'

# Rerunning requires a token.
azure_timeline 500 s1 1 a failed "Connection reset"
: > "${work}/reruns"
if PATH="${bin}:${PATH}" FAKE_API="${api}" AZURE_DEVOPS_EXT_PAT='' \
  "${RERUN}" 'https://dev.azure.com/org/proj/_build/results?buildId=500' \
  > "${work}/output" 2>&1; then
  fail "rerun-failed-ci succeeded without an Azure DevOps token"
fi
if [ -s "${work}/reruns" ] || ! grep -q 'AZURE_DEVOPS_EXT_PAT is not set' "${work}/output"; then
  fail "rerun-failed-ci did not report the missing Azure DevOps token"
  cat "${work}/output"
fi

###########################################################################
### Pull requests
###

# A pull request's failed checks:  two jobs of one GitHub Actions run, which
# is examined once, a CircleCI workflow, two jobs of one Azure Pipelines
# build, which is examined once, and an unsupported service.
gha_run 100 completed failure 1
put repos/org/repo/actions/runs/100/jobs '{"jobs": [
  {"id": 101, "name": "a", "conclusion": "failure"},
  {"id": 104, "name": "d", "conclusion": "failure"}]}'
put pr-5 '[
  {"name": "a", "bucket": "fail", "link": "https://github.com/org/repo/actions/runs/100/job/101"},
  {"name": "d", "bucket": "fail", "link": "https://github.com/org/repo/actions/runs/100/job/104"},
  {"name": "e", "bucket": "pass", "link": "https://github.com/org/repo/actions/runs/200/job/201"},
  {"name": "build", "bucket": "fail", "link": "https://app.circleci.com/workflow/wf1?utm_source=github-checks-link"},
  {"name": "p1", "bucket": "fail", "link": "https://dev.azure.com/org/proj/_build/results?buildId=500&view=logs&jobId=a"},
  {"name": "p2", "bucket": "fail", "link": "https://dev.azure.com/org/proj/_build/results?buildId=500&view=logs&jobId=b"},
  {"name": "other", "bucket": "fail", "link": "https://example.com/build/1"}]'
run_rerun "gh run rerun --repo org/repo --failed 100
api/v2/workflow/wf1/rerun {\"from_failed\": true}
${azure}/500?retry=true&api-version=7.1 {}" 5
if ! grep -q 'other: skipping a check from an unsupported CI service' "${work}/output"; then
  fail "the output does not mention the unsupported check"
  cat "${work}/output"
fi

exit "${status}"
