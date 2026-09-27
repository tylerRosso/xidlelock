# Security

xidlelock starts your screen locker; it does not lock the screen itself. A bug in it is a security bug when it leaves a
screen unlocked that should be locked.

## Reporting a vulnerability

Please report it privately, not in a public issue: open the repository's **Security** tab on GitHub and choose
**Report a vulnerability**. The report is visible only to you and the maintainer.

Include the version (`xidlelock -v`), your X server and locker, and the steps that lead to the problem.

You can expect an acknowledgement within 10 days, and a fix or an explanation before anything is made public.

## In scope

- A screen saver activation that should start the locker and does not.
- xidlelock stopping, signalling or otherwise ending a running locker.
- A signal aimed at xidlelock, such as a Ctrl-C or a hangup, reaching the locker.
- Memory-safety bugs in reading what the X server or `.Xauthority` sends.

## Out of scope

- Getting past the locker's own lock screen: report that to the locker's project (slock, i3lock, …).
- The limits the manual documents under CAVEATS: no lock before suspend, a locker that forks, a lock started outside
  xidlelock, `xset s off`, and DPMS timers.

## Supported versions

Only the latest release receives fixes.
