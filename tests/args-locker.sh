#!/bin/sh
# SPDX-License-Identifier: ISC

# Everything from the first operand on is the locker's command line, verbatim.
#
# Pins: each argument reaches the locker as one word, in order -- an empty one,
# one with a space, a glob that no shell may expand, and three that look like
# options. The -h and -v AFTER the locker's name are the locker's: they must be
# passed through, not answered with this program's usage or version -- slock
# itself takes -v. Option parsing stops at the first operand, so -- after it is
# passed through too.

. "${srcdir=.}/tests/init.sh"

start_fakex_
make_locker_

start_xil_ "$PWD/locker" -h -v '' 'two words' '*' --

fakex_send_ on
retry_ 5 locker_started_ 1 || fail_ 'the locker never started'

pid=$(locker_pid_ 1)
printf 'start %s [-h] [-v] [] [two words] [*] [--]\n' "$pid" > expected
grep '^start ' locker.log > actual
compare expected actual || fail=1

test -s xil.out &&
	{ warn_ 'the program wrote to stdout'; cat xil.out >&2; fail=1; }

release_locker_ "$pid" || fail=1

Exit $fail
