#!/bin/sh
# SPDX-License-Identifier: ISC

# An activation with the SendEvent bit set locks like any other.
#
# The top bit of an event's code (0x80) only says the event came through a
# SendEvent request; the low seven bits are the event. libX11 and xcb clients
# both mask it off. Compared unmasked, 91 | 0x80 = 219 matches nothing and the
# activation is silently ignored.
#
# Locking on an event another client forged is harmless: any client can start
# the saver with ForceScreenSaver (what `xset s activate` sends) anyway, and the
# worst it can achieve is a locked screen.

. "${srcdir=.}/tests/init.sh"

start_fakex_
make_locker_

start_xil_ "$PWD/locker"

fakex_send_ sent
fakex_grep_ '^SENT sent$' || fail=1

retry_ 5 locker_started_ 1 ||
	fail_ 'a SendEvent activation started no locker'

release_locker_ "$(locker_pid_ 1)" || fail=1

Exit $fail
