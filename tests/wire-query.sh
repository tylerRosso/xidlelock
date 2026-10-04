#!/bin/sh
# SPDX-License-Identifier: ISC

# Events that arrive ahead of the QueryExtension reply are skipped, however
# many there are, and the reply is read after them.
#
# A server sends MappingNotify to every client, selected or not, so one can
# arrive while the program waits for its reply. fakex's early mode sends two
# ahead of the reply, so a program that skipped only one would read the second
# in its place. Read as the reply, a MappingNotify's byte 8, which is zero,
# says the extension is absent.
#
# Pins: both events went out, and the program then selected the events
# under the opcode the reply named -- the readiness barrier, SELECTINPUT, is
# logged only for opcode 144 -- and locks on an activation.
#
# Seen to fail with the loop's test for a reply made a test for anything but
# an error, and with the loop cut to two reads: each read a MappingNotify as
# the reply and exited 1, saying the server lacks MIT-SCREEN-SAVER. The gap was
# present since the initial import, 7a20770.

. "${srcdir=.}/tests/init.sh"

start_fakex_ early
make_locker_
start_xil_ "$PWD/locker"

sent=$(grep -c '^SENT mapping$' "$FAKEX_LOG")
test "$sent" -eq 2 ||
	{ warn_ "$ME_: fakex sent $sent events ahead of the reply, not 2"; fail=1; }

fakex_send_ on
retry_ 5 locker_started_ 1 || fail_ 'the locker never started'

release_locker_ "$(locker_pid_ 1)" || fail=1

Exit $fail
