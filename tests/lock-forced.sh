#!/bin/sh
# SPDX-License-Identifier: ISC

# An activation the server marks as forced locks like any other.
#
# ScreenSaverNotify carries a forced byte (17), and a real server sets it for
# every activation but its own idle timeout: ForceScreenSaver, which is what
# `xset s activate` sends, and a DPMS power-down, which turns the saver on
# first (xorg-server: dix/dispatch.c ProcForceScreenSaver, Xext/dpms.c
# DPMSSet). Both are documented ways to lock, and until this test fakex only
# ever sent the timeout's forced = 0, so a program that skipped forced
# activations passed the whole default suite; only the opt-in smoke-real-x,
# through `xset s activate`, would have noticed.
#
# Seen to fail with `|| event[17] != 0` added to the condition that skips
# events. The gap was present since the initial import, 7a20770.

. "${srcdir=.}/tests/init.sh"

start_fakex_
make_locker_

start_xil_ "$PWD/locker"

fakex_send_ forced
fakex_grep_ '^SENT forced$' || fail=1

retry_ 5 locker_started_ 1 ||
	fail_ 'a forced activation started no locker'

release_locker_ "$(locker_pid_ 1)" || fail=1

Exit $fail
