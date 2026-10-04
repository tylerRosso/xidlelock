#!/bin/sh
# SPDX-License-Identifier: ISC

# A forced activation locks at once, grace command or not.
#
# The server sets the forced byte for `xset s activate` and for DPMS powering
# the monitor down. The first is a lock asked for now; after the second, the
# saver is on with the monitor off, and the X.Org server sends no further
# event then (os/WaitFor.c).
#
# Pins:
#   1. with no grace period under way, the locker starts and the grace command
#      does not,
#   2. during a grace period, the locker starts without waiting for the
#      command, which is stopped.
#
# Seen to fail with forced activations given a grace period like the
# timeout's, with one leaving the command running, and with SIGTERM sent to
# the shell alone.

. "${srcdir=.}/tests/init.sh"

require_prog_ ps

make_locker_
make_grace_

# 1.
start_fakex_
start_xil_ -g "$PWD/grace" "$PWD/locker"

fakex_send_ forced
retry_ 5 locker_started_ 1 || fail_ 'a forced activation did not lock'

test -e grace.log &&
	{ warn_ 'a grace command ran:'; cat grace.log >&2; fail=1; }

release_locker_ "$(locker_pid_ 1)" || fail=1

# 2.
fakex_send_ on
retry_ 5 grace_started_ 1 || fail_ 'the grace command never started'

pid=$(grace_pid_ 1)
group=$(grace_group_ "$pid")

fakex_send_ forced
retry_ 5 locker_started_ 2 || fail_ 'no lock at once during the grace period'

retry_ 5 gone_ "$pid" || { warn_ 'the grace command was not stopped'; fail=1; }
retry_ 5 gone_ "$group" ||
	{ warn_ 'the stopped grace command was never reaped'; fail=1; }

release_locker_ "$(locker_pid_ 2)" || fail=1

Exit $fail
