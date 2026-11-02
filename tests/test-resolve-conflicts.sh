#!/bin/sh

# Tests that `resolve-conflicts` runs the chains that pr-status.md lists
# under "Dependency chains with conflicts", with an AI agent resolving the
# conflicts, and that it refuses a command that `pr-status` does not write.
#
# Usage:
#   tests/test-resolve-conflicts.sh
#
# The test runs a copy of the commands in which a stub `pr-status` writes
# pr-status.md, and a stub `claude` stands in for the agent.
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.

# The shell commands in single quotes end with a literal backslash, as the
# ones that pr-status writes do.
# shellcheck disable=SC1003

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(CDPATH='' cd -- "${TESTS_DIR}/.." && pwd -P)" || exit 1

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

# The test repository contains no build file, so skip compilation.
MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1
export MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

mkdir "${WORK_DIR}/test-bin"
STUB_LOG="${WORK_DIR}/stub-log"
export STUB_LOG

## The stub agent removes the conflict marker lines of file.txt and the merge
## base's text, keeping both sides.
cat > "${WORK_DIR}/test-bin/claude" << 'EOF'
#!/bin/sh
echo claude >> "${STUB_LOG}"
cat > /dev/null
sed -e '/^<<<<<<< /d' -e '/^||||||| /,/^=======$/d' -e '/^=======$/d' -e '/^>>>>>>> /d' \
  file.txt > file.txt.new
mv file.txt.new file.txt
EOF

## A copy of the commands, in which the stub pr-status replaces the real one.
mkdir "${WORK_DIR}/commands"
for command_file in "${COMMANDS_DIR}"/*; do
  if [ -f "${command_file}" ]; then cp -p "${command_file}" "${WORK_DIR}/commands/"; fi
done

## The stub pr-status writes pr-status.md in the current directory.  On
## its first run, the section of chains with conflicts contains the commands
## in ${STUB_COMMANDS}; afterward, it contains none.
cat > "${WORK_DIR}/commands/pr-status" << 'EOF'
#!/bin/sh
echo pr-status >> "${STUB_LOG}"
if grep -q -x pr-status-ran "${STUB_LOG}"; then
  commands=''
else
  echo pr-status-ran >> "${STUB_LOG}"
  commands="${STUB_COMMANDS}"
fi
{
  echo '# PR dependencies'
  echo
  echo '<!-- BEGIN GENERATED: conflicting-push-commands -->'
  echo '```sh'
  echo "cd $(pwd) && \\"
  if [ -n "${commands}" ]; then printf '%s\n' "${commands}"; fi
  echo 'echo "success"'
  echo '```'
  echo '<!-- END GENERATED: conflicting-push-commands -->'
} > pr-status.md
EOF
chmod +x "${WORK_DIR}/test-bin/claude" "${WORK_DIR}/commands/pr-status"

## Usage: setup_case NAME
## Creates ${WORK_DIR}/NAME, the directory that holds the working copy
## directories, with a remote whose branches "main" and "feature" conflict, and
## a clone of each, myrepo-branch-main and myrepo-branch-feature.
## Sets ${case_dir}.
setup_case() {
  case_dir="${WORK_DIR}/$1"
  mkdir "${case_dir}"
  remote="${case_dir}/myrepo.git"
  git init -q --bare -b main "${remote}"
  git init -q -b main "${case_dir}/seed"
  printf '%s\n' one two three > "${case_dir}/seed/file.txt"
  git -C "${case_dir}/seed" add file.txt
  git -C "${case_dir}/seed" commit -q -m "Initial commit"
  git -C "${case_dir}/seed" remote add origin "${remote}"
  git -C "${case_dir}/seed" push -q --set-upstream origin main
  git -C "${case_dir}/seed" push -q origin main:refs/heads/feature
  for branch in main feature; do
    git clone -q -b "${branch}" "${remote}" "${case_dir}/myrepo-branch-${branch}"
    git -C "${case_dir}/myrepo-branch-${branch}" config pull.rebase false
    printf '%s\n' one "two-${branch}" three > "${case_dir}/myrepo-branch-${branch}/file.txt"
    git -C "${case_dir}/myrepo-branch-${branch}" commit -q -a -m "Change ${branch}"
    git -C "${case_dir}/myrepo-branch-${branch}" push -q
  done
  : > "${STUB_LOG}"
}

## Usage: resolve_conflicts
## Runs `resolve-conflicts` in ${case_dir}, and sets ${resolve_status} and
## ${resolve_output}.
resolve_conflicts() {
  if resolve_output="$(cd "${case_dir}" && PATH="${WORK_DIR}/test-bin:${PATH}" \
    "${WORK_DIR}/commands/resolve-conflicts" 2>&1)"; then
    resolve_status=0
  else
    resolve_status=$?
  fi
}

## A chain with conflicts is pushed, and pr-status runs again.
setup_case chain
STUB_COMMANDS="$(printf '%s\n' 'git-push-to \' '  myrepo-branch-main \' '  myrepo-branch-feature && \')"
export STUB_COMMANDS
resolve_conflicts
if [ "${resolve_status}" -ne 0 ]; then
  fail "chain: resolve-conflicts failed: ${resolve_output}"
fi
if [ "$(grep -c -x pr-status "${STUB_LOG}")" -ne 2 ] || [ "$(grep -c -x claude "${STUB_LOG}")" -ne 1 ]; then
  fail "chain: expected pr-status twice and claude once, but ran: $(cat "${STUB_LOG}")"
fi
expected="$(printf '%s\n' one two-feature two-main three)"
if [ "$(git -C "${case_dir}/myrepo.git" show refs/heads/feature:file.txt)" != "${expected}" ]; then
  fail "chain: the resolved merge was not pushed"
fi

## No chain with conflicts:  nothing to do.
setup_case none
STUB_COMMANDS=''
resolve_conflicts
if [ "${resolve_status}" -ne 0 ]; then
  fail "no chain: resolve-conflicts failed: ${resolve_output}"
fi
case "${resolve_output}" in
  *"no dependency chain has conflicts"*) ;;
  *) fail "no chain: wrong output: ${resolve_output}" ;;
esac

## A command that pr-status does not write is refused, and nothing runs.
# shellcheck disable=SC2016 # The command substitution must not be expanded.
for bad_command in 'touch pwned && \' 'git-push-to $(touch pwned) myrepo-branch-feature && \' 'git-push-to * && \'; do
  setup_case refuse
  STUB_COMMANDS="$(printf '%s\n' 'git-push-to \' '  myrepo-branch-main \' '  myrepo-branch-feature && \' "${bad_command}")"
  resolve_conflicts
  if [ "${resolve_status}" -eq 0 ]; then
    fail "refuse: resolve-conflicts accepted: ${bad_command}"
  fi
  case "${resolve_output}" in
    *"unexpected command"*) ;;
    *) fail "refuse: wrong diagnostic for ${bad_command}: ${resolve_output}" ;;
  esac
  if [ -s "${STUB_LOG}" ] && grep -q -x claude "${STUB_LOG}"; then
    fail "refuse: a chain ran despite: ${bad_command}"
  fi
  if [ -e "${case_dir}/pwned" ]; then
    fail "refuse: the command ran: ${bad_command}"
  fi
  rm -rf "${case_dir}"
done

echo "${SCRIPT_NAME}: all tests passed"
