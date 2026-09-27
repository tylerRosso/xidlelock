#!/bin/sh
# SPDX-License-Identifier: ISC

# Replies and events split across two writes must still be read whole.
#
# Nothing on a stream socket promises that a packet arrives in one read(2).
# fakex's "split" mode writes every reply and event as two halves, so the setup
# reply, the QueryExtension reply and every ScreenSaverNotify reach the
# program in pieces -- if the scheduler lets them.
#
# Two writes are not by themselves two reads: left alone, the server usually
# finishes both writes before the woken-up client runs, and the halves are back
# together by the time it reads. The second phase therefore pins both processes
# to one cpu and runs the server at nice 19, so the client preempts it between
# the two writes. It is skipped, with a warning, where taskset(1) or renice(1)
# cannot do that.
#
# Pins: each activation starts one locker, and the program never reports an
# error, however its packets were cut.

. "${srcdir=.}/tests/init.sh"

make_locker_

# rounds_ N -- N activation-and-release rounds against the running program.
rounds_ ()
{
	rounds_i_=1

	while test "$rounds_i_" -le "$1"; do
		fakex_send_ on

		if ! retry_ 5 locker_started_ "$rounds_i_"; then
			warn_ "$ME_: round $rounds_i_: no locker"
			cat xil.err >&2
			fail=1

			return
		fi

		release_locker_ "$(locker_pid_ "$rounds_i_")" || fail=1
		rounds_i_=$(( rounds_i_ + 1 ))
	done
}

# Phase 1: whatever the scheduler does with it.
start_fakex_ split
start_xil_ "$PWD/locker"
rounds_ 5
stop_xil_

test -s xil.err && { warn_ 'errors in phase 1:'; cat xil.err >&2; fail=1; }

# Phase 2: make the short reads actually happen.
stop_fakex_
start_fakex_ split
rm -f locker.log

if command -v taskset > /dev/null 2>&1 && command -v renice > /dev/null 2>&1 &&
	taskset -c 0 true > /dev/null 2>&1 &&
	renice -n 19 -p "$fakex_pid_" > /dev/null 2>&1 &&
	taskset -pc 0 "$fakex_pid_" > /dev/null 2>&1
then
	taskset -c 0 "$XIL" "$PWD/locker" > xil.out 2> xil.err &
	xil_pid_=$!

	fakex_grep_ '^SELECTINPUT ' || fail_ 'the pinned program never got going'

	rounds_ 5

	test -s xil.err && { warn_ 'errors in phase 2:'; cat xil.err >&2; fail=1; }
else
	warn_ "$ME_: cannot pin to one cpu; the short reads stayed a coin flip"
fi

Exit $fail
