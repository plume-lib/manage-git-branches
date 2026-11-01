# Setup that is shared by the tests in this directory.  Source this file, then
# call `sanitize_git_env` with a scratch directory:
#
#   TESTS_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
#   . "${TESTS_DIR}/lib-git-test-env.sh"
#   sanitize_git_env "${WORK_DIR}"
#
# This file is sourced rather than run, so it has no shebang line and is not
# executable.  Its name does not begin with `test-`, so `run-tests.sh` does
# not treat it as a test.

# shellcheck shell=sh

# Usage: sanitize_git_env DIRECTORY
#
# Makes the calling test independent of the environment and the Git
# configuration of the user who runs it.  Both can otherwise change what the
# commands under test do, or make them fail.  DIRECTORY is a scratch
# directory that the test deletes when it exits; this function creates a file
# in it.
sanitize_git_env() {
  sanitize_git_env_dir="$1"

  # Variables that say which repository a `git` command operates on.  Git
  # sets them for the commands that it runs, so the test suite inherits them
  # when it runs from a hook or from `git bisect run`; every `git` command in
  # a test would then read and write the invoking repository rather than the
  # scratch one.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE \
    GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_PREFIX \
    GIT_INDEX_VERSION

  # Variables that supply configuration directly.  They outrank the files
  # that GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM name, so emptying those
  # files is not enough.
  unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
  # GIT_CONFIG_COUNT says how many GIT_CONFIG_KEY_n/GIT_CONFIG_VALUE_n pairs
  # Git reads, but unset them all, so that a command that sets the count
  # again does not pick up a stale pair.
  for sanitize_git_env_var in $(env | sed -n \
    's/^\(GIT_CONFIG_KEY_[0-9][0-9]*\|GIT_CONFIG_VALUE_[0-9][0-9]*\)=.*/\1/p'); do
    unset "${sanitize_git_env_var}"
  done
  unset sanitize_git_env_var

  # Variables that the scripts under test read.  A test that wants one of
  # them sets it after calling this function.
  unset DEBUG GIT_SSH GIT_SSH_COMMAND GIT_SSH_VARIANT

  # A global setting such as `commit.gpgsign`, `pull.rebase`, `merge.ff`,
  # `core.hooksPath`, or `commit.template` would change what the commands
  # under test do, or make them fail.  Replace the global configuration file
  # with an empty one and ignore the system configuration file.
  GIT_CONFIG_GLOBAL="${sanitize_git_env_dir}/gitconfig"
  GIT_CONFIG_SYSTEM=/dev/null
  GIT_CONFIG_NOSYSTEM=1
  # A committer identity, in case the user running the test has none.
  GIT_AUTHOR_NAME='manage-git-branches test'
  GIT_AUTHOR_EMAIL='test@example.com'
  GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
  GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
  export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM
  export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  : > "${GIT_CONFIG_GLOBAL}" || return 1

  # By default, the commands under test run an AI agent, `claude` or `codex`,
  # when a merge has conflicts or a build fails.  A test must never run a real
  # agent, which would be slow and costly and would make the result depend on
  # the agent.  These stand-ins fail.  A test that wants an agent puts its own
  # stand-in earlier on the PATH.
  mkdir -p "${sanitize_git_env_dir}/no-ai-agent" || return 1
  for sanitize_git_env_agent in claude codex; do
    printf '#!/bin/sh\necho "%s: a test must not run an AI agent" >&2\nexit 1\n' \
      "${sanitize_git_env_agent}" > "${sanitize_git_env_dir}/no-ai-agent/${sanitize_git_env_agent}" \
      && chmod +x "${sanitize_git_env_dir}/no-ai-agent/${sanitize_git_env_agent}" || return 1
  done
  unset sanitize_git_env_agent
  PATH="${sanitize_git_env_dir}/no-ai-agent:${PATH}"
  export PATH

  unset sanitize_git_env_dir
}
