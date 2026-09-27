#!/bin/sh
# SPDX-License-Identifier: ISC

# The server going away while the program waits ends it, at once, with exit 1.
#
# ppoll reports a closed socket as readable for ever. A program that did not
# treat the end of the stream as final would spin at full speed on a dead
# server -- or, if it also ignored the failed read, sit there as a locker that
# will never lock. wait_xil_ kills a program that is still around after five
# seconds, which turns either into a failure (137).
#
# Pins: exit status exactly 1, and the diagnostic, for a server that closes the
# connection and for one that is killed outright.

. "${srcdir=.}/tests/init.sh"

make_locker_

# 1. The server hangs up.
start_fakex_
start_xil_ "$PWD/locker"

fakex_send_ hangup
wait_xil_

test "$xil_status_" -eq 1 ||
	{ warn_ "$ME_: hangup: expected exit 1, got $xil_status_"; fail=1; }

expected='^xidlelock: the X server closed the connection: '
grep -q "$expected" xil.err ||
	{ warn_ 'no diagnostic for a hangup'; cat xil.err >&2; fail=1; }

# 2. The server dies.
stop_fakex_
start_fakex_
start_xil_ "$PWD/locker"

kill -KILL "$fakex_pid_"
wait "$fakex_pid_" 2> /dev/null
fakex_pid_=

wait_xil_

test "$xil_status_" -eq 1 ||
	{ warn_ "$ME_: killed server: expected exit 1, got $xil_status_"; fail=1; }

grep -q "$expected" xil.err ||
	{ warn_ 'no diagnostic for a dead server'; cat xil.err >&2; fail=1; }

# fakex was killed before it could remove its socket.
rm -f "/tmp/.X11-unix/X${DISPLAY#:}"

Exit $fail
