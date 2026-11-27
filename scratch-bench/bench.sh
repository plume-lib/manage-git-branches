#!/bin/sh
# Temporary diagnostic: measures the cost of common operations.
set -u
W="$(mktemp -d)"
t() { # LABEL N CMD...
  label="$1"; n="$2"; shift 2
  s=$(python3 -c 'import time;print(time.time())')
  i=0; while [ $i -lt "$n" ]; do "$@" > /dev/null 2>&1; i=$((i+1)); done
  e=$(python3 -c 'import time;print(time.time())')
  python3 -c "print(f'%-40s %7.2f ms each' % ('$label', ($e-$s)*1000/$n))"
}
uname -a; command -v git sh bash sed python3; ls -l /bin/sh; git --version; sysctl -n hw.ncpu 2>/dev/null || nproc
echo "TMPDIR=${TMPDIR:-} W=$W"
git init -q "$W/r"; git -C "$W/r" commit -q --allow-empty -m x
printf '#!/bin/sh\nexit 0\n' > "$W/stub"; chmod +x "$W/stub"
t "true (builtin)" 500 true
t "/usr/bin/true" 300 /usr/bin/true
t "env true" 300 env true
t "sh -c :" 300 sh -c :
t "bash -c :" 300 bash -c :
t "dash -c : (if any)" 100 dash -c :
t "sed --version-ish" 300 sed -n 1p /dev/null
t "git --version" 300 git --version
t "/usr/bin/git --version" 100 /usr/bin/git --version
t "git rev-parse HEAD" 300 git -C "$W/r" rev-parse HEAD
t "git status" 200 git -C "$W/r" status
t "git config --get" 200 git -C "$W/r" config --get user.name
t "existing stub script" 300 "$W/stub"
mk() { f="$W/s$i"; printf '#!/bin/sh\nexit 0\n' > "$f"; chmod +x "$f"; "$f"; }
t "fresh stub script (write+chmod+run)" 200 mk
t "mktemp -d" 200 mktemp -d "$W/m.XXXXXX"
gi() { git init -q "$W/g$RANDOM$$$i"; }
t "git init" 100 sh -c 'git init -q "$(mktemp -d '"$W"'/gi.XXXXXX)"'
t "git commit --allow-empty" 100 git -C "$W/r" commit -q --allow-empty -m y
t "python3 -c pass" 50 python3 -c pass
t "\$(...) subshell" 300 sh -c 'x=$(echo hi)'
echo "--- 3 concurrent git --version loops"
s=$(date +%s)
for k in 1 2 3; do ( i=0; while [ $i -lt 300 ]; do git --version >/dev/null; i=$((i+1)); done ) & done; wait
e=$(date +%s); echo "900 git --version in $((e-s)) s across 3 workers"
rm -rf "$W"
