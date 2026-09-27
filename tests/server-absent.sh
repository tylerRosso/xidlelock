#!/bin/sh
# SPDX-License-Identifier: ISC

# No server on the display: diagnosed with the socket path and the real errno
# text, exit 1, and no retry loop.

. "${srcdir=.}/tests/init.sh"

# init.sh's DISPLAY, :9999, which nothing should be serving.
test ! -e /tmp/.X11-unix/X9999 ||
	skip_ 'something exists at /tmp/.X11-unix/X9999'

returns_ 1 "$XIL" true > absent.out 2> absent.err || fail=1

reason='No such file or directory'
printf '%s\n' "xidlelock: cannot connect to '/tmp/.X11-unix/X9999': $reason" \
	> expected.err
compare expected.err absent.err || fail=1

test -s absent.out && { warn_ 'wrote to stdout'; fail=1; }

Exit $fail
