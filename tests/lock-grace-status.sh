#!/bin/sh
# SPDX-License-Identifier: ISC

# A grace command that ends badly is reported, and the lock comes all the same.
#
# The grace period only delays the lock; the lock is what matters. A command
# that failed, or that cannot be found, must not cost it, and must not pass in
# silence either.
#
# Pins, each with the locker started after it and the report on stderr in the
# form the locker's has, with the command as given:
#   1. a grace command that exits with status 3,
#   2. one the shell cannot find, which exits 127 by POSIX.
#
# Seen to fail with the command's end never locking, and with it never
# reported.

. "${srcdir=.}/tests/init.sh"

require_prog_ ps

make_locker_
make_grace_ 3

# 1.
start_fakex_
start_xil_ -g "$PWD/grace" "$PWD/locker"

fakex_send_ on
retry_ 5 grace_started_ 1 || fail_ 'the grace command never started'

release_grace_ "$(grace_group_ "$(grace_pid_ 1)")" ||
	fail_ 'the ended grace command was never reaped'
retry_ 5 locker_started_ 1 || fail_ 'no lock after a failed grace command'

printf "xidlelock: '%s' exited with status 3.\n" "$PWD/grace" > expected.err
compare expected.err xil.err || fail=1

release_locker_ "$(locker_pid_ 1)" || fail=1

# 2. The shell's own complaint goes to stderr too; only the program's is
# compared.
stop_xil_
stop_fakex_
start_fakex_
rm -f locker.log

missing=$PWD/no-such-command
start_xil_ -g "$missing" "$PWD/locker"

fakex_send_ on
retry_ 5 locker_started_ 1 || fail_ 'no lock after a grace command not found'

printf "xidlelock: '%s' exited with status 127.\n" "$missing" > expected.err
grep '^xidlelock: ' xil.err > actual.err
compare expected.err actual.err || fail=1

release_locker_ "$(locker_pid_ 1)" || fail=1

Exit $fail
