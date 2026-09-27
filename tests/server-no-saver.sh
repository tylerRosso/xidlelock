#!/bin/sh
# SPDX-License-Identifier: ISC

# A server without MIT-SCREEN-SAVER is diagnosed, not waited on for ever.
#
# Without the extension there is no event to wait for, and a program that
# carried on would sit there looking like a working locker that never locks.
#
# Pins: exit status exactly 1, a message naming the extension, and no request
# after the QueryExtension that found it missing -- in particular no
# ScreenSaverSelectInput sent to an opcode the server never assigned.

. "${srcdir=.}/tests/init.sh"

start_fakex_ nosaver

returns_ 1 "$XIL" true > absent.out 2> absent.err || fail=1

printf '%s\n' \
	'xidlelock: the X server does not support the MIT-SCREEN-SAVER extension.' \
	> expected.err
compare expected.err absent.err || fail=1

test -s absent.out && { warn_ 'wrote to stdout'; fail=1; }

fakex_grep_ '^QUERYEXTENSION name=MIT-SCREEN-SAVER$' || fail=1
fakex_grep_ '^DISCONNECT$' || fail=1

requests=$(grep -c '^REQUEST ' "$FAKEX_LOG")
test "$requests" -eq 1 ||
	{ warn_ "$ME_: expected 1 request, the server logged $requests"; fail=1; }

Exit $fail
