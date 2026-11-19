#!/bin/sh

# Tests that `fix-ci-all` runs `fix-ci` once for each unblocked pull request
# whose CI failed, that the user opened, and that has a working copy
# directory, and for no other pull request.
#
# Usage:
#   tests/test-fix-ci-all.sh
#
# The status code is 0 if all the tests pass, and nonzero otherwise.
#
# The test writes the snapshot that `pr-status --print-unblocked-prs` reads,
# and passes `--no-pr-status`, so it needs no network.  A fake `gh` and a fake
# `fix-ci` stand in for GitHub and for Claude Code.

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
FIX_CI_ALL="${TESTS_DIR}/../fix-ci-all"

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

# The fake `gh api user` prints the user's login, "me".  The fake `gh pr
# view` prints the contents of the file .fake-pr-url of the current directory,
# which is the URL of the pull request that it shows there, and fails if there
# is no such file.
# The fake `fix-ci` appends the name of its directory and its arguments to
# ${work}/runs.log, and reads its standard input, as Claude Code can.  If the
# directory's name ends in "-fails", it fails.
mkdir -p "${work}/bin"
cat > "${work}/bin/gh" << 'EOF'
#!/bin/sh
case "$1 $2" in
  'api user') echo me ;;
  'pr view') cat .fake-pr-url 2> /dev/null ;;
  *) exit 1 ;;
esac
EOF
cat > "${work}/bin/fix-ci" << EOF
#!/bin/sh
dir="\$(basename -- "\$(pwd)")"
echo "\${dir}" "\$@" >> "${work}/runs.log"
cat > /dev/null
case "\${dir}" in
  *-fails) exit 1 ;;
esac
exit 0
EOF
chmod +x "${work}/bin/gh" "${work}/bin/fix-ci"
PATH="${work}/bin:${PATH}"
export PATH

scan="${work}/scan"
mkdir -p "${scan}"

# Usage: make_clone NAME [NUMBER]
# Creates a clone ${scan}/NAME whose commit differs from every other clone's,
# and prints that commit.  In the clone, `gh pr view` shows pull request
# NUMBER of someone/proj, or no pull request if NUMBER is absent.
make_clone() {
  git init -q -b main "${scan}/$1"
  git -C "${scan}/$1" commit -q --allow-empty -m "Commit of $1"
  if [ "$#" -ge 2 ]; then
    echo "https://github.com/someone/proj/pull/$2" > "${scan}/$1/.fake-pr-url"
  fi
  git -C "${scan}/$1" rev-parse HEAD
}

make_clone proj-branch-a 1 > /dev/null
a2_head="$(make_clone proj-branch-a2 1)"
make_clone proj-branch-b 2 > /dev/null
make_clone proj-branch-c-fails 3 > /dev/null
make_clone proj-branch-theirs 4 > /dev/null
make_clone proj-branch-passed 6 > /dev/null
make_clone proj-branch-upstream 99 > /dev/null
make_clone proj-fork-me-branch-upstream 8 > /dev/null
make_clone proj-branch-no-pr > /dev/null
make_clone proj-branch-tab 10 > /dev/null
tab="$(printf '\t')"
other_head=0123456789012345678901234567890123456789

# Usage: unblocked_pr NUMBER AUTHOR HEAD CI [DIRECTORY...]
# Prints the JSON object that `pr-status --print-unblocked-prs` prints for a
# pull request of someone/proj.
unblocked_pr() {
  unblocked_pr_number="$1"
  unblocked_pr_author="$2"
  unblocked_pr_head="$3"
  unblocked_pr_ci="$4"
  shift 4
  jq -n -c --argjson number "${unblocked_pr_number}" --arg author "${unblocked_pr_author}" \
    --arg head "${unblocked_pr_head}" --arg ci "${unblocked_pr_ci}" '
    {repo: "proj", gh: "someone/proj", number: $number,
     url: "https://github.com/someone/proj/pull/\($number)", author: $author, head: $head,
     directories: $ARGS.positional, ci: $ci}' --args "$@"
}

# PR 1's head is proj-branch-a2's HEAD, so `fix-ci` runs there, not in
# proj-branch-a.  No directory of PR 2 has its head, so `fix-ci` runs in the
# first one where `gh pr view` shows PR 2.  In the first directory of PR 8,
# `gh pr view` shows another pull request, as in a clone of the upstream
# repository with a branch of the same name, so `fix-ci` runs in the second.
# In no directory of PR 9 does `gh pr view` show PR 9, so it is skipped.
# PR 10's only directory has a tab in its name, so it is skipped; it is not
# mistaken for proj-branch-tab.
{
  unblocked_pr 1 me "${a2_head}" failed proj-branch-a proj-branch-a2
  unblocked_pr 2 me "${other_head}" failed proj-branch-b proj-branch-a
  unblocked_pr 3 me "${other_head}" failed proj-branch-c-fails
  unblocked_pr 4 someone "${other_head}" failed proj-branch-theirs
  unblocked_pr 5 me "${other_head}" failed
  unblocked_pr 6 me "${other_head}" passed proj-branch-passed
  unblocked_pr 7 me "${other_head}" pending proj-branch-passed
  unblocked_pr 8 me "${other_head}" failed proj-branch-upstream proj-fork-me-branch-upstream
  unblocked_pr 9 me "${other_head}" failed proj-branch-no-pr
  unblocked_pr 10 me "${other_head}" failed "proj-branch-tab${tab}x"
} | jq -s '{time: "now", facts: {}, unblocked_prs: .}' > "${scan}/.pr-status-snapshot.json"

# Usage: run_fix_ci_all ARGUMENT...
# Runs fix-ci-all with the ARGUMENTs, in ${scan}, after clearing
# ${work}/runs.log.  Sets ${output} to its standard output and standard error,
# and ${run_status} to its exit status.
run_fix_ci_all() {
  : > "${work}/runs.log"
  output="$(cd -- "${scan}" && "${FIX_CI_ALL}" "$@" 2>&1 < /dev/null)"
  run_status=$?
}

# Usage: expect_output TEXT
# Fails unless ${output} contains the line TEXT.
expect_output() {
  if ! printf '%s\n' "${output}" | grep -q -x -F -- "$1"; then
    fail "output lacks the line \"$1\":
${output}"
  fi
}

run_fix_ci_all --no-pr-status -- -p --model opus
expected_runs="proj-branch-a2 -p --model opus
proj-branch-b -p --model opus
proj-branch-c-fails -p --model opus
proj-fork-me-branch-upstream -p --model opus"
if [ "$(cat "${work}/runs.log")" != "${expected_runs}" ]; then
  fail "fix-ci ran in the wrong directories or with the wrong arguments:
$(cat "${work}/runs.log")"
fi
if [ "${run_status}" -ne 1 ]; then
  fail "exit status ${run_status}, not 1, when fix-ci failed in one directory"
fi
expect_output "===== proj-branch-a2: https://github.com/someone/proj/pull/1"
expect_output "fix-ci-all: skipping https://github.com/someone/proj/pull/4, which is by someone"
expect_output "fix-ci-all: skipping https://github.com/someone/proj/pull/5, which has no working copy directory"
expect_output "https://github.com/someone/proj/pull/3 (in proj-branch-c-fails)"
expect_output "fix-ci-all: skipping https://github.com/someone/proj/pull/9, which gh pr view shows in none of its working copy directories"
expect_output "fix-ci-all: skipping https://github.com/someone/proj/pull/10, which has no working copy directory"

# An argument that is not an option of fix-ci-all, before "--", is a usage
# error, even if it is a CLAUDE-OPTION or a misspelled option.
for argument in --dryrun -p; do
  run_fix_ci_all --no-pr-status "${argument}"
  if [ "${run_status}" -ne 2 ] || [ -s "${work}/runs.log" ]; then
    fail "argument ${argument} was not a usage error (status ${run_status}):
${output}
$(cat "${work}/runs.log")"
  fi
done

# "--" ends this command's options, so a later "--dry-run" is a CLAUDE-OPTION.
run_fix_ci_all --no-pr-status -C "${scan}" -- --dry-run
if [ "$(head -n 1 "${work}/runs.log")" != "proj-branch-a2 --dry-run" ]; then
  fail "after --, --dry-run was not passed to fix-ci:
$(cat "${work}/runs.log")"
fi

run_fix_ci_all --dry-run --no-pr-status
if [ -s "${work}/runs.log" ]; then
  fail "--dry-run ran fix-ci:
$(cat "${work}/runs.log")"
fi
if [ "${run_status}" -ne 0 ]; then
  fail "--dry-run exit status ${run_status}, not 0:
${output}"
fi
expect_output "Would run fix-ci in proj-branch-a2 for https://github.com/someone/proj/pull/1"
expect_output "Would run fix-ci in proj-branch-b for https://github.com/someone/proj/pull/2"

# A snapshot written by a pr-status that did not record the authors is an
# error.
jq '.unblocked_prs |= map(del(.author))' "${scan}/.pr-status-snapshot.json" \
  > "${work}/old-snapshot.json"
cp "${work}/old-snapshot.json" "${scan}/.pr-status-snapshot.json"
run_fix_ci_all --no-pr-status
if [ "${run_status}" -ne 1 ] || [ -s "${work}/runs.log" ]; then
  fail "a snapshot without authors did not fail without running fix-ci (status ${run_status}):
${output}"
fi

# No failing pull request:  nothing runs, and the exit status is 0.
jq '.unblocked_prs |= map(select(.ci != "failed"))' "${work}/old-snapshot.json" \
  > "${scan}/.pr-status-snapshot.json"
run_fix_ci_all --no-pr-status
if [ "${run_status}" -ne 0 ] || [ -s "${work}/runs.log" ]; then
  fail "with no failing pull request, status ${run_status}:
${output}"
fi

# A copy of this package whose `pr-status` is a fake.  With
# --print-unblocked-prs, the fake prints the unblocked pull requests that the
# snapshot records.  Otherwise, it writes its other arguments to
# ${work}/pr-status-args, copies ${work}/new-snapshot.json, if it exists, to
# the snapshot, and fails, as `pr-status` does when it cannot update a pull
# request's description.
pkg="${work}/pkg"
mkdir -p "${pkg}"
cp "${TESTS_DIR}"/../*.sh "${FIX_CI_ALL}" "${pkg}/"
cat > "${pkg}/pr-status" << EOF
#!/bin/sh
dir="\$2"
shift 2
if [ "\$1" = --print-unblocked-prs ]; then
  jq .unblocked_prs "\${dir}/.pr-status-snapshot.json"
  exit
fi
echo "\$@" > "${work}/pr-status-args"
if [ -f "${work}/new-snapshot.json" ]; then
  cp "${work}/new-snapshot.json" "\${dir}/.pr-status-snapshot.json"
fi
exit 1
EOF
chmod +x "${pkg}/pr-status"
FIX_CI_ALL="${pkg}/fix-ci-all"
unblocked_pr 1 me "${a2_head}" failed proj-branch-a2 \
  | jq -s '{time: "later", facts: {}, unblocked_prs: .}' > "${work}/new-snapshot.json"

# pr-status fails without writing the snapshot:  fix-ci-all fails, and runs
# no fix-ci.
mv "${work}/new-snapshot.json" "${work}/new-snapshot.json.saved"
run_fix_ci_all
if [ "${run_status}" -ne 1 ] || [ -s "${work}/runs.log" ]; then
  fail "when pr-status failed without writing the snapshot, status ${run_status}:
${output}
$(cat "${work}/runs.log")"
fi
expect_output "fix-ci-all: pr-status failed in ${scan}"
mv "${work}/new-snapshot.json.saved" "${work}/new-snapshot.json"

# --dry-run runs pr-status with --no-documents.
run_fix_ci_all --dry-run
if [ "$(cat "${work}/pr-status-args")" != "--no-documents" ]; then
  fail "--dry-run ran pr-status with the arguments \"$(cat "${work}/pr-status-args")\""
fi

# pr-status fails after writing the snapshot:  fix-ci-all runs fix-ci for
# the pull requests that the new snapshot records, and fails.
cp "${work}/old-snapshot.json" "${scan}/.pr-status-snapshot.json"
run_fix_ci_all
if [ "$(cat "${work}/pr-status-args")" != "" ]; then
  fail "fix-ci-all ran pr-status with the arguments \"$(cat "${work}/pr-status-args")\""
fi
if [ "${run_status}" -ne 1 ] || [ "$(cat "${work}/runs.log")" != "proj-branch-a2" ]; then
  fail "when pr-status failed after writing the snapshot, status ${run_status}:
${output}
$(cat "${work}/runs.log")"
fi

exit "${status}"
