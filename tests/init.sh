# SPDX-License-Identifier: ISC

# Test harness for xidlelock, sourced by every tests/*.sh.
#
# Modelled on gnulib's tests/init.sh, which is what GNU coreutils uses. The
# vocabulary is deliberately the same, so anything written about coreutils tests
# reads across.
#
# Exit status convention, understood by build.sh test:
#   0   pass
#   1   fail          the program is wrong
#   77  skip          this environment cannot run the test, and that is fine
#   99  framework     the test's own setup broke -- NOT a program failure
#
# The usual shape of a test:
#
#   . "${srcdir=.}/tests/init.sh"
#   start_fakex_
#   make_locker_
#   start_xil_ "$PWD/locker"
#   fakex_send_ on
#   retry_ 5 locker_started_ 1 || fail=1
#   Exit $fail

# --------------------------------------------------------------- environment

LC_ALL=C
LANG=C
export LC_ALL LANG

# Never reach the real display or the user's cookie by accident. A test that
# wants the live display sets these itself, deliberately.
DISPLAY=:9999
XAUTHORITY=/nonexistent/xidlelock-test
export DISPLAY XAUTHORITY

# Same idea for PREFIX, and it matters more: the default is ~/.local, which is a
# directory on the user's real PATH. A test that ran `./build.sh install` and
# forgot to set PREFIX would install into it for real. Point it at a path that
# does not exist so a forgotten PREFIX fails loudly instead of succeeding
# somewhere it should never touch. Tests that install set PREFIX per invocation.
PREFIX=/nonexistent/xidlelock-test-prefix
export PREFIX

# And DESTDIR, which install prepends to every path: one exported in the shell
# that runs the suite would carry the install tests outside their directories.
# install-destdir sets it per invocation.
unset DESTDIR

: "${XIL_ROOT:=$(cd "${srcdir:-.}" && pwd)}"
: "${XIL:=$XIL_ROOT/bin/release/xidlelock}"
: "${FAKEX:=$XIL_ROOT/bin/test/fakex}"
export XIL_ROOT XIL FAKEX

fail=0

# ------------------------------------------------------------------ outcomes

warn_ () { printf '%s\n' "$*" >&2; }

# end_ STATUS WORD TEXT... -- report TEXT and end the test with STATUS.
#
# WORD is what build.sh prints for that status, so a test's own last words and
# the runner's verdict agree. build.sh reads a skip's reason back after it.
end_ ()
{
	end_status_=$1
	end_word_=$2
	shift 2
	warn_ "$ME_: $end_word_: $*"
	Exit "$end_status_"
}

# The names are gnulib's, so a test reads like a coreutils one. The code is not,
# and must not become it: gnulib's init.sh is GPL-3.0-or-later, and this file is
# ISC.
fail_ ()              { end_ 1 FAIL "$@"; }
skip_ ()              { end_ 77 SKIP "$@"; }
framework_failure_ () { end_ 99 ERROR "$@"; }
fatal_ ()             { end_ 99 ERROR "$@"; }

ME_=$(basename "$0")

# ------------------------------------------------------------------- helpers

# returns_ N CMD...  -- assert an exact exit status.
#
# `CMD || fail=1` cannot tell failure from a segfault, and a test that accepts
# any non-zero status will happily pass on a crash. Always assert the number.
returns_ ()
{
	returns_expected_=$1
	shift
	"$@"
	returns_actual_=$?

	if test "$returns_actual_" -ne "$returns_expected_"; then
		warn_ "$ME_: expected exit $returns_expected_, got $returns_actual_: $*"

		return 1
	fi

	return 0
}

# compare EXPECTED ACTUAL -- diff two files, printing the difference on failure.
compare ()
{
	if diff -u "$1" "$2" > compare.tmp 2>&1; then
		rm -f compare.tmp

		return 0
	fi

	warn_ "$ME_: $1 and $2 differ:"
	cat compare.tmp >&2
	rm -f compare.tmp

	return 1
}

# retry_ SECONDS CMD... -- poll until CMD succeeds or the deadline passes.
#
# Never sleep a fixed amount and hope. Poll, so a fast machine is fast and a
# loaded one still passes. CMD is run afresh each time, so anything it counts
# must be counted inside it: `retry_ 5 test "$(grep -c x f)" -eq 3` expands
# the substitution once and compares the same stale number every time.
retry_ ()
{
	retry_limit_=$(( ${1} * 50 ))
	shift
	retry_i_=0

	while test "$retry_i_" -lt "$retry_limit_"; do
		if "$@"; then
			return 0
		fi

		retry_i_=$(( retry_i_ + 1 ))
		sleep 0.02
	done

	return 1
}

require_prog_ ()
{
	for require_prog_p_ in "$@"; do
		command -v "$require_prog_p_" > /dev/null 2>&1 ||
			skip_ "required program not found: $require_prog_p_"
	done
}

# can_block_ -- true if env(1) can start a command with signals blocked. GNU
# env has --block-signal since coreutils 8.31; POSIX sh has no way to do it.
can_block_ ()
{
	env --block-signal=INT true > /dev/null 2>&1
}

require_built_ ()
{
	for require_built_f_ in "$@"; do
		test -x "$require_built_f_" ||
			framework_failure_ "not built: $require_built_f_"
	done
}

# ---------------------------------------------------------------- fake server

FAKEX_LOG=fakex.log
FAKEX_CONTROL=fakex.ctl
fakex_pid_=
fakex_display_=

# start_fakex_ [MODE] -- run a fake X server and point DISPLAY at it.
#
# Picks a free display number rather than a fixed one, so a stale socket or a
# concurrent run cannot make an unrelated test fail. fakex itself refuses to
# bind a socket somebody is already serving, which is what makes this safe --
# in particular it can never attach to the real :0.
start_fakex_ ()
{
	start_fakex_mode_=${1:-ok}
	start_fakex_n_=90

	rm -f "$FAKEX_CONTROL"
	mkfifo "$FAKEX_CONTROL" ||
		framework_failure_ "cannot create the control fifo $FAKEX_CONTROL"

	while test "$start_fakex_n_" -lt 160; do
		: > "$FAKEX_LOG"

		"$FAKEX" "$start_fakex_n_" "$start_fakex_mode_" "$PWD/$FAKEX_CONTROL" \
			>> "$FAKEX_LOG" 2>&1 &
		fakex_pid_=$!

		if retry_ 5 grep -q '^LISTENING' "$FAKEX_LOG"; then
			fakex_display_=":$start_fakex_n_"
			DISPLAY=$fakex_display_
			export DISPLAY

			return 0
		fi

		kill "$fakex_pid_" 2> /dev/null
		wait "$fakex_pid_" 2> /dev/null
		fakex_pid_=

		start_fakex_n_=$(( start_fakex_n_ + 1 ))
	done

	framework_failure_ "could not start fakex on any display from :90 to :159"
}

stop_fakex_ ()
{
	test -n "$fakex_pid_" || return 0

	kill "$fakex_pid_" 2> /dev/null
	wait "$fakex_pid_" 2> /dev/null
	fakex_pid_=
}

# fakex_send_ COMMAND -- have the server send an event, or hang up; see the
# list at the top of tests/fakex.c.
#
# fakex holds the fifo open for reading and writing, so opening it here cannot
# block while fakex is alive -- and it is checked to be alive first, because
# with no reader at all the open would block for ever.
fakex_send_ ()
{
	test -n "$fakex_pid_" && kill -0 "$fakex_pid_" 2> /dev/null ||
		framework_failure_ "fakex is not running, cannot send '$1'"

	printf '%s\n' "$1" > "$FAKEX_CONTROL"
}

# fakex_grep_ PATTERN -- assert the server logged something matching PATTERN.
# Waits for it, because the server may log it a moment after it happens.
fakex_grep_ ()
{
	if retry_ 5 grep -q -- "$1" "$FAKEX_LOG"; then
		return 0
	fi

	warn_ "$ME_: fakex log has no match for: $1"
	warn_ "--- $FAKEX_LOG ---"
	cat "$FAKEX_LOG" >&2
	warn_ "------------------"

	return 1
}

# fakex_not_grep_ PATTERN -- assert the server never logged PATTERN.
fakex_not_grep_ ()
{
	if grep -q -- "$1" "$FAKEX_LOG" 2> /dev/null; then
		warn_ "$ME_: fakex log unexpectedly matched: $1"
		cat "$FAKEX_LOG" >&2

		return 1
	fi

	return 0
}

# ------------------------------------------------------------- the program

xil_pid_=
xil_status_=

# start_xil_ [ARG]... -- run the program in the background, stdout to xil.out
# and stderr to xil.err, and wait until the server has seen it select the
# screen saver events.
#
# That request is written after the signal handlers are installed, so from the
# moment fakex logs it the program can be signalled safely, and an event sent
# now is one it will read. A program that never gets that far fails the test.
start_xil_ ()
{
	start_via_ "$XIL" "$@"
}

# start_via_ CMD [ARG]... -- start_xil_, for a CMD that execs the program, such
# as `env --block-signal=INT "$XIL"`. The pid is CMD's, and so the program's.
start_via_ ()
{
	"$@" > xil.out 2> xil.err &
	xil_pid_=$!

	if ! retry_ 5 grep -q '^SELECTINPUT ' "$FAKEX_LOG"; then
		warn_ "--- xil.err ---"
		cat xil.err >&2
		warn_ "--- $FAKEX_LOG ---"
		cat "$FAKEX_LOG" >&2
		fail_ 'the program never selected the screen saver events'
	fi
}

# wait_xil_ -- reap the program and put its exit status in xil_status_.
#
# A program that has not exited within 5 seconds is killed, so a test waiting
# for an exit that never comes fails with 137 instead of hanging the suite. The
# watchdog's output goes to /dev/null: build.sh reads each test through a pipe
# and waits for every writer to close it, a stray sleep included.
#
# The watchdog is stopped with SIGKILL, never TERM. This file traps TERM, and a
# TERM that reaches the watchdog while it still carries that inherited trap is
# lost. dash lost it every time the kill followed the fork at once, as it does
# when the program has already exited; the watchdog then slept out its 5
# seconds, most of the suite's run time, and sent SIGKILL to a pid already
# reaped. Its sleep outlives it, harmlessly: it holds nothing open but
# /dev/null.
wait_xil_ ()
{
	( sleep 5; kill -KILL "$xil_pid_" ) > /dev/null 2>&1 &
	wait_xil_dog_=$!

	wait "$xil_pid_"
	xil_status_=$?
	xil_pid_=

	kill -KILL "$wait_xil_dog_" 2> /dev/null
	wait "$wait_xil_dog_" 2> /dev/null
}

stop_xil_ ()
{
	test -n "$xil_pid_" || return 0

	kill -KILL "$xil_pid_" 2> /dev/null
	wait "$xil_pid_" 2> /dev/null
	xil_pid_=
}

# ------------------------------------------------------------ the fake locker

# make_locker_ [NAME] [STATUS] -- write an executable stand-in for slock.
#
# Each run appends a line to locker.log -- "start", its pid, and each argument
# in brackets -- then stays in the foreground, as a real locker does until the
# screen is unlocked, until release_locker_ lets it go. It then appends "exit"
# and its pid, and exits with STATUS (default 0).
#
# It gives up by itself when this test's directory disappears, or after 30
# seconds. The program starts it in a session of its own, where no signal sent
# to the test's process group can reach it, so without that a failed test would
# leave it behind.
make_locker_ ()
{
	make_locker_name_=${1:-locker}

	cat > "$make_locker_name_" <<EOF
#!/bin/sh
dir='$PWD'
line="start \$\$"
for arg; do line="\$line [\$arg]"; done
printf '%s\n' "\$line" >> "\$dir/locker.log"
i=0
while test -d "\$dir" && test ! -e "\$dir/locker.release" &&
	test \$i -lt 600
do
	sleep 0.05
	i=\$((i + 1))
done
printf 'exit %s\n' "\$\$" >> "\$dir/locker.log"
exit ${2:-0}
EOF

	test -s "$make_locker_name_" ||
		framework_failure_ 'cannot write the locker'

	chmod +x "$make_locker_name_" ||
		framework_failure_ 'cannot make the locker executable'
}

# locker_started_ N -- true once exactly N lockers have started.
locker_started_ ()
{
	test "$(grep -c '^start ' locker.log 2> /dev/null)" -eq "$1"
}

# lockers_running_ -- how many of this test's lockers exist right now.
#
# Anchored on the interpreter the kernel runs the script with: the program's
# own command line names the locker too, and must not be counted.
lockers_running_ ()
{
	pgrep -f -- "^/bin/sh $PWD/locker( |\$)" | wc -l
}

# locker_pid_ N -- the pid of the Nth locker started.
locker_pid_ ()
{
	sed -n 's/^start \([0-9]*\).*/\1/p' locker.log | sed -n "$1p"
}

# release_locker_ PID -- let the running locker exit, and wait until the
# program has REAPED it, not merely until it has exited: kill -0 succeeds on a
# zombie, so it only fails once the pid is gone for good. Fails if that takes
# longer than 5 seconds.
release_locker_ ()
{
	: > locker.release

	release_locker_pid_=$1
	retry_ 5 locker_gone_
	release_locker_status_=$?

	rm -f locker.release

	return $release_locker_status_
}

locker_gone_ () { ! kill -0 "$release_locker_pid_" 2> /dev/null; }

# ------------------------------------------------------- tmpdir and teardown

# Override in a test to clean up anything outside the temporary directory.
cleanup_ () { :; }

Exit ()
{
	set +e
	exit "$1"
}

remove_tmp_ ()
{
	remove_tmp_status_=$?

	stop_xil_
	stop_fakex_
	cleanup_

	if test -n "$test_dir_" && test "${KEEP:-no}" != yes; then
		cd / && rm -rf "$test_dir_"
	elif test -n "$test_dir_"; then
		warn_ "$ME_: keeping $test_dir_"
	fi

	exit $remove_tmp_status_
}

require_built_ "$XIL" "$FAKEX"

test_dir_=$(mktemp -d "${TMPDIR:-/tmp}/xil-$ME_.XXXXXX") ||
	framework_failure_ "cannot create a temporary directory"

trap remove_tmp_ EXIT
trap 'Exit 143' HUP INT TERM

cd "$test_dir_" || framework_failure_ "cannot cd to $test_dir_"
