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
# connection and for one that is killed outright; and for one that closes it
# instead of answering QueryExtension, the same, as the only line on stderr.
#
# The last was seen to fail with the diagnostic taken out of the wait for the
# QueryExtension reply (exit 1 without a word), and with that wait returning
# success on the end of the stream (a second diagnostic, for the selection
# that followed). The gap was present since the initial import, 7a20770.

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

# 3. The server hangs up instead of answering QueryExtension. Started without
# start_xil_: a program that makes no selection never reaches its barrier.
start_fakex_ queryhangup

"$XIL" "$PWD/locker" > xil.out 2> xil.err &
xil_pid_=$!
wait_xil_

test "$xil_status_" -eq 1 ||
	{ warn_ "$ME_: no reply: expected exit 1, got $xil_status_"; fail=1; }

grep -q "$expected" xil.err ||
	{ warn_ 'no diagnostic for a hangup before the reply'; fail=1; }

test "$(wc -l < xil.err)" -eq 1 ||
	{ warn_ 'expected one line on stderr'; cat xil.err >&2; fail=1; }

fakex_grep_ '^QUERYEXTENSION ' || fail=1

Exit $fail
