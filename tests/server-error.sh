#!/bin/sh
# SPDX-License-Identifier: ISC

# An X error ends the program with the error code, whenever it arrives.
#
# Nothing is requested after setup, so an error can only mean the event
# selection failed or the server has lost track of this client. Either way no
# lock will ever come, and carrying on would look like working. An error
# answering QueryExtension leaves no opcode to select under.
#
# Pins, with the code as a literal -- the program prints whatever the server
# said:
#   1. an error answering ScreenSaverSelectInput (fakex "error" mode, code 9):
#      exit 1, the code on stderr, and no locker started,
#   2. an error that arrives later, while the program waits (code 17): exit 1
#      and the code,
#   3. an error answering QueryExtension (fakex "queryerror" mode, code 11):
#      exit 1, the code, and no selection made.
#
# 3 was seen to fail with the test for an error taken out of the wait for the
# QueryExtension reply: the program skipped the error as an event and waited
# for a reply that never came, until wait_xil_ killed it (137). The gap was
# present since the initial import, 7a20770.

. "${srcdir=.}/tests/init.sh"

make_locker_

# 1.
start_fakex_ error
start_xil_ "$PWD/locker"

wait_xil_

test "$xil_status_" -eq 1 ||
	{ warn_ "$ME_: a failed selection exited $xil_status_, not 1"; fail=1; }

grep -q '^xidlelock: the X server returned error code 9\.$' xil.err ||
	{ warn_ 'the selection error was not reported'; cat xil.err >&2; fail=1; }

test -e locker.log && { warn_ 'a locker ran'; cat locker.log >&2; fail=1; }

# 2.
stop_fakex_
start_fakex_
start_xil_ "$PWD/locker"

fakex_send_ error
wait_xil_

test "$xil_status_" -eq 1 ||
	{ warn_ "$ME_: a later error exited $xil_status_, not 1"; fail=1; }

grep -q '^xidlelock: the X server returned error code 17\.$' xil.err ||
	{ warn_ 'the later error was not reported'; cat xil.err >&2; fail=1; }

# 3. Started without start_xil_: a program that makes no selection never
# reaches its barrier.
stop_fakex_
start_fakex_ queryerror

"$XIL" "$PWD/locker" > xil.out 2> xil.err &
xil_pid_=$!
wait_xil_

test "$xil_status_" -eq 1 ||
	{ warn_ "$ME_: a QueryExtension error exited $xil_status_, not 1"; fail=1; }

grep -q '^xidlelock: the X server returned error code 11\.$' xil.err ||
	{ warn_ 'the query error was not reported'; cat xil.err >&2; fail=1; }

# The server reads everything the program wrote before the end of the stream.
fakex_grep_ '^DISCONNECT$' || fail=1
fakex_not_grep_ '^SELECTINPUT ' || fail=1

Exit $fail
