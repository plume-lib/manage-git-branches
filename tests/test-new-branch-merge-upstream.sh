#!/bin/sh

# Tests that `git-new-branch` fetches the upstream repository and merges its
# default branch into the new branch when that merge has no conflicts, and
# that it otherwise leaves the new branch at the current commit, with a
# warning.  In every case, the current directory's branch and working tree are
# left alone, and nothing is built or pushed.
#
# Usage:
#   tests/test-new-branch-merge-upstream.sh
#
# The status code is 0 if all the tests pass, and nonzero otherwise.

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(CDPATH='' cd -- "${TESTS_DIR}/.." && pwd -P)" || exit 1
GIT_NEW_BRANCH="${COMMANDS_DIR}/git-new-branch"

. "${TESTS_DIR}/lib-git-test-env.sh"
# shellcheck source=common-test-functions.sh
. "${TESTS_DIR}/common-test-functions.sh"

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

# The upstream repository, with a branch "main" whose file.txt has three
# lines, and a clone "seed" from which the tests add commits to it.
upstream="${work}/upstream.git"
seed="${work}/seed"
git init -q --bare -b main "${upstream}"
git clone -q "${upstream}" "${seed}" 2> /dev/null
printf 'one\ntwo\nthree\n' > "${seed}/file.txt"
git -C "${seed}" add file.txt
git -C "${seed}" commit -q -m "Initial commit"
git -C "${seed}" push -q origin main

# Usage: advance_upstream FILE CONTENT
# Commits CONTENT to FILE in the upstream repository's default branch.
advance_upstream() {
  commit_file "${seed}" "$1" "$2" || exit 1
  git -C "${seed}" push -q origin main || exit 1
}

# Usage: make_feature_clone DIRECTORY
# Clones the upstream repository into DIRECTORY, and checks out there a new
# branch "feature-NAME", where NAME is the last component of DIRECTORY.  The
# branch has a commit of its own and tracks a branch of the same name in the
# upstream repository, as a pull request's branch does.
make_feature_clone() {
  git clone -q "${upstream}" "$1" || exit 1
  git -C "$1" checkout -q -b "feature-$(basename -- "$1")" || exit 1
  commit_file "$1" feature.txt 'feature work' || exit 1
  git -C "$1" push -q -u origin HEAD || exit 1
}

# Usage: run_new_branch DIRECTORY GIT-NEW-BRANCH-ARGUMENT...
# Runs git-new-branch in DIRECTORY, and sets ${out} to its output.  Fails the
# test if git-new-branch fails.
run_new_branch() {
  run_new_branch_dir="$1"
  shift
  if ! out="$(cd -- "${run_new_branch_dir}" && "${GIT_NEW_BRANCH}" "$@" 2>&1)"; then
    fail "git-new-branch $* in ${run_new_branch_dir} failed: ${out}"
  fi
}

# Usage: has_parents DIRECTORY COMMIT...
# Succeeds if the commit of DIRECTORY has exactly the parents COMMIT....
has_parents() {
  has_parents_dir="$1"
  shift
  [ "$(git -C "${has_parents_dir}" rev-parse HEAD^@ | tr '\n' ' ')" = "$* " ]
}

# A feature branch, and an upstream repository that has advanced in a file
# that the feature branch did not change, so the two merge without conflicts.
# Every mode merges it into the new branch, with a merge commit whose parents
# are the current commit and the upstream commit.  The current directory's
# branch and working tree do not change.
clone1="${work}/proj1"
make_feature_clone "${clone1}"
advance_upstream other.txt 'upstream work'
upstream_head="$(git -C "${upstream}" rev-parse main)"
feature_head="$(git -C "${clone1}" rev-parse HEAD)"
state_before="$(working_tree_state "${clone1}")"
for mode in default clean copy; do
  if [ "${mode}" = default ]; then
    run_new_branch "${clone1}" "new-${mode}"
  else
    run_new_branch "${clone1}" "--${mode}" "new-${mode}"
  fi
  newdir="${work}/proj1-branch-new-${mode}"
  if ! has_parents "${newdir}" "${feature_head}" "${upstream_head}"; then
    fail "mode ${mode}: the new branch is not a merge of the feature branch and upstream: $(git -C "${newdir}" log --oneline --graph)"
  fi
  if [ "$(git -C "${newdir}" symbolic-ref HEAD)" != "refs/heads/new-${mode}" ]; then
    fail "mode ${mode}: ${newdir} does not have the new branch checked out"
  fi
  if [ -n "$(git -C "${newdir}" status --porcelain)" ]; then
    fail "mode ${mode}: ${newdir} is not clean after the merge: $(git -C "${newdir}" status --porcelain)"
  fi
  if [ "$(cat "${newdir}/other.txt")" != 'upstream work' ]; then
    fail "mode ${mode}: the working tree of ${newdir} lacks the upstream change"
  fi
  case "$(git -C "${newdir}" log -1 --format=%s)" in
    "Merge remote-tracking branch 'origin/main' into new-${mode}") ;;
    *) fail "mode ${mode}: unexpected merge message: $(git -C "${newdir}" log -1 --format=%s)" ;;
  esac
  case "${out}" in
    *"merged origin/main, the upstream repository's default branch, into the new branch"*) ;;
    *) fail "mode ${mode}: git-new-branch did not say that it merged: ${out}" ;;
  esac
  case "${out}" in
    *warning*) fail "mode ${mode}: unexpected warning: ${out}" ;;
  esac
done
if [ "$(working_tree_state "${clone1}")" != "${state_before}" ]; then
  fail "git-new-branch changed the branch or the index of ${clone1}"
fi
if [ "$(git -C "${clone1}" rev-parse refs/remotes/origin/main)" != "${upstream_head}" ]; then
  fail "git-new-branch did not fetch the upstream repository into ${clone1}"
fi

# An upstream change that conflicts with the feature branch:  the new branch
# is at the current commit, and a warning says why.
clone2="${work}/proj2"
make_feature_clone "${clone2}"
commit_file "${clone2}" file.txt "$(printf 'one\nfeature\nthree')"
git -C "${clone2}" push -q
advance_upstream file.txt "$(printf 'one\nupstream\nthree')"
feature_head="$(git -C "${clone2}" rev-parse HEAD)"
state_before="$(working_tree_state "${clone2}")"
run_new_branch "${clone2}" --clean conflict
if [ "$(git -C "${work}/proj2-branch-conflict" rev-parse HEAD)" != "${feature_head}" ]; then
  fail "the new branch is not at the current commit when upstream conflicts"
fi
case "${out}" in
  *"warning: the new branch is based on the current commit of ${clone2}; origin/main, the upstream repository's default branch, was not merged into it, because the merge would have conflicts."*) ;;
  *) fail "no warning about the conflict: ${out}" ;;
esac
if [ "$(working_tree_state "${clone2}")" != "${state_before}" ] \
  || [ -n "$(git -C "${clone2}" status --porcelain)" ]; then
  fail "git-new-branch changed ${clone2} when upstream conflicts"
fi

# A clone whose current branch is the upstream repository's default branch
# already contains it after the pull, so there is nothing to merge and nothing
# to say about it.
clone3="${work}/proj3"
git clone -q "${upstream}" "${clone3}"
advance_upstream third.txt 'more upstream work'
run_new_branch "${clone3}" --clean uptodate
if [ "$(git -C "${work}/proj3-branch-uptodate" rev-parse HEAD)" != "$(git -C "${upstream}" rev-parse main)" ]; then
  fail "the new branch of an up-to-date clone is not at the upstream commit"
fi
case "${out}" in
  *merged* | *warning*) fail "unexpected message for an up-to-date clone: ${out}" ;;
esac

# A fork:  the remote "upstream" is the upstream repository, and the current
# branch tracks the fork's "main", which lags behind it.  The new branch is
# then a fast-forward to the upstream commit, with no merge commit.
fork="${work}/fork.git"
git clone -q --bare "${upstream}" "${fork}"
advance_upstream fourth.txt 'upstream work that the fork lacks'
clone4="${work}/proj4"
git clone -q "${fork}" "${clone4}"
git -C "${clone4}" remote add upstream "${upstream}"
run_new_branch "${clone4}" --clean forked
if [ "$(git -C "${work}/proj4-branch-forked" rev-parse HEAD)" != "$(git -C "${upstream}" rev-parse main)" ]; then
  fail "the new branch of a lagging fork is not a fast-forward to upstream/main"
fi
if [ "$(git -C "${clone4}" rev-parse HEAD)" != "$(git -C "${fork}" rev-parse main)" ]; then
  fail "git-new-branch moved the current branch of the fork ${clone4}"
fi
case "${out}" in
  *"merged upstream/main"*) ;;
  *) fail "git-new-branch did not say that it merged upstream/main: ${out}" ;;
esac

# An upstream repository that cannot be fetched:  a warning, and the new
# branch at the current commit.
clone5="${work}/proj5"
make_feature_clone "${clone5}"
git -C "${clone5}" remote add upstream "${work}/no-such-repository.git"
run_new_branch "${clone5}" --clean unfetched
if [ "$(git -C "${work}/proj5-branch-unfetched" rev-parse HEAD)" != "$(git -C "${clone5}" rev-parse HEAD)" ]; then
  fail "the new branch is not at the current commit when the fetch fails"
fi
case "${out}" in
  *"warning: cannot fetch the upstream repository's default branch, so the new branch will not include its latest commits; continuing."*) ;;
  *) fail "no warning about the failed fetch: ${out}" ;;
esac

# A clone with no remote has no upstream repository, and the warning about
# its failed pull is the only one.
clone6="${work}/proj6"
git init -q -b main "${clone6}"
commit_file "${clone6}" file.txt 'local'
run_new_branch "${clone6}" --clean noremote
case "${out}" in
  *"upstream repository"*) fail "a message about the upstream repository of a clone with no remote: ${out}" ;;
esac

# Uncommitted changes in the default mode:  a staged change, an unstaged
# change, and an untracked file, none of which the merge touches, are carried
# into the new directory, and the merge is made.
clone7="${work}/proj7"
make_feature_clone "${clone7}"
advance_upstream fifth.txt 'upstream work beside local changes'
upstream_head="$(git -C "${upstream}" rev-parse main)"
feature_head="$(git -C "${clone7}" rev-parse HEAD)"
echo 'staged change' > "${clone7}/feature.txt"
git -C "${clone7}" add feature.txt
echo 'unstaged change' >> "${clone7}/file.txt"
echo 'untracked' > "${clone7}/untracked.txt"
status_before="$(git -C "${clone7}" status --porcelain)"
state_before="$(working_tree_state "${clone7}")"
run_new_branch "${clone7}" dirty
dirty="${work}/proj7-branch-dirty"
if ! has_parents "${dirty}" "${feature_head}" "${upstream_head}"; then
  fail "uncommitted changes: the new branch is not a merge of the feature branch and upstream"
fi
if [ "$(git -C "${dirty}" status --porcelain)" != "${status_before}" ]; then
  fail "uncommitted changes were not carried over the merge: [$(git -C "${dirty}" status --porcelain)], expected [${status_before}]"
fi
if [ "$(git -C "${dirty}" show :feature.txt)" != 'staged change' ] \
  || [ "$(tail -n 1 "${dirty}/file.txt")" != 'unstaged change' ] \
  || [ "$(cat "${dirty}/fifth.txt")" != 'upstream work beside local changes' ]; then
  fail "the new directory lacks an uncommitted change or the upstream change"
fi
if [ "$(working_tree_state "${clone7}")" != "${state_before}" ] \
  || [ "$(git -C "${clone7}" status --porcelain)" != "${status_before}" ]; then
  fail "git-new-branch changed ${clone7}, which has uncommitted changes"
fi

# An uncommitted change to a file that the merge would change:  the merge is
# not made, with a warning, and the change is carried over intact.
advance_upstream file.txt 'upstream change to the file with an unstaged change'
feature_head="$(git -C "${clone7}" rev-parse HEAD)"
run_new_branch "${clone7}" overlap
overlap="${work}/proj7-branch-overlap"
if [ "$(git -C "${overlap}" rev-parse HEAD)" != "${feature_head}" ]; then
  fail "the new branch is not at the current commit when the merge overlaps uncommitted changes"
fi
case "${out}" in
  *"was not merged into it, because the merge would change files that have uncommitted changes in ${overlap}, or would overwrite untracked files there."*) ;;
  *) fail "no warning about the uncommitted changes that the merge overlaps: ${out}" ;;
esac
if [ "$(git -C "${overlap}" status --porcelain)" != "${status_before}" ] \
  || [ "$(git -C "${overlap}" show :feature.txt)" != 'staged change' ] \
  || [ "$(tail -n 1 "${overlap}/file.txt")" != 'unstaged change' ]; then
  fail "the uncommitted changes were not carried over intact: [$(git -C "${overlap}" status --porcelain)]"
fi

# Too old a git to test a merge for conflicts:  a warning, and no merge.
clone8="${work}/proj8"
make_feature_clone "${clone8}"
advance_upstream sixth.txt 'upstream work for an old git'
make_fake_git "${work}/oldgit" version 0 'git version 2.37.0'
if ! out="$(cd -- "${clone8}" && PATH="${work}/oldgit:${PATH}" "${GIT_NEW_BRANCH}" --clean oldgit 2>&1)"; then
  fail "git-new-branch with git 2.37 failed: ${out}"
fi
if [ "$(git -C "${work}/proj8-branch-oldgit" rev-parse HEAD)" != "$(git -C "${clone8}" rev-parse HEAD)" ]; then
  fail "the new branch is not at the current commit with git 2.37"
fi
case "${out}" in
  *"because testing a merge for conflicts requires git 2.38 or later."*) ;;
  *) fail "no warning about the old git: ${out}" ;;
esac

# A branch directory that is a clone of its own registers the new worktree in
# the main clone, which has not fetched the upstream commit.  The merge needs
# that commit, and it is copied there.
main_clone="${work}/proj9"
git clone -q "${upstream}" "${main_clone}"
other="${work}/proj9-branch-other"
make_feature_clone "${other}"
advance_upstream seventh.txt 'upstream work that the main clone lacks'
upstream_head="$(git -C "${upstream}" rev-parse main)"
feature_head="$(git -C "${other}" rev-parse HEAD)"
run_new_branch "${other}" hosted
hosted="${work}/proj9-branch-hosted"
hosted_common="$(git -C "${hosted}" rev-parse --path-format=absolute --git-common-dir)"
if [ "${hosted_common}" != "${main_clone}/.git" ]; then
  fail "the new worktree is registered in ${hosted_common}, not in ${main_clone}/.git"
fi
if ! has_parents "${hosted}" "${feature_head}" "${upstream_head}"; then
  fail "the worktree registered in the main clone is not a merge of the feature branch and upstream"
fi

# git-new-branch neither builds nor pushes.  A copy of the commands whose
# `compile-project` records each call checks the first; a fake on the PATH
# checks it too.  The upstream repository gains no branch.
fake_commands="${work}/fake-commands"
mkdir -p "${fake_commands}/bin"
for command in git-new-branch common-functions.sh git-ssh-batch-wrapper; do
  cp -p "${COMMANDS_DIR}/${command}" "${fake_commands}/${command}"
done
compile_log="${work}/compile-log"
for fake_compile in "${fake_commands}/compile-project" "${fake_commands}/bin/compile-project"; do
  cat > "${fake_compile}" << FAKE_COMPILE_END
#!/bin/sh
echo "\$0" >> '${compile_log}'
FAKE_COMPILE_END
  chmod +x "${fake_compile}"
done
clone10="${work}/proj10"
make_feature_clone "${clone10}"
advance_upstream eighth.txt 'upstream work before a build'
branches_before="$(git -C "${upstream}" for-each-ref refs/heads)"
if ! out="$(cd -- "${clone10}" && PATH="${fake_commands}/bin:${PATH}" "${fake_commands}/git-new-branch" nobuild 2>&1)"; then
  fail "git-new-branch nobuild failed: ${out}"
fi
case "${out}" in
  *"merged origin/main"*) ;;
  *) fail "git-new-branch nobuild did not merge: ${out}" ;;
esac
if [ -e "${compile_log}" ]; then
  fail "git-new-branch ran compile-project: $(cat "${compile_log}")"
fi
if [ "$(git -C "${upstream}" for-each-ref refs/heads)" != "${branches_before}" ]; then
  fail "git-new-branch pushed to the upstream repository"
fi

exit "${status}"
