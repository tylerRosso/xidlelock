#!/bin/sh
# SPDX-License-Identifier: ISC

# A server that goes away during the setup is diagnosed with exit 1, like one
# that goes away later.
#
# A write to a connection the server has closed raises SIGPIPE, whose default
# action ends the program without a word. The program ignored it only after
# QueryExtension, so a server that went away between the connection setup and
# that request killed it: exit status 141, nothing on stderr. fakex's deaf mode
# stops reading before it answers the setup, so the QueryExtension write fails
# with EPIPE every time; a server that closed after answering would race that
# write, and the program would sometimes read the end of the stream instead.
# The setup request itself cannot be failed on cue: it follows the connect at
# once. querydeaf does the same one step later, before it answers
# QueryExtension, so the write that fails is the event selection's.
#
# Pins, for each: exit status exactly 1, the diagnostic as the only line on
# stderr, nothing on stdout, and that the server read nothing after the step
# it answered.
#
# 1 was seen to fail with SIGPIPE ignored after QueryExtension again, as it was
# (exit 141). The bug was present since the initial import, 7a20770. Its check
# for one line was seen to fail with the failed QueryExtension write going on
# to wait for the reply (a second diagnostic, for the end of the stream), a
# gap present since the initial import too.
#
# 2 was seen to fail with the diagnostic taken out of the selection's write
# (exit 1 without a word), and with that write returning success when it
# failed (a second diagnostic, for the end of the stream the program went on
# to read). The gap was present since the initial import.

. "${srcdir=.}/tests/init.sh"

# deaf_ MODE EXPECTED -- run the program against fakex in MODE, and check that
# it exits 1 with one line on stderr, matching EXPECTED.
deaf_ ()
{
	stop_fakex_
	start_fakex_ "$1"

	returns_ 1 "$XIL" true > deaf.out 2> deaf.err || fail=1

	grep -q "$2" deaf.err ||
		{ warn_ "$1: no diagnostic for EPIPE"; cat deaf.err >&2; fail=1; }

	test "$(wc -l < deaf.err)" -eq 1 ||
		{ warn_ "$1: expected one line on stderr"; cat deaf.err >&2; fail=1; }

	test -s deaf.out && { warn_ "$1: wrote to stdout"; fail=1; }
}

# 1.
deaf_ deaf "^xidlelock: cannot query the X server's extensions: "

fakex_grep_ '^SETUP ' || fail=1
fakex_not_grep_ '^REQUEST ' || fail=1

# 2.
deaf_ querydeaf '^xidlelock: cannot select the screen saver events: '

fakex_grep_ '^QUERYEXTENSION ' || fail=1

requests=$(grep -c '^REQUEST ' "$FAKEX_LOG")
test "$requests" -eq 1 ||
	{ warn_ "$ME_: expected 1 request, the server logged $requests"; fail=1; }

Exit $fail
