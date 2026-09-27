#!/bin/sh
# SPDX-License-Identifier: ISC

# One locker at a time, and a new one as soon as the last has gone.
#
# The saver activates again while the screen is still locked -- walk away from
# a locked screen and it times out once more -- so activations must not stack
# lockers. A second slock cannot grab the keyboard and exits with an error;
# another locker might stack a second lock on the first.
#
# Pins:
#   - two activations while the locker runs start nothing,
#   - an exited locker is REAPED at once, by the SIGCHLD that interrupts the
#     wait -- not at the next activation, which may be hours away and would
#     leave a zombie until then (release_locker_ waits for the pid to vanish),
#   - after that, the next activation starts a new locker.
#
# The final count is taken from the running processes as well as from the log:
# a stacked locker would still be running when the second legitimate one
# starts.

. "${srcdir=.}/tests/init.sh"

require_prog_ pgrep

start_fakex_
make_locker_

start_xil_ "$PWD/locker"

fakex_send_ on
retry_ 5 locker_started_ 1 || fail_ 'the first activation started no locker'

first=$(locker_pid_ 1)

fakex_send_ on
fakex_send_ on

release_locker_ "$first" ||
	fail_ "the exited locker $first was not reaped without a further event"

fakex_send_ on
retry_ 5 locker_started_ 2 ||
	{ warn_ 'no new locker after the first was gone'; cat locker.log >&2; fail=1; }

running=$(lockers_running_)

test "$running" -eq 1 ||
	{ warn_ "$ME_: $running lockers running, expected 1"; fail=1; }

starts=$(grep -c '^start ' locker.log)

test "$starts" -eq 2 ||
	{ warn_ "$ME_: $starts lockers started, expected 2"; fail=1; }

test "$fail" -eq 0 || cat locker.log >&2

second=$(locker_pid_ 2)
test -n "$second" && { release_locker_ "$second" || fail=1; }

Exit $fail
