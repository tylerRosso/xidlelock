#!/bin/sh
# SPDX-License-Identifier: ISC

# xidlelock build script.
#
#   ./build.sh              build the release binary (the default)
#   ./build.sh release      same thing, spelled out
#   ./build.sh debug        unoptimised, with debug info and UBSan
#   ./build.sh run [args]   build debug, then run it with any extra arguments
#   ./build.sh test [name]  build, then run tests/*.sh (optionally just one)
#   ./build.sh install      build, then copy the binary to $PREFIX/bin and the
#                           manual to $PREFIX/share/man/man1
#   ./build.sh uninstall    remove both again
#   ./build.sh clean        remove bin/ and compile_commands.json
#
# PREFIX defaults to ~/.local, the usual per-user prefix. Override it for
# anywhere else:
#     PREFIX=/usr/local ./build.sh install     (needs root)
#
# DESTDIR stages an install for a package: both files go under it, and PATH is
# not checked, since a staging directory is never on it.
#     DESTDIR=/tmp/stage PREFIX=/usr ./build.sh install
# Both must be absolute: the script works from its own directory.
#
# Builds a fully static musl binary. A full rebuild takes about 0.25s, so there
# is no incremental build and no object files -- one compile-and-link, always
# from scratch.

set -eu

# Work from the script's own directory, resolved through symlinks, so this can
# be run from any cwd, by absolute path, or through a symlink in ~/bin.
cd "$(dirname "$(readlink -f "$0")")"

PROGRAM="xidlelock"
CC="${CC:-${HOME:-}/bin/musl-clang}"

# --------------------------------------------------------------------- flags
#
# Every flag here was verified against this toolchain; see AGENTS.md for the
# evidence. The three load-bearing ones:
#
#   -D_GNU_SOURCE                 -std=c17 defines __STRICT_ANSI__, which hides
#                                 SOCK_CLOEXEC, ppoll and environ.
#                                 Passed on the command line rather than
#                                 #defined in main.c, where it would trip
#                                 -Wreserved-macro-identifier.
#   -Wno-disabled-macro-expansion musl's <stdio.h> defines stderr and stdout as
#                                 self-referential macros, and its <signal.h>
#                                 does the same for sa_handler. Not glibc-only
#                                 baggage; removing it breaks this build.
#   -Wno-unsafe-buffer-usage      fires on every pointer arithmetic expression.
#                                 Unusable in C.
#
# Deliberately NOT here, all tested and rejected:
#   -static             $CC is already `clang -static`; passing it is redundant.
#   -D_FORTIFY_SOURCE   a silent no-op against this musl sysroot.
#   -Wl,-z,relro,now    no-op for a static binary.
#   -Wl,-z,noexecstack  no-op: the stack is already RW, not executable.
#   -static-pie         builds cleanly, produces a binary that cannot run --
#                       ld.musl-clang always appends -dynamic-linker.

COMMON="-std=c17 -D_GNU_SOURCE -fstack-protector-strong"
WARN="-Weverything -Wno-disabled-macro-expansion -Wno-unsafe-buffer-usage"
WARN="$WARN -Werror"

RELEASE="-Os -s"

# AddressSanitizer cannot link against static musl at all -- its runtime needs
# a dynamic libc. UBSan can, in minimal-runtime form, and it is the check that
# matters for a program doing offset arithmetic on wire-protocol byte buffers.
# For full ASan, build with the system clang instead (dynamic, throwaway):
#   clang -std=c17 -D_GNU_SOURCE -g3 -fsanitize=address,undefined \
#       main.c -o /tmp/xil
DEBUG="-g3 -fno-omit-frame-pointer -fsanitize=undefined,local-bounds"
DEBUG="$DEBUG -fsanitize-minimal-runtime -fno-sanitize-recover=undefined"

# ------------------------------------------------------------------- dispatch

COMMAND="${1:-release}"

case "$COMMAND" in
	clean)
		rm -rf bin compile_commands.json
		echo "cleaned"
		exit 0
		;;
	uninstall)
		prefix="${PREFIX:-${HOME:-}/.local}"
		target="${DESTDIR:-}$prefix/bin/$PROGRAM"
		manual="${DESTDIR:-}$prefix/share/man/man1/$PROGRAM.1"

		if [ ! -e "$target" ] && [ ! -L "$target" ] &&
			[ ! -e "$manual" ] && [ ! -L "$manual" ]; then
			echo "nothing installed at $target"
			exit 0
		fi

		# Diagnose an unwritable directory rather than leaving rm(1) to fail
		# with a bare "Permission denied" and no way forward.
		for file in "$manual" "$target"; do
			dir=$(dirname "$file")

			if { [ -e "$file" ] || [ -L "$file" ]; } && [ ! -w "$dir" ]; then
				echo "$0: $dir is not writable." >&2
				echo "Remove the installed files as root, for example:" >&2
				echo "    su -c \"rm -f '$target' '$manual'\"" >&2
				exit 1
			fi
		done

		# The manual first, so the last line names the binary, as in install.
		for file in "$manual" "$target"; do
			if [ -e "$file" ] || [ -L "$file" ]; then
				rm -f "$file"
				echo "removed $file"
			fi
		done

		exit 0
		;;
	release)
		BUILD="release"
		MODE="$RELEASE"
		;;
	debug)
		BUILD="debug"
		MODE="$DEBUG"
		;;
	run)
		BUILD="debug"
		MODE="$DEBUG"
		;;
	test)
		BUILD="release"
		MODE="$RELEASE"
		;;
	install)
		BUILD="release"
		MODE="$RELEASE"
		;;
	*)
		echo "usage: $0" \
			"[release|debug|run [args...]|test [name]|install|uninstall|clean]" >&2
		exit 2
		;;
esac

if [ ! -x "$CC" ]; then
	echo "$0: musl compiler not found at $CC" >&2
	echo "clang and musl are the supported toolchain;" \
		"see Requirements in README.md." >&2
	exit 1
fi

# ------------------------------------------------------ toolchain enforcement
#
# clang and musl are enforced here, not merely documented. Everything this
# project states is musl's: the binary sizes, and the flags above, each
# verified against musl's headers. Building against another libc produces a
# program that may well work but is not the one described.

if ! "$CC" --version 2>/dev/null | grep -qi clang; then
	echo "$0: $CC is not clang." >&2
	echo "The build gate is -Weverything, which is a clang extension" \
		"with no GCC" >&2
	echo "equivalent. gcc cannot build this project." \
		"See Requirements in README.md." >&2
	exit 1
fi

# musl deliberately ships no identifying macro, so detect glibc and treat its
# absence as musl. The probe includes a libc header on purpose: __GLIBC__ comes
# from <features.h>, so a probe including nothing reports "not glibc" for every
# compiler. It is preprocess-only (-E) because musl-clang cannot do separate
# compilation (-c) under -Werror -- it always injects linker-only flags.
if printf '#include <stdio.h>\n#ifndef __GLIBC__\n#error not glibc\n#endif\n' |
	"$CC" -std=c17 -D_GNU_SOURCE -E -x c - > /dev/null 2>&1; then
	echo "$0: $CC targets glibc, not musl." >&2
	echo "" >&2
	echo "musl is the supported libc. Ways to get a musl toolchain:" >&2
	echo "  * a musl-native distro (Alpine, void-musl)" \
		"-- plain clang works, no wrapper" >&2
	echo "  * build musl from source; its own musl-clang wrapper" \
		"lands in <prefix>/bin:" >&2
	echo "      ./configure --prefix=\$HOME/musl CC=clang &&" \
		"make && make install" >&2
	echo "  * a packaged cross toolchain, e.g. cross-x86_64-linux-musl on Void" >&2
	echo "  * zig cc -target x86_64-linux-musl" \
		"(one binary, ships its own musl)" >&2
	echo "" >&2
	echo "Point CC at it:  CC=/path/to/musl-clang $0 $COMMAND" >&2
	exit 1
fi

OUT="bin/$BUILD/$PROGRAM"
FRAGMENT="bin/$BUILD/compile_commands.frag"

mkdir -p "bin/$BUILD"

# Delete the output first. clang leaves the old binary untouched when a compile
# fails -- same contents, same mtime -- so without this a failed build silently
# leaves you running the previous one.
rm -f "$OUT" "$FRAGMENT"

# clang writes the -MJ fragment even when the compile fails, so clean it up on
# any exit path.
trap 'rm -f "$FRAGMENT"' EXIT

# $COMMON, $MODE and $WARN are intentionally unquoted: they are flag lists that
# must word-split.
# shellcheck disable=SC2086
"$CC" $COMMON $MODE $WARN -MJ "$FRAGMENT" ./main.c -o "$OUT"

# Only reached on success, since set -e aborts above otherwise. The fragment is
# a bare object with a trailing comma, which is not valid JSON by itself.
printf '[\n%s\n]\n' "$(sed 's/,$//' "$FRAGMENT")" >compile_commands.json

rm -f "$FRAGMENT"
trap - EXIT

echo "built $PWD/$OUT"

if [ "$COMMAND" = "run" ]; then
	shift
	exec "./$OUT" "$@"
fi

if [ "$COMMAND" = "install" ]; then
	# --------------------------------------------------------------- install
	#
	# Installs a COPY, not a symlink: the installed binary must not change under
	# you when you rebuild for development, and `./build.sh clean` must not be
	# able to leave a dangling link where your screen locking used to be.
	prefix="${PREFIX:-$HOME/.local}"
	bindir="${DESTDIR:-}$prefix/bin"
	mandir="${DESTDIR:-}$prefix/share/man/man1"
	target="$bindir/$PROGRAM"
	manual="$mandir/$PROGRAM.1"

	# refuse_ DIR -- DIR is not writable: say how to finish the install as root.
	# -D, because the manual's directory may not exist yet.
	refuse_ ()
	{
		echo "$0: $1 is not writable." >&2
		echo "The build above succeeded, so copy it as root, for example:" >&2
		echo "    su -c \"install -D -T -m 755 '$PWD/$OUT' '$target' &&" \
			"install -D -T -m 644 '$PWD/$PROGRAM.1' '$manual'\"" >&2
		echo "Do not re-run this script under plain su: su resets HOME," \
			"so \$HOME/bin/musl-clang" >&2
		echo "would resolve to root's home" \
			"and the compile would fail before installing anything." >&2
		exit 1
	}

	# Each directory is made and checked before the next is made, so a refused
	# install leaves no empty manual directory behind.
	#
	# Each is normalised to an absolute, symlink-resolved path so the messages
	# below and the PATH comparison all speak about the same string. Without
	# this a trailing slash in PREFIX gives "$HOME/.local//bin", which matches
	# nothing in PATH and warns about a directory that is perfectly well on it.
	if ! mkdir -p "$bindir"; then
		echo "$0: cannot create $bindir" >&2
		exit 1
	fi

	bindir=$(cd "$bindir" && pwd -P)
	target="$bindir/$PROGRAM"

	if [ ! -w "$bindir" ]; then
		refuse_ "$bindir"
	fi

	if ! mkdir -p "$mandir"; then
		echo "$0: cannot create $mandir" >&2
		exit 1
	fi

	mandir=$(cd "$mandir" && pwd -P)
	manual="$mandir/$PROGRAM.1"

	if [ ! -w "$mandir" ]; then
		refuse_ "$mandir"
	fi

	# -T, so that a directory sitting at the target is an error rather than
	# being installed INTO while the script reports success for a path that is
	# not the file. The manual goes first, so the last line names the binary.
	install -T -m 644 "$PROGRAM.1" "$manual"
	echo "installed $manual"

	install -T -m 755 "$OUT" "$target"
	echo "installed $target"

	# A staging directory is never on PATH, so the check below would only put
	# a false warning into every package build.
	if [ -n "${DESTDIR:-}" ]; then
		exit 0
	fi

	# A prefix's bin is not necessarily on PATH (~/bin often is not) -- an easy
	# way to install something and then wonder why the shell cannot find it.
	# Both sides are resolved before comparing, so a different spelling of the
	# same directory does not produce a false warning.
	on_path=$(
		IFS=:
		for dir in $PATH; do
			if [ -z "$dir" ]; then
				dir=.
			fi

			if resolved=$(cd "$dir" 2>/dev/null && pwd -P); then
				if [ "$resolved" = "$bindir" ]; then
					echo yes
					exit 0
				fi
			fi
		done

		echo no
	)

	if [ "$on_path" != yes ]; then
		echo "warning: $bindir is not on your PATH," \
			"so '$PROGRAM' will not be found by name." >&2
		echo "         Add it, or run it as $target" >&2
	fi

	exit 0
fi

if [ "$COMMAND" != "test" ]; then
	exit 0
fi

# ----------------------------------------------------------------------- test
#
# Black-box tests: every one of them runs the built binary and checks what it
# actually did. There are no C unit tests, which is the same choice GNU
# coreutils made -- 722 tests, none of which call a function inside a program.
#
# The fake X server is built with the same flags and gate as the program.

mkdir -p bin/test
rm -f bin/test/fakex

"$CC" $COMMON $RELEASE $WARN tests/fakex.c -o bin/test/fakex

echo "built $PWD/bin/test/fakex"
echo

XIL_ROOT="$PWD"
XIL="$PWD/$OUT"
FAKEX="$PWD/bin/test/fakex"
srcdir="$PWD"
export XIL_ROOT XIL FAKEX srcdir

shift || true
selection="${1:-}"

# Per-test deadline. Override for a slow machine:
#     TEST_TIMEOUT=120 ./build.sh test
TEST_TIMEOUT="${TEST_TIMEOUT:-60}"

passed=0
failed=0
skipped=0
broken=0
failed_names=""

for t in tests/*.sh; do
	name=$(basename "$t" .sh)

	# init.sh is the harness, not a test.
	if [ "$name" = "init" ]; then
		continue
	fi

	if [ -n "$selection" ] && [ "$name" != "$selection" ]; then
		continue
	fi

	# Two guards here, both learned the hard way:
	#   - under `set -e` a bare assignment from a failing command substitution
	#     would abort the whole run on the first failing test;
	#   - a bug that stops the program exiting hangs the test forever, so
	#     every test gets a hard deadline. A wedged test must fail, not stall
	#     the suite.
	if output=$(timeout "$TEST_TIMEOUT" sh "$t" 2>&1); then
		status=0
	else
		status=$?
	fi

	case "$status" in
		0)
			passed=$((passed + 1))
			printf '  PASS  %s\n' "$name"
			;;
		124)
			failed=$((failed + 1))
			failed_names="$failed_names $name"
			printf '  TIMEOUT %s (exceeded %ss)\n' "$name" "$TEST_TIMEOUT"
			printf '%s\n' "$output" | sed 's/^/        /'
			;;
		77)
			skipped=$((skipped + 1))
			# skip_ in tests/init.sh writes "NAME.sh: SKIP: REASON".
			reason=$(printf '%s' "$output" | sed -n 's/^[^:]*: SKIP: //p' |
				head -1)
			printf '  SKIP  %s -- %s\n' "$name" "$reason"
			;;
		99)
			broken=$((broken + 1))
			printf '  ERROR %s\n' "$name"
			printf '%s\n' "$output" | sed 's/^/        /'
			;;
		*)
			failed=$((failed + 1))
			failed_names="$failed_names $name"
			printf '  FAIL  %s (exit %s)\n' "$name" "$status"
			printf '%s\n' "$output" | sed 's/^/        /'
			;;
	esac
done

echo
printf '%s passed, %s failed, %s skipped, %s errored\n' \
	"$passed" "$failed" "$skipped" "$broken"

if [ -n "$selection" ] &&
	[ $((passed + failed + skipped + broken)) -eq 0 ]; then
	echo "no test named '$selection'" >&2
	exit 2
fi

if [ "$failed" -ne 0 ] || [ "$broken" -ne 0 ]; then
	if [ -n "$failed_names" ]; then
		echo "failed:$failed_names" >&2
	fi

	exit 1
fi
