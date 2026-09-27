# xidlelock Development Guidelines

Rules, and the reasoning behind the ones that look arbitrary. Most exist because something already went wrong.
User-facing documentation is in `README.md`; this file is for people changing the code.

## Toolchain

```sh
./build.sh [release|debug|run [args]|test [name]|install|uninstall|clean]
```

- **clang and musl are ENFORCED by `build.sh`, not just documented.** Before any compile it checks `$CC --version` for
  clang and preprocesses a probe to reject a glibc target. Do not remove either: every figure this project states is
  musl's.
  - The probe must `#include <stdio.h>` — `__GLIBC__` comes from `<features.h>`, so a probe including nothing reports
    "not glibc" for *every* compiler.
  - The probe is `-E` only: musl-clang cannot do separate compilation (`-c`) under `-Werror`, because it always injects
    linker-only flags. Keep the build one compile-and-link.
  - `clean` and `uninstall` run before the check and need no compiler.
  - `$CC` is honoured; the default is `$HOME/bin/musl-clang`.
- **Fully static.** `musl-clang` is `clang -static` with its own sysroot, so anything linked in must exist as a static
  archive.
- **The build must stay clean under `-std=c17 -Weverything -Werror`.** Restructure the code rather than silencing a
  warning. `-Weverything` is not a stable interface, so a compiler upgrade can fail a clean build. When that happens,
  add a targeted `-Wno-` in `build.sh`; do not change the C files. The one warning silenced in source is
  `-Wunused-function`, inside `xwire.h` only; see Code Conventions.
- Three flags are load-bearing, each verified by removal:
  - `-D_GNU_SOURCE` — `-std=c17` sets `__STRICT_ANSI__`, hiding `ppoll`, `environ`, `sigaction` and the rest of the
    signal API, `PATH_MAX` and `SOCK_CLOEXEC`. Unlike a program that needs only POSIX, `-D_POSIX_C_SOURCE=200809L` does
    **not** build: musl declares `ppoll` and `environ` only under `_GNU_SOURCE` or `_BSD_SOURCE`. The source uses no
    GNU extensions. Passed on the command line, not `#define`d, which would trip `-Wreserved-macro-identifier`.
  - `-Wno-disabled-macro-expansion` — **not** glibc baggage: musl needs it for its own self-referential `stderr`,
    `stdout` and `sa_handler` macros.
  - `-Wno-unsafe-buffer-usage` — fires on all pointer arithmetic (47 diagnostics in `main.c`); unusable in C.
- Tested and rejected, do not add back: `-static`, `-D_FORTIFY_SOURCE`, `-Wl,-z,relro,now` and `-Wl,-z,noexecstack`
  all leave the release binary byte for byte the same — redundant (`$CC` already is `-static`) or no-ops on this
  sysroot, and `_FORTIFY_SOURCE` is the dangerous one, because it reads as hardening that is absent. `-static-pie`
  builds, but `ld.musl-clang` always appends `-dynamic-linker`, so the result cannot run (exit 127).
- ASan cannot link against static musl. UBSan works in minimal-runtime form and is in the debug build. For full ASan,
  build a throwaway dynamic binary with the system clang — a debugging command, not a build target. The fakex tests run
  against either by pointing `XIL` at it (`XIL=/tmp/xil sh tests/NAME.sh`, with `XIL_ROOT`, `FAKEX` and `srcdir` set
  as `build.sh test` sets them).
- Every build regenerates `compile_commands.json` via `clang -MJ`. It captures the wrapper's injected
  `-nostdinc --sysroot`, which is the point: without it clangd accepts code the gate rejects.
- After editing C, run `clang-format -i` on the files you touched and rebuild.

### `build.sh` invariants — do not undo

- `set -eu`, so a failed compile cannot fall through to the success message.
- `cd "$(dirname "$(readlink -f "$0")")"` — `readlink -f` matters; plain `$(dirname "$0")` breaks when the script is
  reached through a symlink.
- `rm -f "$OUT"` **before** compiling. clang leaves the previous binary untouched on a compile error, same contents and
  same mtime, so without this a failed build silently leaves you running stale code.
- The `-MJ` fragment is written even when the compile fails, so an `EXIT` trap removes it and `compile_commands.json` is
  rewritten only on success.
- `CC="${HOME:-}/bin/musl-clang"` — an unset `HOME` must not abort `clean` or `uninstall` under `set -u`; neither needs
  a compiler.

## Install

- Copies, never symlinks. A symlink lets `./build.sh clean` leave a dangling link where the screen locking used to be,
  and lets a stray `./build.sh debug` put a UBSan build in the login path. `tests/install-copy.sh` pins this.
- `install -T` is deliberate: without it a directory at the target path is installed *into* while the script reports
  success for a path that is not the binary.
- The unwritable-target message must keep suggesting a command that copies the **already-built** binary as root. Never
  suggest re-running this script under plain `su`: `su` resets `HOME`, so `$HOME/bin/musl-clang` resolves to root's home
  and the build fails before installing anything.
- The PATH warning resolves both sides with `cd … && pwd -P` before comparing; a literal string match warns falsely for
  a trailing slash, a relative path or a symlinked spelling.
- The manual goes to `$PREFIX/share/man/man1` at mode 644, installed **before** the binary, so the last line of output
  still names the binary; `uninstall` removes both, and says "nothing installed" only when neither is there. Each
  directory is made and checked before the next is made, so a refused install leaves no empty `man1` behind.
- `DESTDIR` is prepended to both paths, by `install` and `uninstall` alike, and turns the PATH warning off: a staging
  directory is never on PATH. `install-destdir` sets `PREFIX` inside its own directory too, never `/usr`, so a build.sh
  that ignored `DESTDIR` could not reach the real system. `init.sh` unsets `DESTDIR`, as it neutralises `PREFIX`: one
  exported in the shell running the suite carried `install-copy`'s files outside its directory.

## Tests

- `./build.sh test` builds the program and `tests/fakex.c`, then runs every `tests/*.sh`. `tests/init.sh` is the harness
  and is skipped by the runner.
- **Black box only. Do not add C unit tests.** Every test runs the built binary and checks what it did.
- **The suite must never run the real `slock`.** Every test names its locker, a stand-in from `make_locker_`, except
  `args-default`, which puts a stand-in `slock` first on `PATH` and refuses to start the program unless `command -v
  slock` resolves to it.
- **Assert against LITERAL X11 numbers** (98, 6, 3, 2, 1), never the macro names in `main.c`. A test that compared the
  program to its own macros would pass with every constant wrong.
- **The extension's numbers must be asserted in both fakex modes.** A real server assigns MIT-SCREEN-SAVER's major
  opcode and first event at startup. fakex uses 144/91, and 150/95 in `moved` mode; a program that hard-coded the first
  pair passes every `ok`-mode test, which is why `wire-select` and `lock-activate` run in both.
- **Every test must be seen to fail.** Break `main.c` deliberately, watch that test go red, restore. A test never
  observed failing is worse than none — it reads as coverage. The suite was swept with 37 such mutations, one or more
  per test, and every one was caught — after the sweep had found three of the traps below: the shell's signal mask,
  the inherited blocked signal, and the MappingNotify byte. The 20 caught since, by the tests and assertions added
  after the sweep, are recorded in those tests' comment blocks; record the mutation there for any new test, and for a
  regression test.
- **Proving that something did not happen needs a point after which it would have.** `lock-other-events` sends the
  events, then has the server hang up: the program reads everything queued before the end of the stream and exits, and
  `posix_spawn` does not return before the exec, so once the program has exited any locker it started exists as a
  process. Waiting a while and seeing nothing proves nothing.
- **The shell clears its signal mask when it starts**, so a script locker always reports an empty `SigBlk` whatever it
  was given — a test built that way passed with `POSIX_SPAWN_SETSIGMASK` removed. `lock-isolation` uses `sleep` as the
  locker, and starts the program with SIGQUIT blocked through `env --block-signal` so the right mask is recognisably
  neither empty nor the program's working one.
- **An inherited blocked signal is its own case.** `wait_mask` starts as the mask the program inherited, so the
  `sigdelset` calls only matter when the parent had those signals blocked; with a plain start, removing one passes.
  `signal-exit` therefore also starts the program with each signal blocked, where `env` supports it.
- **`kill -0` succeeds on a zombie.** `release_locker_` waits for it to fail, which is how the suite proves the locker
  was *reaped*, not merely that it exited.
- **Anchor `pgrep -f` on the locker's interpreter.** The program's own command line names the locker too; an
  unanchored pattern counted the program as a second locker.
- **Lockers outlive the test's process group.** The program starts them in a session of their own, so a test's timeout
  cannot kill them. The stand-in gives up by itself when the test directory disappears or after 30 seconds; a test that
  starts any other locker kills it from `cleanup_`.
- **The readiness barrier is `SELECTINPUT` in the fakex log.** The program installs its signal handlers before it
  writes that request, so from then on it can be signalled, and an event sent is one it will read. `start_xil_` waits
  for it.
- `fakex_send_` drives events through fakex's control fifo. fakex holds it open read-write, so a write cannot block
  while fakex lives; `fakex_send_` checks that it does, because with no reader at all the open blocks for ever.
- fakex's MappingNotify carries 1 — the value of On — in its unused byte 1, so a program that read the state without
  checking the event code would lock on it.
- **fakex has two activations**: `on` is the idle timeout's, with the forced byte 0, and `forced` is what a real server
  sends for ForceScreenSaver (`xset s activate`) and a DPMS power-down, with it 1. With only `on`, a program that
  skipped forced activations passed the whole default suite; `lock-forced` pins them.
- `returns_ N cmd` asserts an exact status. Never `cmd || fail=1` — that passes on a segfault.
- `retry_` polls; never sleep-and-hope. **Trap:** `retry_ 5 test "$(grep -c …)" -eq 3` expands the substitution once and
  compares the same stale number 250 times. Wrap it in a function, as `locker_started_` does.
- `wait_xil_` kills a program still running after five seconds, so a program that should have exited fails with 137
  instead of hanging the suite. Its watchdog writes to `/dev/null`: `build.sh` reads each test through a pipe and waits
  for every writer, a stray `sleep` included. **It stops the watchdog with SIGKILL**, never TERM: `init.sh` traps TERM,
  and a TERM that reaches the just-forked watchdog while it still carries that trap is lost. dash lost it every time
  the kill followed the fork at once, as it does when the program has already exited; the watchdog then slept out its
  five seconds — 35 of the suite's 40 — and sent SIGKILL to a pid already reaped.
- Exit statuses: 0 pass, 1 fail, **77 skip**, **99 the test's own setup broke**. Keep the last two distinct.
- `TEST_TIMEOUT` (default 60s) per test is load-bearing: a bug that stops the program exiting otherwise hangs the whole
  suite instead of failing one test.
- `tests/fakex.c` must keep compiling under the same gate as `main.c`, and must keep probing with `connect()` before
  binding so it refuses a socket already being served — that is what makes attaching to the real `:0` structurally
  impossible. Do not replace it with a bare `unlink()`.
- `smoke-real-x` is the only test allowed near the live display: `skip_`-by-default behind `XIL_TEST_REAL_X=1`, it
  blanks the screen for a moment with `xset s activate`, resets the saver from a `cleanup_` hook, and skips while a
  locking daemon runs that would lock the screen for real. It uses the session's own `DISPLAY` and `XAUTHORITY`, saved
  **before** sourcing `init.sh`, which overwrites both; it once assumed `:0` and `~/.Xauthority`, which skips on a
  machine running `:1` and fails where a display manager keeps the cookie elsewhere.
- **A new source file must be added to `make_proj_`** in `tests/install-copy.sh`, `tests/install-uninstall.sh` and
  `tests/install-destdir.sh`. They build and install from a copy made of the files named there, so a file the compiler
  or `install` needs and the copy lacks — the manual is one — fails all three at the first build or install.
- `doc-manpage` compares the options in the usage with the tags of the manual's OPTIONS section as `mandoc` renders
  them, found by their indent: two spaces in the usage, five in the rendering. It pipes through `col -bx`, not `-b`,
  which turns runs of spaces into tabs. Its lint is `-W warning`, leaving out the style notes: "referenced manual not
  found" depends on which manuals a machine has installed.

## Code Conventions

- **libc only.** No third-party dependencies, including X11 client libraries: speaking the protocol directly is the
  point of the project, and it must build on a machine with no X11 headers.
- **Single translation unit**, everything `static`. `main.c` includes `xwire.h` textually; nothing is compiled
  separately, which musl-clang could not do under the gate anyway.
- **`xwire.h` is a byte-for-byte copy of xrootclock's.** It is the X11 transport and nothing else — DISPLAY parsing,
  the `.Xauthority` cookie, connect, handshake, `x_sync`, `x_drain` — and it may depend on the includer only through
  `PROGRAM_NAME`. Change it in xrootclock first, then copy it here in a commit of its own; `cmp` the two before
  committing. This program uses neither `x_sync` nor `x_drain`, which is why the header turns `-Wunused-function` off
  between a `push` and a `pop` of its own. Requests specific to this program (`QueryExtension`,
  `ScreenSaverSelectInput`) stay in `main.c`.
- **Never kill the locker.** Not on exit, not on a signal, not when the server goes away: a dead locker is an unlocked
  screen. `signal-exit` pins it.
- **The locker gets a session of its own and the signal state this program started with**: `POSIX_SPAWN_SETSID`,
  `SETSIGMASK` with the inherited mask, `SETSIGDEF` for SIGPIPE (which this program ignores, and an ignored signal
  survives exec). A Ctrl-C or a hangup aimed at this program's process group must not reach the locker.
- **One locker at a time.** An activation while the last locker still runs starts nothing; the saver times out again
  on a locked screen as soon as the user walks away.
- **The handled signals are blocked everywhere except inside `ppoll`**, which unblocks them atomically for the wait. A
  signal that arrives while an event is handled stays pending and ends the next wait at once, instead of landing
  between the `keep_running` check and the wait. SIGCHLD has a handler that does nothing: its default action is to be
  discarded without interrupting the wait, which would leave an exited locker a zombie until the next activation.
- **Signal setup happens after `QueryExtension` and before `ScreenSaverSelectInput`.** Before it, the default actions
  still apply, so SIGTERM kills a program stuck in a handshake the server never answers. After it, the server's having
  seen the selection means the handlers are in place, which is the tests' readiness barrier.
- **No request after the selection, and no sync.** `x_sync` skips the events that arrive ahead of its reply, so an
  activation in that window would be lost. An error answering the selection arrives in the main loop instead, and is
  fatal there.
- **The event code comes from `QueryExtension`**, never a constant, and is compared with the SendEvent bit (0x80)
  masked off, as libX11 and xcb both do.
- **Wire buffers are plain `uint8_t` arrays with explicit offsets**, never structs — structs invite padding and
  alignment assumptions on a wire protocol, and `-Wpadded` rejects them anyway.
- **Array bounds must be compile-time constants.** `pad4()` is a function, hence `QUERY_EXTENSION_REQUEST` rather than a
  VLA.
- **Declarations at the top of their block** — `-Wdeclaration-after-statement` is on.
- **Line length.** Markdown wraps at 120 columns, table rows excepted; shell at 80. C is whatever `clang-format`
  produces from the repository `.clang-format`.
- **Comments and messages describe any machine, not this one.** Never state what is on this machine's PATH, which
  privilege tools it has or lacks, or what runs on its desktop; say what is true everywhere.

## Version Control

- Licensed ISC (`LICENSE`), with `SPDX-License-Identifier: ISC` at the top of every source file: the C files, the
  manual, `build.sh` and every `tests/*.sh`, where it follows the `#!` line. Keep the SPDX line on any new source
  file: it survives a file being copied out of the repo.
- **`tests/init.sh` takes gnulib's names, never its code.** gnulib's `init.sh` is GPL-3.0-or-later and this one is
  ISC. Its four outcome helpers once matched gnulib's almost word for word, and were rewritten around `end_`; the
  `SKIP: ` that `skip_` writes is what `build.sh` reads a skip's reason back from.
- `master` is the only long-lived branch; anything else is short-lived, merged and deleted.
- `.vscode/` is tracked on purpose: the lldb-dap launch config and the build tasks are project setup, not personal
  preference. Do not add it to `.gitignore`.
- **Committing is the owner's call.** Leave changes in the working directory for review.
- **The version lives in `VERSION` in `main.c` and nowhere else**; `-v` prints it as `xidlelock-VERSION`, and
  `args-version` pins that form, not the value. A release changes it and tags the commit `vVERSION`. The manual's
  `.Dd` is the date the manual last changed: update it with any edit to the manual.

### Commit messages — coreutils/gnulib style

There is no `ChangeLog` file: the git log is the ChangeLog. The format follows coreutils' `HACKING`, adapted to a
one-program repository.

- **Subject: `area: summary`.** Lower-case area from the table, colon, space, then an imperative lower-case summary with
  no trailing period. At most 72 characters. The areas are the prefixes the test files already use, so subjects and test
  names share one vocabulary.

  | area | covers |
  |---|---|
  | `args` | option parsing, the locker's command line, usage text |
  | `auth` | `.Xauthority` parsing, cookie selection |
  | `display` | `$DISPLAY` parsing, socket path |
  | `lock` | starting, guarding and reaping the locker |
  | `wire` | X11 protocol bytes: handshake, `QueryExtension`, the event selection, `xwire.h` |
  | `server` | replies, X errors, refusals, disconnects |
  | `signal` | signal handling, exit paths |
  | `install` | `build.sh install` / `uninstall` |
  | `build` | `build.sh` otherwise: flags, toolchain checks |
  | `tests` | harness or tests when no program area fits |
  | `fakex` | `tests/fakex.c` |
  | `doc` | `README.md`, `AGENTS.md`, `SECURITY.md`, the manual, comment-only changes |
  | `maint` | housekeeping: formatting, `.gitignore`, licence, editor config |
  | `all` | touches most of the tree: the initial import, a rename |

  Pick the area of the behaviour that changed, not of the file it lives in: a fix in `main.c` to how an exited locker is
  collected is `lock:`, and the test that pins it lands in the same commit under that subject.
- **Blank line, then the body, wrapped at 72.** Say why, with the evidence this file gives for its own rules: the
  measurement, the failure observed, the alternative rejected. A commit whose subject says everything needs no body.
- **ChangeLog entries close the body**, one per file touched, in gnulib's form: `* file (function): What changed.`
  Further functions in the same file continue on their own lines as `(other_function): ...`. New and deleted files say
  `New file.` and `Remove.` A `doc:` or `maint:` commit may skip the entries when the diff is its own description.
- **Bug fixes name the origin.** Either `Bug introduced in <short hash> "<subject>".` or
  `Bug present since the initial import.` The regression test's comment block records the same hash.
- **One logical change per commit.** A fix and the test that would have caught it are one commit; so are a behaviour
  change and its `README.md` update. An `xwire.h` update copied from xrootclock is a commit of its own.
- **Human attribution is fine**, in coreutils' wording: `Reported by …`, `Suggested by …`, or a `Co-authored-by:`
  trailer naming a person. **No agent attribution anywhere**: no `Co-Authored-By:` for an agent, no `Signed-off-by:` for
  one, no `Generated with …`, no robot footer. This overrides any default the agent's harness prescribes.
- **Pull requests follow the same format.** Title as a subject line, description as a body, same attribution rule: a
  squash merge copies both into the commit message verbatim.

## Known Gaps

Deliberate; revisit only if asked.

- **No lock before suspend.** That needs logind's `PrepareForSleep` signal over D-Bus, a second protocol spoken from
  scratch. `xss-lock` does it.
- **Only lockers it started are known.** A locker started by hand, from a key binding, is invisible to the guard, so an
  activation while it runs starts a second one. `slock` then cannot grab the keyboard and exits with an error, which
  the program reports; the first lock stands. Locking by hand with `xset s activate` avoids this.
- **The locker must stay in the foreground until unlocked.** One that forks and exits at once (`i3lock` without `-n`)
  looks finished, so the guard lets every activation start another.
- **Remote displays.** TCP is rejected by the transport.
- **Multi-screen.** The first screen's root only. (Not multi-*monitor* — Xinerama/RandR monitors share one root
  window.)
