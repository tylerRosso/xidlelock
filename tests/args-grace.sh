#!/bin/sh
# SPDX-License-Identifier: ISC

# The grace command is given as -g COMMAND, --grace COMMAND or
# --grace=COMMAND, and an option missing it is refused.
#
# Pins:
#   1. -g and --grace with nothing after them: exit 1, the message naming the
#      option, the usage on stderr, and nothing on stdout. No server runs
#      here: a program that took the missing argument for an empty one would
#      try the display and say something else,
#   2. each spelling runs the grace command on an activation.
#
# Seen to fail with --grace= and --grace each unknown, with --grace='s value
# taken from the wrong offset, and with the check for a missing argument taken
# out: the program ran on without a grace command and tried the display.

. "${srcdir=.}/tests/init.sh"

# 1.
for option in -g --grace; do
	returns_ 1 "$XIL" "$option" > bare.out 2> bare.err || fail=1

	grep -q "^xidlelock: option '$option' requires an argument\.\$" bare.err ||
		{ warn_ "no message for a bare $option"; cat bare.err >&2; fail=1; }
	grep -q '^Usage: xidlelock ' bare.err ||
		{ warn_ "no usage on stderr after a bare $option"; fail=1; }
	test -s bare.out && { warn_ "a bare $option wrote to stdout"; fail=1; }
done

# 2.
make_locker_
make_grace_

for spelling in -g --grace --grace=; do
	stop_xil_
	stop_fakex_
	start_fakex_
	rm -f grace.log

	case $spelling in
		*=) start_xil_ "$spelling$PWD/grace" "$PWD/locker" ;;
		*)  start_xil_ "$spelling" "$PWD/grace" "$PWD/locker" ;;
	esac

	fakex_send_ on
	retry_ 5 grace_started_ 1 ||
		{ warn_ "$spelling: the grace command never started"; fail=1; }
done

Exit $fail
