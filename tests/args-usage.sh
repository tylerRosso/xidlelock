#!/bin/sh
# SPDX-License-Identifier: ISC

# Usage and unknown options.
#
# Pins: -h and --help print the same usage, on stdout, exit 0 and need no
# display; the usage names slock as the default, and every option the program
# accepts: -h, --help, -v, --version and --. An unknown option exits 1, naming
# it, with the usage on stderr and nothing on stdout -- it is refused, not
# mistaken for the start of the locker's command line.
#
# The usage once listed only -h. Seen to fail with the '--' line removed from
# usage(), with '-h, --help' cut back to '-h', and with the -v line removed.

. "${srcdir=.}/tests/init.sh"

returns_ 0 "$XIL" -h     > help.out 2>&1 || fail=1
returns_ 0 "$XIL" --help > help2.out 2>&1 || fail=1
compare help.out help2.out || fail=1

grep -q '^Usage: xidlelock \[LOCKER \[ARGUMENT\]\.\.\.\]$' help.out ||
	{ warn_ 'no usage line'; cat help.out >&2; fail=1; }
grep -q "^LOCKER defaults to 'slock'" help.out ||
	{ warn_ 'the usage does not name the default locker'; fail=1; }
grep -q '^  -h, --help  ' help.out ||
	{ warn_ 'the usage does not list -h and --help'; fail=1; }
grep -q '^  -v, --version  ' help.out ||
	{ warn_ 'the usage does not list -v and --version'; fail=1; }
grep -q '^  --  ' help.out ||
	{ warn_ 'the usage does not list --'; fail=1; }

# init.sh points DISPLAY at a display that does not exist.
grep -q 'DISPLAY' help.out && { warn_ '-h touched DISPLAY'; fail=1; }

returns_ 1 "$XIL" --nope > bad.out 2> bad.err || fail=1
grep -q "^xidlelock: unknown option '--nope'\.\$" bad.err ||
	{ warn_ 'no unknown-option message'; cat bad.err >&2; fail=1; }
grep -q '^Usage: xidlelock ' bad.err ||
	{ warn_ 'no usage on stderr after an unknown option'; fail=1; }
test -s bad.out && { warn_ 'an unknown option wrote to stdout'; fail=1; }

Exit $fail
