#!/bin/sh
# SPDX-License-Identifier: ISC

# A DISPLAY the transport rejects stops the program before anything else.
#
# The parser is xwire.h's and is tested in full where that file is maintained.
# What is pinned here is this program's use of it: it is handed $DISPLAY, and a
# refusal means exit 1 with exactly the parser's message on stderr -- not a
# connection attempt, not a crash, not a second message.

. "${srcdir=.}/tests/init.sh"

# check_ MESSAGE -- run with the DISPLAY currently in the environment and assert
# exit 1 with exactly MESSAGE, and nothing else, on stderr.
check_ ()
{
	printf '%s\n' "$1" > expected.err

	returns_ 1 "$XIL" true 2> actual.err || fail=1
	compare expected.err actual.err || fail=1
}

unset DISPLAY
check_ "xidlelock: DISPLAY is not set."

DISPLAY='host:0'
export DISPLAY
check_ "xidlelock: only local displays are supported, got 'host:0'."

DISPLAY=':abc'
check_ "xidlelock: malformed display number in ':abc'."

Exit $fail
