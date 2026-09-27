#!/bin/sh
# SPDX-License-Identifier: ISC

# The screen saver turning on starts the locker; nothing before that does.
#
# Pins:
#   - no locker at startup: selecting the events is not an activation,
#   - one ScreenSaverNotify with state On (1) starts exactly one locker,
#   - the event is recognised by the code the server's QueryExtension reply
#     assigned it, not by a constant: the "moved" server puts it at 95 instead
#     of 91, and a program that hard-coded 91 would never lock there.

. "${srcdir=.}/tests/init.sh"

require_prog_ pgrep

make_locker_

for mode in ok moved; do
	stop_fakex_
	start_fakex_ "$mode"
	rm -f locker.log

	start_xil_ "$PWD/locker"

	# posix_spawn does not return before the exec has happened, so a locker
	# started at startup would already be a process by now.
	test "$(lockers_running_)" -eq 0 ||
		{ warn_ "$ME_: $mode: a locker is running before any activation"; fail=1; }

	fakex_send_ on
	fakex_grep_ '^SENT on$' || fail=1

	if retry_ 5 locker_started_ 1; then
		release_locker_ "$(locker_pid_ 1)" || fail=1
	else
		warn_ "$ME_: $mode: the activation started no locker"
		cat xil.err >&2
		fail=1
	fi

	stop_xil_
done

Exit $fail
