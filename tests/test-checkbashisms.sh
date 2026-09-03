#!/bin/sh

# Tests that prek.toml configures a `checkbashisms` check for shell scripts.
# The test verifies that the check exists, that the check accepts a POSIX
# script, and that the check rejects a script containing a bashism.
# Run this test from anywhere; it operates on the enclosing clone.

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
TOPLEVEL="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

cd "${TOPLEVEL}"

status=0

report_failure() {
  echo "$0: FAILURE: $1"
  status=1
}

if ! prek list | grep -q 'checkbashisms$'; then
  report_failure "prek.toml configures no checkbashisms hook"
  exit "${status}"
fi

# prek selects files relative to the top level of the clone, so the scripts
# under test must live within the clone.
testdir="$(mktemp -d "${TOPLEVEL}/checkbashisms-test.XXXXXX")"
trap 'rm -rf "${testdir}"' EXIT INT TERM

# `checkbashisms` reads the shebang line, and prek recognizes a script as a
# shell script only if the script is executable.
cat > "${testdir}/posix-script" << 'EOF'
#!/bin/sh
if [ -n "$1" ]; then
  echo "$1"
fi
EOF
chmod +x "${testdir}/posix-script"

# Assembling "[[" from a variable keeps this test script itself free of
# bashisms, so that the repository's own checkbashisms check passes.
bracket='['
cat > "${testdir}/bashism-script" << EOF
#!/bin/sh
if ${bracket}${bracket} -n "\$1" ]]; then
  echo "\$1"
fi
EOF
chmod +x "${testdir}/bashism-script"

if ! prek run checkbashisms --files "${testdir}/posix-script"; then
  report_failure "the checkbashisms check rejected a POSIX script"
fi

if prek run checkbashisms --files "${testdir}/bashism-script" > /dev/null 2>&1; then
  report_failure "the checkbashisms check accepted a script containing a bashism"
fi

if [ "${status}" -eq 0 ]; then
  echo "$0: PASS"
fi

exit "${status}"
