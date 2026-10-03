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
# once.
#
# Pins: exit status exactly 1, the diagnostic, nothing on stdout, and that the
# server read nothing after the setup.
#
# Seen to fail with SIGPIPE ignored after QueryExtension again, as it was
# (exit 141). The bug was present since the initial import, 7a20770.

. "${srcdir=.}/tests/init.sh"

start_fakex_ deaf

returns_ 1 "$XIL" true > deaf.out 2> deaf.err || fail=1

expected="^xidlelock: cannot query the X server's extensions: "
grep -q "$expected" deaf.err ||
	{ warn_ 'no diagnostic for EPIPE'; cat deaf.err >&2; fail=1; }

test -s deaf.out && { warn_ 'wrote to stdout'; fail=1; }

fakex_grep_ '^SETUP ' || fail=1
fakex_not_grep_ '^REQUEST ' || fail=1

Exit $fail
