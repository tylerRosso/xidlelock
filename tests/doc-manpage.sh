#!/bin/sh
# SPDX-License-Identifier: ISC

# The manual is well-formed and lists exactly the options the program takes.
#
# The usage text once listed only -h while the program took --help and -- as
# well, and a manual can drift the same way, in either direction. So the
# options are taken from the program itself -- the lines of its usage indented
# two spaces and starting with '-' -- and compared with the tags of the
# manual's OPTIONS section as mandoc renders it. Comparing the rendering
# rather than the mdoc source keeps the test out of how the source is spelled.
#
# A tag is compared whole, every spelling of the option in it, up to the run
# of spaces before its description. Its argument is compared only for being
# there: the usage names it in capitals and the manual in lower case, so
# =COMMAND and =command both become =ARG. The test once compared each tag
# only up to its first space, which took the short option and the comma after
# it, so a long option misspelt in the manual passed.
#
# Pins: mandoc reports nothing at warning level or above, and the two option
# lists are the same, in the same order. Style notes are left out on purpose:
# "referenced manual not found" depends on which manuals a machine has.
#
# Seen to fail with the -v entry deleted from the manual, with an entry for an
# option the program lacks added to it, with a list left unclosed, with the -g
# entry deleted, with --grace misspelt in the manual and in the usage, and
# with the manual's =command dropped. The last three passed before tags were
# compared whole; the gap was present since the initial import, 7a20770.

. "${srcdir=.}/tests/init.sh"

require_prog_ mandoc col

manual="$XIL_ROOT/xidlelock.1"

test -f "$manual" || framework_failure_ "no manual at $manual"

returns_ 0 mandoc -T lint -W warning "$manual" > lint.out 2>&1 || fail=1

test -s lint.out && { warn_ 'mandoc reported:'; cat lint.out >&2; fail=1; }

# option_tags_ INDENT -- the option tags among the lines read, which are
# those starting with INDENT and then '-': each cut at the run of spaces
# before its description, with every =ARGUMENT made =ARG.
option_tags_ ()
{
	sed -n "s/^$1\(-.*\)/\1/p" | sed 's/  .*//; s/=[^ ,]*/=ARG/g'
}

returns_ 0 "$XIL" -h > usage.out 2>&1 || fail=1
option_tags_ '  ' < usage.out > from-usage

test -s from-usage ||
	framework_failure_ 'found no options in the usage; has its layout changed?'

# col -x as well as -b: without it col turns runs of spaces into tabs, and
# the tags are found by their indent of exactly five spaces.
mandoc -T ascii "$manual" | col -bx > manual.txt ||
	framework_failure_ 'cannot render the manual'

sed -n '/^OPTIONS$/,/^[A-Z]/p' manual.txt | option_tags_ '     ' > from-manual

compare from-usage from-manual || fail=1

Exit $fail
