#!/bin/sh

# Tests for the `git-checkout-branch` script.
#
# Usage:
#   tests/test-git-checkout-branch.sh
#
# The exit status is 0 if all tests pass, 1 otherwise.
#
# These tests exercise only cases that require no network access.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
GIT_CHECKOUT_BRANCH="${SCRIPT_DIR}/../git-checkout-branch"

. "${SCRIPT_DIR}/lib-git-test-env.sh"

status=0

fail() {
  echo "FAIL: $*" >&2
  status=1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT INT TERM

sanitize_git_env "${tmpdir}"

# Create a repository that has no remote, with a branch "localonly" in
# addition to the initial branch.
repo="${tmpdir}/myrepo-branch-main"
mkdir -p "${repo}"
(
  cd "${repo}" || exit 1
  git init -q -b main .
  echo "hello" > file.txt
  git add file.txt
  git commit -q -m "Initial commit"
  git branch localonly
) || exit 1

# A branch that exists only locally can be checked out.
if ! out="$(cd "${repo}" && "${GIT_CHECKOUT_BRANCH}" localonly 2>&1)"; then
  fail "nonzero exit status for the local branch localonly: ${out}"
fi
localdir="${tmpdir}/myrepo-branch-localonly"
if [ ! -d "${localdir}" ]; then
  fail "directory was not created: ${localdir}"
else
  checkedout="$(git -C "${localdir}" rev-parse --abbrev-ref HEAD)"
  if [ "${checkedout}" != "localonly" ]; then
    fail "checked out ${checkedout} rather than localonly in ${localdir}"
  fi
fi

# A branch that does not exist is an error, and the message says so.
if out="$(cd "${repo}" && "${GIT_CHECKOUT_BRANCH}" nosuchbranch 2>&1)"; then
  fail "zero exit status for the nonexistent branch nosuchbranch"
fi
case "${out}" in
  *"does not exist"*) ;;
  *) fail "unexpected message for the nonexistent branch nosuchbranch: ${out}" ;;
esac
if [ -e "${tmpdir}/myrepo-branch-nosuchbranch" ]; then
  fail "directory was created for the nonexistent branch nosuchbranch"
fi

# A branch that exists only as a remote-tracking branch can be checked out.
clone="${tmpdir}/myclone-branch-main"
git clone -q "${repo}" "${clone}"
if ! out="$(cd "${clone}" && "${GIT_CHECKOUT_BRANCH}" localonly 2>&1)"; then
  fail "nonzero exit status for the remote-tracking branch localonly: ${out}"
fi
clonedir="${tmpdir}/myclone-branch-localonly"
if [ ! -d "${clonedir}" ]; then
  fail "directory was not created: ${clonedir}"
else
  checkedout="$(git -C "${clonedir}" rev-parse --abbrev-ref HEAD)"
  if [ "${checkedout}" != "localonly" ]; then
    fail "checked out ${checkedout} rather than localonly in ${clonedir}"
  fi
fi

# A clone whose sole remote is not named "origin" is asked about the branch.
othername="${tmpdir}/othername-branch-main"
git clone -q "${repo}" "${othername}"
git -C "${othername}" remote rename origin elsewhere
if ! out="$(cd "${othername}" && "${GIT_CHECKOUT_BRANCH}" localonly 2>&1)"; then
  fail "nonzero exit status for a branch of a remote not named origin: ${out}"
fi
otherdir="${tmpdir}/othername-branch-localonly"
if [ ! -d "${otherdir}" ]; then
  fail "directory was not created: ${otherdir}"
else
  checkedout="$(git -C "${otherdir}" rev-parse --abbrev-ref HEAD)"
  if [ "${checkedout}" != "localonly" ]; then
    fail "checked out ${checkedout} rather than localonly in ${otherdir}"
  fi
fi

# The diagnostic for a nonexistent branch names the remote that was asked,
# rather than "origin", which such a clone does not have.
if out="$(cd "${othername}" && "${GIT_CHECKOUT_BRANCH}" nosuchbranch 2>&1)"; then
  fail "zero exit status for the nonexistent branch nosuchbranch"
fi
case "${out}" in
  *"does not exist, locally or on remote elsewhere"*) ;;
  *) fail "the message does not name the remote that was asked: ${out}" ;;
esac

# A clone that pushes to a fork checks out a branch of the remote that it
# fetches from.  The push remote is the wrong one to ask about a branch:  a
# fork does not have the project's branches, so asking it would report that a
# branch that plainly exists does not exist.
forkclone="${tmpdir}/forkclone-branch-main"
git clone -q "${repo}" "${forkclone}"
git init -q --bare -b main "${tmpdir}/fork.git"
git -C "${forkclone}" remote add fork "${tmpdir}/fork.git"
git -C "${forkclone}" config branch.main.pushRemote fork
if ! out="$(cd "${forkclone}" && "${GIT_CHECKOUT_BRANCH}" localonly 2>&1)"; then
  fail "nonzero exit status for a branch of the fetch remote: ${out}"
fi
forkdir="${tmpdir}/forkclone-branch-localonly"
if [ ! -d "${forkdir}" ]; then
  fail "directory was not created: ${forkdir}"
else
  checkedout="$(git -C "${forkdir}" rev-parse --abbrev-ref HEAD)"
  if [ "${checkedout}" != "localonly" ]; then
    fail "checked out ${checkedout} rather than localonly in ${forkdir}"
  fi
fi

# The diagnostic for a nonexistent branch names the remote that was asked,
# which is the one the clone fetches from rather than the one it pushes to.
if out="$(cd "${forkclone}" && "${GIT_CHECKOUT_BRANCH}" nosuchbranch 2>&1)"; then
  fail "zero exit status for the nonexistent branch nosuchbranch"
fi
case "${out}" in
  *"does not exist, locally or on remote origin"*) ;;
  *) fail "the message does not name the remote that was asked: ${out}" ;;
esac

# A branch that only a remote other than the fetch remote has can be checked
# out, because `git checkout` creates the local branch from the
# remote-tracking branch of any remote.
git -C "${forkclone}" push -q fork "refs/remotes/origin/localonly:refs/heads/onlyfork"
git -C "${forkclone}" fetch -q fork
if ! out="$(cd "${forkclone}" && "${GIT_CHECKOUT_BRANCH}" onlyfork 2>&1)"; then
  fail "nonzero exit status for a branch of a remote other than the fetch remote: ${out}"
fi
onlyforkdir="${tmpdir}/forkclone-branch-onlyfork"
if [ ! -d "${onlyforkdir}" ]; then
  fail "directory was not created: ${onlyforkdir}"
else
  checkedout="$(git -C "${onlyforkdir}" rev-parse --abbrev-ref HEAD)"
  if [ "${checkedout}" != "onlyfork" ]; then
    fail "checked out ${checkedout} rather than onlyfork in ${onlyforkdir}"
  fi
fi

# When several remotes have a branch of that name and the fetch remote is not
# one of them, which one to check out is ambiguous.  Saying so costs the user
# nothing, whereas letting the checkout choose fails only after the working
# copy has been copied:  `git checkout BRANCH` reports "matched multiple
# remote tracking branches" and nothing is checked out.
ambiguous="${tmpdir}/ambiguous-branch-main"
git clone -q "${repo}" "${ambiguous}"
git init -q --bare -b main "${tmpdir}/fork1.git"
git init -q --bare -b main "${tmpdir}/fork2.git"
git -C "${ambiguous}" remote add fork1 "${tmpdir}/fork1.git"
git -C "${ambiguous}" remote add fork2 "${tmpdir}/fork2.git"
git -C "${ambiguous}" push -q fork1 "refs/remotes/origin/localonly:refs/heads/shared"
git -C "${ambiguous}" push -q fork2 "refs/remotes/origin/localonly:refs/heads/shared"
git -C "${ambiguous}" fetch -q fork1
git -C "${ambiguous}" fetch -q fork2
if out="$(cd "${ambiguous}" && "${GIT_CHECKOUT_BRANCH}" shared 2>&1)"; then
  fail "zero exit status for a branch that several remotes have"
fi
case "${out}" in
  *"ERROR: branch shared exists on several remotes"*) ;;
  *) fail "git-checkout-branch did not report the ambiguity: ${out}" ;;
esac
case "${out}" in
  *fork1*fork2* | *fork2*fork1*) ;;
  *) fail "git-checkout-branch did not list the remotes that have the branch: ${out}" ;;
esac
for leftover in "${tmpdir}/ambiguous-branch-shared" "${tmpdir}/ambiguous-branch-shared-TMP"; do
  if [ -e "${leftover}" ]; then
    fail "directory was created for the ambiguous branch shared: ${leftover}"
  fi
done

# `checkout.defaultRemote` resolves the ambiguity, as it does for git's own
# search for a remote-tracking branch.
git -C "${ambiguous}" config checkout.defaultRemote fork2
if ! out="$(cd "${ambiguous}" && "${GIT_CHECKOUT_BRANCH}" shared 2>&1)"; then
  fail "nonzero exit status for a branch that checkout.defaultRemote chooses: ${out}"
fi
ambiguousdir="${tmpdir}/ambiguous-branch-shared"
if [ ! -d "${ambiguousdir}" ]; then
  fail "directory was not created: ${ambiguousdir}"
else
  upstream="$(git -C "${ambiguousdir}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2> /dev/null)"
  if [ "${upstream}" != "fork2/shared" ]; then
    fail "the upstream is ${upstream} rather than the fork2/shared that checkout.defaultRemote chose"
  fi
fi

# The fetch remote is used when it is one of the remotes that have the branch,
# without any configuration:  it is the remote that this clone's branches come
# from, and the branch of any other remote is a different branch.
git init -q --bare -b main "${tmpdir}/origin2.git"
git -C "${ambiguous}" push -q "${tmpdir}/origin2.git" "refs/remotes/origin/main:refs/heads/main"
git -C "${ambiguous}" push -q "${tmpdir}/origin2.git" "refs/remotes/origin/localonly:refs/heads/shared"
preferred="${tmpdir}/preferred-branch-main"
git clone -q "${tmpdir}/origin2.git" "${preferred}"
git -C "${preferred}" remote add fork1 "${tmpdir}/fork1.git"
git -C "${preferred}" fetch -q fork1
if ! out="$(cd "${preferred}" && "${GIT_CHECKOUT_BRANCH}" shared 2>&1)"; then
  fail "nonzero exit status for a branch that the fetch remote also has: ${out}"
fi
preferreddir="${tmpdir}/preferred-branch-shared"
if [ ! -d "${preferreddir}" ]; then
  fail "directory was not created: ${preferreddir}"
else
  upstream="$(git -C "${preferreddir}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2> /dev/null)"
  if [ "${upstream}" != "origin/shared" ]; then
    fail "the upstream is ${upstream} rather than the origin/shared of the fetch remote"
  fi
fi

# A clone whose fetch refspec does not cover the branch has no ref for it, so
# the branch is fetched rather than only queried.  A successful query does not
# make the checkout succeed:  `git checkout BRANCH` needs a ref in the clone,
# and reports "pathspec 'BRANCH' did not match" without one.  The new working
# copy still gets an upstream, which `git-push-to` and `git-pull-from` require.
narrow="${tmpdir}/narrow-branch-main"
git clone -q --single-branch -b main "${repo}" "${narrow}"
if ! out="$(cd "${narrow}" && "${GIT_CHECKOUT_BRANCH}" localonly 2>&1)"; then
  fail "nonzero exit status for a branch outside this clone's fetch refspec: ${out}"
fi
narrowdir="${tmpdir}/narrow-branch-localonly"
if [ ! -d "${narrowdir}" ]; then
  fail "directory was not created: ${narrowdir}"
else
  checkedout="$(git -C "${narrowdir}" rev-parse --abbrev-ref HEAD)"
  if [ "${checkedout}" != "localonly" ]; then
    fail "checked out ${checkedout} rather than localonly in ${narrowdir}"
  fi
  if [ "$(git -C "${narrowdir}" rev-parse HEAD)" \
    != "$(git -C "${repo}" rev-parse refs/heads/localonly)" ]; then
    fail "the branch in ${narrowdir} is not the localonly of the remote"
  fi
  upstream_remote="$(git -C "${narrowdir}" config --get branch.localonly.remote)"
  upstream_merge="$(git -C "${narrowdir}" config --get branch.localonly.merge)"
  if [ "${upstream_remote}" != "origin" ] \
    || [ "${upstream_merge}" != "refs/heads/localonly" ]; then
    fail "the upstream in ${narrowdir} is [${upstream_remote}] [${upstream_merge}]"
  fi
fi

# A pathname, which git accepts wherever it accepts a remote's name, has no
# remote-tracking namespace, so the fetch records the branch only in
# FETCH_HEAD.  The new branch's upstream is then that pathname, which is what
# `git push --set-upstream ../other.git BRANCH` would record.
pathname="${tmpdir}/pathname-branch-main"
git clone -q "${repo}" "${pathname}"
# Removing the remote deletes its remote-tracking branches, leaving the
# pathname in `branch.main.remote` as the only remote there is.
git -C "${pathname}" remote remove origin
git -C "${pathname}" config branch.main.remote "${repo}"
git -C "${pathname}" config branch.main.merge refs/heads/main
if ! out="$(cd "${pathname}" && "${GIT_CHECKOUT_BRANCH}" localonly 2>&1)"; then
  fail "nonzero exit status for a branch of a remote named by a pathname: ${out}"
fi
pathnamedir="${tmpdir}/pathname-branch-localonly"
if [ ! -d "${pathnamedir}" ]; then
  fail "directory was not created: ${pathnamedir}"
else
  if [ "$(git -C "${pathnamedir}" rev-parse HEAD)" \
    != "$(git -C "${repo}" rev-parse refs/heads/localonly)" ]; then
    fail "the branch in ${pathnamedir} is not the localonly of the remote"
  fi
  upstream_remote="$(git -C "${pathnamedir}" config --get branch.localonly.remote)"
  if [ "${upstream_remote}" != "${repo}" ]; then
    fail "the upstream remote in ${pathnamedir} is [${upstream_remote}], not ${repo}"
  fi
fi

# `HEAD` is not a branch name, even though a clone has a symbolic ref
# `refs/remotes/origin/HEAD`.
if out="$(cd "${clone}" && "${GIT_CHECKOUT_BRANCH}" HEAD 2>&1)"; then
  fail "zero exit status for HEAD"
fi
case "${out}" in
  *"does not exist"*) ;;
  *) fail "unexpected message for HEAD: ${out}" ;;
esac
if [ -e "${tmpdir}/myclone-branch-HEAD" ]; then
  fail "directory was created for HEAD"
fi

# The query to `origin` disables SSH's own interactive prompts, as the README
# promises.  Without that, a prompt for an unknown host key or for the
# passphrase of a key blocks forever when this script runs from another script
# or from a CI job, where nobody sees the prompt and nobody can answer it.
# The fake `ssh` records the arguments of each invocation and then fails, so
# the query fails and the branch is reported as nonexistent; what this checks
# is the option that the query passed.  `sanitize_git_env` has already unset
# the variables that would otherwise select some other SSH command.
# shellcheck source=common-functions.sh
. "${SCRIPT_DIR}/common-functions.sh"
sshclone="${tmpdir}/sshclone-branch-main"
git clone -q "${repo}" "${sshclone}"
use_fake_ssh "${sshclone}" "${tmpdir}/ssh-arguments"
# A name that no local test can answer, so that the remote is asked:  the
# clone has no branch and no remote-tracking branch of that name.
if (cd "${sshclone}" && "${GIT_CHECKOUT_BRANCH}" onlyremote > /dev/null 2>&1); then
  fail "zero exit status for a branch that only an unreachable remote could have"
fi
if [ ! -s "${tmpdir}/ssh-arguments" ]; then
  fail "git-checkout-branch did not ask origin about the branch"
elif ! grep -q -- '-o BatchMode=yes' "${tmpdir}/ssh-arguments"; then
  fail "the query to origin did not disable SSH's prompts: $(cat "${tmpdir}/ssh-arguments")"
fi

# The wrong number of arguments is an error.
if (cd "${repo}" && "${GIT_CHECKOUT_BRANCH}" > /dev/null 2>&1); then
  fail "zero exit status when given no argument"
fi
if (cd "${repo}" && "${GIT_CHECKOUT_BRANCH}" a b > /dev/null 2>&1); then
  fail "zero exit status when given two arguments"
fi

if [ "${status}" = 0 ]; then
  echo "test-git-checkout-branch.sh: all tests passed"
fi
exit "${status}"
