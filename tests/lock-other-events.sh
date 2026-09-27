#!/bin/sh
# SPDX-License-Identifier: ISC

# Only the saver turning ON locks. Off, Cycle and core events do not.
#
# Off (0) arrives every time the user comes back, so locking on it would lock
# the screen the moment it was unlocked. Cycle (2) is the saver changing its
# picture. MappingNotify (34) is a core event every client receives unasked.
#
# Proving that something did NOT happen needs a point after which it would have:
# the server hangs up once the three events are sent, the program reads all
# three before it sees the end of the stream and exits, and posix_spawn does not
# return before the exec -- so once the program has exited, any locker it
# started exists as a process. None may.

. "${srcdir=.}/tests/init.sh"

require_prog_ pgrep

start_fakex_
make_locker_

start_xil_ "$PWD/locker"

for event in off cycle mapping; do
	fakex_send_ $event
	fakex_grep_ "^SENT $event\$" || fail=1
done

fakex_send_ hangup
wait_xil_

test "$xil_status_" -eq 1 ||
	{ warn_ "$ME_: expected exit 1 after the hangup, got $xil_status_"; fail=1; }

running=$(lockers_running_)

test "$running" -eq 0 ||
	{ warn_ "$ME_: $running locker(s) started by a non-activation"; fail=1; }

test -e locker.log && { warn_ 'a locker ran:'; cat locker.log >&2; fail=1; }

Exit $fail
