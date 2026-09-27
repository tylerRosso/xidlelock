#!/bin/sh
# SPDX-License-Identifier: ISC

# A server that rejects the connection setup: the reason must be relayed.
#
# The setup reply carries the refusal as a counted string -- byte 0 of the
# 8-byte prefix is 0 (Failed), byte 1 is the reason length, the text follows.
#
# Pins: exit status exactly 1, the server's own reason relayed verbatim, and a
# single attempt: a refusal is final, and a reconnect loop would hammer the
# server instead of failing.

. "${srcdir=.}/tests/init.sh"

start_fakex_ refuse

returns_ 1 "$XIL" true > refuse.out 2> refuse.err ||
	{ cat refuse.err >&2; fail=1; }

expected='^xidlelock: the X server refused the connection:'
grep -q "$expected fakex refuses this connection\$" refuse.err ||
	{ warn_ 'the server reason was not relayed'; cat refuse.err >&2; fail=1; }

test -s refuse.out && { warn_ 'wrote to stdout'; fail=1; }

fakex_grep_ '^SETUP authname=0 authdata=0$' || fail=1

setups_=$(grep -c '^SETUP ' "$FAKEX_LOG")

test "$setups_" -eq 1 ||
	{ warn_ "connected $setups_ times, expected 1"; fail=1; }

Exit $fail
