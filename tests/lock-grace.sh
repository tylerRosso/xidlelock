#!/bin/sh
# SPDX-License-Identifier: ISC

# With -g, the saver's own timeout runs the grace command first, and the lock
# comes when that ends.
#
# The grace command keeps the grace period's time, so the program keeps none,
# and waits for no Cycle event either: the X.Org server skips its saver checks
# while DPMS has the monitor powered down (os/WaitFor.c), so a lock waiting for
# one would never come.
#
# Pins:
#   1. the command runs through the shell, which splits its words; no locker
#      starts with it, and the locker starts once it has ended by itself, with
#      nothing on stderr,
#   2. an activation that starts a grace command starts no locker: the server
#      hangs up while the command runs, and once the program has exited, any
#      locker it started exists as a process. None may. The program also
#      stopped the command on its way out.
#
# Seen to fail with the timeout locking at once, with the command's end never
# locking, with the command run without the shell, as one word that names no
# file, with SIGTERM sent to the shell alone rather than its process group
# (the command outlived the program), and with the command left running when
# the program exits.

. "${srcdir=.}/tests/init.sh"

require_prog_ pgrep ps

make_locker_
make_grace_

# 1.
start_fakex_
start_xil_ -g "$PWD/grace one 'two words'" "$PWD/locker"

fakex_send_ on
retry_ 5 grace_started_ 1 || fail_ 'the grace command never started'

pid=$(grace_pid_ 1)
group=$(grace_group_ "$pid")

printf 'start %s [one] [two words]\n' "$pid" > expected
grep '^start ' grace.log > actual
compare expected actual || fail=1

test -e locker.log && { warn_ 'a locker ran with the grace command'; fail=1; }

release_grace_ "$group" || fail_ 'the ended grace command was never reaped'
retry_ 5 locker_started_ 1 ||
	fail_ 'no locker after the grace command ended'

test -s xil.err && { warn_ 'wrote to stderr'; cat xil.err >&2; fail=1; }

release_locker_ "$(locker_pid_ 1)" || fail=1

# 2.
stop_xil_
stop_fakex_
start_fakex_
rm -f locker.log grace.log

start_xil_ -g "$PWD/grace" "$PWD/locker"

fakex_send_ on
retry_ 5 grace_started_ 1 || fail_ 'the second grace command never started'

pid=$(grace_pid_ 1)

fakex_send_ hangup
wait_xil_

test "$xil_status_" -eq 1 ||
	{ warn_ "$ME_: hangup: expected exit 1, got $xil_status_"; fail=1; }

running=$(lockers_running_)

test "$running" -eq 0 ||
	{ warn_ "$ME_: $running locker(s) started with the grace command"; fail=1; }

test -e locker.log && { warn_ 'a locker ran:'; cat locker.log >&2; fail=1; }

retry_ 5 gone_ "$pid" ||
	{ warn_ 'the grace command outlived the program'; fail=1; }

Exit $fail
