#!/bin/sh
# SPDX-License-Identifier: ISC

# `--` ends the options, so a locker whose name begins with '-' can be named.
#
# Pins: without --, such a name is an unknown option (exit 1, before any
# connection is made); after --, it is found on PATH and run.

. "${srcdir=.}/tests/init.sh"

start_fakex_

# The ./ keeps chmod from reading the name as an option; the program is given
# the bare name and finds it on PATH.
make_locker_ ./-dashed
PATH="$PWD:$PATH"
export PATH

returns_ 1 "$XIL" -dashed > plain.out 2> plain.err || fail=1
grep -q "^xidlelock: unknown option '-dashed'\.\$" plain.err || {
	warn_ 'a dash-led name was not refused without --'
	cat plain.err >&2
	fail=1
}
fakex_not_grep_ '^SETUP ' || fail=1

start_xil_ -- -dashed

fakex_send_ on
retry_ 5 locker_started_ 1 || fail_ 'the -- locker never started'

release_locker_ "$(locker_pid_ 1)" || fail=1

Exit $fail
