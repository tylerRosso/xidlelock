#!/bin/sh
# SPDX-License-Identifier: ISC

# SIGTERM, SIGINT and SIGHUP end the program cleanly -- and leave the screen
# locked.
#
# Pins, for each signal, with a locker running:
#   - exit status 0. `wait` reports 128+signal (143, 130, 129) for a process
#     that DIED of the signal, so 0 is a real assertion. SIGINT is the sharp
#     one: POSIX has the shell ignore it in a background child, so only a
#     handler installed unconditionally sees it at all,
#   - the program was parked in ppoll with the signals blocked everywhere else,
#     so the wait itself must be what the signal ends; a mask that never let
#     them through would leave the program running until wait_xil_ kills it
#     (137). The wait unblocks them even when the program was STARTED with them
#     blocked, so each signal is also tried on a program started that way,
#     where env(1) can do it,
#   - the locker is still running afterwards and was not signalled: stopping
#     this program must never unlock the screen.

. "${srcdir=.}/tests/init.sh"

make_locker_

cases="TERM INT HUP"
can_block_ && cases="$cases TERM:blocked INT:blocked HUP:blocked"

for case_ in $cases; do
	sig=${case_%:*}

	stop_fakex_
	start_fakex_
	rm -f locker.log

	if test "$case_" = "$sig"; then
		start_xil_ "$PWD/locker"
	else
		start_via_ env --block-signal="$sig" "$XIL" "$PWD/locker"
	fi

	fakex_send_ on

	if ! retry_ 5 locker_started_ 1; then
		warn_ "$ME_: $case_: the locker never started"
		fail=1
		stop_xil_

		continue
	fi

	pid=$(locker_pid_ 1)

	kill -"$sig" "$xil_pid_"
	wait_xil_

	test "$xil_status_" -eq 0 ||
		{ warn_ "$ME_: $case_: expected exit 0, got $xil_status_"; fail=1; }

	kill -0 "$pid" 2> /dev/null ||
		{ warn_ "$ME_: $case_: the signal ended the locker too"; fail=1; }
	grep -q '^exit ' locker.log &&
		{ warn_ "$ME_: $case_: the locker exited"; fail=1; }

	# Its parent is gone, so whoever adopted it reaps it.
	release_locker_ "$pid" || fail=1
done

Exit $fail
