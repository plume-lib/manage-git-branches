#!/bin/sh

# Tests `git-diff-upstream`.
#
# Usage:
#   tests/test-git-diff-upstream.sh
#
# The status code is 0 if all tests pass and 1 otherwise.
#
# The tests use local "remote" repositories, so they do not access the network.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"
COMMANDS_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)" || exit 1
GIT_DIFF_UPSTREAM="${COMMANDS_DIR}/git-diff-upstream"

. "${SCRIPT_DIR}/lib-git-test-env.sh"
# shellcheck source=common-test-functions.sh
. "${SCRIPT_DIR}/common-test-functions.sh"

failures=0

# Prints a message and records a test failure.
fail() {
  echo "${SCRIPT_NAME}: FAIL: $1" >&2
  failures=$((failures + 1))
}

# Usage: expect_files DESCRIPTION EXPECTED [ARGS]
# Runs `git-diff-upstream ARGS` in ${fork}, and checks that it
# succeeds and prints the file names EXPECTED, one per line.
expect_files() {
  description="$1"
  expected="$2"
  shift 2
  actual="$(cd "${fork}" && "${GIT_DIFF_UPSTREAM}" "$@" 2> "${testdir}/errors")"
  status="$?"
  if [ "${status}" -ne 0 ]; then
    fail "${description}: exited with status ${status}: $(cat "${testdir}/errors")"
  elif [ "${actual}" != "${expected}" ]; then
    fail "${description}: printed [${actual}], expected [${expected}]"
  fi
}

testdir="$(mktemp -d)"
trap 'rm -rf "${testdir}"' EXIT
trap 'rm -rf "${testdir}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${testdir}"; trap - TERM; kill -s TERM "$$"' TERM

sanitize_git_env "${testdir}"

# The canonical repository, whose default branch is not named "main", and a
# fork of it.
canonical="${testdir}/canonical.git"
git init -q --bare -b trunk "${canonical}"
canonical_work="${testdir}/canonical-work"
git clone -q "${canonical}" "${canonical_work}" 2> /dev/null
commit_file "${canonical_work}" a.txt 'a1'
commit_file "${canonical_work}" b.txt 'b1'
git -C "${canonical_work}" push -q origin trunk
fork_remote="${testdir}/fork.git"
git clone -q --bare "${canonical}" "${fork_remote}"

fork="${testdir}/fork"
git clone -q "${fork_remote}" "${fork}"
git -C "${fork}" switch -q -c feature
commit_file "${fork}" a.txt 'a2'

# With no `upstream` remote, the diff is against `origin`.
expect_files 'origin only' 'a.txt' --name-only

# Usage: merge_from_canonical BRANCH
# Merges the canonical repository's BRANCH into ${fork}'s current branch,
# without updating the remote-tracking branches of ${fork}, so that the merge
# base changes only once this command fetches.
merge_from_canonical() {
  git -C "${fork}" fetch -q "${canonical}" "$1" \
    && git -C "${fork}" merge -q --no-edit FETCH_HEAD
}

# `git remote add` does not create `upstream/HEAD`.
git -C "${fork}" remote add upstream "${canonical}"
commit_file "${canonical_work}" b.txt 'b2'
git -C "${canonical_work}" push -q origin trunk

# `--no-fetch` does not see the new commit in `upstream`, but this command
# still creates `upstream/HEAD`, which requires `upstream/trunk` to exist.
git -C "${fork}" fetch -q upstream
# A change in `upstream` that `feature` has not merged does not appear.
expect_files 'unmerged upstream change' 'a.txt' --no-fetch --name-only

commit_file "${canonical_work}" c.txt 'c1'
git -C "${canonical_work}" push -q origin trunk
merge_from_canonical trunk
expect_files '--no-fetch' 'a.txt
c.txt' --no-fetch --name-only

# Fetching moves the merge base to the new commit.
expect_files 'fetch' 'a.txt' --name-only

printf 'b3\n' > "${fork}/b.txt"
expect_files 'working tree' 'a.txt
b.txt' --name-only

# GIT-DIFF-ARGS may name paths.
expect_files 'path' 'b.txt' --name-only -- b.txt

# After `upstream` renames its default branch and a fetch with `--prune`
# deletes the old one, `upstream/HEAD` names a branch that does not exist.
git -C "${canonical}" branch -m trunk main
git -C "${fork}" fetch -q --prune upstream
# `rev-parse` warns about the dangling `upstream/HEAD`.
if git -C "${fork}" rev-parse --verify --quiet upstream/HEAD > /dev/null 2>&1; then
  fail 'renamed default branch: upstream/HEAD still resolves, so this test checks nothing'
fi
expect_files 'renamed default branch' 'a.txt
b.txt' --no-fetch --name-only

# After `upstream` renames its default branch again, a fetch without `--prune`
# keeps the old remote-tracking branch, so `upstream/HEAD` still resolves, to
# a commit that lacks the renamed branch's new commits.  `feature` merges
# those commits, so the diff from the old branch would show them.
git -C "${canonical}" branch -m main stable
commit_file "${canonical_work}" d.txt 'd1'
git -C "${canonical_work}" push -q origin HEAD:stable
merge_from_canonical stable
git -C "${fork}" config fetch.prune false
# Git 2.48 and later update `upstream/HEAD` during the fetch, so this command
# needs no `git remote set-head`, which would connect to the remote again.
make_counting_git "${testdir}/counting-git" "${testdir}/git-commands"
saved_path="${PATH}"
PATH="${testdir}/counting-git:${PATH}"
expect_files 'renamed default branch without --prune' 'a.txt
b.txt' --name-only
PATH="${saved_path}"
git_minor="$(git version | sed -n 's/^git version 2\.\([0-9]*\).*/\1/p')"
if [ -n "${git_minor}" ] && [ "${git_minor}" -ge 48 ] \
  && grep -q '^remote set-head' "${testdir}/git-commands"; then
  fail 'renamed default branch without --prune: ran git remote set-head'
fi

# A clone of a GitHub fork, me/proj, of someone/proj.  A fake `gh` stands in
# for GitHub:  `gh repo view` prints what the real `gh` does with this
# command's `--jq` filter:  the upstream repository and the default branch,
# which for me/proj are its parent, someone/proj, and for any other
# repository are the repository itself.  `gh auth token` succeeds unless
# ${FAKE_GH_NO_TOKEN} is non-empty, as when no user has logged in.  Each
# call's arguments are appended to ${testdir}/gh.log.  `url.BASE.insteadOf`
# maps each GitHub URL to a local repository, so the test needs no network.
mkdir -p "${testdir}/bin"
cat > "${testdir}/bin/gh" << EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${testdir}/gh.log"
case "\$1 \$2 \$3" in
  'auth token '*) [ -z "\${FAKE_GH_NO_TOKEN}" ] && echo 'fake-token' ;;
  'repo view github.com/me/proj') echo 'someone/proj trunk' ;;
  'repo view github.com/'*) echo "\${3#github.com/} trunk" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${testdir}/bin/gh"
saved_path="${PATH}"
PATH="${testdir}/bin:${PATH}"
gh_parent="${testdir}/gh-parent.git"
gh_fork="${testdir}/gh-fork.git"
git clone -q --bare "${canonical}" "${gh_parent}"
git clone -q --bare "${canonical}" "${gh_fork}"
git config --global "url.${gh_parent}.insteadOf" 'https://github.com/someone/proj.git'
git config --global "url.${gh_fork}.insteadOf" 'https://github.com/me/proj.git'
gh_parent_work="${testdir}/gh-parent-work"
git clone -q 'https://github.com/someone/proj.git' "${gh_parent_work}" 2> /dev/null

# Usage: make_fork_clone DIRECTORY
# Clones the fork into DIRECTORY, which has only the remote `origin`, and
# checks out a branch `feature` that changes a.txt and that merges the parent's
# commits that the fork's default branch lacks.  Sets ${fork} to DIRECTORY.
make_fork_clone() {
  fork="$1"
  git clone -q 'https://github.com/me/proj.git' "${fork}"
  git -C "${fork}" switch -q -c feature
  commit_file "${fork}" a.txt 'a2'
  git -C "${fork}" fetch -q --no-tags 'https://github.com/someone/proj.git' "$(git -C "${gh_parent_work}" branch --show-current)" \
    && git -C "${fork}" merge -q --no-edit FETCH_HEAD
}

# The parent gains a commit, with a tag, that the fork's default branch
# lacks.
commit_file "${gh_parent_work}" e.txt 'e1'
git -C "${gh_parent_work}" tag parent-tag
git -C "${gh_parent_work}" push -q origin HEAD parent-tag

# With `--no-fetch`, this command does not ask GitHub, so it diffs from the
# fork's default branch.
make_fork_clone "${testdir}/gh-clone-no-fetch"
: > "${testdir}/gh.log"
expect_files 'fork, --no-fetch' 'a.txt
e.txt' --no-fetch --name-only
if [ -s "${testdir}/gh.log" ]; then
  fail "fork, --no-fetch: ran gh $(cat "${testdir}/gh.log")"
fi

# Usage: expect_no_upstream_remote DESCRIPTION
# Checks that ${fork} has no remote named `upstream`.
expect_no_upstream_remote() {
  if git -C "${fork}" config --get remote.upstream.url > /dev/null; then
    fail "$1: added remote upstream"
  fi
}

# Usage: expect_recorded DESCRIPTION SLUG EXPECTED
# Checks that ${fork} records EXPECTED as the upstream repository of SLUG.
expect_recorded() {
  recorded="$(git -C "${fork}" config --get "github-fork.$2.upstream")"
  if [ "${recorded}" != "$3" ]; then
    fail "$1: recorded [${recorded}] as the upstream repository of $2, expected [$3]"
  fi
}

# Otherwise, this command fetches the parent's default branch, without its
# tags, from a URL of the fork's form, diffs from it, adds no remote, and
# records the parent.
make_fork_clone "${testdir}/gh-clone"
expect_files 'fork' 'a.txt' --name-only
expect_no_upstream_remote 'fork'
expect_recorded 'fork' me/proj someone/proj
if ! git -C "${fork}" rev-parse --verify --quiet refs/fork-upstream/someone/proj > /dev/null; then
  fail 'fork: did not fetch into refs/fork-upstream/someone/proj'
fi
if [ -n "$(git -C "${fork}" tag --list parent-tag)" ]; then
  fail "fork: fetched the parent's tag"
fi

# Later runs use the recorded parent and do not ask GitHub again.  With
# `--no-fetch`, they use what the first run fetched.
: > "${testdir}/gh.log"
expect_files 'fork, second run' 'a.txt' --name-only
expect_files 'fork, second run, --no-fetch' 'a.txt' --no-fetch --name-only
if [ -s "${testdir}/gh.log" ]; then
  fail "fork, second run: ran gh $(cat "${testdir}/gh.log")"
fi

# A recorded "none" makes this command diff from the fork.
git -C "${fork}" config github-fork.me/proj.upstream none
expect_files 'fork, recorded none' 'a.txt
e.txt' --name-only

# A remote for the parent of another name, whose URL spells the parent's name
# in another case, is used, and nothing is fetched into refs/fork-upstream.
make_fork_clone "${testdir}/gh-clone-other-remote"
git -C "${fork}" remote add canonical 'https://github.com/someone/proj.git'
git -C "${fork}" config remote.canonical.url 'https://github.com/SomeOne/proj.git'
git config --global --add "url.${gh_parent}.insteadOf" 'https://github.com/SomeOne/proj.git'
expect_files 'fork with a remote for the parent' 'a.txt' --name-only
expect_no_upstream_remote 'fork with a remote for the parent'
if [ -n "$(git -C "${fork}" for-each-ref refs/fork-upstream)" ]; then
  fail 'fork with a remote for the parent: fetched into refs/fork-upstream'
fi
git config --global --unset "url.${gh_parent}.insteadOf" 'https://github.com/SomeOne/proj.git'

# A remote whose URL is a shortcut that `url.BASE.insteadOf` expands to a
# GitHub URL is recognized as a GitHub repository.  The fork's URL is not
# fetched, so the shortcut need not reach a local repository.
make_fork_clone "${testdir}/gh-clone-shortcut"
git -C "${fork}" config url.https://github.com/.insteadOf gh:
git -C "${fork}" config remote.origin.url gh:me/proj.git
expect_files 'fork with a shortcut URL' 'a.txt' --name-only
expect_recorded 'fork with a shortcut URL' me/proj someone/proj

# The repository that `gh` uses by default, which `remote.REMOTE.gh-resolved`
# names, is the upstream repository, and GitHub is not asked.
make_fork_clone "${testdir}/gh-clone-resolved"
git -C "${fork}" config remote.origin.gh-resolved someone/proj
: > "${testdir}/gh.log"
expect_files 'gh-resolved names the parent' 'a.txt' --name-only
make_fork_clone "${testdir}/gh-clone-resolved-base"
git -C "${fork}" config remote.origin.gh-resolved base
expect_files 'gh-resolved names the fork' 'a.txt
e.txt' --name-only
if [ -s "${testdir}/gh.log" ]; then
  fail "gh-resolved: ran gh $(cat "${testdir}/gh.log")"
fi
expect_recorded 'gh-resolved names the fork' me/proj ''

# A `gh` that has no token for github.com is not asked, so this command diffs
# from the fork, silently, and records nothing.
make_fork_clone "${testdir}/gh-clone-no-token"
: > "${testdir}/gh.log"
FAKE_GH_NO_TOKEN=1
export FAKE_GH_NO_TOKEN
expect_files 'gh without a token' 'a.txt
e.txt' --name-only
unset FAKE_GH_NO_TOKEN
if [ -s "${testdir}/errors" ]; then
  fail "gh without a token: printed $(cat "${testdir}/errors")"
fi
if grep -q -F 'repo view' "${testdir}/gh.log"; then
  fail "gh without a token: ran gh $(cat "${testdir}/gh.log")"
fi
expect_recorded 'gh without a token' me/proj ''

# A GitHub repository that is not a fork is the upstream repository.
fork="${testdir}/gh-clone-parent"
git clone -q 'https://github.com/someone/proj.git' "${fork}"
git -C "${fork}" switch -q -c feature
commit_file "${fork}" a.txt 'a3'
expect_files 'not a fork' 'a.txt' --name-only
expect_no_upstream_remote 'not a fork'
expect_recorded 'not a fork' someone/proj none
PATH="${saved_path}"

if [ "${failures}" -ne 0 ]; then
  echo "${SCRIPT_NAME}: ${failures} failure(s)" >&2
  exit 1
fi
