#!/bin/sh
# SPDX-License-Identifier: ISC

# xwire.h is byte for byte the copy maintained in xrootclock.
#
# The transport is shared by copying, so a fix made to one copy is one the
# other lacks until somebody carries it over. This test is the reminder. It
# compares this program's xwire.h with the one in a checkout of xrootclock,
# named by XROOTCLOCK or, failing that, the directory beside this one, and
# skips when there is none to compare with. It reads that checkout's working
# tree, so a fix made there and not yet copied here is red at once.
#
# Seen to fail with a blank line added to this program's copy.

. "${srcdir=.}/tests/init.sh"

ours=$XIL_ROOT/xwire.h
theirs=${XROOTCLOCK:-$XIL_ROOT/../xrootclock}/xwire.h

test -f "$ours" || framework_failure_ "no xwire.h at $ours"
test -f "$theirs" || skip_ "no checkout of xrootclock at ${theirs%/xwire.h}"

compare "$theirs" "$ours" || fail=1

Exit $fail
