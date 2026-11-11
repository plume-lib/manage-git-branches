#!/bin/sh

# Tests `git-pull-upstream`.
#
# Usage:
#   tests/test-git-pull-upstream.sh
#
# The status code is 0 if all tests pass and 1 otherwise.
#
# The tests use local "remote" repositories, so they do not access the network.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SCRIPT_NAME="$(basename -- "$0")"
COMMANDS_DIR="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd -P)" || exit 1
GIT_PULL_UPSTREAM="${COMMANDS_DIR}/git-pull-upstream"

. "${SCRIPT_DIR}/lib-git-test-env.sh"
# shellcheck source=common-test-functions.sh
. "${SCRIPT_DIR}/common-test-functions.sh"

failures=0

# Prints a message and records a test failure.
fail() {
  echo "${SCRIPT_NAME}: FAIL: $1" >&2
  failures=$((failures + 1))
}

# Usage: pull_upstream DIRECTORY [ARGS]
# Runs `git-pull-upstream ARGS` in DIRECTORY, writing its standard error to
# ${testdir}/errors.
pull_upstream() {
  (cd "$1" && shift && "${GIT_PULL_UPSTREAM}" "$@") > /dev/null 2> "${testdir}/errors"
}

# Usage: pushed_head
# Prints the commit that branch "feature" has in the fork's remote repository.
pushed_head() {
  git -C "${fork_remote}" rev-parse refs/heads/feature
}

testdir="$(mktemp -d)"
trap 'rm -rf "${testdir}"' EXIT
trap 'rm -rf "${testdir}"; trap - INT; kill -s INT "$$"' INT
trap 'rm -rf "${testdir}"; trap - TERM; kill -s TERM "$$"' TERM

sanitize_git_env "${testdir}"

# The canonical repository, whose default branch is not named "main", and a
# fork of it, with a branch "feature" that has an upstream branch.  The
# Makefile builds successfully unless the file "broken" exists.
canonical="${testdir}/canonical.git"
git init -q --bare -b trunk "${canonical}"
canonical_work="${testdir}/canonical-work"
git clone -q "${canonical}" "${canonical_work}" 2> /dev/null
printf 'all:\n\ttest ! -e broken\n' > "${canonical_work}/Makefile"
git -C "${canonical_work}" add Makefile
commit_file "${canonical_work}" a.txt 'a1'
git -C "${canonical_work}" push -q origin trunk
fork_remote="${testdir}/fork.git"
git clone -q --bare "${canonical}" "${fork_remote}"

fork="${testdir}/fork"
git clone -q "${fork_remote}" "${fork}"
git -C "${fork}" remote add upstream "${canonical}"
git -C "${fork}" switch -q -c feature
mkdir "${fork}/subdir"
commit_file "${fork}" subdir/b.txt 'b1'
git -C "${fork}" push -q -u origin feature

# The fork's branch already contains the default branch of `upstream`.  The
# run, which has nothing to merge or push, still deletes AGENT-TODO.md, whose
# only entry is about a merge that is no longer in progress.
before="$(git -C "${fork}" rev-parse HEAD)"
# The backquotes are Markdown, not command substitutions.
# shellcheck disable=SC2016
printf '%s\n' '# AI agent sessions to continue' '' \
  'A script of manage-git-branches, such as `git-push-to`, appends an entry here.' '' \
  '## Finish the merge in progress (git-pull-upstream, 2026-11-09 08:23:59)' '' \
  "The merge of commit ${before} is in progress in ${fork}." \
  'Finish it (resolve its conflicts and commit it), or abort it with `git merge --abort`; then delete this entry.' \
  > "${fork}/AGENT-TODO.md"
if ! pull_upstream "${fork}"; then
  fail "up to date: failed: $(cat "${testdir}/errors")"
elif [ "$(git -C "${fork}" rev-parse HEAD)" != "${before}" ]; then
  fail "up to date: changed HEAD"
elif [ -e "${fork}/AGENT-TODO.md" ]; then
  fail "up to date: did not delete AGENT-TODO.md: $(cat "${testdir}/errors")"
fi
rm -f "${fork}/AGENT-TODO.md"

# A new commit in `upstream` is merged and pushed, even when this command is
# run in a subdirectory.
commit_file "${canonical_work}" a.txt 'a2'
git -C "${canonical_work}" push -q origin trunk
if ! pull_upstream "${fork}/subdir"; then
  fail "merge: failed: $(cat "${testdir}/errors")"
else
  subject="$(git -C "${fork}" log -1 --format=%s)"
  if [ "${subject}" != "Merge remote-tracking branch 'upstream/trunk' into feature" ]; then
    fail "merge: wrong merge message: ${subject}"
  fi
  if [ "$(cat "${fork}/a.txt")" != 'a2' ]; then
    fail "merge: did not merge a.txt"
  fi
  if [ "$(pushed_head)" != "$(git -C "${fork}" rev-parse HEAD)" ]; then
    fail "merge: did not push"
  fi
fi

# With `merge.log` set, the merge message has the commit summaries that
# `git merge` writes, but not the comment lines, such as "# By AUTHOR", that
# `git fmt-merge-msg` adds when someone other than the user wrote a commit.
# A comment character of "*", with which the summaries begin, changes
# neither.
git -C "${fork}" config merge.log true
for comment_char in '#' '*'; do
  git -C "${fork}" config core.commentChar "${comment_char}"
  printf 'a3 %s\n' "${comment_char}" > "${canonical_work}/a.txt"
  git -C "${canonical_work}" add a.txt
  summary="Change a.txt for comment character ${comment_char}"
  git -C "${canonical_work}" commit -q -m "${summary}" \
    --author='Another Author <another@example.com>'
  git -C "${canonical_work}" push -q origin trunk
  if ! pull_upstream "${fork}"; then
    fail "merge.log, comment character ${comment_char}: failed: $(cat "${testdir}/errors")"
  else
    message="$(git -C "${fork}" log -1 --format=%B)"
    case "${message}" in
      *'By Another Author'*) fail "merge.log, comment character ${comment_char}: the merge message has comment lines: ${message}" ;;
    esac
    case "${message}" in
      *"* upstream/trunk:"*"${summary}"*) ;;
      *) fail "merge.log, comment character ${comment_char}: the merge message lacks the commit summaries: ${message}" ;;
    esac
  fi
done
git -C "${fork}" config --unset merge.log
git -C "${fork}" config --unset core.commentChar

# The current branch is pulled from its own upstream branch first.
other="${testdir}/other"
git clone -q -b feature "${fork_remote}" "${other}"
commit_file "${other}" c.txt 'c1'
git -C "${other}" push -q origin feature
commit_file "${canonical_work}" a.txt 'a3'
git -C "${canonical_work}" push -q origin trunk
if ! pull_upstream "${fork}"; then
  fail "pull first: failed: $(cat "${testdir}/errors")"
elif [ ! -e "${fork}/c.txt" ] || [ "$(cat "${fork}/a.txt")" != 'a3' ]; then
  fail "pull first: did not pull and merge"
fi

# A merge that does not build is not pushed, unless `--nocompile` is given.
pushed_before="$(pushed_head)"
commit_file "${canonical_work}" broken 'x'
git -C "${canonical_work}" push -q origin trunk
if pull_upstream "${fork}"; then
  fail "build failure: succeeded"
elif [ "$(pushed_head)" != "${pushed_before}" ]; then
  fail "build failure: pushed"
fi

# The merge that was not pushed survives the pull of a new commit on the
# branch, even when `pull.rebase` is set, and the pull's own merge does not
# stop at an editor.  `GIT_MERGE_AUTOEDIT` makes git start the editor even
# though no terminal is attached, and the editor `false` makes the merge fail.
# The pull's merge, like `git merge`, runs the `pre-merge-commit` hook, not
# the `pre-commit` hook, which fails.
unpushed_merge="$(git -C "${fork}" rev-parse HEAD)"
git -C "${other}" pull -q --no-rebase
commit_file "${other}" c.txt 'c2'
git -C "${other}" push -q origin feature
git -C "${fork}" config pull.rebase true
fork_hooks="$(git -C "${fork}" rev-parse --path-format=absolute --git-path hooks)"
mkdir -p "${fork_hooks}"
printf '#!/bin/sh\nexit 1\n' > "${fork_hooks}/pre-commit"
chmod +x "${fork_hooks}/pre-commit"
if ! GIT_MERGE_AUTOEDIT=yes GIT_EDITOR=false pull_upstream "${fork}" --nocompile; then
  fail "--nocompile: failed: $(cat "${testdir}/errors")"
elif [ "$(pushed_head)" != "$(git -C "${fork}" rev-parse HEAD)" ]; then
  fail "--nocompile: did not push"
elif ! git -C "${fork}" merge-base --is-ancestor "${unpushed_merge}" HEAD; then
  fail "--nocompile: lost the merge that was not pushed"
elif [ "$(cat "${fork}/c.txt")" != 'c2' ]; then
  fail "--nocompile: did not pull c.txt"
fi
git -C "${fork}" config --unset pull.rebase
rm "${fork_hooks}/pre-commit"

# A conflicting merge fails and is not pushed.
commit_file "${fork}" a.txt 'fork'
git -C "${fork}" push -q
pushed_before="$(pushed_head)"
commit_file "${canonical_work}" a.txt 'canonical'
git -C "${canonical_work}" push -q origin trunk
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "conflict: succeeded"
elif [ "$(pushed_head)" != "${pushed_before}" ]; then
  fail "conflict: pushed"
fi
git -C "${fork}" merge --abort

# Usage: expect_merge DESCRIPTION REMOTE FILE
# Commits FILE to the default branch of ${fork_remote}, runs this command in
# ${fork}, and checks that it merges REMOTE's default branch and pushes.
expect_merge() {
  git -C "${other}" fetch -q origin
  git -C "${other}" switch -q trunk
  git -C "${other}" merge -q --ff-only origin/trunk
  commit_file "${other}" "$3" "$3"
  git -C "${other}" push -q origin trunk
  if ! MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
    fail "$1: failed: $(cat "${testdir}/errors")"
    return
  fi
  expect_merge_subject="$(git -C "${fork}" log -1 --format=%s)"
  if [ "${expect_merge_subject}" != "Merge remote-tracking branch '$2/trunk' into feature" ]; then
    fail "$1: wrong merge message: ${expect_merge_subject}"
  elif [ ! -e "${fork}/$3" ]; then
    fail "$1: did not merge $3"
  elif [ "$(pushed_head)" != "$(git -C "${fork}" rev-parse HEAD)" ]; then
    fail "$1: did not push"
  fi
}

# Without an `upstream` remote, `origin` is the upstream repository.
git -C "${fork}" remote remove upstream
expect_merge 'origin' origin d.txt

# Without `upstream` or `origin`, the clone's only remote is the upstream
# repository.
git -C "${fork}" remote rename origin github
expect_merge 'sole remote' github e.txt

# A branch that pushes to the upstream repository's default branch is not
# pushed, even when it has commits that are not pushed.
git -C "${fork}" switch -q trunk
git -C "${fork}" merge -q --ff-only github/trunk
commit_file "${fork}" f.txt 'f'
trunk_before="$(git -C "${fork_remote}" rev-parse refs/heads/trunk)"
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "push to upstream default branch: succeeded"
elif [ "$(git -C "${fork_remote}" rev-parse refs/heads/trunk)" != "${trunk_before}" ]; then
  fail "push to upstream default branch: pushed"
elif ! grep -q 'does not push it' "${testdir}/errors"; then
  fail "push to upstream default branch: wrong message: $(cat "${testdir}/errors")"
fi
git -C "${fork}" switch -q feature

# A clone that has no remote named "upstream" or "origin", and more than one
# remote, fails before the pull changes the current branch.
git -C "${fork}" remote add mirror "${fork_remote}"
git -C "${other}" switch -q feature
git -C "${other}" pull -q --no-rebase
commit_file "${other}" g.txt 'g'
git -C "${other}" push -q origin feature
before="$(git -C "${fork}" rev-parse HEAD)"
if pull_upstream "${fork}"; then
  fail "two remotes: succeeded"
elif [ "$(git -C "${fork}" rev-parse HEAD)" != "${before}" ]; then
  fail "two remotes: changed HEAD"
fi
git -C "${fork}" remote remove mirror

# A branch that cannot be pushed is not merged.  When `push.default` is
# "simple", a branch whose name differs from its upstream branch's cannot be
# pushed to that remote.
git -C "${other}" switch -q trunk
git -C "${other}" pull -q --no-rebase
commit_file "${other}" h.txt 'h'
git -C "${other}" push -q origin trunk
git -C "${fork}" switch -q -c renamed --track github/feature
git -C "${fork}" config push.default simple
commit_file "${fork}" renamed.txt 'r'
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "cannot push: succeeded"
elif [ -e "${fork}/h.txt" ]; then
  fail "cannot push: merged"
elif ! grep -q 'cannot be pushed' "${testdir}/errors"; then
  fail "cannot push: wrong message: $(cat "${testdir}/errors")"
fi
git -C "${fork}" switch -q feature

# In a fork, a branch that pushes to the remote "upstream" is not pushed, even
# to a branch other than the default branch.  The refusal comes before the
# pull, so the branch's upstream branch's new commit is not pulled.
git -C "${fork}" remote add upstream "${canonical}"
git -C "${fork}" fetch -q upstream
git -C "${fork}" switch -q -c topic upstream/trunk
git -C "${fork}" config push.default current
commit_file "${fork}" topic.txt 't'
commit_file "${canonical_work}" i.txt 'i'
git -C "${canonical_work}" push -q origin trunk
before="$(git -C "${fork}" rev-parse HEAD)"
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "push to upstream: succeeded"
elif git -C "${canonical}" rev-parse --verify --quiet refs/heads/topic > /dev/null; then
  fail "push to upstream: pushed"
elif [ "$(git -C "${fork}" rev-parse HEAD)" != "${before}" ]; then
  fail "push to upstream: pulled"
elif ! grep -q 'does not push it' "${testdir}/errors"; then
  fail "push to upstream: wrong message: $(cat "${testdir}/errors")"
fi
git -C "${fork}" config --unset push.default
git -C "${fork}" switch -q feature

# A `git push` that might push other branches too is refused, before the pull.
# The current branch's upstream branch has a new commit, which must not be
# pulled.
git -C "${other}" switch -q feature
git -C "${other}" pull -q --no-rebase
commit_file "${other}" j.txt 'j'
git -C "${other}" push -q origin feature
before="$(git -C "${fork}" rev-parse HEAD)"
git -C "${fork}" config push.default matching
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "push.default=matching: succeeded"
elif [ "$(git -C "${fork}" rev-parse HEAD)" != "${before}" ]; then
  fail "push.default=matching: pulled"
elif ! grep -q 'push.default is "matching"' "${testdir}/errors"; then
  fail "push.default=matching: wrong message: $(cat "${testdir}/errors")"
fi
git -C "${fork}" config --unset push.default
git -C "${fork}" config remote.github.mirror true
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "remote.github.mirror: succeeded"
elif [ "$(git -C "${fork}" rev-parse HEAD)" != "${before}" ]; then
  fail "remote.github.mirror: pulled"
elif ! grep -q 'remote.github.mirror is set' "${testdir}/errors"; then
  fail "remote.github.mirror: wrong message: $(cat "${testdir}/errors")"
fi
git -C "${fork}" config --unset remote.github.mirror
git -C "${fork}" config remote.github.push 'refs/heads/*:refs/heads/*'
if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "remote.github.push: succeeded"
elif [ "$(git -C "${fork}" rev-parse HEAD)" != "${before}" ]; then
  fail "remote.github.push: pulled"
elif ! grep -q 'remote.github.push is set' "${testdir}/errors"; then
  fail "remote.github.push: wrong message: $(cat "${testdir}/errors")"
fi
git -C "${fork}" config --unset remote.github.push

# In a triangular workflow, a branch that matches the branch it pulls from but
# not the branch it pushes to is pushed, even though there is nothing to merge.
# The branch pulls from `github/feature` and pushes to `push/feature`, which
# lacks the branch's latest commit.
git -C "${fork}" pull -q --no-rebase --no-edit
git -C "${fork}" fetch -q upstream
# `-X ours` resolves the conflict in a.txt that an earlier test made.
git -C "${fork}" merge -q --no-edit -X ours upstream/trunk > /dev/null
push_remote="${testdir}/push.git"
git clone -q --bare "${fork_remote}" "${push_remote}"
git -C "${fork}" remote add push "${push_remote}"
git -C "${fork}" config branch.feature.pushRemote push
git -C "${fork}" config push.default current
git -C "${fork}" fetch -q push
commit_file "${fork}" k.txt 'k'
git -C "${fork}" push -q github feature
git -C "${fork}" fetch -q github
if ! MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "triangular: failed: $(cat "${testdir}/errors")"
elif [ "$(git -C "${push_remote}" rev-parse refs/heads/feature)" != "$(git -C "${fork}" rev-parse HEAD)" ]; then
  fail "triangular: did not push"
fi
git -C "${fork}" config --unset push.default
git -C "${fork}" config --unset branch.feature.pushRemote
git -C "${fork}" remote remove push

# A branch that has no upstream branch fails with a diagnostic that says so.
git -C "${fork}" switch -q -c no-upstream
if pull_upstream "${fork}"; then
  fail "no upstream branch: succeeded"
elif ! grep -q 'has no upstream branch' "${testdir}/errors"; then
  fail "no upstream branch: wrong message: $(cat "${testdir}/errors")"
fi
git -C "${fork}" switch -q feature

# An extra argument is rejected.
if pull_upstream "${fork}" extra; then
  fail "extra argument: succeeded"
fi

# In a clone of a GitHub fork that a user owns and that has no remote named
# "upstream", the upstream repository is the fork's parent.  A stub `gh` says
# that me/proj is a fork of someone/proj:  `gh repo view` prints the upstream
# repository and the default branch, which for me/proj are its parent,
# someone/proj, and for any other repository are the repository itself, and
# `gh auth token` succeeds.  `gh api -X GET` appends its arguments to
# ${testdir}/gh-api-log and prints what `--jq` would make of GitHub's answer:
# for the pull requests from a branch of me/proj, the file ${testdir}/gh-pulls;
# for those from a branch of someone/proj, the file ${testdir}/gh-base-pulls;
# and for pull request N, the file ${testdir}/gh-pull-N.  It fails if the file
# does not exist.
# `url.BASE.insteadOf` maps their GitHub URLs to local bare repositories.
mkdir "${testdir}/bin"
cat > "${testdir}/bin/gh" << EOF
#!/bin/sh
case "\$1 \$2 \$3" in
  'auth token '*) echo 'fake-token' ;;
  'repo view github.com/me/proj') echo 'someone/proj trunk' ;;
  'repo view github.com/'*) echo "\${3#github.com/} trunk" ;;
  'api -X GET')
    printf '%s\n' "\$*" >> "${testdir}/gh-api-log"
    case "\$4 \$*" in
      */pulls' '*' head=me:'*) cat "${testdir}/gh-pulls" 2> /dev/null ;;
      */pulls' '*' head=someone:'*) cat "${testdir}/gh-base-pulls" 2> /dev/null ;;
      */pulls/*) cat "${testdir}/gh-pull-\${4##*/}" 2> /dev/null ;;
      *) exit 1 ;;
    esac
    ;;
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
git config --global --add "url.${gh_parent}.insteadOf" 'git@github.com:someone/proj.git'
git config --global "url.${gh_fork}.insteadOf" 'https://github.com/me/proj.git'
gh_parent_work="${testdir}/gh-parent-work"
git clone -q 'https://github.com/someone/proj.git' "${gh_parent_work}" 2> /dev/null

# Usage: gh_parent_commit FILE
# Commits FILE to the parent's default branch.
gh_parent_commit() {
  commit_file "${gh_parent_work}" "$1" "$1"
  git -C "${gh_parent_work}" push -q origin HEAD
}

# Usage: make_gh_fork_clone DIRECTORY
# Clones the fork into DIRECTORY, which has only the remote `origin`, and
# checks out a branch `feature` that tracks and pushes to `origin/feature`.
# Sets ${fork} to DIRECTORY.
make_gh_fork_clone() {
  fork="$1"
  git clone -q 'https://github.com/me/proj.git' "${fork}"
  git -C "${fork}" switch -q -c "feature-${fork##*/}"
  commit_file "${fork}" "${fork##*/}.txt" 'fork'
  git -C "${fork}" push -q -u origin HEAD
}

# Usage: gh_fork_pushed_head
# Prints the commit that ${fork}'s current branch has in the fork's GitHub
# repository.
gh_fork_pushed_head() {
  git -C "${gh_fork}" rev-parse "refs/heads/$(git -C "${fork}" branch --show-current)"
}

# Usage: expect_gh_merge DESCRIPTION SUBJECT FILE
# Runs this command in ${fork}, and checks that it merges FILE with a merge
# commit whose subject is SUBJECT and pushes to the fork.
expect_gh_merge() {
  if ! MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
    fail "$1: failed: $(cat "${testdir}/errors")"
    return
  fi
  expect_gh_merge_subject="$(git -C "${fork}" log -1 --format=%s)"
  if [ "${expect_gh_merge_subject}" != "$2" ]; then
    fail "$1: wrong merge message: ${expect_gh_merge_subject}"
  elif [ ! -e "${fork}/$3" ]; then
    fail "$1: did not merge $3"
  elif [ "$(gh_fork_pushed_head)" != "$(git -C "${fork}" rev-parse HEAD)" ]; then
    fail "$1: did not push"
  fi
}

# Usage: expect_gh_refused DESCRIPTION BRANCH
# Runs this command in ${fork}, and checks that it fails, says that it does
# not push, and leaves the parent without BRANCH.
expect_gh_refused() {
  if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
    fail "$1: succeeded"
  elif git -C "${gh_parent}" rev-parse --verify --quiet "refs/heads/$2" > /dev/null; then
    fail "$1: pushed to the parent"
  elif ! grep -q 'does not push it' "${testdir}/errors"; then
    fail "$1: wrong message: $(cat "${testdir}/errors")"
  fi
}

# The parent, which is not a remote of the clone, is fetched from its URL into
# refs/fork-upstream, and the merge message names the URL as `git pull` would.
make_gh_fork_clone "${testdir}/gh-clone"
gh_parent_commit l.txt
expect_gh_merge 'fork' "Merge https://github.com/someone/proj into feature-gh-clone" l.txt
if git -C "${fork}" config --get remote.upstream.url > /dev/null; then
  fail 'fork: added remote upstream'
fi
if ! git -C "${fork}" rev-parse --verify --quiet refs/fork-upstream/someone/proj > /dev/null; then
  fail 'fork: did not fetch into refs/fork-upstream/someone/proj'
fi

# A branch that pushes to the parent's URL is not pushed, even when the URL
# is spelled differently from the one that was fetched.
git -C "${fork}" switch -q -c to-parent-url
git -C "${fork}" config branch.to-parent-url.remote origin
git -C "${fork}" config branch.to-parent-url.merge refs/heads/feature-gh-clone
git -C "${fork}" config branch.to-parent-url.pushRemote 'git@github.com:someone/proj.git'
git -C "${fork}" config push.default current
gh_parent_commit m.txt
expect_gh_refused 'push to the parent URL' to-parent-url

# The clone's remote for the parent is the upstream repository.  A branch that
# pushes to the parent through another remote for it is not pushed.
make_gh_fork_clone "${testdir}/gh-clone-remotes"
git -C "${fork}" remote add canonical 'https://github.com/someone/proj.git'
git -C "${fork}" remote add canonical-ssh 'git@github.com:someone/proj.git'
gh_parent_commit n.txt
expect_gh_merge 'fork with a remote for the parent' \
  "Merge remote-tracking branch 'canonical/trunk' into feature-gh-clone-remotes" n.txt
if [ -n "$(git -C "${fork}" for-each-ref refs/fork-upstream)" ]; then
  fail 'fork with a remote for the parent: fetched into refs/fork-upstream'
fi
git -C "${fork}" switch -q -c to-parent-remote
git -C "${fork}" config branch.to-parent-remote.remote origin
git -C "${fork}" config branch.to-parent-remote.merge refs/heads/feature-gh-clone-remotes
git -C "${fork}" config branch.to-parent-remote.pushRemote canonical-ssh
git -C "${fork}" config push.default current
gh_parent_commit o.txt
expect_gh_refused 'push to the parent through another remote' to-parent-remote

# Usage: expect_dependent_refused DESCRIPTION FILE
# Runs this command in ${fork}, and checks that it fails, says that the
# current branch builds on another pull request, and neither merges FILE nor
# pushes.
expect_dependent_refused() {
  expect_dependent_refused_pushed="$(gh_fork_pushed_head)"
  if MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
    fail "$1: succeeded"
  elif ! grep -q 'builds on another pull request' "${testdir}/errors" \
    || ! grep -q -e '--allow-dependent' "${testdir}/errors"; then
    fail "$1: wrong message: $(cat "${testdir}/errors")"
  elif [ -e "${fork}/$2" ]; then
    fail "$1: merged $2"
  elif [ "$(gh_fork_pushed_head)" != "${expect_dependent_refused_pushed}" ]; then
    fail "$1: pushed"
  fi
}

# A branch whose pull request's base branch is another pull request's branch
# is not merged into, unless "--allow-dependent" is passed.  A pull request
# from a branch of the same name in another repository does not count.
make_gh_fork_clone "${testdir}/gh-clone-dependent"
printf 'pr 5 feature-b trunk trunk me/proj\nbody 5 Stacked on #4. me/proj\n' > "${testdir}/gh-pulls"
printf '4 someone/proj\n' > "${testdir}/gh-base-pulls"
gh_parent_commit p.txt
expect_dependent_refused 'stacked pull request' p.txt
if ! grep -q 'its base branch is feature-b, the head branch of someone/proj#4' "${testdir}/errors"; then
  fail "stacked pull request: does not name the base branch: $(cat "${testdir}/errors")"
elif ! grep -q 'repos/someone/proj/pulls -f head=someone:feature-b -f state=open' "${testdir}/gh-api-log"; then
  fail "stacked pull request: does not ask about feature-b: $(cat "${testdir}/gh-api-log")"
fi
if ! MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}" --allow-dependent; then
  fail "--allow-dependent: failed: $(cat "${testdir}/errors")"
elif [ ! -e "${fork}/p.txt" ]; then
  fail "--allow-dependent: did not merge p.txt"
fi
printf 'pr 6 feature-b trunk trunk Someone/Proj\npr 7 trunk trunk trunk ME/PROJ\n' > "${testdir}/gh-pulls"
gh_parent_commit q.txt
expect_gh_merge 'pull request from another repository' \
  "Merge https://github.com/someone/proj into feature-gh-clone-dependent" q.txt

# A base branch that is not the head branch of an open pull request of the
# base repository, such as a release branch or the branch of a pull request
# that has landed, does not count.
printf 'pr 11 release-1 trunk trunk me/proj\n' > "${testdir}/gh-pulls"
printf '12 someone/other\n' > "${testdir}/gh-base-pulls"
gh_parent_commit q2.txt
expect_gh_merge 'base branch without an open pull request' \
  "Merge https://github.com/someone/proj into feature-gh-clone-dependent" q2.txt

# A "Land after" line that names no pull request, such as an issue, does not
# hide a stacked base branch.
printf 'pr 5 feature-b trunk trunk me/proj\nbody 5 Land after #20. me/proj\n' > "${testdir}/gh-pulls"
printf '4 someone/proj\n' > "${testdir}/gh-base-pulls"
gh_parent_commit q3.txt
expect_dependent_refused 'stacked, and land after an issue' q3.txt

# Nor is a branch whose pull request's description says to land after an
# open pull request, even with a carriage return at the end of the line.
# One that says to land after a closed pull request is merged into.
printf 'pr 8 trunk trunk trunk me/proj\nbody 8 Land after #9.\r me/proj\nbody 8  me/proj\nbody 8 Text. me/proj\n' > "${testdir}/gh-pulls"
printf 'open trunk\n' > "${testdir}/gh-pull-9"
expect_dependent_refused 'land after an open pull request' q3.txt
if ! grep -q 'its description says to land after someone/proj#9' "${testdir}/errors"; then
  fail "land after an open pull request: does not name it: $(cat "${testdir}/errors")"
fi
# The line can name the pull request as "ORG/REPO#N", in any case, or by its
# URL, and it can continue with text that names no other pull request.
for line in 'Land after Someone/Proj#9 (it adds the helper).' \
  'Land after https://github.com/someone/proj/pull/9'; do
  printf 'pr 8 trunk trunk trunk me/proj\nbody 8 %s me/proj\n' "${line}" > "${testdir}/gh-pulls"
  expect_dependent_refused "${line}" q3.txt
done
# A line that names several pull requests, or one in another repository, does
# not count, so GitHub is not asked about the pull request.
printf 'pr 8 trunk trunk trunk me/proj\nbody 8 Land after #9 and #10. me/proj\nbody 8 Land after other/proj#9. me/proj\n' > "${testdir}/gh-pulls"
rm -f "${testdir}/gh-api-log"
expect_gh_merge 'land after several or another repository' \
  "Merge https://github.com/someone/proj into feature-gh-clone-dependent" q3.txt
if grep -q 'pulls/' "${testdir}/gh-api-log" || grep -q 'ignoring\|assuming' "${testdir}/errors"; then
  fail "land after several or another repository: counted a line: $(cat "${testdir}/errors")"
fi
printf 'pr 8 trunk trunk trunk me/proj\nbody 8 Land after #9. me/proj\n' > "${testdir}/gh-pulls"
printf 'closed trunk\n' > "${testdir}/gh-pull-9"
gh_parent_commit r.txt
expect_gh_merge 'land after a closed pull request' \
  "Merge https://github.com/someone/proj into feature-gh-clone-dependent" r.txt

# A branch that already contains the default branch is built and pushed even
# if its pull request builds on another one.
printf 'pr 10 feature-b trunk trunk me/proj\n' > "${testdir}/gh-pulls"
printf '4 someone/proj\n' > "${testdir}/gh-base-pulls"
commit_file "${fork}" s.txt 's'
if ! MANAGE_GIT_BRANCHES_SKIP_COMPILE_PROJECT=1 pull_upstream "${fork}"; then
  fail "dependent, nothing to merge: failed: $(cat "${testdir}/errors")"
elif [ "$(gh_fork_pushed_head)" != "$(git -C "${fork}" rev-parse HEAD)" ]; then
  fail "dependent, nothing to merge: did not push"
fi

# If GitHub cannot list the pull requests, this command says so and merges.
rm -f "${testdir}/gh-pulls"
gh_parent_commit t.txt
expect_gh_merge 'GitHub cannot be asked' \
  "Merge https://github.com/someone/proj into feature-gh-clone-dependent" t.txt
if ! grep -q 'assuming that it does not' "${testdir}/errors"; then
  fail "GitHub cannot be asked: does not say so: $(cat "${testdir}/errors")"
fi
# Nor if GitHub cannot be asked about the base branch.
printf 'pr 5 feature-b trunk trunk me/proj\n' > "${testdir}/gh-pulls"
rm -f "${testdir}/gh-base-pulls"
gh_parent_commit u.txt
expect_gh_merge 'GitHub cannot be asked about the base branch' \
  "Merge https://github.com/someone/proj into feature-gh-clone-dependent" u.txt
if ! grep -q 'assuming that it is not' "${testdir}/errors"; then
  fail "GitHub cannot be asked about the base branch: does not say so: $(cat "${testdir}/errors")"
fi
PATH="${saved_path}"

if [ "${failures}" -ne 0 ]; then
  echo "${SCRIPT_NAME}: ${failures} failure(s)" >&2
  exit 1
fi
