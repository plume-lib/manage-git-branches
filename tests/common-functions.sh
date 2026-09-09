# shellcheck shell=sh

# Functions that this package's tests share.  A test sources this file, rather
# than running it as a command, so it has no shebang line and is not
# executable.

## Usage: isolate_git_configuration DIRECTORY
## Makes the test independent of the invoking user's git configuration, by
## replacing the global configuration with an empty file in DIRECTORY and the
## system configuration with /dev/null.  A global setting such as
## `commit.gpgsign`, `pull.rebase`, `merge.ff`, `core.hooksPath`, or
## `commit.template` would otherwise change what the commands under test do, or
## make them fail.  Also sets a committer identity, in case the user running
## the test has none.
isolate_git_configuration() {
  GIT_CONFIG_GLOBAL="$1/gitconfig"
  GIT_CONFIG_SYSTEM=/dev/null
  GIT_AUTHOR_NAME="Test User"
  GIT_AUTHOR_EMAIL="test@example.com"
  GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
  GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
  export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
  export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  : > "${GIT_CONFIG_GLOBAL}"
}

## Usage: use_fake_ssh CLONE ARGUMENTS_FILE
## Makes the remote "origin" of the clone CLONE reachable only over SSH, and
## makes that SSH a fake one that appends its arguments to ARGUMENTS_FILE, one
## invocation per line, and then exits with a failure status.  The test can
## then check which options the query passed to SSH, such as the one that
## disables SSH's own prompts.  The fake `ssh` command is created beside
## ARGUMENTS_FILE, which is truncated, so that it holds only the arguments of
## the invocations that the test is about to make.
use_fake_ssh() {
  use_fake_ssh_clone="$1"
  SSH_ARGUMENTS_FILE="$2"
  export SSH_ARGUMENTS_FILE
  use_fake_ssh_command="$(dirname -- "${SSH_ARGUMENTS_FILE}")/fake-ssh"
  cat > "${use_fake_ssh_command}" << 'FAKE_SSH_END'
#!/bin/sh
printf '%s\n' "$*" >> "${SSH_ARGUMENTS_FILE}"
exit 1
FAKE_SSH_END
  chmod +x "${use_fake_ssh_command}"
  git -C "${use_fake_ssh_clone}" config core.sshCommand "${use_fake_ssh_command}"
  git -C "${use_fake_ssh_clone}" config ssh.variant ssh
  git -C "${use_fake_ssh_clone}" remote set-url origin 'ssh://example.invalid/no-such-repo.git'
  : > "${SSH_ARGUMENTS_FILE}"
}
