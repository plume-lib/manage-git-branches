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

# The fake `gh`.  `gh repo view` prints ${FAKE_GH_PARENT}, which is empty for
# a repository that is not a fork; `gh pr list` prints ${FAKE_GH_PRS}, the
# lines that the real `gh` would print after applying the `--jq` filter.  Both
# fail if ${FAKE_GH_FAIL} is non-empty.  Each call's arguments are appended to
# ${work}/gh.log.
mkdir -p "${work}/bin"
cat > "${work}/bin/gh" << EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${work}/gh.log"
if [ -n "\${FAKE_GH_FAIL}" ]; then exit 1; fi
case "\$1 \$2" in
  'repo view') printf '%s\n' "\${FAKE_GH_PARENT}" ;;
  'pr list') if [ -n "\${FAKE_GH_PRS}" ]; then printf '%s\n' "\${FAKE_GH_PRS}"; fi ;;
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
git -C "${work}/seed" push -q origin main main:refs/heads/feature

mkdir -p "${work}/scan"
dir="${work}/scan/proj-branch-feature"
git clone -q -b feature 'https://github.com/someone/proj' "${dir}"
if [ "$(git -C "${dir}" config --get remote.origin.url)" != 'https://github.com/someone/proj' ]; then
  fail "the clone's configured URL is not the GitHub URL"
fi

# Runs git-orphaned-branches in ${work}/scan with the arguments, putting its
# standard output in ${out} and its standard error in ${err}.
scan() {
  out="$(cd "${work}/scan" && "${GIT_ORPHANED_BRANCHES}" "$@" 2> "${work}/err")"
  scan_status=$?
  err="$(cat "${work}/err")"
}

# Every pull request is closed or merged:  a warning, and nothing listed.
FAKE_GH_PARENT='upstream/proj' FAKE_GH_PRS="$(printf 'CLOSED 7\nMERGED 9')" scan
[ "${scan_status}" -eq 0 ] || fail "status ${scan_status} with closed pull requests"
[ -z "${out}" ] || fail "listed [${out}] with closed pull requests"
case "${err}" in
  *"warning: not listing ${dir}:  every pull request for branch feature of someone/proj is closed or merged (upstream/proj #7 (closed) #9 (merged))"*) ;;
  *) fail "unexpected warning with closed pull requests: [${err}]" ;;
esac
if ! grep -q -F -- 'pr list -R upstream/proj --head feature' "${work}/gh.log"; then
  fail "gh pr list did not ask the parent repository: $(cat "${work}/gh.log")"
fi

# --remove keeps the directory.
FAKE_GH_PARENT='' FAKE_GH_PRS='MERGED 9' scan --remove
[ -d "${dir}" ] || fail "--remove removed ${dir}"
case "${err}" in
  *"warning: not listing ${dir}:"*) ;;
  *) fail "--remove did not warn: [${err}]" ;;
esac

# An open pull request:  no warning.
FAKE_GH_PARENT='' FAKE_GH_PRS="$(printf 'CLOSED 7\nOPEN 8')" scan
[ -z "${err}" ] || fail "warned with an open pull request: [${err}]"

# No pull request:  no warning.
FAKE_GH_PARENT='' FAKE_GH_PRS='' scan
[ -z "${err}" ] || fail "warned with no pull request: [${err}]"

# gh fails:  no warning.
FAKE_GH_FAIL=1 FAKE_GH_PRS='CLOSED 7' scan
[ "${scan_status}" -eq 0 ] || fail "status ${scan_status} when gh fails"
[ -z "${err}" ] || fail "warned when gh fails: [${err}]"

# A remote that is not on GitHub:  gh is not asked.
: > "${work}/gh.log"
git -C "${dir}" config remote.origin.url "${work}/remote.git"
FAKE_GH_PRS='CLOSED 7' scan
[ -z "${err}" ] || fail "warned for a remote that is not on GitHub: [${err}]"
[ ! -s "${work}/gh.log" ] || fail "asked gh about a remote that is not on GitHub: $(cat "${work}/gh.log")"

if [ "${status}" = 0 ]; then
  echo "${SCRIPT_NAME}: OK"
fi
exit "${status}"
