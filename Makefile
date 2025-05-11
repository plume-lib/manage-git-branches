default: style-check

style-fix: shell-style-fix

style-check: shell-style-check

SH_SCRIPTS = $(shell grep -r -l '^\#! \?\(/bin/\|/usr/bin/env \)sh' * | grep -v /.git/ | grep -v '~$$' | grep -v gradlew)
BASH_SCRIPTS = $(shell grep -r -l '^\#! \?\(/bin/\|/usr/bin/env \)bash' * | grep -v /.git/ | grep -v '~$$')

shell-style-fix:
	shfmt -w -i 2 -ci -bn -sr ${SH_SCRIPTS} ${BASH_SCRIPTS}
	shellcheck -x -P SCRIPTDIR --format=diff ${SH_SCRIPTS} ${BASH_SCRIPTS} | patch -p1

shell-style-check:
	shfmt -d -i 2 -ci -bn -sr ${SH_SCRIPTS} ${BASH_SCRIPTS}
	shellcheck -x -P SCRIPTDIR --format=gcc ${SH_SCRIPTS} ${BASH_SCRIPTS}
	checkbashisms -l ${SH_SCRIPTS}

showvars:
	@echo "SH_SCRIPTS=${SH_SCRIPTS}"
	@echo "BASH_SCRIPTS=${BASH_SCRIPTS}"
