#!/bin/sh
# SPDX-License-Identifier: ISC

# DESTDIR stages an install for a package: install and uninstall both work
# under it, and the PATH check stays out of the way.
#
# SAFETY -- DO NOT "SIMPLIFY" THIS AWAY: DESTDIR and PREFIX both point inside
# this test's own temporary directory, and build_sh_ refuses anything else. A
# build.sh that ignored DESTDIR would install into PREFIX itself, which is why
# PREFIX is a directory in here too and never /usr: a broken DESTDIR must not
# be able to reach the real system.
#
# Everything is built and installed from a private COPY of the project, never
# from $XIL_ROOT, as in the other install tests.
#
# WHAT IT PINS:
#   - the binary and the manual land under DESTDIR/PREFIX, at modes 755 and
#     644, and nothing at all is created at PREFIX itself.
#   - the "installed" lines name the staged paths, the binary's last.
#   - nothing on stderr, the PATH warning included: a staging directory is
#     never on PATH, so the warning would be noise in every package build.
#   - uninstall with the same DESTDIR removes both staged files.
#
# Seen to fail with DESTDIR ignored by install, with the PATH check left on for
# a staged install, and with DESTDIR ignored by uninstall.

. "${srcdir=.}/tests/init.sh"

# Captured once, immediately: init.sh has already cd'd into the per-test
# temporary directory, and every path below is built from this.
top_=$PWD
prog=$(basename "$XIL")

# build_sh_ PROJ DESTDIR PREFIX SUBCOMMAND -- run PROJ/build.sh, staged.
#
# The single door every build.sh invocation in this file goes through, so the
# safety rule above is enforced in one place.
build_sh_ ()
{
	for build_sh_dir_ in "$2" "$3"; do
		case "$build_sh_dir_" in
			"$top_"/*) ;;
			*) framework_failure_ \
				"refusing a path outside $top_: $build_sh_dir_" ;;
		esac
	done

	DESTDIR="$2" PREFIX="$3" "$1/build.sh" "$4"
}

# show_ FILE... -- dump captured output after a failed assertion.
show_ ()
{
	for show_f_ in "$@"; do
		warn_ "--- $show_f_ ---"
		cat "$show_f_" >&2
	done
}

# make_proj_ DIR -- a private copy of the project to build and install from.
make_proj_ ()
{
	mkdir -p "$1" || framework_failure_ "cannot create $1"

	cp "$XIL_ROOT/build.sh" "$XIL_ROOT/main.c" "$XIL_ROOT/xwire.h" \
		"$XIL_ROOT/xidlelock.1" "$1" ||
		framework_failure_ "cannot copy the project into $1"

	test -x "$1/build.sh" || framework_failure_ "$1/build.sh is not executable"
}

proj="$top_/proj"
stage="$top_/stage"
prefix="$top_/usr"
target="$stage$prefix/bin/$prog"
manual="$stage$prefix/share/man/man1/$prog.1"

make_proj_ "$proj"

# ------------------------------------------------------------------ install

returns_ 0 build_sh_ "$proj" "$stage" "$prefix" install \
	> in.out 2> in.err || {
	show_ in.out in.err
	fail=1
}

test -s in.err && {
	warn_ "$ME_: a staged install wrote to stderr:"
	cat in.err >&2
	fail=1
}

test ! -e "$prefix" || {
	warn_ "$ME_: the install went to PREFIX itself, not under DESTDIR:"
	ls -lR "$prefix" >&2
	fail=1
}

got=$(tail -1 in.out)

test "x$got" = "xinstalled $target" || {
	warn_ "$ME_: expected 'installed $target' last on stdout, got '$got'"
	cat in.out >&2
	fail=1
}

grep -q -x -F "installed $manual" in.out || {
	warn_ "$ME_: no 'installed $manual' line on stdout"
	cat in.out >&2
	fail=1
}

test -f "$target" || fail_ "the staged install did not create $target"
test -f "$manual" || fail_ "the staged install did not create $manual"

mode=$(ls -l "$target" | cut -c1-10)

test "x$mode" = "x-rwxr-xr-x" || {
	warn_ "$ME_: expected the binary at mode -rwxr-xr-x, got $mode"
	fail=1
}

mode=$(ls -l "$manual" | cut -c1-10)

test "x$mode" = "x-rw-r--r--" || {
	warn_ "$ME_: expected the manual at mode -rw-r--r--, got $mode"
	fail=1
}

cmp "$proj/bin/release/$prog" "$target" || {
	warn_ "$ME_: the staged binary differs from bin/release"
	fail=1
}

# ---------------------------------------------------------------- uninstall

returns_ 0 build_sh_ "$proj" "$stage" "$prefix" uninstall \
	> rm.out 2> rm.err || {
	show_ rm.out rm.err
	fail=1
}

for file in "$target" "$manual"; do
	grep -q -x -F "removed $file" rm.out || {
		warn_ "$ME_: no 'removed $file' line on stdout"
		cat rm.out >&2
		fail=1
	}

	test ! -e "$file" || {
		warn_ "$ME_: a staged uninstall left $file behind"
		fail=1
	}
done

Exit $fail
