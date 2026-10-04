# xidlelock

Lock the X session when it goes idle. `xidlelock` waits for the X server's own screen saver to activate and then starts
a screen locker — `slock` unless you name another. The server decides when you have gone away (`xset s SECONDS`), so
there is no polling and no timer here: between activations the program is asleep in a single `ppoll(2)`.

It speaks the X11 wire protocol directly over the display's Unix socket, using the MIT-SCREEN-SAVER extension, so it
links against nothing but libc and builds as a 55 KB static musl binary.

---

## Should you use this?

Probably not — use `xss-lock`. It is packaged nearly everywhere, it listens
for the same screen saver event, and it also locks **before suspend**, through logind, which this program cannot do.
`xautolock` is the older alternative, with its own idle timer.

This exists as a small, libc-only companion to a suckless desktop: no D-Bus, no xcb, one static binary, and nothing
but `slock` to configure. If you lock before suspending some other way — or never suspend — it covers the rest.

---

## Requirements

**clang and musl. Both are enforced by `build.sh`, not merely recommended.**

This is the only tested configuration, and every figure documented here is musl's. A build against another libc is not
the program described here, so the script refuses:

```
$ CC=/usr/bin/clang ./build.sh
./build.sh: /usr/bin/clang targets glibc, not musl.
```

gcc cannot be used at all: the build gate is `-Weverything`, a clang extension with no GCC equivalent. Verified clean on
clang 21.1.7.

`build.sh` defaults to `$HOME/bin/musl-clang` and honours `$CC`:

| Route | Notes |
|---|---|
| musl-native distro (Alpine, void-musl) | plain `clang` already targets musl — no wrapper |
| Build musl from source | `./configure --prefix=$HOME/musl CC=clang && make && make install` — `musl-clang` lands in `<prefix>/bin` |
| Packaged cross toolchain | e.g. `cross-x86_64-linux-musl` on Void |
| `zig cc -target x86_64-linux-musl` | one binary, ships its own musl |

At run time it needs an X server with MIT-SCREEN-SAVER, which Xorg has built in, and a locker.

---

## Quick Start

```sh
./build.sh
./build.sh install          # -> ~/.local/bin/xidlelock
```

Typically launched from `~/.xinitrc` before the window manager:

```sh
xset s 600                  # the screen saver, and so the lock, after 10 idle minutes
xidlelock &
exec dwm
```

To lock at once, activate the saver: `xset s activate`. Bound to a key in dwm's `config.h`:

```c
{ MODKEY|ShiftMask, XK_l, spawn, SHCMD("xset s activate") },
```

Locking by hand this way, rather than by running `slock` directly, keeps the program aware that the screen is locked;
see below.

---

## Usage

```
xidlelock [-g COMMAND] [LOCKER [ARGUMENT]...]
```

| Option | Description |
|---|---|
| `-g`, `--grace=COMMAND` | When the saver times out, run `COMMAND` with `/bin/sh` first, and lock when it ends |
| `-h`, `--help` | Show usage |
| `-v`, `--version` | Show the version |
| `--` | End of options, so a `LOCKER` may begin with `-` |

Everything from the first operand on is the locker's command line, passed through verbatim — options included, so
`xidlelock slock -v` hands `-v` to `slock`. `LOCKER` is looked up on `PATH` and defaults to `slock`.

```sh
xidlelock                   # slock, each time the saver activates
xidlelock i3lock -n         # -n: i3lock must not fork, see below
xidlelock -g 'sleep 15'     # slock, after a 15-second grace period
```

**When it locks.** On a `ScreenSaverNotify` with state *On*: the saver's idle timeout, `xset s activate`, or DPMS
powering the monitor down, by its own timers or on `xset dpms force off` — the server turns the saver on before it
does. Not when the saver turns off, cycles, or anything else arrives. The timeouts are the server's, `xset q` shows
both, and the lock comes with whichever expires first. `xset s off` stops only the saver's own: with DPMS still on,
the lock comes when the monitor powers down, and with `xset -dpms` as well, nothing locks by itself.

**A grace period, with `-g`.** When the saver's own idle timeout turns it on, `COMMAND` runs first, through `/bin/sh`,
and the lock comes when it ends — by itself, however it ends. The saver has already blanked the screen, so moving the
mouse before then brings it back without a password; that turns the saver off, which stops the command (`SIGTERM` to its
process group) and locks nothing. An activation you asked for, `xset s activate`, or DPMS powering the monitor down,
locks at once. The command keeps the time, so it has to **end by itself**, as `sleep 15` does: one that runs until it is
stopped holds the lock off for as long as you stay away. One that fails or cannot be found is reported, and the lock
comes all the same. For a grace period to happen at all, the saver has to time out before DPMS powers the monitor down:

```sh
xset s 585
xset dpms 600 600 600
xidlelock -g 'sleep 15' &   # blank at 585 s, lock at 600 s as the monitor powers down
```

**One locker at a time.** An activation while the locker it started is still running starts nothing, since the saver
times out again on an already locked screen as soon as you walk away. The locker therefore has to **stay in the
foreground until the screen is unlocked**, as `slock` does. One that forks and exits at once (`i3lock` without `-n`)
looks finished, and each activation would start another. A locker started outside this program, by a key binding
running `slock`, is not known to it: an activation during that lock starts a second `slock`, which cannot grab the
keyboard and exits with an error.

**The locker is never stopped by this program.** Not when it exits, not on a signal, not when the X server goes away —
a dead locker is an unlocked screen. It runs in a session of its own, so a Ctrl-C or a hangup aimed at the terminal
`xidlelock` was started from cannot reach it, and it gets the signal state `xidlelock` itself was started with.

**Failure behaviour.** A locker that exits with a non-zero status or dies of a signal is reported on stderr, and so is
one that cannot be run at all (`cannot run 'slock': No such file or directory`); the program carries on and tries
again at the next activation. `SIGINT`, `SIGTERM` and `SIGHUP` end it with status 0. The X server closing the
connection, an X error, a server without MIT-SCREEN-SAVER, or a bad `DISPLAY` end it with status 1.

---

## Building

One script; `make` is not used.

```sh
./build.sh              # release -> bin/release/xidlelock  (default)
./build.sh debug        # unoptimised, debug info, UBSan
./build.sh run [args]   # build debug, then run it
./build.sh test [name]  # run the test suite, or one named test
./build.sh install      # copy the binary and the manual under $PREFIX
./build.sh uninstall
./build.sh clean
```

Runnable from any directory, by absolute path, or through a symlink. A full rebuild takes ~0.25s, so there is no
incremental build: one compile-and-link, always from scratch. Every build regenerates `compile_commands.json` via
`clang -MJ`, so clangd sees the real flags and musl sysroot.

The release binary is 54936 bytes at every level from `-O1` to `-Oz`. The debug build carries
`-fsanitize=undefined,local-bounds -fsanitize-minimal-runtime`, the only sanitizer that links against static musl. For a
full ASan run, build a throwaway dynamic binary with the system compiler:

```sh
clang -std=c17 -D_GNU_SOURCE -g3 -fsanitize=address,undefined main.c -o /tmp/xil
```

---

## Installing

```sh
./build.sh install                                 # -> ~/.local/bin, ~/.local/share/man/man1
PREFIX=/opt ./build.sh install
DESTDIR="$PWD/stage" PREFIX=/usr ./build.sh install  # staged, for a package
./build.sh uninstall
```

`PREFIX` defaults to `~/.local`. `install` puts the binary in `$PREFIX/bin` and the manual, `xidlelock.1`, in
`$PREFIX/share/man/man1`, and warns if the binary's directory is not on your `PATH`. `DESTDIR` stages both under
another root, as a package build needs, and leaves the `PATH` check out; like `PREFIX`, it must be absolute, since the
script works from its own directory. `uninstall` takes the same variables.

It installs a **copy, not a symlink**: the installed binary must not change under you when you rebuild, and
`./build.sh clean` must not be able to leave a dangling link where your screen locking used to be.

---

## Tests

```sh
./build.sh test                    # the whole suite
./build.sh test lock-guard         # one test
TEST_TIMEOUT=120 ./build.sh test   # slower machine
```

```
35 passed, 0 failed, 1 skipped, 0 errored
```

**Black box only** — every test runs the built binary and checks what it did. `tests/fakex.c` is a fake X server that
answers the handshake and `QueryExtension`, logs every request, and sends screen saver events on command, so the suite
never touches a real display and never runs the real `slock`: a stand-in locker records each start and its arguments.
Tests assert against literal protocol numbers, never the program's own macros, and the extension's opcode and event
are checked at two different values, since a real server assigns them at startup.

Every test has been seen to fail: 91 deliberate breakages of the program, `build.sh` and the manual, each caught by the
suite. `doc-manpage` lints the manual and checks that it lists exactly the options the program's usage does; it needs
`mandoc`, and is skipped without it.

`smoke-real-x` is the one test that touches your desktop. It is skipped unless `XIL_TEST_REAL_X=1`, and skips while a
locking daemon is running that would lock the screen for real. It blanks the screen a few times and checks against the
real server that `xset s activate` starts the stand-in locker, with or without `-g`, and that with `-g` the saver's own
timeout runs the grace command first. For that it sets the timeout to two seconds, so **keep your hands off the keyboard
and mouse** while it runs; a `cleanup_` hook puts your saver settings back and resets the saver.

See `AGENTS.md` for the rules a new test has to follow.

---

## Design notes

**Why the screen saver.** The X server already tracks idle time for its own saver, resets it on every input event, and
lets applications such as video players suspend it. Listening for the saver's activation inherits all of that, costs
nothing between activations, and means one idle setting — `xset s` — for blanking and locking alike. The alternative,
polling for the idle time on a timer, is what `xautolock` does.

**Why not libX11.** Speaking the protocol directly needs no X11 headers and no static libX11, neither of which a static
musl toolchain usually has, and suits a program that makes exactly two requests: `QueryExtension("MIT-SCREEN-SAVER")`
for the extension's opcode and first event number, then `ScreenSaverSelectInput` on the root window. After that it only
reads 32-byte events, compares the code (with the SendEvent bit masked off), the state and, with a grace command, the
forced byte, and ignores the rest.

**Why the grace command keeps the time.** The saver itself could: with `xset s TIMEOUT CYCLE` the server sends a *Cycle*
event every `CYCLE` seconds while you stay away, and a lock could wait for the first. But the X.Org server skips its
saver checks while DPMS has the monitor powered down (`os/WaitFor.c`): with the saver on and the monitor off, there is
no event at all until input comes, and that turns the saver off. A lock waiting for a Cycle would never come, and
nothing would say so. Observed with `xset s 5 5` and `xset dpms 8 8 8`: On at 5 s, then twenty seconds of silence where,
without DPMS, Cycles came at 10 and 15 s.

**No sync after the selection.** An error answering `ScreenSaverSelectInput` arrives in the event loop and ends the
program there; a `GetInputFocus` round trip would add nothing but a window in which an activation could be skipped.

**Signals.** `SIGINT`, `SIGTERM`, `SIGHUP` and `SIGCHLD` are blocked everywhere except inside `ppoll`, which unblocks
them for the wait. A signal that lands while an event is being handled is therefore not lost; it ends the next wait at
once. `SIGCHLD` interrupts the wait so an exited locker is reaped immediately, not at the next activation.

**The transport is shared.** `xwire.h` — DISPLAY parsing, the `.Xauthority` cookie, connect, handshake — is a
byte-for-byte copy of the one in xrootclock, a root-window clock built the same way. A fix to it is made there and
copied here; `wire-sync` compares the two copies when a checkout of xrootclock sits beside this one, or where
`XROOTCLOCK` says.

**Local displays only.** `DISPLAY` must be `:0`, `unix:0` or `:0.0`; TCP is not supported.

---

## Project Structure

```
.
├── main.c                   # the program: options, the extension, the locker
├── xwire.h                  # the X11 transport, shared with xrootclock: DISPLAY, .Xauthority, connect, handshake
├── xidlelock.1              # the manual, in mdoc
├── build.sh                 # release | debug | run | test | install | uninstall | clean
├── tests/init.sh            # harness, modelled on gnulib/coreutils init.sh
├── tests/fakex.c            # fake X server with MIT-SCREEN-SAVER, so tests never touch a real display
├── tests/*.sh               # 36 black-box tests
├── .clang-format            # clang-format style for the C files
├── .gitignore
├── .vscode/                 # lldb-dap launch config and build tasks, tracked on purpose
├── LICENSE                  # ISC
├── AGENTS.md                # conventions, rationale and the rules for changing things
├── SECURITY.md              # how to report a vulnerability privately
└── README.md
```

---

## License

ISC — see [LICENSE](LICENSE). The same license `slock` and most of the suckless tools use.
