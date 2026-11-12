#!/bin/sh

# Tests the functions in common-functions.sh.
#
# Usage:
#   tests/test-common-functions.sh
#
# The test creates its repositories under a temporary directory, which it
# removes when it exits.

set -e

SCRIPT_NAME="$(basename -- "$0")"
TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
COMMANDS_DIR="$(CDPATH='' cd -- "${TESTS_DIR}/.." && pwd -P)" || exit 1

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manage-git-branches-test.XXXXXX")"
# Resolve symbolic links, as git does in the pathnames that
# `git worktree list` prints:  on macOS, $TMPDIR is below /var, a symbolic
# link to /private/var.
WORK_DIR="$(CDPATH='' cd -- "${WORK_DIR}" && pwd -P)" || exit 1
# The signal handlers re-raise the signal with the handler removed, so that
# the script dies of the signal rather than resuming where it was
# interrupted, and so that the caller sees that it was killed by a signal.
trap 'rm -rf "${WORK_DIR}"' EXIT
trap 'rm -rf "${WORK_DIR}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${WORK_DIR}"; trap - TERM; kill -s TERM "$$"' TERM

# shellcheck source=lib-git-test-env.sh
. "${TESTS_DIR}/lib-git-test-env.sh"

sanitize_git_env "${WORK_DIR}"

# `common-functions.sh` expects ${SCRIPT_DIR} to be the directory that holds
# this package's files.  The functions that this test calls do not use it, but
# set it anyway, so that the file is sourced the way its comment requires.
# shellcheck disable=SC2034
SCRIPT_DIR="${COMMANDS_DIR}"
# shellcheck source=../common-functions.sh
. "${COMMANDS_DIR}/common-functions.sh"

fail() {
  echo "${SCRIPT_NAME}: FAILURE: $*" >&2
  exit 1
}

## Usage: check_usable REMOTES NAME EXPECTED
## Checks that `remote_is_usable`, for the clone in ${WORK_DIR}, answers
## EXPECTED for NAME, which is "yes" or "no".  A relative pathname is resolved
## in ${WORK_DIR}.
check_usable() {
  if remote_is_usable "${WORK_DIR}" "$1" "$2"; then
    check_usable_actual='yes'
  else
    check_usable_actual='no'
  fi
  if [ "${check_usable_actual}" != "$3" ]; then
    fail "remote_is_usable [$1] [$2] answered ${check_usable_actual}, not $3"
  fi
}

REMOTES='origin
upstream'

# A name that the clone has.
check_usable "${REMOTES}" 'origin' 'yes'
check_usable "${REMOTES}" 'upstream' 'yes'

# No name at all, and a name that only some other clone has.  The latter is
# what `remote.pushDefault` in ~/.gitconfig amounts to in a clone that has no
# such remote.
check_usable "${REMOTES}" '' 'no'
check_usable "${REMOTES}" 'fork' 'no'

# A URL, which git accepts wherever it accepts a remote's name.  A string that
# contains ":" is an scp-style or a scheme-style URL, and "~" begins a pathname
# in the shell syntax that git accepts for a local repository.
check_usable "${REMOTES}" 'git@example.com:owner/other.git' 'yes'
check_usable "${REMOTES}" 'https://example.com/owner/other.git' 'yes'
# Assemble the tilde, which does not expand inside quotes anyway, so that the
# test says what it means rather than looking like an unexpanded "~".
TILDE='~'
check_usable "${REMOTES}" "${TILDE}/other.git" 'yes'
check_usable "${REMOTES}" "${TILDE}other" 'yes'

# A pathname, which git also accepts wherever it accepts a remote's name.
# `git push --set-upstream ../other.git BRANCH` writes such a value into
# `branch.BRANCH.remote`.  Only a pathname that names a repository is usable:
# git accepts "/" in the name of a remote, so a slash does not by itself tell a
# pathname from the name of a remote that this clone lacks.  A pathname may
# name a bare repository or a working tree.
git init -q --bare -b main "${WORK_DIR}/mirrors/other.git"
git init -q -b main "${WORK_DIR}/working-tree"
check_usable "${REMOTES}" 'mirrors/other.git' 'yes'
check_usable "${REMOTES}" './working-tree' 'yes'
check_usable "${REMOTES}" 'mirrors/nosuch.git' 'no'
check_usable "${REMOTES}" '/srv/git/nosuch-49b1c0.git' 'no'

# A name with no "/" in it is the name of a remote, so a repository of that
# name within the working tree does not make it usable, even though git would
# resolve the name as a relative pathname in a clone that has no such remote.
# A nested repository is commonplace -- a submodule, or a vendored clone -- and
# it is not the fork that `remote.pushDefault = working-tree` names, so pushing
# a branch into it is the failure that this function exists to prevent.  A
# value that is meant as a pathname says so with a "/", as "./working-tree"
# above does.
check_usable "${REMOTES}" 'working-tree' 'no'

# A file or a directory that is not a repository does not make a name usable.
# A working tree commonly contains a directory whose name is also a common
# name for a remote:  if an `upstream/` directory made `upstream` usable, then
# `remote.pushDefault = upstream` in ~/.gitconfig would send every query about
# the branch to something that is not a repository, and git answers such a
# query with "does not appear to be a git repository" -- exactly the failure
# that this function exists to prevent.  The clone in this check has only the
# remote "origin", so the name itself does not make "upstream" usable.
mkdir -p "${WORK_DIR}/upstream"
: > "${WORK_DIR}/plain-file"
check_usable 'origin' 'upstream' 'no'
check_usable "${REMOTES}" 'plain-file' 'no'

# A directory within a working tree is not the repository that contains it,
# even though a git command run there would find that repository.
mkdir -p "${WORK_DIR}/working-tree/subdir"
check_usable "${REMOTES}" 'working-tree/subdir' 'no'

# A remote that only some other clone has, whose name contains "/".  This is
# what `remote.pushDefault = team/fork` in ~/.gitconfig amounts to here, and
# `git remote add team/fork URL` shows that such a name is one that a remote
# can have.  Reporting it as usable would send every query to a repository
# that does not exist, which silently disables the check that made the query.
check_usable "${REMOTES}" 'team/fork' 'no'

# `push_remote` reports the pathname that the branch is pushed to, rather than
# falling back to "origin".  Falling back would make `is-deleted-branch` ask
# the wrong repository about the branch, which can report that a branch that
# still exists there was deleted.
git init -q -b main "${WORK_DIR}/clone"
echo "first line" > "${WORK_DIR}/clone/file.txt"
git -C "${WORK_DIR}/clone" add file.txt
git -C "${WORK_DIR}/clone" commit -q -m "Initial commit"
git -C "${WORK_DIR}/clone" remote add origin "${WORK_DIR}/origin.git"
git init -q --bare -b main "${WORK_DIR}/origin.git"
git -C "${WORK_DIR}/clone" config branch.main.remote '../mirrors/other.git'

remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != '../mirrors/other.git' ]; then
  fail "push_remote reported [${remote}] for a branch pushed to ../mirrors/other.git"
fi

# The pathname really is where git pushes the branch, so reporting it is right.
git -C "${WORK_DIR}/clone" push -q '../mirrors/other.git' main
if ! git -C "${WORK_DIR}/mirrors/other.git" rev-parse --verify --quiet main > /dev/null; then
  fail 'git did not push to the pathname that push_remote reported'
fi

# A name that no remote has still yields "origin", the remote that git itself
# falls back to, whether or not the name contains "/".  Reporting the name
# itself would make every query about the branch fail, and a failed query is
# not an answer:  `is-deleted-branch` would report "cannot tell" for a branch
# that "origin" can be asked about.
git -C "${WORK_DIR}/clone" config branch.main.remote 'fork'
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'origin' ]; then
  fail "push_remote reported [${remote}] for a branch whose remote this clone does not have"
fi
git -C "${WORK_DIR}/clone" config branch.main.remote 'team/fork'
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'origin' ]; then
  fail "push_remote reported [${remote}] for a branch whose remote is a name containing a slash"
fi

# `is_remote_name` distinguishes the two kinds of value that `push_remote`
# reports, so that a caller fetches into a remote-tracking namespace only where
# the remote has one.
if ! is_remote_name "${WORK_DIR}/clone" 'origin'; then
  fail 'is_remote_name said that "origin" is not a remote of the clone'
fi
if is_remote_name "${WORK_DIR}/clone" '../mirrors/other.git'; then
  fail 'is_remote_name said that a pathname is a remote of the clone'
fi
if is_remote_name "${WORK_DIR}/clone" 'fork'; then
  fail 'is_remote_name said that a name the clone lacks is a remote of it'
fi

# A directory in the working tree does not make the name of a remote that the
# clone lacks look like a pathname.  `remote.pushDefault = fork` in
# ~/.gitconfig names a remote that only some other clone has; if a `fork/`
# directory in the working tree made that name usable, every query about the
# branch would go to something that is not a repository, and the check that
# made the query would silently stop working.
git -C "${WORK_DIR}/clone" config --unset branch.main.remote
git -C "${WORK_DIR}/clone" config remote.pushDefault 'fork'
mkdir -p "${WORK_DIR}/clone/fork"
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'origin' ]; then
  fail "push_remote reported [${remote}] for a name that only a working-tree directory matches"
fi

# A repository nested in the working tree does not make such a name usable
# either.  A submodule, or a vendored clone, in a directory named "upstream" is
# commonplace, and `remote.pushDefault = upstream` in ~/.gitconfig names the
# fork that some other clone has:  pushing the branch into the nested
# repository is the same failure as pushing to a name that no repository has.
git init -q --bare -b main "${WORK_DIR}/clone/upstream"
git -C "${WORK_DIR}/clone" config remote.pushDefault 'upstream'
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'origin' ]; then
  fail "push_remote reported [${remote}] for a name that only a nested repository matches"
fi

# A pathname that does name a repository is still reported, even when it lies
# within the working tree, where the directories in the checks above lie.
git init -q --bare -b main "${WORK_DIR}/clone/fork/repository.git"
git -C "${WORK_DIR}/clone" config remote.pushDefault 'fork/repository.git'
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'fork/repository.git' ]; then
  fail "push_remote reported [${remote}] for a branch pushed to fork/repository.git"
fi

# `branch.BRANCH.pushRemote` outranks `branch.BRANCH.remote`, as `git push`
# itself does:  a branch that is fetched from one remote and pushed to another
# is pushed to the one that the pushRemote names.
git -C "${WORK_DIR}/clone" config branch.main.pushRemote '../mirrors/other.git'
git -C "${WORK_DIR}/clone" config branch.main.remote 'origin'
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != '../mirrors/other.git' ]; then
  fail "push_remote reported [${remote}] for a branch whose pushRemote is ../mirrors/other.git"
fi

# An empty branch, which means that HEAD is detached, uses only the
# configuration that is not about a particular branch:  the branch settings
# above are the ones of some other branch, which say nothing about this push.
remote="$(push_remote "${WORK_DIR}/clone" '')"
if [ "${remote}" != 'fork/repository.git' ]; then
  fail "push_remote reported [${remote}] for an empty branch"
fi
git -C "${WORK_DIR}/clone" config --unset branch.main.pushRemote
git -C "${WORK_DIR}/clone" config --unset branch.main.remote

# `fetch_remote` reports the remote that the branch is fetched from, which is
# not always the one that `push_remote` reports.  In the fork workflow the
# clone pushes to a fork -- `remote.pushDefault` or `branch.BRANCH.pushRemote`
# names it -- and fetches the project's branches from another remote, so a
# question about what the project has must go to the latter.  Asking the fork
# would report that a branch of the project does not exist.
git init -q --bare -b main "${WORK_DIR}/fork.git"
git -C "${WORK_DIR}/clone" remote add fork "${WORK_DIR}/fork.git"
git -C "${WORK_DIR}/clone" config remote.pushDefault 'fork'
remote="$(fetch_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'origin' ]; then
  fail "fetch_remote reported [${remote}] for a clone whose remote.pushDefault is fork"
fi
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'fork' ]; then
  fail "push_remote reported [${remote}] for a clone whose remote.pushDefault is fork"
fi
git -C "${WORK_DIR}/clone" config --unset remote.pushDefault
git -C "${WORK_DIR}/clone" config branch.main.pushRemote 'fork'
remote="$(fetch_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'origin' ]; then
  fail "fetch_remote reported [${remote}] for a branch whose pushRemote is fork"
fi

# `branch.BRANCH.remote` does say where the branch is fetched from, so
# `fetch_remote` reports it even though a pushRemote outranks it for a push.
git -C "${WORK_DIR}/clone" config branch.main.remote 'fork'
remote="$(fetch_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'fork' ]; then
  fail "fetch_remote reported [${remote}] for a branch whose remote is fork"
fi
git -C "${WORK_DIR}/clone" config --unset branch.main.remote
git -C "${WORK_DIR}/clone" config --unset branch.main.pushRemote

# A clone whose sole remote is not named "origin" fetches from that one.
git -C "${WORK_DIR}/clone" remote remove fork
git -C "${WORK_DIR}/clone" remote rename origin elsewhere
remote="$(fetch_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'elsewhere' ]; then
  fail "fetch_remote reported [${remote}] for a clone whose sole remote is elsewhere"
fi
# The same clone pushes to that remote, because it is the only one it has.
remote="$(push_remote "${WORK_DIR}/clone" main)"
if [ "${remote}" != 'elsewhere' ]; then
  fail "push_remote reported [${remote}] for a clone whose sole remote is elsewhere"
fi

## Usage: check_url_key URL EXPECTED
## Checks that `url_key`, in ${WORK_DIR}, prints EXPECTED for URL.
check_url_key() {
  check_url_key_actual="$(url_key "${WORK_DIR}" "$1")"
  if [ "${check_url_key_actual}" != "$2" ]; then
    fail "url_key [$1] printed [${check_url_key_actual}], not [$2]"
  fi
}

# Spellings of one repository's URL have one key.
check_url_key 'git@github.com:Org/Proj.git' 'github.com/org/proj'
check_url_key 'https://GitHub.com/org/proj/' 'github.com/org/proj'
# A scheme's default port is the same as no port.
check_url_key 'ssh://git@github.com:22/org/proj.git' 'github.com/org/proj'
check_url_key 'https://github.com:443/org/proj' 'github.com/org/proj'
# Any other port is part of the key, so a server on another port is a different
# repository.  An scp-style path that begins with digits is not a port.
check_url_key 'https://example.com:8443/org/proj' 'example.com:8443/org/proj'
check_url_key 'https://example.com/org/proj' 'example.com/org/proj'
check_url_key 'example.com:8443/org/proj' 'example.com/8443/org/proj'
# Only a host that ignores the case of its paths has its path in lower case.
check_url_key 'https://example.com/Org/Proj' 'example.com/Org/Proj'

## Usage: check_fetch_head_location URL EXPECTED
## Checks that `fetch_head_location` prints EXPECTED for URL.
check_fetch_head_location() {
  check_fetch_head_location_actual="$(fetch_head_location "$1")"
  if [ "${check_fetch_head_location_actual}" != "$2" ]; then
    fail "fetch_head_location [$1] printed [${check_fetch_head_location_actual}], not [$2]"
  fi
}

# A user name and password, trailing slashes, and a trailing ".git" are
# removed, as `git fetch` removes them.
check_fetch_head_location 'git@github.com:org/proj.git' 'github.com:org/proj'
check_fetch_head_location 'https://user:token@github.com/org/proj.git/' 'https://github.com/org/proj'
check_fetch_head_location 'ssh://git@github.com/org/proj' 'ssh://github.com/org/proj'
# An "@" after the host is part of the path.
check_fetch_head_location 'https://github.com/org/a@b.git' 'https://github.com/org/a@b'
check_fetch_head_location 'github.com:org/a@b' 'github.com:org/a@b'
check_fetch_head_location '/srv/git/proj.git' '/srv/git/proj'

# A `file://` URL and the pathname of one directory are one repository, but
# they reach it through different transports, so one answer to
# `git ls-remote` does not serve both.
git init -q --bare "${WORK_DIR}/heads.git"
for heads_dir in heads-by-url heads-by-path; do
  git init -q "${WORK_DIR}/${heads_dir}"
done
git -C "${WORK_DIR}/heads-by-url" remote add origin "file://${WORK_DIR}/heads.git"
git -C "${WORK_DIR}/heads-by-path" remote add origin "${WORK_DIR}/heads.git"
by_url="$(repository_key "${WORK_DIR}/heads-by-url" origin)"
if [ -z "${by_url}" ] || [ "${by_url}" != "$(repository_key "${WORK_DIR}/heads-by-path" origin)" ]; then
  fail "repository_key does not equate a file:// URL with its pathname"
fi
by_url="$(remote_heads_key "${WORK_DIR}/heads-by-url" origin)"
if [ -z "${by_url}" ] || [ "${by_url}" = "$(remote_heads_key "${WORK_DIR}/heads-by-path" origin)" ]; then
  fail "remote_heads_key [${by_url}] does not distinguish a file:// URL from its pathname"
fi

## Usage: check_is_deleted_branch DIRECTORY EXPECTED DESCRIPTION
## Checks that `is_deleted_branch DIRECTORY` returns status EXPECTED.
check_is_deleted_branch() {
  check_is_deleted_branch_status=0
  is_deleted_branch "$1" || check_is_deleted_branch_status="$?"
  if [ "${check_is_deleted_branch_status}" -ne "$2" ]; then
    fail "is_deleted_branch on $3 returned ${check_is_deleted_branch_status}, not $2"
  fi
}

# `is_deleted_branch` is the body of the `is-deleted-branch` command, which is
# a wrapper around it.  tests/test-is-deleted-branch.sh exercises the answers
# in depth through the command; what this checks is that the function answers
# the same way when a script sources it and calls it directly, which is how
# the other commands of this package use it.
git init -q --bare -b main "${WORK_DIR}/idb-remote.git"
# Redirect stderr to suppress the "you appear to have cloned an empty
# repository" warning.
git clone -q "${WORK_DIR}/idb-remote.git" "${WORK_DIR}/idb-seed" 2> /dev/null
echo 'content' > "${WORK_DIR}/idb-seed/file.txt"
git -C "${WORK_DIR}/idb-seed" add file.txt
git -C "${WORK_DIR}/idb-seed" commit -q -m 'Initial commit'
git -C "${WORK_DIR}/idb-seed" push -q -u origin main
git -C "${WORK_DIR}/idb-seed" push -q origin main:refs/heads/doomed
git clone -q -b doomed "${WORK_DIR}/idb-remote.git" "${WORK_DIR}/idb-dead"
git clone -q -b main "${WORK_DIR}/idb-remote.git" "${WORK_DIR}/idb-live"
git -C "${WORK_DIR}/idb-seed" push -q origin --delete doomed
check_is_deleted_branch "${WORK_DIR}/idb-dead" 0 'a branch deleted in its remote'
check_is_deleted_branch "${WORK_DIR}/idb-live" 1 'a branch that still exists'
mkdir -p "${WORK_DIR}/idb-plain-directory"
check_is_deleted_branch "${WORK_DIR}/idb-plain-directory" 2 'no working tree'
if [ -z "${is_deleted_branch_no_usable_repository}" ]; then
  fail "is_deleted_branch did not record that git can use no repository at a plain directory"
fi
mkdir -p "${WORK_DIR}/idb-live/subdirectory"
check_is_deleted_branch "${WORK_DIR}/idb-live/subdirectory" 2 'a subdirectory of a working tree'
if [ -n "${is_deleted_branch_no_usable_repository}" ]; then
  fail "is_deleted_branch recorded that git can use no repository at a subdirectory of a working tree"
fi
check_is_deleted_branch "${WORK_DIR}/idb-remote.git" 2 'a bare repository'
if [ -n "${is_deleted_branch_no_usable_repository}" ]; then
  fail "is_deleted_branch recorded that git can use no repository at a bare repository"
fi

# `check_is_deleted_branch` calls the function on the left of `||`, which
# suppresses `set -e` for the whole of the function's body.  A caller that acts
# on the answer instead -- the commands of this package run under `set -e` --
# gets no such suppression, so check that the function survives one.  Do it in
# a separate script, because a failure here kills the shell that runs it.
#
# The branch is pushed without `-u`, so it has no upstream configuration and
# the `git config --get` queries fail, and it is then deleted in the remote, so
# the `ls-remote` query fails too.  Both failures are answers rather than
# errors, and the function must return 0 rather than let them abort the caller.
git clone -q -b main "${WORK_DIR}/idb-remote.git" "${WORK_DIR}/idb-errexit"
git -C "${WORK_DIR}/idb-errexit" checkout -q -b unconfigured
git -C "${WORK_DIR}/idb-errexit" push -q origin unconfigured
# Delete it from another clone, so that this one keeps the remote-tracking ref
# that shows that the branch was pushed.
git -C "${WORK_DIR}/idb-seed" push -q origin --delete unconfigured
cat > "${WORK_DIR}/errexit-caller.sh" << 'EOF'
#!/bin/sh
set -e
SCRIPT_NAME='errexit-caller.sh'
SCRIPT_DIR="$2"
# shellcheck source=/dev/null
. "$2/common-functions.sh"
is_deleted_branch "$1"
echo 'survived'
EOF
errexit_output="$(sh "${WORK_DIR}/errexit-caller.sh" "${WORK_DIR}/idb-errexit" \
  "${COMMANDS_DIR}" 2>&1)" \
  || fail "is_deleted_branch aborted a caller that runs under set -e: [${errexit_output}]"
if [ "${errexit_output}" != 'survived' ]; then
  fail "is_deleted_branch under set -e printed [${errexit_output}], not [survived]"
fi

# `require_git` accepts the git that runs this test for a requirement that it
# meets, and refuses one that it does not, naming the version that it found.
# It exits rather than returning, so run it in a subshell.
if ! require_git_output="$( (require_git 0) 2>&1)"; then
  fail "require_git 0 refused git: [${require_git_output}]"
fi
if require_git_output="$( (require_git 9999 'for a test') 2>&1)"; then
  fail "require_git 9999 accepted git"
fi
case "${require_git_output}" in
  *"requires git 2.9999 or later for a test, but found git $(git version | sed 's/^git version //')") ;;
  *) fail "unexpected message from require_git 9999: [${require_git_output}]" ;;
esac
# A git that reports an old version, or one that cannot be parsed.  The
# subshells change PATH for `require_git` alone, which is the point.
. "${TESTS_DIR}/common-test-functions.sh"
make_fake_git "${WORK_DIR}/oldgit" version 0 'git version 2.30.9'
# shellcheck disable=SC2030
if require_git_output="$( (PATH="${WORK_DIR}/oldgit:${PATH}" && require_git 31) 2>&1)"; then
  fail "require_git 31 accepted git 2.30.9"
fi
case "${require_git_output}" in
  *"requires git 2.31 or later, but found git 2.30.9") ;;
  *) fail "unexpected message from require_git 31 for git 2.30.9: [${require_git_output}]" ;;
esac
make_fake_git "${WORK_DIR}/oddgit" version 0 'git version unknown'
# shellcheck disable=SC2030,SC2031
if require_git_output="$( (PATH="${WORK_DIR}/oddgit:${PATH}" && require_git 31) 2>&1)"; then
  fail "require_git 31 accepted an unparsable version"
fi
# `git_at_least` reports the unparsable version, and `require_git` then
# reports the requirement.
case "${require_git_output}" in
  *"cannot parse git version: unknown"*"requires git 2.31 or later, but found git unknown") ;;
  *) fail "unexpected message for an unparsable version: [${require_git_output}]" ;;
esac

# `changes_already_present` recognizes a squash-merge into main of a pull
# request whose branch feature merged, when main changed the file after the
# pull request's branch started, so that the squash-merge is a three-way
# merge rather than a copy of the pull request's version.  No commit on
# feature has main's version, so only the pull request's commit matches.
cap_repo="${WORK_DIR}/cap"
git init -q -b main "${cap_repo}"
printf '%s\n' one two three four five six seven eight nine > "${cap_repo}/file.txt"
git -C "${cap_repo}" add file.txt
git -C "${cap_repo}" commit -q -m 'Initial commit'
git -C "${cap_repo}" branch pr
git -C "${cap_repo}" branch feature
printf '%s\n' one two three four five six seven eight NINE-main > "${cap_repo}/file.txt"
git -C "${cap_repo}" commit -q -a -m 'Change line 9'
git -C "${cap_repo}" worktree add -q "${WORK_DIR}/cap-pr" pr
printf '%s\n' one two 'THREE changed by the pull request' four five six seven eight nine > "${WORK_DIR}/cap-pr/file.txt"
git -C "${WORK_DIR}/cap-pr" commit -q -a -m 'Change line 3'
cap_pr="$(git -C "${cap_repo}" rev-parse --short pr)"
git -C "${cap_repo}" worktree add -q "${WORK_DIR}/cap-feature" feature
git -C "${WORK_DIR}/cap-feature" merge -q --ff-only pr
printf '%s\n' one two 'THREE changed by the pull request' four five six SEVEN-feature eight nine > "${WORK_DIR}/cap-feature/file.txt"
git -C "${WORK_DIR}/cap-feature" commit -q -a -m 'Change line 7'
git -C "${WORK_DIR}/cap-feature" merge -q --no-edit main > /dev/null
printf '%s\n' one two 'THREE changed by the pull request' four five six seven eight NINE-main > "${cap_repo}/file.txt"
git -C "${cap_repo}" commit -q -a -m 'Change line 3 (#1)'
cap_squash="$(git -C "${cap_repo}" rev-parse --short HEAD)"
if ! (cd "${cap_repo}" && changes_already_present file.txt feature main && echo "${cap_others}|${cap_kepts}") > "${WORK_DIR}/cap-out"; then
  fail "changes_already_present did not recognize a squash-merge after a change to main"
elif [ "$(cat "${WORK_DIR}/cap-out")" != "${cap_squash}|${cap_pr}" ]; then
  fail "changes_already_present named [$(cat "${WORK_DIR}/cap-out")], not [${cap_squash}|${cap_pr}]"
fi
# A later change on main that feature lacks is not present.
printf '%s\n' one two 'THREE changed by the pull request' four five six seven EIGHT-main NINE-main > "${cap_repo}/file.txt"
git -C "${cap_repo}" commit -q -a -m 'Change line 8'
if (cd "${cap_repo}" && changes_already_present file.txt feature main); then
  fail "changes_already_present accepted a change that feature lacks"
fi
# So is one that the filter cannot rule out, because a version on feature
# contains main's new line within a different line; only the merge rules it
# out.
printf '%s\n' one two 'THREE changed by the pull request' four five six SEVEN-feature 'EIGHT-main, but longer' \
  NINE-main > "${WORK_DIR}/cap-feature/file.txt"
git -C "${WORK_DIR}/cap-feature" commit -q -a -m 'Change line 8 differently'
cap_lookalike="$(git -C "${cap_repo}" rev-parse feature)"
cpp_out="$(cd "${cap_repo}" && changes_present_plausible file.txt "$(git rev-parse 'main~1:file.txt')" \
  "$(git rev-parse 'main:file.txt')" "${cap_lookalike}")"
[ "${cpp_out}" = "${cap_lookalike}" ] \
  || fail "changes_present_plausible ruled out a version that contains main's new line: [${cpp_out}]"
if (cd "${cap_repo}" && changes_present_max_unfiltered=0 && changes_already_present file.txt feature main); then
  fail "changes_already_present accepted a change that feature lacks, with the filter"
fi

# `changes_present_plausible` prints each candidate whose version contains
# the lines that the result has more times than the merge's own version,
# every candidate when there are no such lines, and every candidate when
# `git grep` fails.
cpp_current="$(git -C "${cap_repo}" rev-parse 'main~2:file.txt')"
cpp_want="$(git -C "${cap_repo}" rev-parse 'main~1:file.txt')"
cpp_pr="$(git -C "${cap_repo}" rev-parse pr)"
cpp_initial="$(git -C "${cap_repo}" rev-parse 'main~3')"
cpp_out="$(cd "${cap_repo}" && changes_present_plausible file.txt "${cpp_current}" "${cpp_want}" "${cpp_initial}" "${cpp_pr}")"
[ "${cpp_out}" = "${cpp_pr}" ] \
  || fail "changes_present_plausible printed [${cpp_out}], not only the pull request's commit"
cpp_deleted="$(printf '%s\n' one two three four six seven eight NINE-main | git -C "${cap_repo}" hash-object -w --stdin)"
cpp_out="$(cd "${cap_repo}" && changes_present_plausible file.txt "${cpp_current}" "${cpp_deleted}" "${cpp_initial}" "${cpp_pr}")"
[ "${cpp_out}" = "${cpp_initial}
${cpp_pr}" ] || fail "changes_present_plausible filtered a deletion: [${cpp_out}]"
cpp_out="$(cd "${cap_repo}" && changes_present_plausible file.txt "${cpp_current}" "${cpp_want}" "${cpp_initial}" 0000000000000000000000000000000000000001)"
[ "${cpp_out}" = "${cpp_initial}
0000000000000000000000000000000000000001" ] \
  || fail "changes_present_plausible filtered after \`git grep\` failed: [${cpp_out}]"

# `changes_already_present` recognizes a commit on main whose version of the
# file is that of a commit on feature, when the repository lacks that
# version, as a partial clone can.  `git rev-parse` recovers its hash, which
# is all that the merge needs, because main's version is the merge base's.
cap_missing_repo="${WORK_DIR}/cap-missing"
git init -q -b main "${cap_missing_repo}"
printf '%s\n' one two three > "${cap_missing_repo}/file.txt"
git -C "${cap_missing_repo}" add file.txt
git -C "${cap_missing_repo}" commit -q -m 'Initial commit'
git -C "${cap_missing_repo}" worktree add -q -b feature "${WORK_DIR}/cap-missing-feature"
printf '%s\n' one TWO three > "${WORK_DIR}/cap-missing-feature/file.txt"
git -C "${WORK_DIR}/cap-missing-feature" commit -q -a -m 'Change line 2'
printf '%s\n' one TWO three > "${cap_missing_repo}/file.txt"
git -C "${cap_missing_repo}" commit -q -a -m 'Change line 2 (#1)'
cap_missing_blob="$(git -C "${cap_missing_repo}" rev-parse 'main:file.txt')"
cap_missing_object="$(git -C "${cap_missing_repo}" rev-parse --path-format=absolute \
  --git-path "objects/$(printf '%s' "${cap_missing_blob}" | cut -c1-2)/$(printf '%s' "${cap_missing_blob}" | cut -c3-)")"
mv "${cap_missing_object}" "${cap_missing_object}.hidden"
if git -C "${cap_missing_repo}" cat-file -e "${cap_missing_blob}" 2> /dev/null; then
  fail "the repository still has blob ${cap_missing_blob}"
fi
if ! (cd "${cap_missing_repo}" && changes_already_present file.txt feature main); then
  fail "changes_already_present did not recognize a version that the repository lacks"
fi
if ! (cd "${cap_missing_repo}" && changes_present_max_unfiltered=0 && changes_already_present file.txt feature main); then
  fail "changes_already_present did not recognize a version that the repository lacks, with the filter"
fi

# `undo_worktree_add` removes a worktree, its registration, and its branch,
# and leaves everything else of the repository alone.
uwa_main="${WORK_DIR}/uwa-branch-main"
git init -q -b main "${uwa_main}"
echo 'content' > "${uwa_main}/file.txt"
git -C "${uwa_main}" add file.txt
git -C "${uwa_main}" commit -q -m 'Initial commit'
uwa_commit="$(git -C "${uwa_main}" rev-parse HEAD)"
git -C "${uwa_main}" worktree add -q -b doomed "${WORK_DIR}/uwa-branch-doomed"
git -C "${uwa_main}" config branch.doomed.remote origin
git -C "${uwa_main}" config branch.doomed.merge refs/heads/doomed
uwa_gitdir="$(git -C "${WORK_DIR}/uwa-branch-doomed" rev-parse --absolute-git-dir)"
# A half-built worktree has modifications, which `git worktree remove` would
# refuse without `--force`.
echo 'modified' > "${WORK_DIR}/uwa-branch-doomed/file.txt"
# A moved worktree elsewhere in the repository, which `git worktree prune`
# would destroy, must survive.
git -C "${uwa_main}" worktree add -q -b moved "${WORK_DIR}/uwa-branch-moved"
mv "${WORK_DIR}/uwa-branch-moved" "${WORK_DIR}/uwa-branch-moved-elsewhere"
undo_worktree_add "${uwa_main}" "${WORK_DIR}/uwa-branch-doomed" "${uwa_gitdir}" \
  doomed "${uwa_commit}"
if [ -e "${WORK_DIR}/uwa-branch-doomed" ] || [ -e "${uwa_gitdir}" ]; then
  fail "undo_worktree_add left the worktree or its administrative directory"
fi
if git -C "${uwa_main}" rev-parse --verify --quiet refs/heads/doomed > /dev/null; then
  fail "undo_worktree_add left the branch doomed"
fi
if git -C "${uwa_main}" config --get-regexp '^branch\.doomed\.' > /dev/null; then
  fail "undo_worktree_add left the configuration of the branch doomed"
fi
if ! git -C "${uwa_main}" worktree list --porcelain | grep -q -x -F \
  "worktree ${WORK_DIR}/uwa-branch-moved"; then
  fail "undo_worktree_add removed the registration of a moved worktree"
fi
git -C "${uwa_main}" worktree repair "${WORK_DIR}/uwa-branch-moved-elsewhere" > /dev/null 2>&1

# Interrupted between the renames that put a worktree in place, the caller has
# no directory at the registered path, only the administrative directory that
# it learned.  That is removed, and the registration with it, without
# disturbing the registration of a path that is missing for another reason.
git -C "${uwa_main}" worktree add -q --no-checkout -b halfway "${WORK_DIR}/uwa-branch-halfway"
uwa_gitdir="$(git -C "${WORK_DIR}/uwa-branch-halfway" rev-parse --absolute-git-dir)"
rm -rf "${WORK_DIR}/uwa-branch-halfway"
git -C "${uwa_main}" worktree add -q -b stale "${WORK_DIR}/uwa-branch-stale"
rm -rf "${WORK_DIR}/uwa-branch-stale"
undo_worktree_add "${uwa_main}" "${WORK_DIR}/uwa-branch-halfway" "${uwa_gitdir}" \
  halfway "${uwa_commit}"
if [ -e "${uwa_gitdir}" ]; then
  fail "undo_worktree_add left the administrative directory of a missing worktree"
fi
if git -C "${uwa_main}" worktree list --porcelain | grep -q -x -F \
  "worktree ${WORK_DIR}/uwa-branch-halfway"; then
  fail "undo_worktree_add left the registration of a missing worktree"
fi

# A `git worktree add` that failed has nothing at the path, and the caller
# learned no administrative directory.  A registration of that path that is
# not the caller's -- a stale one, which is what made the add fail -- is left
# alone, but the branch that the add created before it failed is deleted.
git -C "${uwa_main}" branch stalebranch
uwa_stale_gitdir="$(git -C "${uwa_main}" rev-parse --path-format=absolute \
  --git-common-dir)/worktrees/uwa-branch-stale"
undo_worktree_add "${uwa_main}" "${WORK_DIR}/uwa-branch-stale" '' \
  stalebranch "${uwa_commit}"
if [ ! -d "${uwa_stale_gitdir}" ]; then
  fail "undo_worktree_add removed a stale registration that was not its own"
fi
if git -C "${uwa_main}" rev-parse --verify --quiet refs/heads/stalebranch > /dev/null; then
  fail "undo_worktree_add left the branch stalebranch"
fi

# A branch that is no longer at the commit that the caller created it at was
# moved by something else, and is left alone.
git -C "${uwa_main}" commit -q --allow-empty -m 'Second commit'
git -C "${uwa_main}" branch movedbranch
git -C "${uwa_main}" config branch.movedbranch.merge refs/heads/movedbranch
undo_worktree_add "${uwa_main}" "${WORK_DIR}/uwa-branch-nothing" '' \
  movedbranch "${uwa_commit}"
if ! git -C "${uwa_main}" rev-parse --verify --quiet refs/heads/movedbranch > /dev/null; then
  fail "undo_worktree_add deleted a branch that is not at the given commit"
fi
if ! git -C "${uwa_main}" config --get branch.movedbranch.merge > /dev/null; then
  fail "undo_worktree_add removed the configuration of a branch that it left"
fi

## Tests of check_conflict_resolution.  Each case makes AUTO_MERGE a tree
## whose file f.txt has given contents, with conflict markers, and writes the
## resolution to f.txt in the working tree.
git init -q "${WORK_DIR}/ccr"

## Usage: check_resolution_files EXPECTED DESCRIPTION
## Makes AUTO_MERGE a tree whose file f.txt is ${WORK_DIR}/ccr-auto, and checks
## that `check_conflict_resolution` accepts (EXPECTED "accept") or rejects
## (EXPECTED "reject") the resolution in ${WORK_DIR}/ccr/f.txt.  It passes
## ${ccr_contains_separator} as the argument that says whether a side of the
## merge contains a line "=======".
ccr_contains_separator=no
check_resolution_files() {
  check_resolution_blob="$(git -C "${WORK_DIR}/ccr" hash-object --no-filters -w "${WORK_DIR}/ccr-auto")"
  check_resolution_tree="$(printf '100644 blob %s\tf.txt\n' "${check_resolution_blob}" \
    | git -C "${WORK_DIR}/ccr" mktree)"
  git -C "${WORK_DIR}/ccr" update-ref AUTO_MERGE "${check_resolution_tree}"
  if (cd "${WORK_DIR}/ccr" && check_conflict_resolution f.txt "${ccr_contains_separator}" 2> /dev/null); then
    check_resolution_actual=accept
  else
    check_resolution_actual=reject
  fi
  if [ "${check_resolution_actual}" != "$1" ]; then
    fail "check_conflict_resolution: $2: expected $1, got ${check_resolution_actual}"
  fi
}

## Usage: check_resolution EXPECTED DESCRIPTION AUTO_MERGE_LINES -- RESOLUTION_LINES
## Like `check_resolution_files`, but takes the files' lines as arguments.
check_resolution() {
  check_resolution_expected="$1"
  check_resolution_description="$2"
  shift 2
  : > "${WORK_DIR}/ccr-auto"
  while [ "$1" != "--" ]; do
    printf '%s\n' "$1" >> "${WORK_DIR}/ccr-auto"
    shift
  done
  shift
  : > "${WORK_DIR}/ccr/f.txt"
  for check_resolution_line; do
    printf '%s\n' "${check_resolution_line}" >> "${WORK_DIR}/ccr/f.txt"
  done
  check_resolution_files "${check_resolution_expected}" "${check_resolution_description}"
}

check_resolution accept "both sides kept" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d -- a b c d
# `git diff -U0` puts the deletion of the blank line on the one after the
# region, outside it.
check_resolution accept "blank lines at the end of the region and after it" \
  a '<<<<<<< HEAD' b '' '=======' c '' '>>>>>>> other' '' d -- a b '' c '' d
check_resolution reject "a separator remains" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d -- a b '=======' c d
ccr_contains_separator=yes
check_resolution accept "a heading underline that looks like a separator, when a side contains one" \
  intro '<<<<<<< HEAD' 'Title A' '=======' '=======' 'Title B' '=======' '>>>>>>> other' text \
  -- intro 'Title B' '=======' text
ccr_contains_separator=no
check_resolution accept "diff3 style" \
  a '<<<<<<< HEAD' b '||||||| base' x '=======' c '>>>>>>> other' d -- a bc d
check_resolution accept "two regions" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' m '<<<<<<< HEAD' e '=======' f '>>>>>>> other' z \
  -- a b m e f z
check_resolution accept "two adjacent regions" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' '<<<<<<< HEAD' e '=======' f '>>>>>>> other' z \
  -- a b f z
check_resolution accept "a resolution that repeats the text between regions" \
  a '<<<<<<< HEAD' m '=======' c '>>>>>>> other' m '<<<<<<< HEAD' e '=======' f '>>>>>>> other' z \
  -- a m m f z
check_resolution reject "the text before the region changed" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d -- A b c d
check_resolution reject "the text after the region changed" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d -- a b c
check_resolution reject "the text between regions changed" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' m '<<<<<<< HEAD' e '=======' f '>>>>>>> other' z \
  -- a b M e f z
check_resolution reject "nothing resolved" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d -- a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d
check_resolution reject "a marker remains" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d -- a b c '>>>>>>> other' d
check_resolution reject "no conflict markers in AUTO_MERGE" \
  a b c -- a b c
# After criss-cross merges, the merge base's text contains git's longer
# markers from merging the merge bases, which can be unbalanced.
check_resolution accept "longer markers in the text of the merge base" \
  a '<<<<<<< HEAD' c '||||||| merged common ancestors' '<<<<<<<<< Temporary merge branch 1' X1 \
  '||||||||| 0f1dad6' X '=========' X2 '>>>>>>>>> Temporary merge branch 2' '=======' d \
  '>>>>>>> main' b -- a c d b
check_resolution accept "unbalanced longer markers in the text of the merge base" \
  a X1 '<<<<<<< HEAD' c '||||||| merged common ancestors' '||||||||| 0f1dad6' X '=========' X2 \
  '>>>>>>>>> Temporary merge branch 2' '=======' d '>>>>>>> main' b -- a X1 c d b
check_resolution reject "unbalanced longer markers in the text of the merge base, and markers remain" \
  a X1 '<<<<<<< HEAD' c '||||||| merged common ancestors' '||||||||| 0f1dad6' X '=========' X2 \
  '>>>>>>>>> Temporary merge branch 2' '=======' d '>>>>>>> main' b -- a X1 c '=======' d '>>>>>>> main' b
check_resolution reject "a longer marker from the text of the merge base remains" \
  a '<<<<<<< HEAD' c '||||||| merged common ancestors' X '>>>>>>>>> Temporary merge branch 2' \
  '=======' d '>>>>>>> main' b -- a c '>>>>>>>>> Temporary merge branch 2' d b
# The attribute `conflict-marker-size` sets the length of the markers.  The
# length is that of the markers in AUTO_MERGE, which git wrote using the
# attributes from before the merge, and not the length that the attributes
# in the working tree give, which the merge can change.
check_resolution accept "markers of 10 characters, as the attribute conflict-marker-size makes them" \
  a '<<<<<<<<<< HEAD' b '||||||||||' '>>>>>>>>>>>> Temporary merge branch 2' '==========' c \
  '>>>>>>>>>> other' d -- a b c d
check_resolution reject "a marker of 10 characters remains" \
  a '<<<<<<<<<< HEAD' b '==========' c '>>>>>>>>>> other' d -- a b c '>>>>>>>>>> other' d
printf 'f.txt conflict-marker-size=10\n' > "${WORK_DIR}/ccr/.gitattributes"
check_resolution accept "markers of 7 characters, when a merge set the attribute conflict-marker-size to 10" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d -- a b c d
check_resolution reject "a marker of 7 characters remains, when a merge set the attribute conflict-marker-size to 10" \
  a '<<<<<<< HEAD' b '=======' c '>>>>>>> other' d -- a b c '>>>>>>> other' d
rm "${WORK_DIR}/ccr/.gitattributes"
# Markers shorter than 7 characters, as the attribute conflict-marker-size=5
# makes them, are not recognized.
check_resolution reject "markers of 5 characters" \
  a '<<<<< HEAD' b '=====' c '>>>>> other' d -- a b c d

## Usage: check_resolution_raw EXPECTED DESCRIPTION AUTO_MERGE_TEXT RESOLUTION_TEXT
## Like `check_resolution_files`, but takes the files' contents as printf
## formats, so that a test can omit the final newline or use CRLF line endings.
check_resolution_raw() {
  # shellcheck disable=SC2059 # The contents are formats.
  printf "$3" > "${WORK_DIR}/ccr-auto"
  # shellcheck disable=SC2059 # The contents are formats.
  printf "$4" > "${WORK_DIR}/ccr/f.txt"
  check_resolution_files "$1" "$2"
}

check_resolution_raw accept "no final newline" \
  '<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\nc' 'aA\nb\nc'
check_resolution_raw reject "no final newline, and the last line changed" \
  '<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\nc' 'aA\nb\nC'
check_resolution_raw reject "the final newline was added" \
  '<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\nc' 'aA\nb\nc\n'
check_resolution_raw reject "the final newline was removed" \
  '<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\nc\n' 'aA\nb\nc'
check_resolution_raw accept "no final newline after a region at the end" \
  'x\n<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\n' 'x\naA'
# A checkout converts the repository's LF line endings to CRLF.
printf '* text eol=crlf\n' > "${WORK_DIR}/ccr/.gitattributes"
check_resolution_raw accept "CRLF line endings in the working tree" \
  'x\n<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\n' 'x\r\naA\r\nb\r\n'
check_resolution_raw reject "CRLF line endings, and a clean line changed" \
  'x\n<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\n' 'x\r\naA\r\nB\r\n'
check_resolution_raw reject "CRLF line endings, and a marker without a label remains" \
  'x\n<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\n' 'x\r\naA\r\n>>>>>>>\r\nb\r\n'
check_resolution_raw reject "CRLF line endings, and a separator remains" \
  'x\n<<<<<<< HEAD\na\n=======\nA\n>>>>>>> other\nb\n' 'x\r\na\r\n=======\r\nA\r\nb\r\n'
rm "${WORK_DIR}/ccr/.gitattributes"

## Tests of source_without_url.  The clone has the remote "origin", an
## scp-style URL with the remote-tracking branch "origin/feature", and the
## remote "local", a pathname with the remote-tracking branch "local/main".
## Both contain ${swu_head}, but neither contains ${swu_other}.
git init -q -b main "${WORK_DIR}/swu"
git -C "${WORK_DIR}/swu" commit -q --allow-empty -m "Initial commit"
git -C "${WORK_DIR}/swu" remote add origin 'git@github.com:org/proj.git'
git -C "${WORK_DIR}/swu" remote add local '/nonexistent/repo.git/'
git -C "${WORK_DIR}/swu" update-ref refs/remotes/origin/feature HEAD
git -C "${WORK_DIR}/swu" update-ref refs/remotes/local/main HEAD
swu_head="$(git -C "${WORK_DIR}/swu" rev-parse HEAD)"
git -C "${WORK_DIR}/swu" commit -q --allow-empty -m "Second commit"
swu_other="$(git -C "${WORK_DIR}/swu" rev-parse HEAD)"

## Usage: check_swu SOURCE EXPECTED [COMMIT]
## Checks that `source_without_url`, in ${WORK_DIR}/swu, prints EXPECTED for
## SOURCE and COMMIT, which is ${swu_head} by default.
check_swu() {
  check_swu_actual="$(cd "${WORK_DIR}/swu" && source_without_url "$1" "${3:-${swu_head}}")"
  if [ "${check_swu_actual}" != "$2" ]; then
    fail "source_without_url [$1] printed [${check_swu_actual}], not [$2]"
  fi
}

# `git pull` writes the URL without its user and its trailing ".git".
check_swu "branch 'feature' of github.com:org/proj" \
  "remote-tracking branch 'origin/feature'"
# Another spelling of the URL.
check_swu "branch 'feature' of https://github.com/Org/Proj" \
  "remote-tracking branch 'origin/feature'"
# A pathname, which names no directory, without its trailing "/" and ".git".
check_swu "branch 'main' of /nonexistent/repo" \
  "remote-tracking branch 'local/main'"
# No remote-tracking branch tracks the source, and its URL is not a pathname.
check_swu "branch 'other' of github.com:org/proj" \
  "branch 'other' of github.com:org/proj"
check_swu "branch 'feature' of github.com:org/elsewhere" \
  "branch 'feature' of github.com:org/elsewhere"
# The remote-tracking branch lacks the merged commit.
check_swu "branch 'feature' of github.com:org/proj" \
  "branch 'feature' of github.com:org/proj" "${swu_other}"
# No remote-tracking branch tracks the source, and its URL is a pathname,
# which only its last component names.
check_swu "branch 'main' of /nonexistent/repo" "branch 'main' of repo" \
  "${swu_other}"
check_swu "branch 'main' of ../sibling/proj" "branch 'main' of proj"
# `git pull` writes "/srv/git/proj/" for the URL "/srv/git/proj/.git".
check_swu "branch 'main' of /srv/git/proj/" "branch 'main' of proj"
check_swu "branch 'main' of file:///srv/git/proj" "branch 'main' of proj"
check_swu "branch 'main' of /srv/a:b/proj" "branch 'main' of proj"
# The local repository, whose pathname reveals nothing.
check_swu "branch 'main' of ." "branch 'main' of ."
# A source that names no URL.
check_swu "branch 'main'" "branch 'main'"
check_swu "remote-tracking branch 'origin/main'" \
  "remote-tracking branch 'origin/main'"
# Other sources of a pathname, and the head of a pathname.
check_swu "tag 'v1' of /srv/git/proj" "tag 'v1' of proj"
check_swu "/srv/git/proj" "proj"
check_swu "tag 'v1' of github.com:org/proj" "tag 'v1' of github.com:org/proj"
check_swu "github.com:org/proj" "github.com:org/proj"

## Tests of subject_without_url, in the same clone as those of
## source_without_url.

## Usage: check_subject SUBJECT EXPECTED [COMMIT]
## Checks that `subject_without_url`, in ${WORK_DIR}/swu, prints EXPECTED for
## SUBJECT and COMMIT, which is ${swu_head} by default.
check_subject() {
  check_subject_actual="$(cd "${WORK_DIR}/swu" && subject_without_url "$1" "${3:-${swu_head}}")"
  if [ "${check_subject_actual}" != "$2" ]; then
    fail "subject_without_url [$1] printed [${check_subject_actual}], not [$2]"
  fi
}

check_subject "Merge branch 'feature' of github.com:org/proj into feature" \
  "Merge remote-tracking branch 'origin/feature' into feature"
# On the default branch, `git merge` omits " into BRANCH".
check_subject "Merge branch 'feature' of https://github.com/Org/Proj" \
  "Merge remote-tracking branch 'origin/feature'"
check_subject "Merge branch 'main' of /nonexistent/repo into feature" \
  "Merge branch 'main' of repo into feature" "${swu_other}"
check_subject "Merge branch 'feature' of github.com:org/proj into feature" \
  "Merge branch 'feature' of github.com:org/proj into feature" "${swu_other}"
# A merge that no pull made.
check_subject "Merge branch 'main' into feature" \
  "Merge branch 'main' into feature"
check_subject "Merge remote-tracking branch 'origin/main' into feature" \
  "Merge remote-tracking branch 'origin/main' into feature"
check_subject "Merge pull request #12 from org/feature" \
  "Merge pull request #12 from org/feature"
# Several sources of one repository.
check_subject "Merge branches 'a' and 'b' of /srv/git/proj into feature" \
  "Merge branches 'a' and 'b' of proj into feature"
check_subject "Merge branch 'a', tag 'v1' of /srv/git/proj into feature" \
  "Merge branch 'a', tag 'v1' of proj into feature"
check_subject "Merge tag 'v1' of /srv/git/proj into feature" \
  "Merge tag 'v1' of proj into feature"
check_subject "Merge /srv/git/proj into feature" "Merge proj into feature"
# Sources of several repositories, of which none is named by a
# remote-tracking branch, because COMMIT is the commit of only one of them.
check_subject "Merge branch 'a' of /home/me/p; branch 'b' of github.com:x/y into main" \
  "Merge branch 'a' of p; branch 'b' of github.com:x/y into main"
check_subject "Merge branch 'feature' of github.com:org/proj; branch 'b' of /home/me/q" \
  "Merge branch 'feature' of github.com:org/proj; branch 'b' of q"
check_subject "Merge remote-tracking branch 'origin/x'; branch 'a' of /home/p into feature" \
  "Merge remote-tracking branch 'origin/x'; branch 'a' of p into feature"

## Tests of wait_for_later_time.  Each test uses its own directory, in which
## the function creates its probe directory.
mkdir "${WORK_DIR}/wflt" "${WORK_DIR}/wflt/now" "${WORK_DIR}/wflt/later" \
  "${WORK_DIR}/wflt/never" "${WORK_DIR}/wflt/exists" "${WORK_DIR}/wflt/symlink"

## Usage: check_wflt_probe_removed DIR DESCRIPTION
## Checks that wait_for_later_time removed its probe directory from DIR.
check_wflt_probe_removed() {
  if [ -e "$1/.manage-git-branches-time-probe" ]; then
    fail "wait_for_later_time, $2: the probe directory remains"
  fi
}

# The time never passes a marker whose modification time is far in the
# future, so the function gives up.  A limit of 3 tries keeps it from
# sleeping.
touch -t 209901010000 "${WORK_DIR}/wflt/never-marker"
if wflt_err="$(wait_for_later_time "${WORK_DIR}/wflt/never-marker" "${WORK_DIR}/wflt/never" 3 2>&1)"; then
  fail "wait_for_later_time succeeded for a marker far in the future"
fi
case "${wflt_err}" in
  *"after 3 tries"*) ;;
  *) fail "wait_for_later_time for a marker far in the future: wrong diagnostic: ${wflt_err}" ;;
esac
check_wflt_probe_removed "${WORK_DIR}/wflt/never" "a marker far in the future"

# A file that changes immediately after the function returns is newer than
# the marker.
for wflt_try in 1 2 3; do
  : > "${WORK_DIR}/wflt/now-marker"
  if ! wait_for_later_time "${WORK_DIR}/wflt/now-marker" "${WORK_DIR}/wflt/now"; then
    fail "wait_for_later_time failed on try ${wflt_try}"
  fi
  echo "try ${wflt_try}" > "${WORK_DIR}/wflt/now/changed"
  if [ -z "$(find "${WORK_DIR}/wflt/now/changed" -cnewer "${WORK_DIR}/wflt/now-marker" -print)" ]; then
    fail "wait_for_later_time: a file changed afterward is not newer than the marker, on try ${wflt_try}"
  fi
  check_wflt_probe_removed "${WORK_DIR}/wflt/now" "try ${wflt_try}"
done

# A marker whose modification time is 2 seconds in the future makes the
# function sleep before it succeeds.
: > "${WORK_DIR}/wflt/later-marker"
python3 -c 'import os, sys, time; t = time.time() + 2; os.utime(sys.argv[1], (t, t))' \
  "${WORK_DIR}/wflt/later-marker"
wflt_start="$(date +%s)"
if ! wait_for_later_time "${WORK_DIR}/wflt/later-marker" "${WORK_DIR}/wflt/later"; then
  fail "wait_for_later_time failed for a marker 2 seconds in the future"
fi
if [ "$(($(date +%s) - wflt_start))" -lt 1 ]; then
  fail "wait_for_later_time did not wait for a marker 2 seconds in the future"
fi
echo "changed" > "${WORK_DIR}/wflt/later/changed"
if [ -z "$(find "${WORK_DIR}/wflt/later/changed" -cnewer "${WORK_DIR}/wflt/later-marker" -print)" ]; then
  fail "wait_for_later_time: a file changed afterward is not newer than a marker 2 seconds in the future"
fi
check_wflt_probe_removed "${WORK_DIR}/wflt/later" "a marker 2 seconds in the future"

# An existing file whose name is the probe's is left alone.
echo "user data" > "${WORK_DIR}/wflt/exists/.manage-git-branches-time-probe"
: > "${WORK_DIR}/wflt/exists-marker"
if wflt_err="$(wait_for_later_time "${WORK_DIR}/wflt/exists-marker" "${WORK_DIR}/wflt/exists" 2>&1)"; then
  fail "wait_for_later_time succeeded although a file has its probe's name"
fi
case "${wflt_err}" in
  *"which must not already exist"*) ;;
  *) fail "wait_for_later_time with a file that has its probe's name: wrong diagnostic: ${wflt_err}" ;;
esac
if [ "$(cat "${WORK_DIR}/wflt/exists/.manage-git-branches-time-probe")" != "user data" ]; then
  fail "wait_for_later_time changed an existing file whose name is the probe's"
fi

# An existing symbolic link whose name is the probe's is left alone, even
# one to a file that is not a regular file.
ln -s /dev/null "${WORK_DIR}/wflt/symlink/.manage-git-branches-time-probe"
: > "${WORK_DIR}/wflt/symlink-marker"
if wflt_err="$(wait_for_later_time "${WORK_DIR}/wflt/symlink-marker" "${WORK_DIR}/wflt/symlink" 2>&1)"; then
  fail "wait_for_later_time succeeded although a symbolic link has its probe's name"
fi
case "${wflt_err}" in
  *"which must not already exist"*) ;;
  *) fail "wait_for_later_time with a symbolic link that has its probe's name: wrong diagnostic: ${wflt_err}" ;;
esac
if [ ! -L "${WORK_DIR}/wflt/symlink/.manage-git-branches-time-probe" ]; then
  fail "wait_for_later_time removed an existing symbolic link whose name is the probe's"
fi

## Usage: hum_commit DIRECTORY FILE MESSAGE
## Writes MESSAGE to FILE in DIRECTORY and commits it with that message.
hum_commit() {
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -- "$2"
  git -C "$1" commit -q -m "$3"
}

## Usage: hum_check DESCRIPTION DIRECTORY LINE...
## Fails unless has_unbuilt_merge, run in DIRECTORY, returns 0 and its
## account's lines that say what each side of a merge changed are exactly the
## LINEs, in any order.  (Commits in the test repositories can share a
## timestamp, so `git log` might order merges in either way.)
hum_check() {
  hum_description="$1"
  hum_dir="$2"
  shift 2
  if ! (cd "${hum_dir}" && has_unbuilt_merge '' && printf '%s\n' "${merge_fix_account}" > "${hum_dir}.account"); then
    fail "has_unbuilt_merge: ${hum_description}: no merge is blamed"
  fi
  { grep -e '^  It merged ' "${hum_dir}.account" || true; } | sort > "${hum_dir}.sides"
  printf '%s\n' "$@" | sort > "${hum_dir}.sides.goal"
  if ! cmp -s "${hum_dir}.sides.goal" "${hum_dir}.sides"; then
    fail "has_unbuilt_merge: ${hum_description}: the account of what each side changed is wrong: $(diff "${hum_dir}.sides.goal" "${hum_dir}.sides")"
  fi
}

## Tests of has_unbuilt_merge.  The account lists the commits that only each
## side of a merge had.  The parents of the last merge have two merge bases,
## because of the criss-cross merges before it.
git init -q -b main "${WORK_DIR}/hum-cross"
hum_commit "${WORK_DIR}/hum-cross" base.txt "Initial commit"
git -C "${WORK_DIR}/hum-cross" switch -q -c other
hum_commit "${WORK_DIR}/hum-cross" b1.txt "Change other"
hum_b1="$(git -C "${WORK_DIR}/hum-cross" rev-parse HEAD)"
git -C "${WORK_DIR}/hum-cross" switch -q main
hum_commit "${WORK_DIR}/hum-cross" a1.txt "Change main"
hum_a1="$(git -C "${WORK_DIR}/hum-cross" rev-parse HEAD)"
git -C "${WORK_DIR}/hum-cross" merge -q --no-edit other
hum_commit "${WORK_DIR}/hum-cross" a2.txt "Change main again"
hum_ours="$(git -C "${WORK_DIR}/hum-cross" rev-parse HEAD)"
git -C "${WORK_DIR}/hum-cross" switch -q other
git -C "${WORK_DIR}/hum-cross" merge -q --no-edit "${hum_a1}"
hum_commit "${WORK_DIR}/hum-cross" b2.txt "Change other again"
hum_theirs="$(git -C "${WORK_DIR}/hum-cross" rev-parse HEAD)"
git -C "${WORK_DIR}/hum-cross" switch -q main
git -C "${WORK_DIR}/hum-cross" merge -q --no-edit other
hum_check "criss-cross merges" "${WORK_DIR}/hum-cross" \
  "  It merged commit ${hum_b1} into commit ${hum_a1}.  \`git log -p --remerge-diff ${hum_b1}..${hum_a1}\` shows the commits that only ${hum_a1} had, and \`git log -p --remerge-diff ${hum_a1}..${hum_b1}\` shows the commits that only ${hum_b1} had." \
  "  It merged commit ${hum_a1} into commit ${hum_b1}.  \`git log -p --remerge-diff ${hum_a1}..${hum_b1}\` shows the commits that only ${hum_b1} had, and \`git log -p --remerge-diff ${hum_b1}..${hum_a1}\` shows the commits that only ${hum_a1} had." \
  "  It merged commit ${hum_theirs} into commit ${hum_ours}.  \`git log -p --remerge-diff ${hum_theirs}..${hum_ours}\` shows the commits that only ${hum_ours} had, and \`git log -p --remerge-diff ${hum_ours}..${hum_theirs}\` shows the commits that only ${hum_theirs} had."

## An octopus merge, and a merge of commits that share no history, get only
## their lines.  A merge into an ancestor, which `git merge --no-ff` makes,
## gets an account of only the other side.
git init -q -b main "${WORK_DIR}/hum-misc"
hum_commit "${WORK_DIR}/hum-misc" base.txt "Initial commit"
for hum_branch in x y; do
  git -C "${WORK_DIR}/hum-misc" switch -q -c "${hum_branch}" main
  hum_commit "${WORK_DIR}/hum-misc" "${hum_branch}.txt" "Change ${hum_branch}"
done
git -C "${WORK_DIR}/hum-misc" switch -q main
hum_commit "${WORK_DIR}/hum-misc" main.txt "Change main"
git -C "${WORK_DIR}/hum-misc" merge -q --no-edit x y > /dev/null
git -C "${WORK_DIR}/hum-misc" switch -q --orphan unrelated
hum_commit "${WORK_DIR}/hum-misc" unrelated.txt "Unrelated commit"
git -C "${WORK_DIR}/hum-misc" switch -q main
git -C "${WORK_DIR}/hum-misc" merge -q --no-edit --allow-unrelated-histories unrelated
hum_ours="$(git -C "${WORK_DIR}/hum-misc" rev-parse HEAD)"
git -C "${WORK_DIR}/hum-misc" switch -q -c ahead
hum_commit "${WORK_DIR}/hum-misc" ahead.txt "Change ahead"
hum_theirs="$(git -C "${WORK_DIR}/hum-misc" rev-parse HEAD)"
git -C "${WORK_DIR}/hum-misc" switch -q main
git -C "${WORK_DIR}/hum-misc" merge -q --no-ff --no-commit ahead > /dev/null
hum_commit "${WORK_DIR}/hum-misc" edited.txt "Merge branch 'ahead', with an edit"
if [ "$(git -C "${WORK_DIR}/hum-misc" rev-list --count --merges HEAD)" -ne 3 ]; then
  fail "has_unbuilt_merge: the test repository has the wrong merges: $(git -C "${WORK_DIR}/hum-misc" log --graph --oneline)"
fi
hum_check "an octopus merge, unrelated histories, and a merge into an ancestor" "${WORK_DIR}/hum-misc" \
  "  It merged commit ${hum_theirs} into its ancestor, commit ${hum_ours}.  \`git log -p --remerge-diff ${hum_ours}..${hum_theirs}\` shows the commits that only ${hum_theirs} had."

## Tests of has_unbuilt_merge.  A commit in BUILT that is in the history of a
## remote branch is omitted from the account, but its tree still counts:
## when the current branch's tree is that of such a commit, upstream/main,
## no merge broke the build, although an unpushed merge combined changes.
git init -q -b main "${WORK_DIR}/hum"
hum_commit "${WORK_DIR}/hum" base.txt "Initial commit"
hum_commit "${WORK_DIR}/hum" upstream.txt "Change upstream"
git -C "${WORK_DIR}/hum" update-ref refs/remotes/upstream/main HEAD
git -C "${WORK_DIR}/hum" switch -q -c feature
hum_commit "${WORK_DIR}/hum" feature.txt "Change feature"
git init -q --bare -b main "${WORK_DIR}/hum.git"
git -C "${WORK_DIR}/hum" remote add origin "${WORK_DIR}/hum.git"
git -C "${WORK_DIR}/hum" update-ref refs/remotes/origin/feature HEAD
git -C "${WORK_DIR}/hum" config branch.feature.remote origin
git -C "${WORK_DIR}/hum" config branch.feature.merge refs/heads/feature
git -C "${WORK_DIR}/hum" switch -q -c side
hum_commit "${WORK_DIR}/hum" side.txt "Change side"
git -C "${WORK_DIR}/hum" switch -q feature
hum_commit "${WORK_DIR}/hum" other.txt "Change feature again"
git -C "${WORK_DIR}/hum" merge -q --no-edit side
git -C "${WORK_DIR}/hum" rm -q feature.txt side.txt other.txt
git -C "${WORK_DIR}/hum" commit -q -m "Match upstream"
if (cd "${WORK_DIR}/hum" && has_unbuilt_merge refs/remotes/upstream/main); then
  fail "has_unbuilt_merge: a tree that upstream/main has is blamed on a merge"
fi
## Without that tree, the merge might have broken the build.
hum_commit "${WORK_DIR}/hum" new.txt "Differ from upstream"
if ! (cd "${WORK_DIR}/hum" && has_unbuilt_merge refs/remotes/upstream/main); then
  fail "has_unbuilt_merge: the unpushed merge is not blamed"
fi
## The account omits a commit in BUILT that is in the history of a remote
## branch, such as upstream/main, or of another commit in BUILT, whether
## earlier or later, and keeps only the first of two names of one commit.
git -C "${WORK_DIR}/hum" switch -q -c side2 side
hum_commit "${WORK_DIR}/hum" side2.txt "Change side2"
git -C "${WORK_DIR}/hum" switch -q feature
## Usage: check_account BUILT EXCLUDED
## Checks that `has_unbuilt_merge BUILT` returns 0 and that its account tells
## the agent to exclude EXCLUDED.
check_account() {
  # shellcheck disable=SC2154 # has_unbuilt_merge sets merge_fix_account
  if ! (cd "${WORK_DIR}/hum" && has_unbuilt_merge "$1" \
    && printf '%s\n' "${merge_fix_account}" > "${WORK_DIR}/hum-account"); then
    fail "has_unbuilt_merge $1: the unpushed merge is not blamed"
  elif ! grep -q -F "git log --graph --stat HEAD --not $2\`" "${WORK_DIR}/hum-account"; then
    fail "has_unbuilt_merge $1: the account does not exclude exactly $2: $(cat "${WORK_DIR}/hum-account")"
  fi
}
check_account "refs/remotes/upstream/main side side2" "refs/remotes/origin/feature side2"
check_account "side2 side" "refs/remotes/origin/feature side2"
check_account "side2 refs/heads/side2 side" "refs/remotes/origin/feature side2"

## Tests of is_built_remote.  A relative pathname is resolved in the top
## level of the working tree, even from a subdirectory.
git init -q --bare -b main "${WORK_DIR}/ibr/bare.git"
git init -q -b main "${WORK_DIR}/ibr/working"
git init -q -b main "${WORK_DIR}/ibr/clone"
mkdir "${WORK_DIR}/ibr/clone/sub"
git -C "${WORK_DIR}/ibr/clone" commit -q --allow-empty -m "Initial commit"
git -C "${WORK_DIR}/ibr/clone" remote add bare ../bare.git
git -C "${WORK_DIR}/ibr/clone" remote add working ../working
git -C "${WORK_DIR}/ibr/clone" remote add missing ../missing.git
git -C "${WORK_DIR}/ibr/clone" remote add github https://github.com/org/repo.git
## Usage: check_built_remote DIRECTORY REMOTE EXPECTED
## Checks that `is_built_remote DIRECTORY REMOTE` returns EXPECTED.
check_built_remote() {
  if is_built_remote "$1" "$2"; then
    check_built_remote_status=0
  else
    check_built_remote_status=1
  fi
  if [ "${check_built_remote_status}" -ne "$3" ]; then
    fail "is_built_remote $1 $2 returned ${check_built_remote_status}, not $3"
  fi
}
for ibr_dir in "${WORK_DIR}/ibr/clone" "${WORK_DIR}/ibr/clone/sub"; do
  # is_built_remote remembers its results for the top level, which both
  # directories have.
  built_remote_cache=''
  check_built_remote "${ibr_dir}" bare 0
  check_built_remote "${ibr_dir}" ../bare.git 0
  check_built_remote "${ibr_dir}" github 0
  check_built_remote "${ibr_dir}" working 1
  check_built_remote "${ibr_dir}" missing 1
  check_built_remote "${ibr_dir}" . 1
done
## A bare repository with a linked worktree is committed to locally.
git -C "${WORK_DIR}/ibr/clone" push -q bare main
git -C "${WORK_DIR}/ibr/bare.git" worktree add -q ../bare-worktree main 2> /dev/null
built_remote_cache=''
check_built_remote "${WORK_DIR}/ibr/clone" bare 1

## Tests of remote_branch_refs.  It omits the remote-tracking branch of a
## remote whose branches need not have been built.
git -C "${WORK_DIR}/ibr/working" commit -q --allow-empty -m "Initial commit"
git -C "${WORK_DIR}/ibr/clone" fetch -q working
git -C "${WORK_DIR}/ibr/clone" fetch -q bare
git -C "${WORK_DIR}/ibr/clone" branch -q --set-upstream-to=working/main
if [ -n "$(remote_branch_refs "${WORK_DIR}/ibr/clone")" ]; then
  fail "remote_branch_refs: a working clone's branch counts as built: $(remote_branch_refs "${WORK_DIR}/ibr/clone")"
fi
git -C "${WORK_DIR}/ibr/bare.git" worktree remove ../bare-worktree
built_remote_cache=''
git -C "${WORK_DIR}/ibr/clone" branch -q --set-upstream-to=bare/main
if [ "$(remote_branch_refs "${WORK_DIR}/ibr/clone")" != refs/remotes/bare/main ]; then
  fail "remote_branch_refs: a bare repository's branch does not count as built: $(remote_branch_refs "${WORK_DIR}/ibr/clone")"
fi

## Tests of upstream_fetch_head.  It prints the head that the latest fetch of
## the upstream branch recorded, even when `branch.main.remote` is a URL, which
## gives no remote-tracking branch, and nothing after a fetch of another
## repository or when the upstream repository's branches need not be built.
built_remote_cache=''
git clone -q "${WORK_DIR}/ibr/bare.git" "${WORK_DIR}/ufh"
git -C "${WORK_DIR}/ufh" config branch.main.remote "${WORK_DIR}/ibr/bare.git/"
git -C "${WORK_DIR}/ufh" fetch -q
ufh_expected="$(git -C "${WORK_DIR}/ibr/bare.git" rev-parse main)"
if ! ufh_actual="$(upstream_fetch_head "${WORK_DIR}/ufh")" || [ "${ufh_actual}" != "${ufh_expected}" ]; then
  fail "upstream_fetch_head printed [${ufh_actual}], not ${ufh_expected}"
fi
git -C "${WORK_DIR}/ufh" fetch -q "${WORK_DIR}/ibr/working" main
if ufh_actual="$(upstream_fetch_head "${WORK_DIR}/ufh")" || [ -n "${ufh_actual}" ]; then
  fail "upstream_fetch_head after a fetch of another repository printed [${ufh_actual}]"
fi
git -C "${WORK_DIR}/ufh" config branch.main.remote "${WORK_DIR}/ibr/working"
git -C "${WORK_DIR}/ufh" fetch -q
if ufh_actual="$(upstream_fetch_head "${WORK_DIR}/ufh")" || [ -n "${ufh_actual}" ]; then
  fail "upstream_fetch_head for a working clone printed [${ufh_actual}]"
fi

## Tests of refuse_merge_in_progress.  It refuses unmerged files that a
## cherry-pick left, without a merge in progress.
git init -q -b main "${WORK_DIR}/rmip"
echo one > "${WORK_DIR}/rmip/file.txt"
git -C "${WORK_DIR}/rmip" add file.txt
git -C "${WORK_DIR}/rmip" commit -q -m one
if ! refuse_merge_in_progress "${WORK_DIR}/rmip" "unused" 2> /dev/null; then
  fail "refuse_merge_in_progress refused a clean directory"
fi
git -C "${WORK_DIR}/rmip" checkout -q -b side
echo two > "${WORK_DIR}/rmip/file.txt"
git -C "${WORK_DIR}/rmip" commit -q -a -m two
git -C "${WORK_DIR}/rmip" checkout -q main
echo three > "${WORK_DIR}/rmip/file.txt"
git -C "${WORK_DIR}/rmip" commit -q -a -m three
git -C "${WORK_DIR}/rmip" cherry-pick side > /dev/null 2>&1 || true
if rmip_out="$(refuse_merge_in_progress "${WORK_DIR}/rmip" "unused" 2>&1)"; then
  fail "refuse_merge_in_progress accepted unmerged files"
fi
case "${rmip_out}" in
  *"${WORK_DIR}/rmip has unmerged files"*) ;;
  *) fail "refuse_merge_in_progress: wrong diagnostic for unmerged files: ${rmip_out}" ;;
esac

## Tests of is_pulled_first_dir and add_pulled_first_dir.  A directory
## matches only as a whole.
pulled_first_dirs=''
add_pulled_first_dir dir-a
add_pulled_first_dir dir-a
if [ "${pulled_first_dirs}" != "dir-a
" ]; then
  fail "add_pulled_first_dir added a directory twice: [${pulled_first_dirs}]"
fi
if ! is_pulled_first_dir dir-a || is_pulled_first_dir dir || is_pulled_first_dir dir-a-b; then
  fail "is_pulled_first_dir answered wrongly for [${pulled_first_dirs}]"
fi

## Tests of current_branch.  A tag with the branch's name does not change the
## name that it prints.
git init -q -b main "${WORK_DIR}/cb"
git -C "${WORK_DIR}/cb" commit -q --allow-empty -m "Initial commit"
git -C "${WORK_DIR}/cb" tag main
if [ "$(current_branch "${WORK_DIR}/cb")" != main ]; then
  fail "current_branch: printed $(current_branch "${WORK_DIR}/cb"), not main"
fi
if [ "$(cd "${WORK_DIR}/cb" && current_branch)" != main ]; then
  fail "current_branch with no directory: printed $(cd "${WORK_DIR}/cb" && current_branch), not main"
fi
git -C "${WORK_DIR}/cb" checkout -q --detach
if cb_output="$(current_branch "${WORK_DIR}/cb")" || [ -n "${cb_output}" ]; then
  fail "current_branch: a detached HEAD was named ${cb_output}"
fi

## Tests of fork_url, and so of split_repository_url, which it calls.
## Usage: check_fork_url URL ORG EXPECTED
## Checks that `fork_url URL ORG` prints EXPECTED, or fails if EXPECTED is
## empty.
check_fork_url() {
  if check_fork_url_actual="$(fork_url "$1" "$2")"; then
    check_fork_url_status=0
  else
    check_fork_url_status=1
  fi
  if [ -z "$3" ]; then
    if [ "${check_fork_url_status}" -eq 0 ] || [ -n "${check_fork_url_actual}" ]; then
      fail "fork_url [$1] [$2] printed [${check_fork_url_actual}] and returned ${check_fork_url_status}, rather than failing"
    fi
  elif [ "${check_fork_url_status}" -ne 0 ] || [ "${check_fork_url_actual}" != "$3" ]; then
    fail "fork_url [$1] [$2] printed [${check_fork_url_actual}] and returned ${check_fork_url_status}, not [$3]"
  fi
}
check_fork_url 'git@github.com:typetools/cf.git' cushon 'git@github.com:cushon/cf.git'
check_fork_url 'https://github.com/typetools/cf.git/' cushon 'https://github.com/cushon/cf.git'
check_fork_url 'ssh://git@github.com/typetools/cf' cushon 'ssh://git@github.com/cushon/cf'
check_fork_url 'file:///srv/git/typetools/cf.git' cushon 'file:///srv/git/cushon/cf.git'
check_fork_url '/srv/git/typetools/cf.git' cushon '/srv/git/cushon/cf.git'
# A URL whose path has only one component has no owner.  What precedes that
# component is the host, possibly with a port.
check_fork_url 'cf.git' cushon ''
check_fork_url 'host:cf.git' cushon ''
check_fork_url 'https://github.com/cf.git' cushon ''
check_fork_url 'ssh://git@host:22/cf.git' cushon ''
check_fork_url 'ssh://host/cf.git' cushon ''

## Tests of missing_git_dir and report_broken_working_tree.  Each directory
## under ${mgd_root} holds a `.git` file, or a `.git` directory, that a test
## case writes.
mgd_root="${WORK_DIR}/mgd"
mkdir -p "${mgd_root}/exists/.git/worktrees/wt" "${mgd_root}/wt/subdir"
# A git directory holds a file HEAD.
echo 'ref: refs/heads/main' > "${mgd_root}/exists/.git/HEAD"
mgd_physical="$(physical_path "${mgd_root}")"

## Usage: check_missing_git_dir GIT_FILE_CONTENTS EXPECTED DESCRIPTION
## Writes GIT_FILE_CONTENTS, a printf format, to ${mgd_root}/wt/.git, and
## checks that `missing_git_dir ${mgd_root}/wt` prints EXPECTED, which is
## empty if the function is to return 1.
check_missing_git_dir() {
  # shellcheck disable=SC2059 # The format is the test case's argument.
  printf "$1" > "${mgd_root}/wt/.git"
  if cmgd_actual="$(missing_git_dir "${mgd_root}/wt")"; then
    [ -n "${cmgd_actual}" ] || fail "missing_git_dir printed nothing but returned 0: $3"
  else
    [ -z "${cmgd_actual}" ] || fail "missing_git_dir printed [${cmgd_actual}] but returned 1: $3"
  fi
  [ "${cmgd_actual}" = "$2" ] || fail "missing_git_dir printed [${cmgd_actual}], not [$2]: $3"
}

check_missing_git_dir "gitdir: ${mgd_root}/gone\\n" "${mgd_root}/gone" 'an absolute pathname'
check_missing_git_dir 'gitdir: ../gone\n' "${mgd_physical}/gone" 'a relative pathname'
check_missing_git_dir 'gitdir: ../gone/../x/.git\n' "${mgd_physical}/gone/../x/.git" \
  'a relative pathname with ".." after a missing directory'
check_missing_git_dir "gitdir: ${mgd_root}/gone\\r\\n" "${mgd_root}/gone" 'CRLF line ending'
check_missing_git_dir "gitdir: ${mgd_root}/exists/.git/HEAD\\n" "${mgd_root}/exists/.git/HEAD" \
  'a regular file'
check_missing_git_dir "gitdir: ${mgd_root}/exists/.git/worktrees/wt\\r\\n" '' \
  'an existing git directory, CRLF line ending'
check_missing_git_dir "gitdir: ${mgd_root}/gone" "${mgd_root}/gone" 'no final newline'
check_missing_git_dir "gitdir: ${mgd_root}/exists/.git/worktrees/wt\\n" '' 'an existing git directory'
check_missing_git_dir 'gitdir: ../exists/.git/worktrees/wt\n' '' 'an existing git directory, relative'
check_missing_git_dir 'not a gitdir line\n' '' 'no gitdir line'
check_missing_git_dir '' '' 'an empty file'
# A file that cannot be opened has no answer, and no stale answer from the
# previous call.  Only an unprivileged user is stopped by the permissions.
if [ "$(id -u)" != 0 ]; then
  chmod 000 "${mgd_root}/wt/.git"
  if cmgd_actual="$(missing_git_dir "${mgd_root}/wt" 2>&1)"; then
    fail "missing_git_dir returned 0 for an unreadable .git file"
  fi
  [ -z "${cmgd_actual}" ] || fail "missing_git_dir printed [${cmgd_actual}] for an unreadable .git file"
  chmod 600 "${mgd_root}/wt/.git"
fi
# A `.git` directory is not a `.git` file.
if missing_git_dir "${mgd_root}/exists" > /dev/null; then
  fail "missing_git_dir returned 0 for a .git directory"
fi
# `gitfile_git_dir` resolves ".." in a relative pathname that exists.
printf 'gitdir: ../exists/.git/worktrees/wt\n' > "${mgd_root}/wt/.git"
ggd_actual="$(gitfile_git_dir "${mgd_root}/wt")" \
  || fail "gitfile_git_dir returned 1 for a relative pathname"
[ "${ggd_actual}" = "${mgd_physical}/exists/.git/worktrees/wt" ] \
  || fail "gitfile_git_dir printed [${ggd_actual}] for a relative pathname"

printf 'gitdir: %s\n' "${mgd_root}/gone/.git/worktrees/wt" > "${mgd_root}/wt/.git"
if ! rbwt_out="$(report_broken_working_tree "${mgd_root}/wt" 'ERROR: ' 2>&1)"; then
  fail "report_broken_working_tree returned 1 for a broken worktree"
fi
case "${rbwt_out}" in
  *"${SCRIPT_NAME}: ERROR: broken git working tree: ${mgd_root}/wt"*"does not exist: ${mgd_root}/gone/.git/worktrees/wt"*"its repository does not exist; it was moved or deleted: ${mgd_root}/gone/.git"*"git worktree repair ${mgd_physical}/wt"*) ;;
  *) fail "unexpected report for a broken worktree: ${rbwt_out}" ;;
esac
if ! rbwt_out="$(report_broken_working_tree "${mgd_root}/wt/subdir" 2>&1)"; then
  fail "report_broken_working_tree returned 1 for a subdirectory of a broken worktree"
fi
case "${rbwt_out}" in
  *"in a broken git working tree: ${mgd_root}/wt/subdir"*"the broken working tree is: ${mgd_root}/wt"*) ;;
  *) fail "unexpected report for a subdirectory of a broken worktree: ${rbwt_out}" ;;
esac
printf 'gitdir: %s\n' "${mgd_root}/exists/.git/worktrees/gone" > "${mgd_root}/wt/.git"
rbwt_out="$(report_broken_working_tree "${mgd_root}/wt" 2>&1)" || true
case "${rbwt_out}" in
  *"its repository exists but no longer registers this worktree: ${mgd_root}/exists/.git"*) ;;
  *) fail "unexpected report for an unregistered worktree: ${rbwt_out}" ;;
esac
# Trailing slashes in the `.git` file do not hide the repository.
printf 'gitdir: %s//\n' "${mgd_root}/gone/.git/worktrees/wt" > "${mgd_root}/wt/.git"
rbwt_out="$(report_broken_working_tree "${mgd_root}/wt" 2>&1)" \
  || fail "report_broken_working_tree returned 1 for a gitdir with trailing slashes"
case "${rbwt_out}" in
  *"does not exist: ${mgd_root}/gone/.git/worktrees/wt
"*"its repository does not exist; it was moved or deleted: ${mgd_root}/gone/.git"*) ;;
  *) fail "unexpected report for a gitdir with trailing slashes: ${rbwt_out}" ;;
esac
# A git directory that is a regular file is reported as not a directory, and
# not as missing.
printf 'gitdir: %s\n' "${mgd_root}/exists/.git/HEAD" > "${mgd_root}/wt/.git"
rbwt_out="$(report_broken_working_tree "${mgd_root}/wt" 2>&1)" \
  || fail "report_broken_working_tree returned 1 for a gitdir that is a regular file"
case "${rbwt_out}" in
  *"something that is not a directory: ${mgd_root}/exists/.git/HEAD"*) ;;
  *) fail "unexpected report for a gitdir that is a regular file: ${rbwt_out}" ;;
esac
case "${rbwt_out}" in
  *"does not exist"* | *"its repository"*)
    fail "misleading report for a gitdir that is a regular file: ${rbwt_out}"
    ;;
esac
# The suggested `git worktree repair` command quotes a pathname that the
# shell would split or interpret.
mkdir -p "${mgd_root}/it's wt"
printf 'gitdir: %s\n' "${mgd_root}/gone/.git/worktrees/wt" > "${mgd_root}/it's wt/.git"
rbwt_out="$(report_broken_working_tree "${mgd_root}/it's wt" 2>&1)" || true
case "${rbwt_out}" in
  *"git worktree repair '${mgd_physical}/it'\''s wt'\`"*) ;;
  *) fail "unexpected repair command for a pathname with a space and a quote: ${rbwt_out}" ;;
esac
# `report_unusable_working_tree` prints MESSAGE and returns 1 for a directory
# that is not in a broken working tree.
if rnwtt_out="$(report_unusable_working_tree "${mgd_root}/exists/.git" 'ERROR: ' 'some message' 2>&1)"; then
  fail "report_unusable_working_tree returned 0 for a directory that is not broken"
fi
[ "${rnwtt_out}" = "${SCRIPT_NAME}: ERROR: some message" ] \
  || fail "unexpected report_unusable_working_tree diagnostic: ${rnwtt_out}"
# A missing git directory that is not REPOSITORY/worktrees/NAME, even one
# with a component "worktrees" or whose parent "worktrees" is not in a git
# directory, gets no report about a repository.
for rbwt_gitdir in "${mgd_root}/gone/worktrees/a/b" "${mgd_root}/wt/worktrees/proj.git" \
  "${mgd_root}/exists/worktrees/proj.git"; do
  mkdir -p "${mgd_root}/wt/worktrees"
  printf 'gitdir: %s\n' "${rbwt_gitdir}" > "${mgd_root}/wt/.git"
  rbwt_out="$(report_broken_working_tree "${mgd_root}/wt" 2>&1)" \
    || fail "report_broken_working_tree returned 1 for ${rbwt_gitdir}"
  case "${rbwt_out}" in
    *"does not exist: ${rbwt_gitdir}"*) ;;
    *) fail "unexpected report for ${rbwt_gitdir}: ${rbwt_out}" ;;
  esac
  case "${rbwt_out}" in
    *"its repository"*) fail "report about a repository for ${rbwt_gitdir}: ${rbwt_out}" ;;
  esac
done
# `report_not_working_tree_top` falls back to a plain diagnostic.
rnwtt_out="$(report_not_working_tree_top "${mgd_root}/exists/.git" 'ERROR: ' 2>&1)"
[ "${rnwtt_out}" = "${SCRIPT_NAME}: ERROR: not the top level of a git working tree: ${mgd_root}/exists/.git" ] \
  || fail "unexpected report_not_working_tree_top diagnostic: ${rnwtt_out}"
printf 'gitdir: %s\n' "${mgd_root}/gone" > "${mgd_root}/wt/.git"
rnwtt_out="$(report_not_working_tree_top "${mgd_root}/wt" 2>&1)"
case "${rnwtt_out}" in
  *"broken git working tree: ${mgd_root}/wt"*) ;;
  *) fail "report_not_working_tree_top did not report a broken worktree: ${rnwtt_out}" ;;
esac
# A working tree that is not broken, and a directory in no working tree, get
# no report.
if rbwt_out="$(report_broken_working_tree "${mgd_root}/exists" 2>&1)" || [ -n "${rbwt_out}" ]; then
  fail "report_broken_working_tree reported a working tree that is not broken: ${rbwt_out}"
fi
if rbwt_out="$(report_broken_working_tree / 2>&1)" || [ -n "${rbwt_out}" ]; then
  fail "report_broken_working_tree reported the root directory: ${rbwt_out}"
fi

# `prune_agent_todo` removes the entries of AGENT-TODO.md that no longer apply.
# The name of the working tree contains a space, so that `run_agent` writes
# its pathname quoted in a command.
pat_dir="${WORK_DIR}/prune tree"
git init -q -b main "${pat_dir}"
git -C "${pat_dir}" commit -q --allow-empty -m "First commit"
pat_first="$(git -C "${pat_dir}" rev-parse HEAD)"
git -C "${pat_dir}" commit -q --allow-empty -m "Second commit"
pat_second="$(git -C "${pat_dir}" rev-parse HEAD)"
pat_todo="${pat_dir}/AGENT-TODO.md"
pat_cd="cd '${pat_dir}' && claude --resume"
# The backquotes are Markdown, not command substitutions.
# shellcheck disable=SC2016
pat_preamble='# AI agent sessions to continue

A script of manage-git-branches, such as `git-push-to`, appends an entry
here when an AI agent fails, when the script rejects its work, or when
the script leaves a merge in progress.  An entry'"'"'s command continues the
agent'"'"'s session interactively.  Delete the entry once you have dealt with
it.'
# An entry about a merge of ${pat_first} in the working tree.
pat_merge_first="## Finish the merge in progress (git-push-to, 2026-11-09 08:23:59)

The merge of commit ${pat_first} is in progress in ${pat_dir}.
Finish it (resolve its conflicts and commit it), or abort it with \`git merge --abort\`; then delete this entry."
# An entry about an agent's failure to resolve a merge of ${pat_second}.
pat_merge_second="## Resolve the conflicts in the merge of branch 'main' (git-push-to, 2026-11-09 08:24:00)

The merge of commit ${pat_second} is in progress in ${pat_dir}.
Finish it (resolve its conflicts and commit it), or abort it with \`git merge --abort\`; then delete this entry.

\`\`\`sh
${pat_cd} 5e495947-c99d-4688-804f-00834cce9aaa
\`\`\`"
pat_build="## Fix the build after merging branch 'main' (git-pull-upstream, 2026-11-10 07:47:29)

\`\`\`sh
${pat_cd} a10375ce-87e0-4104-a154-335948d32056
\`\`\`"
# An entry about a build that the agent attempted to fix in several
# sessions.
pat_build_sessions="## Fix the build after merges (git-push-to, 2026-11-10 07:49:02)

Session 1 of 2:

\`\`\`sh
${pat_cd} 3b8c0a2e-5f1d-4c7a-9e64-2d0f8b1a7c35
\`\`\`

Session 2 of 2:

\`\`\`sh
${pat_cd} 9e1f4d6b-08a3-4b52-b7c9-61e2a5f3d084
\`\`\`"
# Entries to keep:  one about another working tree, as in a copy of the file;
# one that a person wrote; and one of another kind.
pat_other_tree="## Fix the build after merges (git-push-to, 2026-11-10 07:51:59)

\`\`\`sh
cd /elsewhere && claude --resume 0d91d672-a3b0-46a7-851a-62477e166fdc
\`\`\`"
pat_person='## Check the merge of pull request #12

The merge of commit 0123 is in progress in elsewhere.'
pat_ci="## Make the CI of https://github.com/org/proj/pull/7 pass (fix-renovate-prs, 2026-11-10 07:00:00)

\`\`\`sh
${pat_cd} 77c927f1-09fa-48e5-9ceb-faca2c95627e
\`\`\`"

## Usage: write_todo PART...
## Writes ${pat_todo}, which consists of the PARTs, each followed by a blank
## line, except for the last.
write_todo() {
  {
    printf '%s\n' "$1"
    shift
    for wt_part in "$@"; do
      printf '\n%s\n' "${wt_part}"
    done
  } > "${pat_todo}"
}

## Usage: check_todo DESCRIPTION PART...
## Checks that ${pat_todo} consists of the PARTs, as `write_todo` writes
## them.
check_todo() {
  ct_description="$1"
  shift
  ct_expected="${WORK_DIR}/expected-todo"
  pat_todo_saved="${pat_todo}"
  pat_todo="${ct_expected}"
  write_todo "$@"
  pat_todo="${pat_todo_saved}"
  if ! cmp -s "${ct_expected}" "${pat_todo}"; then
    fail "prune_agent_todo, ${ct_description}: wrong AGENT-TODO.md:
$(diff "${ct_expected}" "${pat_todo}" || true)"
  fi
}

## Usage: prune_todo BUILT
## Runs `prune_agent_todo BUILT` in ${pat_dir}, and sets ${pat_output} to
## what it printed.
prune_todo() {
  pat_output="$(cd "${pat_dir}" && prune_agent_todo "$1" 2>&1)" \
    || fail "prune_agent_todo returned a nonzero status: ${pat_output}"
}

# While the merge of ${pat_second} is in progress, the entry about the merge
# of ${pat_first} no longer applies, and the entry about the build applies
# until the build succeeds.
pat_merge_head="$(git -C "${pat_dir}" rev-parse --git-path MERGE_HEAD)"
case "${pat_merge_head}" in
  /*) ;;
  *) pat_merge_head="${pat_dir}/${pat_merge_head}" ;;
esac
printf '%s\n' "${pat_second}" > "${pat_merge_head}"
write_todo "${pat_preamble}" "${pat_merge_first}" "${pat_merge_second}" "${pat_build}" \
  "${pat_build_sessions}" "${pat_other_tree}" "${pat_person}" "${pat_ci}"
prune_todo 0
check_todo "merge in progress" "${pat_preamble}" "${pat_merge_second}" "${pat_build}" \
  "${pat_build_sessions}" "${pat_other_tree}" "${pat_person}" "${pat_ci}"
case "${pat_output}" in
  *"removed from ${pat_todo} 1 entry that no longer applies") ;;
  *) fail "prune_agent_todo, merge in progress: wrong diagnostic: ${pat_output}" ;;
esac
# Nothing more is removed while the build has not succeeded.
prune_todo 0
check_todo "merge in progress, again" "${pat_preamble}" "${pat_merge_second}" "${pat_build}" \
  "${pat_build_sessions}" "${pat_other_tree}" "${pat_person}" "${pat_ci}"
[ -z "${pat_output}" ] || fail "prune_agent_todo, merge in progress, again: unexpected diagnostic: ${pat_output}"
# Once the merge is finished and the build succeeds, only the entries about
# the working tree's merges and builds are removed.
rm -f "${pat_merge_head}"
prune_todo 1
check_todo "build succeeded" "${pat_preamble}" "${pat_other_tree}" "${pat_person}" "${pat_ci}"
case "${pat_output}" in
  *"removed from ${pat_todo} 3 entries that no longer apply") ;;
  *) fail "prune_agent_todo, build succeeded: wrong diagnostic: ${pat_output}" ;;
esac

# A file whose last entry is removed ends with that entry's predecessor, with
# no blank line after it.
write_todo "${pat_preamble}" "${pat_person}" "${pat_build}"
prune_todo 1
check_todo "last entry" "${pat_preamble}" "${pat_person}"

# A file with no entry left, and nothing but the title and the explanation,
# is deleted.
write_todo "${pat_preamble}" "${pat_merge_first}" "${pat_build}"
prune_todo 1
[ ! -e "${pat_todo}" ] || fail "prune_agent_todo, no entry left: the file was not deleted: $(cat "${pat_todo}")"
case "${pat_output}" in
  *"deleted ${pat_todo}, whose entries no longer apply") ;;
  *) fail "prune_agent_todo, no entry left: wrong diagnostic: ${pat_output}" ;;
esac
# But a file to which a person added a paragraph is kept.
pat_note='**Note:**  Do nothing about the entries below until the release.'
pat_noted_preamble="# AI agent sessions to continue

${pat_note}

A script of manage-git-branches appends an entry here."
write_todo "${pat_noted_preamble}" "${pat_build}"
prune_todo 1
check_todo "a person's note" "${pat_noted_preamble}"
# So is a file whose explanation a person changed.
write_todo "# AI agent sessions to continue

My own list." "${pat_build}"
prune_todo 1
check_todo "a person's explanation" "# AI agent sessions to continue

My own list."
# A file with no entry, and nothing but the title and the explanation, is
# deleted, as after a person deleted its last entry, even though no entry is
# removed.
write_todo "${pat_preamble}"
prune_todo 0
[ ! -e "${pat_todo}" ] || fail "prune_agent_todo, no entry: the file was not deleted: $(cat "${pat_todo}")"
case "${pat_output}" in
  *"deleted ${pat_todo}, which has no entry") ;;
  *) fail "prune_agent_todo, no entry: wrong diagnostic: ${pat_output}" ;;
esac
# A file whose explanation a person extended, without a blank line, is kept.
pat_extended_preamble="${pat_preamble}
Do nothing about the entries below until the release."
write_todo "${pat_extended_preamble}" "${pat_build}"
prune_todo 1
check_todo "a person's line in the explanation" "${pat_extended_preamble}"
# A file with the explanation that does not mention a merge is deleted.
# The backquotes are Markdown, not command substitutions.
# shellcheck disable=SC2016
write_todo '# AI agent sessions to continue

A script of manage-git-branches, such as `git-push-to`, appends an entry
here when an AI agent fails or when the script rejects its work.  The
entry'"'"'s command continues the agent'"'"'s session interactively.  Delete the
entry once you have dealt with it.' "${pat_build}"
prune_todo 1
[ ! -e "${pat_todo}" ] || fail "prune_agent_todo, explanation without a merge: the file was not deleted: $(cat "${pat_todo}")"
# Run in a subdirectory of the working tree, reached through a symbolic link,
# the function removes the entries that name the top level as `pwd` prints
# it there, through the link.
pat_link="${WORK_DIR}/prune link"
ln -s "${pat_dir}" "${pat_link}"
mkdir -p "${pat_dir}/sub"
write_todo "${pat_preamble}" "${pat_person}" "## Fix the build after merges (git-pull-upstream, 2026-11-10 07:51:59)

\`\`\`sh
cd '${pat_link}' && claude --resume 0d91d672-a3b0-46a7-851a-62477e166fdc
\`\`\`"
pat_output="$(cd "${pat_link}/sub" && prune_agent_todo 1 2>&1)" \
  || fail "prune_agent_todo, subdirectory: returned a nonzero status: ${pat_output}"
check_todo "subdirectory" "${pat_preamble}" "${pat_person}"
rmdir "${pat_dir}/sub"
# An entry to which a person added text is kept:  a line after its command,
# a line after its merge paragraph, or a paragraph at the end of the file,
# which belongs to the last entry.
pat_build_noted="${pat_build}
My note:  wait for the upstream fix."
pat_merge_noted="${pat_merge_first}
Ask the release manager first."
write_todo "${pat_preamble}" "${pat_build_noted}" "${pat_merge_noted}" "${pat_merge_first}" \
  "${pat_build}" "My note at the end."
prune_todo 1
check_todo "a person's note in an entry" "${pat_preamble}" "${pat_build_noted}" "${pat_merge_noted}" \
  "${pat_build}" "My note at the end."
# A file with CRLF line endings is pruned, and keeps its line endings.
# ${pat_crlf} is the expected file.
pat_crlf="${WORK_DIR}/crlf-todo"
write_todo "${pat_preamble}" "${pat_person}" "${pat_ci}"
awk '{ printf "%s\r\n", $0 }' "${pat_todo}" > "${pat_crlf}"
write_todo "${pat_preamble}" "${pat_person}" "${pat_build}" "${pat_ci}"
awk '{ printf "%s\r\n", $0 }' "${pat_todo}" > "${WORK_DIR}/crlf-input"
cat "${WORK_DIR}/crlf-input" > "${pat_todo}"
prune_todo 1
cmp -s "${pat_crlf}" "${pat_todo}" \
  || fail "prune_agent_todo, CRLF: wrong AGENT-TODO.md: $(od -c "${pat_todo}" | head -n 20)"
# A rewritten file keeps its permissions, and no temporary file remains, in
# the working tree or in the git directory.
write_todo "${pat_preamble}" "${pat_person}" "${pat_build}"
chmod 640 "${pat_todo}"
prune_todo 1
check_todo "permissions" "${pat_preamble}" "${pat_person}"
[ -n "$(find "${pat_todo}" -perm 640)" ] \
  || fail "prune_agent_todo did not keep the permissions: $(ls -l "${pat_todo}")"
chmod 644 "${pat_todo}"
for pat_leftover in "${pat_dir}"/.AGENT-TODO.md.* "${pat_dir}"/.git/manage-git-branches-agent-todo*; do
  [ ! -e "${pat_leftover}" ] || fail "prune_agent_todo left a temporary file: ${pat_leftover}"
done
# A file that changes while it is pruned, as when another script appends an
# entry, is left unchanged.  The `awk` that `prune_agent_todo` runs appends an
# entry before it runs the real awk.
pat_bin="${WORK_DIR}/prune-bin"
mkdir -p "${pat_bin}"
pat_awk="$(command -v awk)"
cat > "${pat_bin}/awk" << EOF
#!/bin/sh
printf '\n%s\n' '${pat_other_tree}' >> '${pat_todo}'
exec '${pat_awk}' "\$@"
EOF
chmod +x "${pat_bin}/awk"
write_todo "${pat_preamble}" "${pat_person}" "${pat_build}"
# shellcheck disable=SC2031
pat_output="$(cd "${pat_dir}" && PATH="${pat_bin}:${PATH}" && prune_agent_todo 1 2>&1)" \
  || fail "prune_agent_todo, concurrent append: returned a nonzero status: ${pat_output}"
check_todo "concurrent append" "${pat_preamble}" "${pat_person}" "${pat_build}" "${pat_other_tree}"
case "${pat_output}" in
  *"${pat_todo} changed while it was being pruned, so it was not pruned") ;;
  *) fail "prune_agent_todo, concurrent append: wrong diagnostic: ${pat_output}" ;;
esac
# A file that is not a regular file with one link is not changed.
write_todo "${pat_preamble}" "${pat_build}"
mv "${pat_todo}" "${WORK_DIR}/linked-todo"
ln -s "${WORK_DIR}/linked-todo" "${pat_todo}"
prune_todo 1
if [ ! -L "${pat_todo}" ] \
  || ! grep -q -F -x -- "${pat_cd} a10375ce-87e0-4104-a154-335948d32056" "${WORK_DIR}/linked-todo"; then
  fail "prune_agent_todo changed a symbolic link"
fi
rm -f "${pat_todo}"
ln "${WORK_DIR}/linked-todo" "${pat_todo}"
prune_todo 1
grep -q -F -x -- "${pat_cd} a10375ce-87e0-4104-a154-335948d32056" "${pat_todo}" \
  || fail "prune_agent_todo changed a file with two links"
rm -f "${pat_todo}"
# A missing file is no error.
prune_todo 1
[ -z "${pat_output}" ] || fail "prune_agent_todo, no file: unexpected diagnostic: ${pat_output}"
# A file that the awk script cannot process, here because the script is
# missing, is left unchanged, and the diagnostic names the script.
write_todo "${pat_preamble}" "${pat_build}"
pat_output="$(cd "${pat_dir}" && SCRIPT_DIR="${WORK_DIR}/no-such-dir" && prune_agent_todo 1 2>&1)" \
  || fail "prune_agent_todo, missing awk script: returned a nonzero status: ${pat_output}"
check_todo "missing awk script" "${pat_preamble}" "${pat_build}"
case "${pat_output}" in
  *"cannot process ${pat_todo} with ${WORK_DIR}/no-such-dir/prune-agent-todo.awk, so it was not pruned") ;;
  *) fail "prune_agent_todo, missing awk script: wrong diagnostic: ${pat_output}" ;;
esac
rm -f "${pat_todo}"

echo "${SCRIPT_NAME}: OK"
