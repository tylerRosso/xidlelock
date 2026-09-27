#!/bin/sh
# SPDX-License-Identifier: ISC

# A locker that cannot be run is reported on every activation, and the program
# keeps listening.
#
# posix_spawnp reports the failed exec to the caller, so the message carries
# the real reason. Exiting instead would be worse: the one thing this program
# is for would then stop quietly, where a message on each activation keeps the
# failure in front of the user until the command line is fixed.
#
# Pins: the reason text for a name not on PATH and for a file that is not
# executable, one line per activation, and no exit in between.

. "${srcdir=.}/tests/init.sh"

# errors_ N -- true once stderr holds exactly N lines.
errors_ ()
{
	test "$(wc -l < xil.err)" -eq "$1"
}

name=xidlelock-test-no-such-locker

command -v "$name" > /dev/null 2>&1 && skip_ "$name is on PATH"

start_fakex_
start_xil_ "$name"

fakex_send_ on
retry_ 5 errors_ 1 || { warn_ 'no message for the first activation'; fail=1; }

fakex_send_ on
retry_ 5 errors_ 2 || { warn_ 'no message for the second activation'; fail=1; }

cat > expected.err <<EOF
xidlelock: cannot run '$name': No such file or directory
xidlelock: cannot run '$name': No such file or directory
EOF

compare expected.err xil.err || fail=1

stop_xil_

# A file that exists but may not be executed.
printf '#!/bin/sh\nexit 0\n' > noexec
chmod 644 noexec

stop_fakex_
start_fakex_
start_xil_ "$PWD/noexec"

fakex_send_ on
retry_ 5 errors_ 1 ||
	{ warn_ 'no message for a non-executable locker'; fail=1; }

printf '%s\n' "xidlelock: cannot run '$PWD/noexec': Permission denied" \
	> expected.err
compare expected.err xil.err || fail=1

Exit $fail
