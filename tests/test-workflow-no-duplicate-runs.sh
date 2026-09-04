#!/bin/sh

# Tests that the prek workflow runs at most once per commit.  A pull request
# from a branch of this repository fires both the `push` event and the
# `pull_request` event, so the job must run for only one of the two.  A pull
# request from a fork fires only the `pull_request` event, so the job must run
# for that one.
#
# The test reads the workflow's `on:` triggers and the job's `if:` condition,
# then evaluates the condition against a synthetic context for each event.
#
# Usage:
#   tests/test-workflow-no-duplicate-runs.sh

set -e

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"
REPO_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)"
WORKFLOW="${REPO_DIR}/.github/workflows/prek.yaml"

# The value of `github.repository` when the workflow runs in this repository.
REPOSITORY='plume-lib/manage-git-branches'

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $1" >&2
  exit 1
}

# Prints the argument with its enclosing single quotes removed.
unquote() {
  value="$1"
  case "${value}" in
    "'"*"'") ;;
    *) fail "not a string literal: $1" ;;
  esac
  value="${value#\'}"
  printf '%s\n' "${value%\'}"
}

# Prints "true" or "false": the value of the GitHub Actions `if:` condition $1
# for an event named $2 whose pull request comes from repository $3 (empty for
# an event that is not a pull request).
#
# This understands only the subset of the expression language that the workflow
# uses: `github.` context references and single-quoted string literals, compared
# with `==` or `!=`, joined by `||`.  Anything else is a test failure rather
# than a silently wrong answer.
evaluate_condition() {
  condition="$1"
  expanded="$(printf '%s\n' "${condition}" | sed \
    -e "s|github\.event_name|'$2'|g" \
    -e "s|github\.event\.pull_request\.head\.repo\.full_name|'$3'|g" \
    -e "s|github\.repository|'${REPOSITORY}'|g")"
  case "${expanded}" in
    *github.* | *'&&'* | *'('* | *'!'[!=]*) fail "cannot evaluate condition: ${condition}" ;;
  esac

  result=false
  terms="$(printf '%s\n' "${expanded}" | awk -F'\\|\\|' '{ for (i = 1; i <= NF; i++) print $i }')"
  while IFS= read -r term; do
    [ -n "${term}" ] || continue
    set -f
    # Word splitting is intended here; no string literal contains a space.
    # shellcheck disable=SC2086
    set -- ${term}
    set +f
    [ $# -eq 3 ] || fail "cannot parse \"${term}\" in condition: ${condition}"
    lhs="$(unquote "$1")"
    rhs="$(unquote "$3")"
    case "$2" in
      '==') if [ "${lhs}" = "${rhs}" ]; then result=true; fi ;;
      '!=') if [ "${lhs}" != "${rhs}" ]; then result=true; fi ;;
      *) fail "cannot evaluate operator \"$2\" in condition: ${condition}" ;;
    esac
  done << INNER_EOF
${terms}
INNER_EOF
  printf '%s\n' "${result}"
}

[ -f "${WORKFLOW}" ] || fail "no such file: ${WORKFLOW}"

# The test assumes that the workflow fires on a push to any branch and on any
# pull request.  If that changes, this test needs to change with it.
triggers="$(sed -n 's/^"\{0,1\}on"\{0,1\}: *//p' "${WORKFLOW}")"
if [ "${triggers}" != '[push, pull_request]' ]; then
  fail "expected the workflow triggers to be [push, pull_request], found \"${triggers}\""
fi

# An absent `if:` means the job always runs.
condition="$(sed -n 's/^    if: *//p' "${WORKFLOW}")"
if [ -z "${condition}" ]; then
  condition="'x' == 'x'"
fi

# A pull request from a branch of this repository fires both events.
push_run="$(evaluate_condition "${condition}" push '')"
same_repo_pr_run="$(evaluate_condition "${condition}" pull_request "${REPOSITORY}")"
if [ "${push_run}" = true ] && [ "${same_repo_pr_run}" = true ]; then
  fail "the job runs twice for a pull request from a branch of this repository"
fi
if [ "${push_run}" = false ] && [ "${same_repo_pr_run}" = false ]; then
  fail "the job never runs for a pull request from a branch of this repository"
fi

# A push to a branch with no pull request fires only the push event.
if [ "${push_run}" != true ]; then
  fail "the job does not run for a push"
fi

# A pull request from a fork fires only the pull_request event.
fork_pr_run="$(evaluate_condition "${condition}" pull_request 'someone-else/manage-git-branches')"
if [ "${fork_pr_run}" != true ]; then
  fail "the job does not run for a pull request from a fork"
fi

echo "${SCRIPT_NAME}: OK"
