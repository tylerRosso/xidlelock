#!/bin/sh
# SPDX-License-Identifier: ISC

# The cookie found in $XAUTHORITY is the one offered in the connection setup.
#
# Cookie selection is xwire.h's and is tested in full where that file is
# maintained; what is pinned here is that this program passes load_cookie()'s
# result on to the handshake instead of connecting anonymously. The fixture is
# one FamilyWild (65535) entry with a 14-byte cookie, so the server must log
# the 18-byte MIT-MAGIC-COOKIE-1 name and 14 bytes of data -- literal lengths,
# never the program's AUTH_METHOD_LEN.

. "${srcdir=.}/tests/init.sh"

start_fakex_
make_locker_

# u16_ N -- one big-endian 16-bit integer, as .Xauthority stores them.
u16_ ()
{
	printf "$(printf '\\%03o\\%03o' $(( ( $1 / 256 ) % 256 )) $(( $1 % 256 )))"
}

# field_ TEXT -- a 16-bit length followed by that many bytes.
field_ ()
{
	u16_ ${#1}
	printf '%s' "$1"
}

{
	u16_ 65535
	field_ ''
	field_ "${DISPLAY#:}"
	field_ 'MIT-MAGIC-COOKIE-1'
	field_ 'WILDCOOKIE1234'
} > wild.xauth

XAUTHORITY=$PWD/wild.xauth
export XAUTHORITY

start_xil_ "$PWD/locker"

fakex_grep_ '^SETUP authname=18 authdata=14$' || fail=1

Exit $fail
