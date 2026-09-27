#!/bin/sh
# SPDX-License-Identifier: ISC

# An activation on the REAL X server starts the locker.
#
# WHAT IT PINS: that the requests and the event, as this program encodes and
# decodes them, are the ones a real server speaks. fakex is our own code and
# could be wrong in exactly the way the program is. `xset s activate` sends
# ForceScreenSaver(Activate); the server turns the saver on and sends
# ScreenSaverNotify (On) to every client that selected it. The locker starting
# is therefore also the proof that the server accepted QueryExtension and
# ScreenSaverSelectInput: an error for either would have reached the program
# first and ended it with exit 1.
#
# SAFETY: this blanks the live display for a moment, so it is opt-in
# (XIL_TEST_REAL_X). The locker is this test's stand-in, never slock, and the
# test skips while a real locking daemon runs -- `xset s activate` would make IT
# lock the screen for real. cleanup_ resets the saver on every path, including
# a failing or interrupted run, so the screen is not left blank.
#
# READINESS: without fakex's log there is nothing to say the program has
# selected the events, so the test waits until the kernel reports it asleep in
# poll (/proc/PID/wchan). The program calls ppoll only after the selection has
# been written.
#
# WHICH DISPLAY: the one the session names, never an assumed :0 -- and with the
# session's own cookie. Both are saved before init.sh points them somewhere
# harmless. A display manager often keeps the cookie outside ~/.Xauthority, so
# falling back to that file would fail the test on a working machine. Seen to
# fail with either saved value left unrestored.

real_display_=${DISPLAY-}
real_xauthority_=${XAUTHORITY-}
real_xauthority_set_=${XAUTHORITY+yes}

. "${srcdir=.}/tests/init.sh"

test "${XIL_TEST_REAL_X:-0}" = 1 ||
	skip_ 'set XIL_TEST_REAL_X=1 to run against the live X display'

test -n "$real_display_" || skip_ 'DISPLAY is not set: no live X display'

# The forms the program accepts: :N and unix:N, either with a .SCREEN.
case $real_display_ in
	:* | unix:*) ;;
	*) skip_ "DISPLAY=$real_display_ is not a local display" ;;
esac

number_=${real_display_#*:}
number_=${number_%%.*}

case $number_ in
	'' | *[!0-9]*) skip_ "DISPLAY=$real_display_ has no display number" ;;
esac

test -S "/tmp/.X11-unix/X$number_" ||
	skip_ "no live X server: /tmp/.X11-unix/X$number_ is not a socket"
require_prog_ xset pgrep
test -r /proc/self/wchan || skip_ 'no /proc/PID/wchan to wait on'

for daemon in xidlelock xss-lock xautolock xscreensaver; do
	if pgrep -x "$daemon" > /dev/null 2>&1; then
		skip_ "$daemon is running and would lock the screen for real"
	fi
done

# Back to the session's own. An XAUTHORITY that was unset stays unset, so the
# program and xset fall back to $HOME/.Xauthority alike.
DISPLAY=$real_display_
export DISPLAY

if test "$real_xauthority_set_" = yes; then
	XAUTHORITY=$real_xauthority_
	export XAUTHORITY
else
	unset XAUTHORITY
fi

activated_=no

cleanup_ ()
{
	test "$activated_" = yes || return 0

	xset s reset > /dev/null 2>&1 ||
		warn_ "$ME_: COULD NOT RESET the screen saver; move the mouse"
}

make_locker_

"$XIL" "$PWD/locker" > xil.out 2> xil.err &
xil_pid_=$!

waiting_ () { grep -q poll "/proc/$xil_pid_/wchan" 2> /dev/null; }

retry_ 5 waiting_ || {
	cat xil.err >&2
	fail_ 'the program never reached its wait'
}

activated_=yes
xset s activate || framework_failure_ 'xset s activate failed'

retry_ 5 locker_started_ 1 || {
	warn_ "$ME_: no locker after xset s activate; is the saver disabled?"
	cat xil.err >&2
	fail=1
}

xset s reset || warn_ "$ME_: xset s reset failed"

pid=$(locker_pid_ 1)
test -n "$pid" && { release_locker_ "$pid" || fail=1; }

kill -TERM "$xil_pid_"
wait_xil_

test "$xil_status_" -eq 0 ||
	{ warn_ "$ME_: expected exit 0 after SIGTERM, got $xil_status_"; fail=1; }

test -s xil.err && { warn_ 'the program reported:'; cat xil.err >&2; fail=1; }

Exit $fail
