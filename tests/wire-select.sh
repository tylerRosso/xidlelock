#!/bin/sh
# SPDX-License-Identifier: ISC

# The two requests the program makes, byte for byte, in order, and nothing else.
#
# After the connection setup:
#
#   QueryExtension         opcode 98, length 6 (the 8-byte request plus the
#                          16-byte name, in 4-byte units), name MIT-SCREEN-SAVER
#   ScreenSaverSelectInput the major opcode the server's reply named, minor 2,
#                          length 3, the root window from the setup reply
#                          (fakex's 0x000002a5), mask 1 (ScreenSaverNotifyMask)
#
# and then no request at all: the program only listens from there on. The
# opcode is the one the server assigned, never a constant, so the whole
# exchange is run twice, against the "ok" server (144) and the "moved" one
# (150). A program that hard-coded 144 would pass the first run only.

. "${srcdir=.}/tests/init.sh"

make_locker_

for mode in ok moved; do
	stop_fakex_
	start_fakex_ "$mode"

	start_xil_ "$PWD/locker"

	# End the run first: the server logs DISCONNECT once the socket closes, so
	# after that line the log is complete and cannot still be growing.
	kill -TERM "$xil_pid_"
	wait_xil_
	fakex_grep_ '^DISCONNECT$' || fail=1

	case $mode in
		ok)    major=144 ;;
		moved) major=150 ;;
	esac

	cat > expected <<EOF
SETUP authname=0 authdata=0
REQUEST opcode=98 length=6
QUERYEXTENSION name=MIT-SCREEN-SAVER
REQUEST opcode=$major length=3
SELECTINPUT minor=2 window=0x000002a5 mask=1
DISCONNECT
EOF

	grep -v '^LISTENING ' "$FAKEX_LOG" > actual
	compare expected actual || { warn_ "$ME_: in mode $mode"; fail=1; }
done

Exit $fail
