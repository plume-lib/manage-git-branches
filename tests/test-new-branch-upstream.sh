#!/bin/sh

# Tests that `git-new-branch` starts the new branch at the latest commit of
# the upstream repository's default branch when the current branch has that
# branch's name and the upstream commit is a fast-forward of the current
# commit, and that it otherwise starts the new branch at the current commit.
# The new branch is never a merge.  When the new branch starts at the upstream
# commit, the current directory's branch is fast-forwarded there too, carrying
# its uncommitted changes forward.  Nothing is built or pushed.
#
# Usage:
#   tests/test-new-branch-upstream.sh
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

# Usage: make_fork_clone DIRECTORY
# Makes a fork DIRECTORY.git of the upstream repository, and a clone of the
# fork in DIRECTORY, on branch "main", whose remote "upstream" is the upstream
# repository.
make_fork_clone() {
  git clone -q --bare "${upstream}" "$1.git" || exit 1
  git clone -q "$1.git" "$1" || exit 1
  git -C "$1" remote add upstream "${upstream}" || exit 1
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

# Usage: expect_current_commit DESCRIPTION DIRECTORY NEWDIR
# Fails the test unless the new branch in NEWDIR is at the commit of
# DIRECTORY, and ${out} says nothing about the upstream repository.
expect_current_commit() {
  if [ "$(git -C "$3" rev-parse HEAD)" != "$(git -C "$2" rev-parse HEAD)" ]; then
    fail "$1: the new branch is not at the current commit: $(git -C "$3" log --oneline --graph)"
  fi
  case "${out}" in
    *upstream* | *fast-forward* | *warning*) fail "$1: unexpected message: ${out}" ;;
  esac
}

# A fork whose "main" lags behind the upstream repository's:  every mode
# fast-forwards the current branch to the upstream commit and starts the new
# branch there, with no merge commit.  Each mode gets a fork of its own,
# because after the first fast-forward there is nothing to do.
for mode in default clean copy; do
  make_fork_clone "${work}/proj1${mode}"
done
advance_upstream other.txt 'upstream work'
upstream_head="$(git -C "${upstream}" rev-parse main)"
for mode in default clean copy; do
  clone1="${work}/proj1${mode}"
  if [ "${mode}" = default ]; then
    run_new_branch "${clone1}" "new-${mode}"
  else
    run_new_branch "${clone1}" "--${mode}" "new-${mode}"
  fi
  newdir="${work}/proj1${mode}-branch-new-${mode}"
  if [ "$(git -C "${newdir}" rev-parse HEAD)" != "${upstream_head}" ]; then
    fail "mode ${mode}: the new branch is not at upstream/main: $(git -C "${newdir}" log --oneline --graph)"
  fi
  if [ "$(git -C "${newdir}" symbolic-ref HEAD)" != "refs/heads/new-${mode}" ]; then
    fail "mode ${mode}: ${newdir} does not have the new branch checked out"
  fi
  if [ -n "$(git -C "${newdir}" status --porcelain)" ]; then
    fail "mode ${mode}: ${newdir} is not clean after the fast-forward: $(git -C "${newdir}" status --porcelain)"
  fi
  if [ "$(cat "${newdir}/other.txt")" != 'upstream work' ]; then
    fail "mode ${mode}: the working tree of ${newdir} lacks the upstream change"
  fi
  case "${out}" in
    *"fast-forwarded ${clone1} to upstream/main, the upstream repository's default branch, where the new branch starts."*) ;;
    *) fail "mode ${mode}: git-new-branch did not say that it fast-forwarded: ${out}" ;;
  esac
  case "${out}" in
    *warning*) fail "mode ${mode}: unexpected warning: ${out}" ;;
  esac
  if [ "$(git -C "${clone1}" rev-parse HEAD)" != "${upstream_head}" ] \
    || [ "$(git -C "${clone1}" symbolic-ref HEAD)" != refs/heads/main ] \
    || [ -n "$(git -C "${clone1}" status --porcelain)" ]; then
    fail "mode ${mode}: ${clone1} was not fast-forwarded to upstream/main: $(git -C "${clone1}" status --porcelain)"
  fi
done

# A pull request's branch in a fork, where `upstream/HEAD` already names
# "main":  the new branch is at the current commit, the upstream repository is
# not fetched, and nothing is said about it.
clone2="${work}/proj2"
make_fork_clone "${clone2}"
git -C "${clone2}" fetch -q upstream
git -C "${clone2}" remote set-head upstream main
git -C "${clone2}" switch -q -c feature
commit_file "${clone2}" feature.txt 'feature work'
git -C "${clone2}" push -q -u origin HEAD
advance_upstream second.txt 'upstream work that a feature branch lacks'
tracking_before="$(git -C "${clone2}" rev-parse refs/remotes/upstream/main)"
run_new_branch "${clone2}" --clean pr
expect_current_commit "a pull request's branch" "${clone2}" "${work}/proj2-branch-pr"
if [ "$(git -C "${clone2}" rev-parse refs/remotes/upstream/main)" != "${tracking_before}" ]; then
  fail "git-new-branch fetched the upstream repository for a pull request's branch"
fi

# A release branch that has no commits of its own, so that the upstream
# default branch is a fast-forward of it:  the new branch is at the current
# commit, because the release branch has another name.
clone3="${work}/proj3"
make_fork_clone "${clone3}"
git -C "${clone3}" switch -q -c release
git -C "${clone3}" push -q -u origin HEAD
advance_upstream third.txt 'upstream work after the release branch'
run_new_branch "${clone3}" --clean fix
expect_current_commit "a release branch" "${clone3}" "${work}/proj3-branch-fix"

# A downstream fork, whose "main" has commits that the upstream repository's
# lacks:  the new branch is at the current commit, with no merge.
clone4="${work}/proj4"
make_fork_clone "${clone4}"
commit_file "${clone4}" downstream.txt 'downstream work'
git -C "${clone4}" push -q
advance_upstream fourth.txt 'upstream work that the downstream fork lacks'
run_new_branch "${clone4}" --clean downstream
expect_current_commit "a downstream fork" "${clone4}" "${work}/proj4-branch-downstream"

# A clone whose current branch is the upstream repository's default branch
# already contains it after the pull, so there is nothing to do and nothing
# to say about it.
clone5="${work}/proj5"
git clone -q "${upstream}" "${clone5}"
advance_upstream fifth.txt 'more upstream work'
run_new_branch "${clone5}" --clean uptodate
if [ "$(git -C "${work}/proj5-branch-uptodate" rev-parse HEAD)" != "$(git -C "${upstream}" rev-parse main)" ]; then
  fail "the new branch of an up-to-date clone is not at the upstream commit"
fi
case "${out}" in
  *fast-forward* | *warning*) fail "unexpected message for an up-to-date clone: ${out}" ;;
esac

# An upstream repository that cannot be fetched:  a warning, and the new
# branch at the current commit.
clone6="${work}/proj6"
make_fork_clone "${clone6}"
git -C "${clone6}" remote set-url upstream "${work}/no-such-repository.git"
run_new_branch "${clone6}" --clean unfetched
if [ "$(git -C "${work}/proj6-branch-unfetched" rev-parse HEAD)" != "$(git -C "${clone6}" rev-parse HEAD)" ]; then
  fail "the new branch is not at the current commit when the fetch fails"
fi
case "${out}" in
  *"warning: cannot fetch the upstream repository's default branch, so the new branch cannot start at its latest commit; continuing."*) ;;
  *) fail "no warning about the failed fetch: ${out}" ;;
esac

# A clone with no remote has no upstream repository, and the warning about
# its failed pull is the only one.
clone7="${work}/proj7"
git init -q -b main "${clone7}"
commit_file "${clone7}" file.txt 'local'
run_new_branch "${clone7}" --clean noremote
case "${out}" in
  *"upstream repository"*) fail "a message about the upstream repository of a clone with no remote: ${out}" ;;
esac

# Uncommitted changes in the default mode:  a staged change, an unstaged
# change, and an untracked file, none of which the fast-forward touches, are
# carried over the fast-forward and into the new directory.
clone8="${work}/proj8"
make_fork_clone "${clone8}"
advance_upstream sixth.txt 'upstream work beside local changes'
upstream_head="$(git -C "${upstream}" rev-parse main)"
echo 'staged change' > "${clone8}/staged.txt"
git -C "${clone8}" add staged.txt
echo 'unstaged change' >> "${clone8}/file.txt"
echo 'untracked' > "${clone8}/untracked.txt"
status_before="$(git -C "${clone8}" status --porcelain)"
run_new_branch "${clone8}" dirty
dirty="${work}/proj8-branch-dirty"
if [ "$(git -C "${dirty}" rev-parse HEAD)" != "${upstream_head}" ]; then
  fail "uncommitted changes: the new branch is not at upstream/main"
fi
if [ "$(git -C "${dirty}" status --porcelain)" != "${status_before}" ]; then
  fail "uncommitted changes were not carried over the fast-forward: [$(git -C "${dirty}" status --porcelain)], expected [${status_before}]"
fi
if [ "$(git -C "${dirty}" show :staged.txt)" != 'staged change' ] \
  || [ "$(tail -n 1 "${dirty}/file.txt")" != 'unstaged change' ] \
  || [ "$(cat "${dirty}/sixth.txt")" != 'upstream work beside local changes' ]; then
  fail "the new directory lacks an uncommitted change or the upstream change"
fi
if [ "$(git -C "${clone8}" rev-parse HEAD)" != "${upstream_head}" ] \
  || [ "$(git -C "${clone8}" status --porcelain)" != "${status_before}" ] \
  || [ "$(cat "${clone8}/sixth.txt")" != 'upstream work beside local changes' ]; then
  fail "${clone8} was not fast-forwarded with its uncommitted changes intact: [$(git -C "${clone8}" status --porcelain)]"
fi

# An uncommitted change to a file that the fast-forward would change:  the
# fast-forward is not made, with a warning, and the change is carried over
# intact.
advance_upstream file.txt 'upstream change to the file with an unstaged change'
current_head="$(git -C "${clone8}" rev-parse HEAD)"
run_new_branch "${clone8}" overlap
overlap="${work}/proj8-branch-overlap"
if [ "$(git -C "${overlap}" rev-parse HEAD)" != "${current_head}" ] \
  || [ "$(git -C "${clone8}" rev-parse HEAD)" != "${current_head}" ]; then
  fail "a branch moved when the fast-forward overlaps uncommitted changes"
fi
case "${out}" in
  *"warning: ${clone8} was not fast-forwarded to upstream/main, the upstream repository's default branch, because \`git read-tree\` failed, for the reason that it gives above"*"so the new branch starts at the current commit of ${clone8}."*) ;;
  *) fail "no warning about the uncommitted changes that the fast-forward overlaps: ${out}" ;;
esac
if [ "$(git -C "${overlap}" status --porcelain)" != "${status_before}" ] \
  || [ "$(git -C "${overlap}" show :staged.txt)" != 'staged change' ] \
  || [ "$(tail -n 1 "${overlap}/file.txt")" != 'unstaged change' ]; then
  fail "the uncommitted changes were not carried over intact: [$(git -C "${overlap}" status --porcelain)]"
fi
if [ "$(git -C "${clone8}" status --porcelain)" != "${status_before}" ]; then
  fail "the uncommitted changes in ${clone8} were not left intact: [$(git -C "${clone8}" status --porcelain)]"
fi

# The same, in a clean checkout:  the current branch is not fast-forwarded,
# but the new branch starts at the upstream commit all the same.
run_new_branch "${clone8}" --clean cleanoverlap
if [ "$(git -C "${work}/proj8-branch-cleanoverlap" rev-parse HEAD)" != "$(git -C "${upstream}" rev-parse main)" ] \
  || [ "$(git -C "${clone8}" rev-parse HEAD)" != "${current_head}" ]; then
  fail "--clean: the new branch is not at upstream/main, or ${clone8} moved"
fi
case "${out}" in
  *"warning: ${clone8} was not fast-forwarded"*"the new branch starts at upstream/main all the same, because it is a clean checkout."*) ;;
  *) fail "--clean: no message about the fast-forward that was not made: ${out}" ;;
esac

# A branch directory that is a clone of its own registers the new worktree in
# the main clone, which has not fetched the upstream commit.  The new branch
# needs that commit, and it is copied there.
main_clone="${work}/proj9"
make_fork_clone "${main_clone}"
other="${work}/proj9-branch-other"
git clone -q "${main_clone}.git" "${other}"
git -C "${other}" remote add upstream "${upstream}"
advance_upstream seventh.txt 'upstream work that the main clone lacks'
upstream_head="$(git -C "${upstream}" rev-parse main)"
run_new_branch "${other}" hosted
hosted="${work}/proj9-branch-hosted"
hosted_common="$(git -C "${hosted}" rev-parse --path-format=absolute --git-common-dir)"
if [ "${hosted_common}" != "${main_clone}/.git" ]; then
  fail "the new worktree is registered in ${hosted_common}, not in ${main_clone}/.git"
fi
if [ "$(git -C "${hosted}" rev-parse HEAD)" != "${upstream_head}" ]; then
  fail "the worktree registered in the main clone is not at upstream/main"
fi

# A stale `upstream/HEAD`, which names a branch "master" that the upstream
# repository no longer has, does not hide its default branch "main".
clone13="${work}/proj13"
make_fork_clone "${clone13}"
git -C "${clone13}" fetch -q upstream
git -C "${clone13}" update-ref refs/remotes/upstream/master HEAD
git -C "${clone13}" symbolic-ref refs/remotes/upstream/HEAD refs/remotes/upstream/master
advance_upstream ninth.txt 'upstream work after a rename'
run_new_branch "${clone13}" --clean renamed
if [ "$(git -C "${work}/proj13-branch-renamed" rev-parse HEAD)" != "$(git -C "${upstream}" rev-parse main)" ]; then
  fail "a stale upstream/HEAD kept the new branch from upstream/main: ${out}"
fi

# A tag "main" in the fork, which makes the short name of the current branch
# "heads/main", does not keep the new branch from upstream/main.
clone14="${work}/proj14"
make_fork_clone "${clone14}"
git -C "${clone14}" tag main
advance_upstream tenth.txt 'upstream work beside a tag'
run_new_branch "${clone14}" --clean tagged
if [ "$(git -C "${work}/proj14-branch-tagged" rev-parse HEAD)" != "$(git -C "${upstream}" rev-parse main)" ]; then
  fail "a tag main kept the new branch from upstream/main: ${out}"
fi

# A clone whose upstream repository is the remote that `git pull` fetched
# does not fetch it again.  A missing `origin/HEAD`, which its fetch would
# create, shows whether it did.  `followRemoteHEAD` keeps the pull from
# creating it; the fetch of the upstream repository overrides that setting.
clone15="${work}/proj15"
git clone -q "${upstream}" "${clone15}"
git -C "${clone15}" remote set-head origin -d
git -C "${clone15}" config remote.origin.followRemoteHEAD never
run_new_branch "${clone15}" --clean onefetch
if git -C "${clone15}" symbolic-ref --quiet refs/remotes/origin/HEAD > /dev/null; then
  fail "git-new-branch fetched origin again after the pull"
fi

# A clone with two remotes, neither named "upstream" nor "origin", has no
# upstream repository, and nothing is said about one.
clone16="${work}/proj16"
git clone -q -o gh "${upstream}" "${clone16}"
git -C "${clone16}" remote add gl "${upstream}"
run_new_branch "${clone16}" --clean tworemotes
case "${out}" in
  *upstream* | *warning*) fail "a message about the upstream repository of a clone with two other remotes: ${out}" ;;
esac

# A name that the fork already has is refused before the upstream repository
# is fetched.
clone17="${work}/proj17"
make_fork_clone "${clone17}"
git -C "${clone17}" push -q origin main:taken
git -C "${clone17}" fetch -q origin
if out="$(cd -- "${clone17}" && "${GIT_NEW_BRANCH}" --clean taken 2>&1)"; then
  fail "git-new-branch accepted a name that the fork has: ${out}"
fi
if git -C "${clone17}" rev-parse --verify --quiet refs/remotes/upstream/main > /dev/null; then
  fail "git-new-branch fetched the upstream repository before refusing a name"
fi

# An unstaged deletion of a file that the fast-forward would change:  the
# fast-forward is not made, with a warning, and the file stays deleted.
clone18="${work}/proj18"
make_fork_clone "${clone18}"
rm -- "${clone18}/file.txt"
advance_upstream file.txt 'upstream change to a file that a clone deleted'
run_new_branch "${clone18}" deleted
deleted="${work}/proj18-branch-deleted"
if [ "$(git -C "${deleted}" rev-parse HEAD)" != "$(git -C "${clone18}" rev-parse HEAD)" ]; then
  fail "the new branch is not at the current commit when the fast-forward would change a deleted file"
fi
if [ -e "${deleted}/file.txt" ]; then
  fail "the fast-forward restored a file that ${clone18} deleted"
fi
if [ -e "${clone18}/file.txt" ]; then
  fail "the fast-forward restored a file that ${clone18} deleted, in ${clone18}"
fi
case "${out}" in
  *"warning: ${clone18} was not fast-forwarded"*"because the fast-forward would change files that are deleted there."*) ;;
  *) fail "no warning about the deleted file that the fast-forward would change: ${out}" ;;
esac

# A leftover temporary directory refuses the command before the
# fast-forward, so the current branch does not move.
clone19="${work}/proj19"
make_fork_clone "${clone19}"
advance_upstream eleventh.txt 'upstream work before a refusal'
head_before="$(git -C "${clone19}" rev-parse HEAD)"
mkdir "${work}/proj19-branch-leftover-TMP"
if out="$(cd -- "${clone19}" && "${GIT_NEW_BRANCH}" leftover 2>&1)"; then
  fail "git-new-branch succeeded despite a leftover temporary directory: ${out}"
fi
case "${out}" in
  *"ERROR: directory exists: ${work}/proj19-branch-leftover-TMP"*) ;;
  *) fail "no error about the leftover temporary directory: ${out}" ;;
esac
if [ "$(git -C "${clone19}" rev-parse HEAD)" != "${head_before}" ]; then
  fail "a refused git-new-branch fast-forwarded ${clone19}"
fi

# git-new-branch neither builds nor pushes.  A copy of the commands whose
# `compile-project` records each call checks the first; a fake on the PATH
# checks it too.  Neither the fork nor the upstream repository changes.
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
make_fork_clone "${clone10}"
advance_upstream eighth.txt 'upstream work before a build'
refs_before="$(git -C "${upstream}" for-each-ref refs/heads; git -C "${clone10}.git" for-each-ref refs/heads)"
if ! out="$(cd -- "${clone10}" && PATH="${fake_commands}/bin:${PATH}" "${fake_commands}/git-new-branch" nobuild 2>&1)"; then
  fail "git-new-branch nobuild failed: ${out}"
fi
case "${out}" in
  *"fast-forwarded ${clone10} to upstream/main"*) ;;
  *) fail "git-new-branch nobuild did not fast-forward: ${out}" ;;
esac
if [ -e "${compile_log}" ]; then
  fail "git-new-branch ran compile-project: $(cat "${compile_log}")"
fi
if [ "$(git -C "${upstream}" for-each-ref refs/heads; git -C "${clone10}.git" for-each-ref refs/heads)" != "${refs_before}" ]; then
  fail "git-new-branch pushed to the fork or the upstream repository"
fi

# An upstream commit that adds a submodule:  the new branch is at the current
# commit, with a warning, in a worktree as in a clean checkout.  This test is
# last, because every later fork would have the submodule.
clone11="${work}/proj11"
make_fork_clone "${clone11}"
git init -q -b main "${work}/sub"
commit_file "${work}/sub" sub.txt 'submodule content'
# git 2.38.1 and later refuse the "file" transport for a submodule unless
# allowed.
git -C "${seed}" -c protocol.file.allow=always submodule add -q \
  "${work}/sub" sub 2> /dev/null || exit 1
git -C "${seed}" commit -q -m "Add a submodule" || exit 1
git -C "${seed}" push -q origin main || exit 1
for mode in default clean; do
  if [ "${mode}" = default ]; then
    run_new_branch "${clone11}" "sub-${mode}"
  else
    run_new_branch "${clone11}" "--${mode}" "sub-${mode}"
  fi
  newdir="${work}/proj11-branch-sub-${mode}"
  if [ "$(git -C "${newdir}" rev-parse HEAD)" != "$(git -C "${clone11}" rev-parse HEAD)" ]; then
    fail "mode ${mode}: the new branch is not at the current commit when upstream/main adds a submodule"
  fi
  if [ -e "${newdir}/sub" ] || [ -n "$(git -C "${newdir}" status --porcelain)" ]; then
    fail "mode ${mode}: ${newdir} has the submodule or changes: $(git -C "${newdir}" status --porcelain)"
  fi
  case "${out}" in
    *"warning: the new branch starts at the current commit of ${clone11}, not at upstream/main, the upstream repository's default branch, because the fast-forward would add, remove, or update a submodule."*) ;;
    *) fail "mode ${mode}: no warning about the submodule that upstream/main adds: ${out}" ;;
  esac
done

# An upstream commit that updates a submodule, in a fork that has it:  the new
# directory is a copy, because of the submodule, and its branch is at the
# current commit, with a warning.
clone12="${work}/proj12"
make_fork_clone "${clone12}"
commit_file "${work}/sub" sub.txt 'newer submodule content'
git -C "${seed}/sub" pull -q || exit 1
git -C "${seed}" commit -q -a -m "Update the submodule" || exit 1
git -C "${seed}" push -q origin main || exit 1
run_new_branch "${clone12}" sub-update
newdir="${work}/proj12-branch-sub-update"
if [ "$(git -C "${newdir}" rev-parse HEAD)" != "$(git -C "${clone12}" rev-parse HEAD)" ]; then
  fail "the new branch is not at the current commit when upstream/main updates a submodule"
fi
case "${out}" in
  *"because the fast-forward would add, remove, or update a submodule."*) ;;
  *) fail "no warning about the submodule that upstream/main updates: ${out}" ;;
esac

exit "${status}"
