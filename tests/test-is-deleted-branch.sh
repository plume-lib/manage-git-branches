#!/bin/sh

# Tests `is-deleted-branch` and the way `git-orphaned-branches` uses it.
#
# Usage:
#   tests/test-is-deleted-branch.sh
#
# The status code is 0 if all tests pass and 1 otherwise.
#
# The tests use a local "remote" repository, so they do not access the network.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"
IS_DELETED_BRANCH="$(dirname -- "${SCRIPT_DIR}")/is-deleted-branch"
GIT_ORPHANED_BRANCHES="$(dirname -- "${SCRIPT_DIR}")/git-orphaned-branches"

failures=0

# Prints a message and records a test failure.
fail() {
  echo "${SCRIPT_NAME}: FAIL: $1" >&2
  failures=$((failures + 1))
}

# Usage: expect_status EXPECTED DIRECTORY DESCRIPTION
# Runs `is-deleted-branch DIRECTORY` and checks its status code.
expect_status() {
  expected="$1"
  dir="$2"
  description="$3"
  "${IS_DELETED_BRANCH}" "${dir}" > /dev/null 2>&1
  actual="$?"
  if [ "${actual}" -ne "${expected}" ]; then
    fail "${description}: expected status ${expected}, got ${actual}"
  fi
}

# Usage: expect_failure_message COMMAND DIRECTORY DESCRIPTION
# Runs `COMMAND DIRECTORY`, and checks that it exits with status 3, meaning
# that the question could not be answered, and complains on standard error
# that it cannot list the remote's branches.
expect_failure_message() {
  cmd="$1"
  dir="$2"
  description="$3"
  stderr_file="${testdir}/stderr"
  "${cmd}" "${dir}" > /dev/null 2> "${stderr_file}"
  actual="$?"
  if [ "${actual}" -ne 3 ]; then
    fail "${description}: expected status 3, got ${actual}"
  fi
  if ! grep -q 'cannot list branches of remote' "${stderr_file}"; then
    fail "${description}: expected \"cannot list branches of remote\" on standard error, got [$(cat "${stderr_file}")]"
  fi
}

# Usage: expect_batch_option DESCRIPTION
# Checks that the SSH invocations recorded since the argument file was last
# emptied used Plink's and Putty's `-batch` rather than OpenSSH's
# `-o BatchMode=yes`.
expect_batch_option() {
  if [ ! -s "${ssh_arguments}" ]; then
    fail "$1: the SSH command was not invoked"
  elif grep -q -- '-o BatchMode=yes' "${ssh_arguments}"; then
    fail "$1: invocation included \"-o BatchMode=yes\""
  elif ! grep -q -- '-batch' "${ssh_arguments}"; then
    fail "$1: invocation did not include \"-batch\", got [$(cat "${ssh_arguments}")]"
  fi
}

# Usage: repo_state DIRECTORY
# Prints a summary of everything that `is-deleted-branch` must not change:
# the commits that are reachable from any ref, and the working tree status.
repo_state() {
  git -C "$1" log --all --format='%H %d' 2>&1
  git -C "$1" status --porcelain 2>&1
}

testdir="$(mktemp -d)"
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${testdir}"' EXIT
trap 'rm -rf "${testdir}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${testdir}"; trap - TERM; kill -s TERM "$$"' TERM

# Make the tests independent of the user's git configuration.
GIT_CONFIG_GLOBAL="${testdir}/gitconfig"
GIT_CONFIG_SYSTEM=/dev/null
GIT_AUTHOR_NAME='Test Person'
GIT_AUTHOR_EMAIL='test@example.com'
GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset DEBUG GIT_SSH GIT_SSH_COMMAND GIT_SSH_VARIANT
: > "${GIT_CONFIG_GLOBAL}"

## Create a remote repository with branches "main", "live", and "dead".
remote="${testdir}/myrepo-remote.git"
git init -q --bare -b main "${remote}"
git clone -q "${remote}" "${testdir}/setup" 2> /dev/null
(
  cd "${testdir}/setup" || exit 1
  echo 'first' > file.txt
  git add file.txt
  git commit -q -m 'First commit'
  git push -q -u origin main
  for branch in live dead; do
    git checkout -q -b "${branch}" main
    echo "${branch}" > "${branch}.txt"
    git add "${branch}.txt"
    git commit -q -m "Commit on ${branch}"
    git push -q -u origin "${branch}"
  done
) || exit 1

## Create a working copy for each branch.
for branch in live dead; do
  git clone -q -b "${branch}" "${remote}" "${testdir}/myrepo-branch-${branch}"
  # Exercise branch-name lookup when a tag makes the short ref ambiguous.
  git -C "${testdir}/myrepo-branch-${branch}" tag "${branch}"
done

## Create a working copy for each branch that has no upstream configuration.
## Neither `git checkout -b BRANCH` (which `git-new-branch` runs) nor
## `git push REMOTE BRANCH` sets one, so such a working copy is common.
for branch in live dead; do
  dir="${testdir}/myrepo-branch-notracking-${branch}"
  git clone -q -b "${branch}" "${remote}" "${dir}"
  git -C "${dir}" config --unset "branch.${branch}.remote"
  git -C "${dir}" config --unset-all "branch.${branch}.merge"
done

## A working copy with no upstream configuration whose only remote is not
## named "origin".
git clone -q -b live "${remote}" "${testdir}/myrepo-branch-otherremote"
git -C "${testdir}/myrepo-branch-otherremote" remote rename origin upstream
git -C "${testdir}/myrepo-branch-otherremote" config --unset branch.live.remote
git -C "${testdir}/myrepo-branch-otherremote" config --unset-all branch.live.merge

## A working copy whose branch was never pushed, but which has a stale
## remote-tracking ref for a branch of the same name that someone else pushed
## and deleted, and that this working copy never pruned.  Such a ref is no
## sign that this branch was pushed.
staleref="${testdir}/myrepo-branch-staleref"
git clone -q "${remote}" "${staleref}"
git -C "${staleref}" checkout -q -b dead
git -C "${staleref}" config --unset branch.dead.remote
git -C "${staleref}" config --unset-all branch.dead.merge
echo 'unpushed' > "${staleref}/unpushed.txt"
git -C "${staleref}" add unpushed.txt
git -C "${staleref}" commit -q -m 'Unpushed commit on a never-pushed branch'

## A working copy with no upstream configuration whose remote-tracking refs are
## pruned.  Pruning deletes the only sign that the branch was pushed.
pruned="${testdir}/myrepo-branch-pruned"
git clone -q -b dead "${remote}" "${pruned}"
git -C "${pruned}" config --unset branch.dead.remote
git -C "${pruned}" config --unset-all branch.dead.merge

## A working copy with no upstream configuration whose remote-tracking refs are
## in a location of their own, because the remote has a fetch refspec other
## than the default one.
customrefspec="${testdir}/myrepo-branch-customrefspec"
git clone -q -b dead "${remote}" "${customrefspec}"
git -C "${customrefspec}" config --unset branch.dead.remote
git -C "${customrefspec}" config --unset-all branch.dead.merge
git -C "${customrefspec}" config remote.origin.fetch \
  '+refs/heads/*:refs/custom/origin/*'
git -C "${customrefspec}" update-ref refs/custom/origin/dead \
  refs/remotes/origin/dead
git -C "${customrefspec}" update-ref -d refs/remotes/origin/dead

## A working copy whose `branch.BRANCH.merge` names a ref that no longer
## exists in the remote, but whose `branch.BRANCH.remote` is unset.  Git
## ignores `branch.BRANCH.merge` in that case, so this branch's upstream is
## the branch of the same name.
mergeonly="${testdir}/myrepo-branch-mergeonly"
git clone -q -b live "${remote}" "${mergeonly}"
git -C "${mergeonly}" config --unset branch.live.remote
git -C "${mergeonly}" config branch.live.merge refs/heads/dead

## A working copy in which `branch.BRANCH.pushRemote`, `remote.pushDefault`,
## and `branch.BRANCH.remote` all name different remotes.  The branch exists
## in the latter two and was deleted in the first, which is the one that
## `git push` uses.  The working copy has a commit that it never pushed, so
## the push that its reflog records is the only sign that it pushed at all.
pushremote="${testdir}/myrepo-branch-pushremote"
git init -q --bare -b main "${testdir}/myrepo-pushremote.git"
git init -q --bare -b main "${testdir}/myrepo-pushdefault.git"
git clone -q -b live "${remote}" "${pushremote}"
git -C "${pushremote}" remote add pushremote "${testdir}/myrepo-pushremote.git"
git -C "${pushremote}" remote add pushdefault "${testdir}/myrepo-pushdefault.git"
git -C "${pushremote}" push -q pushremote live
git -C "${pushremote}" push -q pushdefault live
git -C "${pushremote}" config branch.live.pushRemote pushremote
git -C "${pushremote}" config remote.pushDefault pushdefault
echo 'unpushed' > "${pushremote}/unpushed.txt"
git -C "${pushremote}" add unpushed.txt
git -C "${pushremote}" commit -q -m 'Commit made after pushing'
## Delete the branch in the remote itself rather than with
## `git push --delete`, which would also delete the remote-tracking ref.
git -C "${testdir}/myrepo-pushremote.git" update-ref -d refs/heads/live

## Make the remote's "live" branch have a commit that the working copy lacks.
## A `git pull` in the working copy would fetch this commit.
(
  cd "${testdir}/setup" || exit 1
  git checkout -q live
  echo 'more' >> live.txt
  git commit -q -a -m 'Another commit on live'
  git push -q origin live
) || exit 1

## Delete the "dead" branch in the remote.
git -C "${testdir}/setup" push -q origin --delete dead

## Pruning the working copy above deletes its remote-tracking ref for the
## deleted branch, and the ref's reflog along with it.
git -C "${pruned}" fetch -q --prune origin

## A working copy whose branch was never pushed.
git clone -q "${remote}" "${testdir}/myrepo-branch-brandnew"
git -C "${testdir}/myrepo-branch-brandnew" checkout -q -b brandnew

## A working copy with a detached HEAD, which is on no branch at all.
git clone -q "${remote}" "${testdir}/myrepo-branch-detached"
git -C "${testdir}/myrepo-branch-detached" checkout -q --detach HEAD

## A working copy whose branch tracks a non-head ref in the remote.
git -C "${testdir}/setup" tag upstream-tag
git -C "${testdir}/setup" push -q origin upstream-tag
git clone -q -b live "${remote}" "${testdir}/myrepo-branch-tag-upstream"
git -C "${testdir}/myrepo-branch-tag-upstream" config branch.live.merge \
  refs/tags/upstream-tag

## A working copy with multiple configured upstream refs, one deleted and one
## live.  The branch is active if any configured upstream ref exists.
git clone -q -b live "${remote}" "${testdir}/myrepo-branch-multiple-upstreams"
git -C "${testdir}/myrepo-branch-multiple-upstreams" config --unset-all branch.live.merge
git -C "${testdir}/myrepo-branch-multiple-upstreams" config --add branch.live.merge \
  refs/heads/dead
git -C "${testdir}/myrepo-branch-multiple-upstreams" config --add branch.live.merge \
  refs/heads/live

## A working copy whose remote repository cannot be reached.
git clone -q -b live "${remote}" "${testdir}/myrepo-branch-unreachable"
ssh_arguments="${testdir}/ssh-arguments"
fake_ssh="${testdir}/fake-ssh"
cat > "${fake_ssh}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SSH_ARGUMENTS_FILE}"
exit 1
EOF
chmod +x "${fake_ssh}"
SSH_ARGUMENTS_FILE="${ssh_arguments}"
export SSH_ARGUMENTS_FILE
git -C "${testdir}/myrepo-branch-unreachable" config core.sshCommand "${fake_ssh}"
git -C "${testdir}/myrepo-branch-unreachable" config ssh.variant ssh
git -C "${testdir}/myrepo-branch-unreachable" remote set-url origin \
  'ssh://example.invalid/no-such-repo.git'

## A working copy whose branch was never pushed and whose remote cannot be
## reached.  Answering must not require the network.
neverpushed="${testdir}/myrepo-branch-neverpushed"
git clone -q "${remote}" "${neverpushed}"
git -C "${neverpushed}" checkout -q -b neverpushed
git -C "${neverpushed}" config core.sshCommand "${fake_ssh}"
git -C "${neverpushed}" config ssh.variant ssh
git -C "${neverpushed}" remote set-url origin \
  'ssh://example.invalid/no-such-repo.git'

## A working copy of an empty repository.  Its branch has no commit, and yet
## `git clone` gives that branch upstream configuration.
git init -q --bare -b main "${testdir}/myrepo-empty.git"
git clone -q "${testdir}/myrepo-empty.git" "${testdir}/myrepo-branch-unborn" \
  2> /dev/null

## A directory that is not a clone.
mkdir "${testdir}/myrepo-branch-notaclone"

## A subdirectory of a clone whose branch was deleted.  It is not itself a
## clone, even though git commands run in it operate on the clone.
mkdir "${testdir}/myrepo-branch-dead/subdirectory"

## The tests.

# `is-deleted-branch` must not modify the directory that it inspects.  This is
# the test that fails when `is-deleted-branch` is implemented using `git pull`.
for branch in live dead brandnew; do
  dir="${testdir}/myrepo-branch-${branch}"
  before="$(repo_state "${dir}")"
  "${IS_DELETED_BRANCH}" "${dir}" > /dev/null 2>&1
  after="$(repo_state "${dir}")"
  if [ "${before}" != "${after}" ]; then
    fail "is-deleted-branch modified ${dir}"
    echo "before:" >&2
    echo "${before}" >&2
    echo "after:" >&2
    echo "${after}" >&2
  fi
done

expect_status 1 "${testdir}/myrepo-branch-live" 'branch that exists in the remote'
expect_status 0 "${testdir}/myrepo-branch-dead" 'branch that was deleted in the remote'
expect_status 3 "${testdir}/myrepo-branch-brandnew" 'branch that was never pushed'
expect_status 1 "${testdir}/myrepo-branch-notracking-live" \
  'branch with no upstream configuration that exists in the remote'
expect_status 0 "${testdir}/myrepo-branch-notracking-dead" \
  'branch with no upstream configuration that was deleted in the remote'
expect_status 1 "${testdir}/myrepo-branch-otherremote" \
  'branch with no upstream configuration whose remote is not named "origin"'
expect_status 3 "${staleref}" \
  'never-pushed branch with a stale remote-tracking ref of the same name'
expect_status 3 "${pruned}" \
  'branch with no upstream configuration whose remote-tracking refs are pruned'
expect_status 0 "${customrefspec}" \
  'branch with no upstream configuration and a non-default fetch refspec'
expect_status 1 "${mergeonly}" \
  'branch whose branch.BRANCH.merge is set but whose branch.BRANCH.remote is not'
expect_status 0 "${pushremote}" \
  'branch that was deleted in the remote that branch.BRANCH.pushRemote names'
expect_status 3 "${testdir}/myrepo-branch-detached" 'working copy with a detached HEAD'
expect_status 3 "${testdir}/myrepo-branch-unborn" 'working copy whose branch has no commit'
expect_status 1 "${testdir}/myrepo-branch-tag-upstream" \
  'branch whose upstream is an existing non-head ref'
expect_status 1 "${testdir}/myrepo-branch-multiple-upstreams" \
  'branch with deleted and existing configured upstream refs'
expect_status 2 "${testdir}/myrepo-branch-notaclone" 'directory that is not a clone'
expect_status 2 "${testdir}/myrepo-branch-dead/subdirectory" \
  'subdirectory of a clone whose branch was deleted'
expect_failure_message "${IS_DELETED_BRANCH}" "${testdir}/myrepo-branch-unreachable" \
  'is-deleted-branch on a working copy whose remote cannot be reached'
if ! grep -q -- '-o BatchMode=yes' "${ssh_arguments}"; then
  fail 'SSH invocation did not include "-o BatchMode=yes"'
fi

# A branch that was never pushed is answered for without contacting the
# remote, and so without an error message about an unreachable remote.
: > "${ssh_arguments}"
neverpushed_stderr="${testdir}/neverpushed-stderr"
"${IS_DELETED_BRANCH}" "${neverpushed}" > /dev/null 2> "${neverpushed_stderr}"
neverpushed_status="$?"
if [ "${neverpushed_status}" -ne 3 ]; then
  fail "never-pushed branch with an unreachable remote: expected status 3, got ${neverpushed_status}"
fi
if [ -s "${ssh_arguments}" ]; then
  fail "never-pushed branch with an unreachable remote: contacted the remote, with [$(cat "${ssh_arguments}")]"
fi
if [ -s "${neverpushed_stderr}" ]; then
  fail "never-pushed branch with an unreachable remote: printed [$(cat "${neverpushed_stderr}")] on standard error"
fi

# GIT_SSH is an executable path, so a path containing spaces must remain a
# single executable name when is-deleted-branch adds BatchMode.
: > "${ssh_arguments}"
git -C "${testdir}/myrepo-branch-unreachable" config --unset core.sshCommand
git -C "${testdir}/myrepo-branch-unreachable" config --unset ssh.variant
git_ssh_with_spaces="${testdir}/fake ssh"
cp "${fake_ssh}" "${git_ssh_with_spaces}"
GIT_SSH="${git_ssh_with_spaces}"
GIT_SSH_VARIANT=ssh
# A nonexistent TMPDIR verifies that is-deleted-branch uses the committed
# wrapper rather than creating a temporary wrapper.
TMPDIR="${testdir}/nonexistent-tmpdir"
export GIT_SSH GIT_SSH_VARIANT TMPDIR
expect_failure_message "${IS_DELETED_BRANCH}" "${testdir}/myrepo-branch-unreachable" \
  'is-deleted-branch with a spaced executable path selected by GIT_SSH'
unset GIT_SSH GIT_SSH_VARIANT TMPDIR
if [ ! -s "${ssh_arguments}" ]; then
  fail 'SSH wrapper selected by GIT_SSH was not invoked'
elif ! grep -q -- '-o BatchMode=yes' "${ssh_arguments}"; then
  fail 'GIT_SSH invocation did not include "-o BatchMode=yes"'
fi

# Git guesses the SSH variant from the basename of GIT_SSH, so the wrapper must
# also announce the variant.  Otherwise Git guesses the "simple" variant, which
# cannot pass a port to SSH, and a remote URL with a port fails to connect.
: > "${ssh_arguments}"
git -C "${testdir}/myrepo-branch-unreachable" remote set-url origin \
  'ssh://example.invalid:2222/no-such-repo.git'
# The basename is "ssh", which is how is-deleted-branch recognizes OpenSSH when
# no variant is configured.
mkdir -p "${testdir}/openssh-bin"
cp "${fake_ssh}" "${testdir}/openssh-bin/ssh"
GIT_SSH="${testdir}/openssh-bin/ssh"
export GIT_SSH
expect_failure_message "${IS_DELETED_BRANCH}" "${testdir}/myrepo-branch-unreachable" \
  'is-deleted-branch with GIT_SSH and a remote URL with a port'
unset GIT_SSH
git -C "${testdir}/myrepo-branch-unreachable" remote set-url origin \
  'ssh://example.invalid/no-such-repo.git'
# Git runs the SSH command with `-G` to guess its variant, and that invocation
# also carries the port.  Require the invocation that requests the branch list,
# which is the one that the "simple" variant never reaches.
if [ ! -s "${ssh_arguments}" ]; then
  fail 'SSH wrapper selected by GIT_SSH was not invoked for a remote URL with a port'
elif ! grep -q -- '-p 2222 .*git-upload-pack' "${ssh_arguments}"; then
  fail "GIT_SSH invocation did not request git-upload-pack with \"-p 2222\", got [$(cat "${ssh_arguments}")]"
elif ! grep -q -- '-o BatchMode=yes.*git-upload-pack' "${ssh_arguments}"; then
  fail 'GIT_SSH invocation with a port did not include "-o BatchMode=yes"'
fi

# An empty GIT_SSH_COMMAND does not override a nonempty GIT_SSH.
: > "${ssh_arguments}"
GIT_SSH="${git_ssh_with_spaces}"
GIT_SSH_COMMAND=''
GIT_SSH_VARIANT=ssh
export GIT_SSH GIT_SSH_COMMAND GIT_SSH_VARIANT
expect_failure_message "${IS_DELETED_BRANCH}" "${testdir}/myrepo-branch-unreachable" \
  'is-deleted-branch with empty GIT_SSH_COMMAND and nonempty GIT_SSH'
unset GIT_SSH GIT_SSH_COMMAND GIT_SSH_VARIANT
if [ ! -s "${ssh_arguments}" ]; then
  fail 'SSH wrapper selected by GIT_SSH was not invoked when GIT_SSH_COMMAND was empty'
elif ! grep -q -- '-o BatchMode=yes' "${ssh_arguments}"; then
  fail 'GIT_SSH invocation did not include "-o BatchMode=yes" when GIT_SSH_COMMAND was empty'
fi

# Plink and Putty do not accept OpenSSH's `-o` option.  They use `-batch` to
# disable interactive prompts.
: > "${ssh_arguments}"
git -C "${testdir}/myrepo-branch-unreachable" config core.sshCommand "${fake_ssh}"
git -C "${testdir}/myrepo-branch-unreachable" config ssh.variant plink
expect_failure_message "${IS_DELETED_BRANCH}" "${testdir}/myrepo-branch-unreachable" \
  'is-deleted-branch with a Plink-style core.sshCommand'
if [ ! -s "${ssh_arguments}" ]; then
  fail 'SSH wrapper selected by core.sshCommand was not invoked'
elif grep -q -- '-o BatchMode=yes' "${ssh_arguments}"; then
  fail 'Plink-style core.sshCommand invocation included "-o BatchMode=yes"'
elif ! grep -q -- '-batch' "${ssh_arguments}"; then
  fail 'Plink-style core.sshCommand invocation did not include "-batch"'
fi

# GIT_SSH_COMMAND takes precedence over core.sshCommand and observes the same
# variant restriction.
: > "${ssh_arguments}"
GIT_SSH_COMMAND="${fake_ssh}"
GIT_SSH_VARIANT=plink
export GIT_SSH_COMMAND GIT_SSH_VARIANT
expect_failure_message "${IS_DELETED_BRANCH}" "${testdir}/myrepo-branch-unreachable" \
  'is-deleted-branch with a Plink-style GIT_SSH_COMMAND'
unset GIT_SSH_COMMAND GIT_SSH_VARIANT
if [ ! -s "${ssh_arguments}" ]; then
  fail 'SSH wrapper selected by GIT_SSH_COMMAND was not invoked'
elif grep -q -- '-o BatchMode=yes' "${ssh_arguments}"; then
  fail 'Plink-style GIT_SSH_COMMAND invocation included "-o BatchMode=yes"'
elif ! grep -q -- '-batch' "${ssh_arguments}"; then
  fail 'Plink-style GIT_SSH_COMMAND invocation did not include "-batch"'
fi

# A Putty-style GIT_SSH executable path uses the wrapper to preserve the path
# as one executable name while adding `-batch`.
: > "${ssh_arguments}"
GIT_SSH="${git_ssh_with_spaces}"
GIT_SSH_VARIANT=putty
export GIT_SSH GIT_SSH_VARIANT
expect_failure_message "${IS_DELETED_BRANCH}" "${testdir}/myrepo-branch-unreachable" \
  'is-deleted-branch with a Putty-style GIT_SSH executable path'
unset GIT_SSH GIT_SSH_VARIANT
if [ ! -s "${ssh_arguments}" ]; then
  fail 'SSH wrapper selected by Putty-style GIT_SSH was not invoked'
elif grep -q -- '-o BatchMode=yes' "${ssh_arguments}"; then
  fail 'Putty-style GIT_SSH invocation included "-o BatchMode=yes"'
elif ! grep -q -- '-batch' "${ssh_arguments}"; then
  fail 'Putty-style GIT_SSH invocation did not include "-batch"'
fi

# With no configured variant, Plink and Putty are recognized by command name,
# in an SSH command and in an executable path alike.
git -C "${testdir}/myrepo-branch-unreachable" config --unset core.sshCommand
git -C "${testdir}/myrepo-branch-unreachable" config --unset ssh.variant
mkdir -p "${testdir}/plink-bin" "${testdir}/putty-bin"
cp "${fake_ssh}" "${testdir}/plink-bin/plink"
cp "${fake_ssh}" "${testdir}/putty-bin/putty"
for variant in plink putty; do
  program="${testdir}/${variant}-bin/${variant}"

  : > "${ssh_arguments}"
  git -C "${testdir}/myrepo-branch-unreachable" config core.sshCommand "${program}"
  expect_failure_message "${IS_DELETED_BRANCH}" "${testdir}/myrepo-branch-unreachable" \
    "is-deleted-branch with an automatically detected ${variant} core.sshCommand"
  git -C "${testdir}/myrepo-branch-unreachable" config --unset core.sshCommand
  expect_batch_option "automatically detected ${variant} core.sshCommand"

  : > "${ssh_arguments}"
  GIT_SSH_COMMAND="${program}"
  export GIT_SSH_COMMAND
  expect_failure_message "${IS_DELETED_BRANCH}" "${testdir}/myrepo-branch-unreachable" \
    "is-deleted-branch with an automatically detected ${variant} GIT_SSH_COMMAND"
  unset GIT_SSH_COMMAND
  expect_batch_option "automatically detected ${variant} GIT_SSH_COMMAND"

  # GIT_SSH is an executable path, so the wrapper adds the option and announces
  # the variant that Git would otherwise have to guess.
  : > "${ssh_arguments}"
  GIT_SSH="${program}"
  export GIT_SSH
  expect_failure_message "${IS_DELETED_BRANCH}" "${testdir}/myrepo-branch-unreachable" \
    "is-deleted-branch with an automatically detected ${variant} GIT_SSH"
  unset GIT_SSH
  expect_batch_option "automatically detected ${variant} GIT_SSH"
done
# Restore the configuration that the remaining tests inherit.
git -C "${testdir}/myrepo-branch-unreachable" config core.sshCommand "${fake_ssh}"
git -C "${testdir}/myrepo-branch-unreachable" config ssh.variant plink

# `git-orphaned-branches` must list exactly the deleted branch, and must not
# modify any of the directories that it inspects.
scanned_clones='live dead brandnew detached unreachable notracking-live
notracking-dead otherremote staleref pruned customrefspec mergeonly pushremote
neverpushed unborn'
for branch in ${scanned_clones}; do
  repo_state "${testdir}/myrepo-branch-${branch}" > "${testdir}/before-${branch}"
done
orphans_stderr="${testdir}/orphans-stderr"
orphans="$(cd "${testdir}" && "${GIT_ORPHANED_BRANCHES}" 2> "${orphans_stderr}")"
for branch in ${scanned_clones}; do
  repo_state "${testdir}/myrepo-branch-${branch}" > "${testdir}/after-${branch}"
  if ! cmp -s "${testdir}/before-${branch}" "${testdir}/after-${branch}"; then
    fail "git-orphaned-branches modified ${testdir}/myrepo-branch-${branch}"
    echo "before:" >&2
    cat "${testdir}/before-${branch}" >&2
    echo "after:" >&2
    cat "${testdir}/after-${branch}" >&2
  fi
done
if ! grep -q 'cannot list branches of remote' "${orphans_stderr}"; then
  fail "git-orphaned-branches: expected \"cannot list branches of remote\" on standard error, got [$(cat "${orphans_stderr}")]"
fi
# `find` does not specify the order in which it visits directories, so compare
# the sorted lists.  `git-orphaned-branches` prints each directory as `cd` and
# `pwd -P` resolve it, because POSIX added `realpath` only in 2024 and some
# systems still lack it.
sorted_orphans="$(printf '%s\n' "${orphans}" | sort)"
expected_orphans="$(
  for orphan in myrepo-branch-dead myrepo-branch-notracking-dead \
    myrepo-branch-customrefspec myrepo-branch-pushremote; do
    # `cd` prints its own diagnostic on failure.
    (CDPATH='' cd -- "${testdir}/${orphan}" && pwd -P)
  done | sort
)"
if [ "${sorted_orphans}" != "${expected_orphans}" ]; then
  fail "git-orphaned-branches printed [${orphans}], expected [${expected_orphans}]"
fi

if [ "${failures}" -ne 0 ]; then
  echo "${SCRIPT_NAME}: ${failures} test(s) failed" >&2
  exit 1
fi

echo "${SCRIPT_NAME}: all tests passed"
