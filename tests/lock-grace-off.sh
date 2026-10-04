#!/bin/sh
# SPDX-License-Identifier: ISC

# The saver turning off before the grace command has ended stops it, and
# nothing locks: the user came back during the grace period.
#
# Pins:
#   1. Off stops the command -- all of it, whatever the shell runs it as --
#      and the program reaps it, without a word about the signal it died of.
#      No locker starts: the server hangs up after that, and once the program
#      has exited, any locker it started exists as a process. None may,
#   2. a command that ignores SIGTERM goes on running after an Off, and the
#      next timeout finds it there: that locks at once, beside no second
#      command. A second would leave the lock to a grace period that may never
#      end, and the saver, still on, sends no further activation.
#
# Seen to fail with Off ignored, with SIGTERM sent to the shell alone (the
# command ran on), with a stopped command's end locking all the same, with the
# signal it died of reported, and, in 2, with the timeout that found the
# command still there starting a second one.

. "${srcdir=.}/tests/init.sh"

require_prog_ pgrep ps

make_locker_
make_grace_

# 1.
start_fakex_
start_xil_ -g "$PWD/grace" "$PWD/locker"

fakex_send_ on
retry_ 5 grace_started_ 1 || fail_ 'the grace command never started'

pid=$(grace_pid_ 1)
group=$(grace_group_ "$pid")

fakex_send_ off

retry_ 5 gone_ "$pid" || { warn_ 'the grace command was not stopped'; fail=1; }
retry_ 5 gone_ "$group" ||
	{ warn_ 'the stopped grace command was never reaped'; fail=1; }

fakex_send_ hangup
wait_xil_

test "$xil_status_" -eq 1 ||
	{ warn_ "$ME_: hangup: expected exit 1, got $xil_status_"; fail=1; }

running=$(lockers_running_)

test "$running" -eq 0 ||
	{ warn_ "$ME_: $running locker(s) started after the Off"; fail=1; }

test -e locker.log && { warn_ 'a locker ran:'; cat locker.log >&2; fail=1; }

# The command it stopped died of the signal, which is not worth a word: the
# one line is the hangup's.
test "$(wc -l < xil.err)" -eq 1 ||
	{ warn_ 'expected one line on stderr'; cat xil.err >&2; fail=1; }

# 2. The ignored signal survives the exec into the stand-in.
stop_fakex_
start_fakex_
rm -f grace.log

start_xil_ -g "trap '' TERM; exec '$PWD/grace'" "$PWD/locker"

fakex_send_ on
retry_ 5 grace_started_ 1 || fail_ 'the stubborn grace command never started'

pid=$(grace_pid_ 1)
group=$(grace_group_ "$pid")

fakex_send_ off
fakex_send_ on

retry_ 5 locker_started_ 1 ||
	fail_ 'no lock with the grace command still there after the Off'

grace_started_ 1 ||
	{ warn_ 'a second grace command started'; cat grace.log >&2; fail=1; }

release_grace_ "$group" || fail_ 'the ended grace command was never reaped'
release_locker_ "$(locker_pid_ 1)" || fail=1

Exit $fail
