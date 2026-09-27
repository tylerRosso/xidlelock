#!/bin/sh
# SPDX-License-Identifier: ISC

# With no LOCKER, the program runs `slock`, looked up on PATH, with no
# arguments.
#
# SAFETY: the slock run here is a stand-in written into this test's directory
# and put first on PATH. The real one must never run from the suite, so the
# lookup is checked before the program starts: a PATH on which `slock` still
# resolves anywhere else is a set-up failure, not something to try.

. "${srcdir=.}/tests/init.sh"

start_fakex_
make_locker_ slock

PATH="$PWD:$PATH"
export PATH

test "x$(command -v slock)" = "x$PWD/slock" ||
	framework_failure_ "slock resolves to $(command -v slock), not the stand-in"

start_xil_

fakex_send_ on
retry_ 5 locker_started_ 1 || fail_ 'slock never started'

grep -q '^start [0-9]*$' locker.log ||
	{ warn_ 'slock was given arguments'; cat locker.log >&2; fail=1; }

release_locker_ "$(locker_pid_ 1)" || fail=1

Exit $fail
