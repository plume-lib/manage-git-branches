#!/bin/sh
set -u
W="$(mktemp -d)"
export GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL=a@b GIT_COMMITTER_NAME=a GIT_COMMITTER_EMAIL=a@b
t() {
  label="$1"; n="$2"; shift 2
  s=$(python3 -c 'import time;print(time.time())')
  i=0; while [ $i -lt "$n" ]; do "$@" > /dev/null 2>&1; i=$((i+1)); done
  e=$(python3 -c 'import time;print(time.time())')
  python3 -c "print(f'%-50s %7.2f ms each' % ('$label', ($e-$s)*1000/$n))"
}
otool -L "$(command -v git)" 2>/dev/null
git init -q "$W/r"; git -C "$W/r" commit -q --allow-empty -m x
for cfg in "core.fsync=none" "core.fsyncMethod=writeout-only" "core.fsync=committed"; do :; done
t "commit default" 100 git -C "$W/r" commit -q --allow-empty -m y
t "commit core.fsync=none" 100 git -c core.fsync=none -C "$W/r" commit -q --allow-empty -m y
t "commit fsyncMethod=writeout-only" 100 git -c core.fsyncMethod=writeout-only -C "$W/r" commit -q --allow-empty -m y
t "update-ref default" 100 git -C "$W/r" update-ref refs/heads/z HEAD
t "update-ref fsync=none" 100 git -c core.fsync=none -C "$W/r" update-ref refs/heads/z HEAD
t "git init default" 50 sh -c 'git init -q "$(mktemp -d '"$W"'/gi.XXXXXX)"'
t "git init fsync=none" 50 sh -c 'git -c core.fsync=none init -q "$(mktemp -d '"$W"'/gi.XXXXXX)"'
t "git init --template=" 50 sh -c 'git init -q --template= "$(mktemp -d '"$W"'/gi.XXXXXX)"'
t "git -c core.fsync=none --version" 100 git -c core.fsync=none --version
t "git rev-parse HEAD" 100 git -C "$W/r" rev-parse HEAD
t "LC_ALL=C git rev-parse" 100 env LC_ALL=C git -C "$W/r" rev-parse HEAD
rm -rf "$W"
