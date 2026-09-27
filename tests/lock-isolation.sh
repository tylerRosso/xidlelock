#!/bin/sh
# SPDX-License-Identifier: ISC

# The locker starts in a session of its own, with the signal state this program
# was started with.
#
# Pins, read from /proc, so the test is skipped where there is none:
#   - own session: the locker is a session leader (session id = pid). A Ctrl-C
#     in the terminal this program was started from, or a hangup of it, goes to
#     this program's process group; in that group the locker would die of it,
#     and a dead locker is an unlocked screen,
#   - signal mask: the program blocks SIGINT, SIGTERM, SIGHUP and SIGCHLD
#     outside its wait, and a mask survives exec. The locker must get the mask
#     the program was STARTED with. The program is started with SIGQUIT blocked
#     (when env(1) can do that), so the right mask is recognisably not empty and
#     not the program's working one either,
#   - SIGPIPE: the program ignores it, and an ignored signal survives exec too.
#     The locker must get the default action back (bit 12 of SigIgn clear).
#
# The locker is sleep(1), not a script: the shell clears its signal mask when it
# starts, which would hide what it was given.

. "${srcdir=.}/tests/init.sh"

test -r /proc/self/status || skip_ 'no /proc/self/status'
require_prog_ pgrep

# sig_field_ PID NAME -- one hex mask line from /proc/PID/status.
sig_field_ ()
{
	sed -n "s/^$2:[[:space:]]*//p" "/proc/$1/status"
}

test $(( 0x$(sig_field_ $$ SigIgn) & 0x1000 )) -eq 0 ||
	skip_ 'this shell already ignores SIGPIPE, so there is nothing to restore'

# A failed test would otherwise leave sleep running for up to 30 seconds, in a
# session that no signal to the test reaches.
pid=
cleanup_ () { test -z "$pid" || kill "$pid" 2> /dev/null; }

# The mask the program is started with: this shell's, plus SIGQUIT (bit 2).
started_mask=$(sig_field_ $$ SigBlk)

start_fakex_

if can_block_; then
	started_mask=$(printf '%016x' $(( 0x$started_mask | 0x4 )))
	start_via_ env --block-signal=QUIT "$XIL" sleep 30
else
	warn_ "$ME_: env cannot block signals; the mask is checked against empty"
	start_xil_ sleep 30
fi

fakex_send_ on

# locker_child_ -- the program's one child, once it exists.
locker_child_ ()
{
	pid=$(pgrep -P "$xil_pid_")
	test -n "$pid"
}

retry_ 5 locker_child_ || fail_ 'the locker never started'

# pid (comm) state ppid pgrp session ...; comm is "sleep", with no spaces.
set -- $(cat "/proc/$pid/stat")

test "x$6" = "x$pid" ||
	{ warn_ "$ME_: the locker $pid is in session $6, not its own"; fail=1; }

blocked=$(sig_field_ "$pid" SigBlk)

test "x$blocked" = "x$started_mask" ||
	{ warn_ "$ME_: locker SigBlk $blocked, expected $started_mask"; fail=1; }

ignored=$(sig_field_ "$pid" SigIgn)

test $(( 0x$ignored & 0x1000 )) -eq 0 ||
	{ warn_ "$ME_: the locker ignores SIGPIPE (SigIgn $ignored)"; fail=1; }

Exit $fail
