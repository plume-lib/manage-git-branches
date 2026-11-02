#!/bin/sh

# Tests that `git-remove-branch-directory` removes a linked worktree whose
# commits GitHub holds in a landed pull request, even when the pull request
# gained commits that the worktree's branch lacks, so that `git-outgoing`
# cannot tell that the branch's changes have landed.
#
# Usage:
#   tests/test-git-remove-branch-directory-landed-prs.sh
#
# The exit status is 0 if all tests pass, 1 otherwise.
#
# A fake `gh` stands in for GitHub, and `url.BASE.insteadOf` maps the
# remote's GitHub URL to a local repository, so the test needs no network.

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMAND="${TESTS_DIR}/../git-remove-branch-directory"

# shellcheck source=lib-git-test-env.sh
. "${TESTS_DIR}/lib-git-test-env.sh"

status=0

fail() {
  echo "${SCRIPT_NAME}: FAIL: $*" >&2
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

# The repository that stands in for GitHub's someone/proj.
github="${work}/github.git"

# The fake `gh`.  `gh repo view` prints the base repository, someone/proj,
# and its default branch, main.  `gh api` for a repository's pull requests
# prints ${FAKE_GH_PULLS}, the lines that the real `gh` would print after
# applying the `--jq` filter.  `gh api` for a comparison of two commits
# prints the comparison's status, which it computes in ${github}, and fails
# if ${github} lacks either commit, as GitHub does.  All fail if
# ${FAKE_GH_FAIL} is non-empty.  Each call's arguments are appended to
# ${work}/gh.log.
mkdir -p "${work}/bin"
cat > "${work}/bin/gh" << EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${work}/gh.log"
if [ -n "\${FAKE_GH_FAIL}" ]; then exit 1; fi
case "\$1 \$2" in
  'repo view') echo 'someone/proj main' ;;
  'api -X')
    case "\$4" in
      */pulls) if [ -n "\${FAKE_GH_PULLS}" ]; then printf '%s\n' "\${FAKE_GH_PULLS}"; fi ;;
      */compare/*)
        basehead="\${4##*/compare/}"
        base="\${basehead%...*}"
        head="\${basehead#*...}"
        git --git-dir="${github}" cat-file -e "\${base}^{commit}" 2> /dev/null \\
          && git --git-dir="${github}" cat-file -e "\${head}^{commit}" 2> /dev/null \\
          || exit 1
        if [ "\${base}" = "\${head}" ]; then
          echo identical
        elif git --git-dir="${github}" merge-base --is-ancestor "\${base}" "\${head}"; then
          echo ahead
        elif git --git-dir="${github}" merge-base --is-ancestor "\${head}" "\${base}"; then
          echo behind
        else
          echo diverged
        fi
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${work}/bin/gh"
PATH="${work}/bin:${PATH}"
export PATH

git init -q --bare -b main "${github}"
git config --global "url.${github}.insteadOf" 'https://github.com/someone/proj'
git clone -q "${github}" "${work}/seed" 2> /dev/null
echo "hello" > "${work}/seed/file.txt"
git -C "${work}/seed" add file.txt
git -C "${work}/seed" commit -q -m "Initial commit"
git -C "${work}/seed" push -q origin main

# The clone whose worktrees are removed.  Its configured URL is GitHub's.
host="${work}/proj"
git clone -q 'https://github.com/someone/proj' "${host}"

## Usage: make_landed_worktree BRANCH [--no-upstream]
## Adds a linked worktree ${work}/proj-branch-BRANCH of ${host} on a new branch
## BRANCH, as `git-new-branch` does, and pushes a commit on it, setting the
## branch's upstream unless --no-upstream is given.  Then, as
## another clone, adds a commit to the remote branch that ${host} never
## fetches, squash-merges the remote branch into `main` as landing a pull
## request does, keeps the pull request's last commit in `refs/pull/1/head` as
## GitHub does, and deletes the remote branch.  Finally fetches into ${host},
## so that BRANCH's remote branch is gone.  Prints the pull request's last
## commit.
make_landed_worktree() {
  mlw_dir="${work}/proj-branch-$1"
  git -C "${host}" worktree add -q -b "$1" "${mlw_dir}"
  git -C "${host}" config "branch.$1.createdForBranchDirectory" true
  echo "work" > "${mlw_dir}/$1.txt"
  git -C "${mlw_dir}" add "$1.txt"
  git -C "${mlw_dir}" commit -q -m "Work on $1"
  if [ "$2" = --no-upstream ]; then
    git -C "${mlw_dir}" push -q origin "$1" 2> /dev/null
  else
    git -C "${mlw_dir}" push -q -u origin "$1" 2> /dev/null
  fi
  # The later commit changes the same line, so that neither merging BRANCH
  # into `main` nor merging it into the squash commit's parent reproduces the
  # squash commit, and `git-outgoing` does not omit BRANCH.
  git -C "${work}/seed" fetch -q origin "$1"
  git -C "${work}/seed" checkout -q -b "$1" FETCH_HEAD
  echo "better work" > "${work}/seed/$1.txt"
  git -C "${work}/seed" commit -q -a -m "Improve the work on $1"
  git -C "${work}/seed" push -q origin "$1"
  mlw_pr_head="$(git -C "${work}/seed" rev-parse HEAD)"
  git -C "${work}/seed" checkout -q main
  git -C "${work}/seed" merge -q --squash "$1" > /dev/null 2>&1
  git -C "${work}/seed" commit -q -m "Land $1"
  git -C "${work}/seed" push -q origin main
  git -C "${work}/seed" branch -q -D "$1"
  git --git-dir="${github}" update-ref "refs/pull/$1/head" "${mlw_pr_head}"
  git --git-dir="${github}" update-ref -d "refs/heads/$1"
  git -C "${host}" fetch -q --prune origin
  printf '%s\n' "${mlw_pr_head}"
}

## Usage: run_command DESCRIPTION EXPECTED-STATUS ARGUMENT...
## Runs the command under test, checks its exit status, and sets ${out} to
## everything that it printed.
run_command() {
  run_command_description="$1"
  run_command_expected="$2"
  shift 2
  out="$("${COMMAND}" "$@" 2>&1)"
  run_command_status="$?"
  if [ "${run_command_status}" -ne "${run_command_expected}" ]; then
    fail "${run_command_description}: exit status ${run_command_status}, expected ${run_command_expected}: ${out}"
  fi
}

## Usage: check_removed DESCRIPTION BRANCH
## Checks that the worktree of BRANCH and the branch itself are gone.
check_removed() {
  if [ -e "${work}/proj-branch-$2" ]; then
    fail "$1: ${work}/proj-branch-$2 was not removed"
  fi
  if git -C "${host}" rev-parse --verify --quiet "refs/heads/$2" > /dev/null; then
    fail "$1: the branch $2 is left"
  fi
}

## Usage: check_kept DESCRIPTION BRANCH
## Checks that the branch BRANCH still exists and that the last command
## refused to remove its worktree for its unpushed commits.
check_kept() {
  if ! git -C "${host}" rev-parse --verify --quiet "refs/heads/$2" > /dev/null; then
    fail "$1: the branch $2 was deleted"
  fi
  if ! printf '%s\n' "${out}" | grep -q -F -e '--force-unpushed'; then
    fail "$1: the output does not mention --force-unpushed: ${out}"
  fi
}

# A worktree whose branch's pull request landed, with a commit that the
# branch lacks, holds nothing that GitHub does not.
pr_head="$(make_landed_worktree landed)"
if [ "$(git -C "${host}" for-each-ref --format='%(upstream:track)' refs/heads/landed)" != '[gone]' ]; then
  fail "the setup: the remote branch of landed is not gone"
fi
if [ -n "$(cd "${host}" && "${TESTS_DIR}/../git-outgoing" --only-branch=landed --omitted)" ]; then
  fail "the setup: git-outgoing omits landed, so the test does not test GitHub's answer"
fi
FAKE_GH_PULLS="${pr_head} someone/proj"
export FAKE_GH_PULLS
run_command 'a landed pull request with later commits' 0 "${work}/proj-branch-landed"
check_removed 'a landed pull request with later commits' landed
if ! grep -q -F "repos/someone/proj/pulls -f head=someone:landed" "${work}/gh.log"; then
  fail "a landed pull request with later commits: gh was not asked about the pull requests"
fi

# The same, for a worktree whose directory was already removed with `rm -rf`,
# as `mdevc` finds them.
pr_head="$(make_landed_worktree rmrf)"
rm -rf "${work}/proj-branch-rmrf"
FAKE_GH_PULLS="${pr_head} someone/proj"
run_command 'a removed worktree of a landed pull request' 0 \
  --repository "${host}" "${work}/proj-branch-rmrf"
check_removed 'a removed worktree of a landed pull request' rmrf

# The same, for a branch that was pushed without setting its upstream, so
# that git does not report its remote branch as gone.
pr_head="$(make_landed_worktree noupstream --no-upstream)"
if [ -n "$(git -C "${host}" for-each-ref --format='%(upstream)' refs/heads/noupstream)" ]; then
  fail "the setup: the branch noupstream has an upstream"
fi
FAKE_GH_PULLS="${pr_head} someone/proj"
run_command 'a landed pull request from a branch without an upstream' 0 \
  "${work}/proj-branch-noupstream"
check_removed 'a landed pull request from a branch without an upstream' noupstream

# A commit made after the last push is not on GitHub, so it would be lost.
pr_head="$(make_landed_worktree unpushed)"
echo "unpushed work" >> "${work}/proj-branch-unpushed/unpushed.txt"
git -C "${work}/proj-branch-unpushed" commit -q -a -m "Unpushed work"
FAKE_GH_PULLS="${pr_head} someone/proj"
run_command 'an unpushed commit after a landed pull request' 1 \
  "${work}/proj-branch-unpushed"
check_kept 'an unpushed commit after a landed pull request' unpushed

# A pull request from a branch of the same name in another owner's repository
# is someone else's.
pr_head="$(make_landed_worktree elsewhere)"
FAKE_GH_PULLS="${pr_head} other/proj"
run_command "another repository's landed pull request" 1 \
  "${work}/proj-branch-elsewhere"
check_kept "another repository's landed pull request" elsewhere

# No landed pull request:  the real `gh` prints nothing for a pull request
# that was closed without landing.
FAKE_GH_PULLS=''
run_command 'no landed pull request' 1 "${work}/proj-branch-elsewhere"
check_kept 'no landed pull request' elsewhere

# When GitHub cannot be asked, nothing is known, so the commits count.
FAKE_GH_PULLS="${pr_head} someone/proj"
FAKE_GH_FAIL=1
export FAKE_GH_FAIL
run_command 'a failing gh' 1 "${work}/proj-branch-elsewhere"
check_kept 'a failing gh' elsewhere
unset FAKE_GH_FAIL

if [ "${status}" -eq 0 ]; then
  echo "${SCRIPT_NAME}: all tests passed"
fi
exit "${status}"
