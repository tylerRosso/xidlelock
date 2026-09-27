#!/bin/sh
# SPDX-License-Identifier: ISC

# How the locker ended is reported when it ended badly; the program carries on.
#
# A locker that exits with an error usually never locked at all -- slock, for
# one, exits 1 when it cannot grab the keyboard -- and one killed by a signal
# has stopped protecting the screen. Neither may pass in silence.
#
# Pins, one locker each, all under one running program:
#   - exit 0 is silent,
#   - exit 3 is "'NAME' exited with status 3.",
#   - SIGKILL is "'NAME' was killed by signal 9.",
# with NAME as given on the command line, stderr holding exactly those two
# lines, and each next activation still starting a new locker.

. "${srcdir=.}/tests/init.sh"

start_fakex_

# The locker is rewritten between runs to change its exit status; the program
# executes the file afresh each time.
make_locker_ locker 0
start_xil_ "$PWD/locker"

fakex_send_ on
retry_ 5 locker_started_ 1 || fail_ 'the first locker never started'
release_locker_ "$(locker_pid_ 1)" || fail=1

make_locker_ locker 3
fakex_send_ on
retry_ 5 locker_started_ 2 || fail_ 'no locker after a clean exit'
release_locker_ "$(locker_pid_ 2)" || fail=1

make_locker_ locker 0
fakex_send_ on
retry_ 5 locker_started_ 3 || fail_ 'no locker after an exit status of 3'

third=$(locker_pid_ 3)
kill -KILL "$third" || framework_failure_ "cannot kill the locker $third"
release_locker_pid_=$third
retry_ 5 locker_gone_ || { warn_ 'the killed locker was never reaped'; fail=1; }

fakex_send_ on
retry_ 5 locker_started_ 4 || { warn_ 'no locker after a killed one'; fail=1; }
release_locker_ "$(locker_pid_ 4)" || fail=1

cat > expected.err <<EOF
xidlelock: '$PWD/locker' exited with status 3.
xidlelock: '$PWD/locker' was killed by signal 9.
EOF

compare expected.err xil.err || fail=1

Exit $fail
