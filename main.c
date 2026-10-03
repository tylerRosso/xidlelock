/* SPDX-License-Identifier: ISC */

/* xidlelock - start a screen locker whenever the X screen saver activates.
 *
 * The X server's own idle timer (xset s SECONDS) decides when the user has gone
 * away; this program only listens for it. It selects ScreenSaverNotify on the
 * root window through the MIT-SCREEN-SAVER extension and, each time the saver
 * turns on, starts the locker -- slock unless another command is given -- unless
 * the one it started last is still running. `xset s activate` turns the saver on
 * at once, which makes it a lock-now command as well.
 *
 * The X11 wire protocol is spoken directly over the display's Unix socket, so
 * the program links against nothing but libc. Between activations it is blocked
 * in ppoll(2).
 */

/* xwire.h prefixes its diagnostics with PROGRAM_NAME, so it must be defined
 * before the includes: clang-format keeps quoted includes ahead of system ones. */
#define PROGRAM_NAME "xidlelock"

#include "xwire.h"

#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

/* The user-visible default. */
#define DEFAULT_LOCKER "slock"

/* The one place the version lives; a release changes it and tags vVERSION. */
#define VERSION "1.1"

/* X11 protocol constants (X11/Xproto.h). The transport's own live in xwire.h. */
#define X_OPCODE_QUERY_EXTENSION 98

/* SendEvent sets the top bit of an event's code; the event is otherwise the
 * same. */
#define X_EVENT_SENT 0x80u

/* MIT-SCREEN-SAVER (X11/extensions/saver.h, X11/extensions/saverproto.h). Its
 * major opcode and first event number are not constants: the server assigns
 * them at startup and QueryExtension reports them. */
#define SAVER_NAME "MIT-SCREEN-SAVER"
#define SAVER_NAME_LEN 16
#define SAVER_SELECT_INPUT 2 /* minor opcode */
#define SAVER_NOTIFY_MASK 1u
#define SAVER_NOTIFY 0 /* event, counted from the extension's first */
#define SAVER_STATE_ON 1

/* pad4() is a function, so the wire buffer needs a constant bound of its own.
 * SAVER_NAME_LEN is already a multiple of four. */
#define QUERY_EXTENSION_REQUEST (8 + SAVER_NAME_LEN)

static volatile sig_atomic_t keep_running = 1;

static void on_signal(int signal_number)
{
	(void)signal_number;

	keep_running = 0;
}

/* SIGCHLD's default action is to be discarded, which would leave ppoll()
 * asleep with an exited locker unreaped until the next activation. A handler,
 * even one that does nothing, makes it interrupt the wait instead; the main loop
 * does the reaping. */
static void on_child(int signal_number) { (void)signal_number; }

/* --------------------------------------------------------------- requests */

/* QueryExtension("MIT-SCREEN-SAVER"). The reply says whether the server has the
 * extension, the major opcode its requests go under and the code its first event
 * arrives as. */
static bool x_query_saver(int file_descriptor, uint8_t *major_opcode, uint8_t *first_event)
{
	uint8_t request[QUERY_EXTENSION_REQUEST];
	uint8_t packet[32];

	memset(request, 0, sizeof request);

	request[0] = X_OPCODE_QUERY_EXTENSION;
	put16(request + 2, (uint16_t)((8u + pad4(SAVER_NAME_LEN)) / 4u));
	put16(request + 4, SAVER_NAME_LEN);
	memcpy(request + 8, SAVER_NAME, SAVER_NAME_LEN);

	if (!write_all(file_descriptor, request, sizeof request))
	{
		fprintf(stderr, PROGRAM_NAME ": cannot query the X server's extensions: %s\n", strerror(errno));

		return false;
	}

	/* No event is selected yet, but a server sends some to every client
	 * regardless (MappingNotify); skip past them to the reply. */
	for (;;)
	{
		if (!read_all(file_descriptor, packet, sizeof packet))
		{
			fprintf(stderr, PROGRAM_NAME ": the X server closed the connection: %s\n", strerror(errno));

			return false;
		}

		if (packet[0] == X_ERROR)
		{
			fprintf(stderr, PROGRAM_NAME ": the X server returned error code %u.\n", packet[1]);

			return false;
		}

		if (packet[0] == X_REPLY)
			break;
	}

	/* present(1) major_opcode(1) first_event(1) first_error(1), from byte 8. */
	if (packet[8] == 0)
	{
		fprintf(stderr, PROGRAM_NAME ": the X server does not support the " SAVER_NAME " extension.\n");

		return false;
	}

	*major_opcode = packet[9];
	*first_event  = packet[10];

	return true;
}

/* ScreenSaverSelectInput(root, ScreenSaverNotifyMask). Generates no reply; an
 * error comes back later, where the main loop reads events. */
static bool x_select_saver(int file_descriptor, uint8_t major_opcode, uint32_t root_window)
{
	uint8_t request[12];

	memset(request, 0, sizeof request);

	request[0] = major_opcode;
	request[1] = SAVER_SELECT_INPUT;
	put16(request + 2, 3); /* length, in 4-byte units */
	put32(request + 4, root_window);
	put32(request + 8, SAVER_NOTIFY_MASK);

	if (!write_all(file_descriptor, request, sizeof request))
	{
		fprintf(stderr, PROGRAM_NAME ": cannot select the screen saver events: %s\n", strerror(errno));

		return false;
	}

	return true;
}

/* ----------------------------------------------------------------- locker */

/* Start the locker and return its pid, or 0 if it could not be started.
 *
 * It gets a session of its own, so a signal aimed at this program's process
 * group -- a Ctrl-C in the terminal it was started from, a hangup -- cannot
 * reach the locker and unlock the screen. It also gets back the signal mask
 * this program was started with, and SIGPIPE's default action: a blocked mask
 * and an ignored signal both survive exec, where handlers do not. */
static pid_t start_locker(char *const locker[], const sigset_t *original_mask)
{
	posix_spawnattr_t attributes;
	sigset_t          defaults;
	pid_t             pid = 0;
	int               result;

	sigemptyset(&defaults);
	sigaddset(&defaults, SIGPIPE);

	result = posix_spawnattr_init(&attributes);

	if (result == 0)
	{
		result = posix_spawnattr_setflags(&attributes,
		                                  (short)(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF));

		if (result == 0)
			result = posix_spawnattr_setsigmask(&attributes, original_mask);

		if (result == 0)
			result = posix_spawnattr_setsigdefault(&attributes, &defaults);

		/* posix_spawnp reports a locker that cannot be run -- not found, not
		 * executable -- as its own error, so there is no child to reap. */
		if (result == 0)
			result = posix_spawnp(&pid, locker[0], NULL, &attributes, locker, environ);

		posix_spawnattr_destroy(&attributes);
	}

	if (result != 0)
	{
		fprintf(stderr, PROGRAM_NAME ": cannot run '%s': %s\n", locker[0], strerror(result));

		return 0;
	}

	return pid;
}

/* Collect the locker if it has exited, so the next activation can start
 * another, and say so if it did not exit cleanly: a locker that failed to lock
 * the screen -- one that cannot grab the keyboard, say -- is otherwise
 * invisible. */
static void reap_locker(pid_t *locker_pid, const char *name)
{
	int   status = 0;
	pid_t result;

	if (*locker_pid == 0)
		return;

	result = waitpid(*locker_pid, &status, WNOHANG);

	if (result == 0)
		return; /* still running */

	*locker_pid = 0;

	if (result < 0)
	{
		perror(PROGRAM_NAME ": waitpid");

		return;
	}

	if (WIFEXITED(status) && WEXITSTATUS(status) != 0)
		fprintf(stderr, PROGRAM_NAME ": '%s' exited with status %d.\n", name, WEXITSTATUS(status));
	else if (WIFSIGNALED(status))
		fprintf(stderr, PROGRAM_NAME ": '%s' was killed by signal %d.\n", name, WTERMSIG(status));
}

/* ------------------------------------------------------------------- main */

static void usage(FILE *stream)
{
	fputs("Usage: " PROGRAM_NAME " [LOCKER [ARGUMENT]...]\n"
	      "\n"
	      "Start a screen locker each time the X screen saver activates.\n"
	      "\n"
	      "  -h, --help     show this help\n"
	      "  -v, --version  show the version\n"
	      "  --             end of options, so LOCKER may begin with '-'\n"
	      "\n"
	      "LOCKER defaults to '" DEFAULT_LOCKER "' and must stay in the foreground until the\n"
	      "screen is unlocked. The saver activates after 'xset s SECONDS' of idle time,\n"
	      "or at once on 'xset s activate'.\n",
	      stream);
}

int main(int argc, char *argv[])
{
	static char default_name[] = DEFAULT_LOCKER;

	char            *default_locker[] = {default_name, NULL};
	char           **locker           = default_locker;
	char             socket_path[PATH_MAX];
	char             display_number[16];
	uint8_t          cookie[MAX_COOKIE];
	uint16_t         cookie_length   = 0;
	uint32_t         root_window     = 0;
	uint8_t          major_opcode    = 0;
	uint8_t          first_event     = 0;
	int              file_descriptor = -1;
	pid_t            locker_pid      = 0;
	bool             ok              = true;
	int              index           = 1;
	sigset_t         handled;
	sigset_t         original_mask;
	sigset_t         wait_mask;
	struct sigaction action;

	while (index < argc && argv[index][0] == '-' && argv[index][1] != '\0')
	{
		const char *option = argv[index];

		if (strcmp(option, "-h") == 0 || strcmp(option, "--help") == 0)
		{
			usage(stdout);

			return EXIT_SUCCESS;
		}

		if (strcmp(option, "-v") == 0 || strcmp(option, "--version") == 0)
		{
			fputs(PROGRAM_NAME "-" VERSION "\n", stdout);

			return EXIT_SUCCESS;
		}

		/* Standard end-of-options marker, so a LOCKER may begin with '-'. */
		if (strcmp(option, "--") == 0)
		{
			index++;

			break;
		}

		fprintf(stderr, PROGRAM_NAME ": unknown option '%s'.\n", option);
		usage(stderr);

		return EXIT_FAILURE;
	}

	/* Everything from the first operand on is the locker's own command line,
	 * options included. */
	if (index < argc)
		locker = argv + index;

	if (!parse_display(getenv("DISPLAY"), socket_path, sizeof socket_path, display_number, sizeof display_number))
		return EXIT_FAILURE;

	/* An absent cookie is fine; an access-controlled server will say no. */
	(void)load_cookie(display_number, cookie, &cookie_length);

	/* A dead X server must surface as a write error, not as a fatal signal.
	 * Ignored before the first write, the connection setup's: a server that
	 * goes away before the events are selected must be reported too. */
	memset(&action, 0, sizeof action);
	action.sa_handler = SIG_IGN;
	sigemptyset(&action.sa_mask);
	sigaction(SIGPIPE, &action, NULL);

	file_descriptor = x_connect(socket_path);

	if (file_descriptor < 0)
		return EXIT_FAILURE;

	if (!x_handshake(file_descriptor, cookie, cookie_length, &root_window) ||
	    !x_query_saver(file_descriptor, &major_opcode, &first_event))
	{
		close(file_descriptor);

		return EXIT_FAILURE;
	}

	/* The signals this program handles are blocked everywhere except inside
	 * ppoll(), which unblocks them for the wait and nowhere else. One that
	 * arrives while an event is being handled therefore stays pending and ends
	 * the next wait at once, instead of landing between the keep_running check
	 * and the wait and going unnoticed until the next event.
	 *
	 * Done only now, so their defaults still apply while the connection is being
	 * set up: SIGTERM kills a program stuck in a handshake the server never
	 * answers. It is done before the events are selected, so by the time the
	 * server has seen that request the handlers are in place. */
	sigemptyset(&handled);
	sigaddset(&handled, SIGINT);
	sigaddset(&handled, SIGTERM);
	sigaddset(&handled, SIGHUP);
	sigaddset(&handled, SIGCHLD);
	sigprocmask(SIG_BLOCK, &handled, &original_mask);

	wait_mask = original_mask;
	sigdelset(&wait_mask, SIGINT);
	sigdelset(&wait_mask, SIGTERM);
	sigdelset(&wait_mask, SIGHUP);
	sigdelset(&wait_mask, SIGCHLD);

	memset(&action, 0, sizeof action);
	action.sa_handler = on_signal;
	sigemptyset(&action.sa_mask);
	sigaction(SIGINT, &action, NULL);
	sigaction(SIGTERM, &action, NULL);
	sigaction(SIGHUP, &action, NULL);

	/* Only exits matter; a locker that is stopped is still holding the lock. */
	memset(&action, 0, sizeof action);
	action.sa_handler = on_child;
	action.sa_flags   = SA_NOCLDSTOP;
	sigemptyset(&action.sa_mask);
	sigaction(SIGCHLD, &action, NULL);

	if (!x_select_saver(file_descriptor, major_opcode, root_window))
	{
		close(file_descriptor);

		return EXIT_FAILURE;
	}

	while (keep_running)
	{
		struct pollfd watch;
		uint8_t       event[32];

		reap_locker(&locker_pid, locker[0]);

		watch.fd      = file_descriptor;
		watch.events  = POLLIN;
		watch.revents = 0;

		if (ppoll(&watch, 1, NULL, &wait_mask) < 0)
		{
			if (errno == EINTR)
				continue;

			perror(PROGRAM_NAME ": ppoll");
			ok = false;

			break;
		}

		/* A hangup or a socket error is reported by the read, like the end of
		 * the stream it is. */
		if (!read_all(file_descriptor, event, sizeof event))
		{
			fprintf(stderr, PROGRAM_NAME ": the X server closed the connection: %s\n", strerror(errno));
			ok = false;

			break;
		}

		/* Nothing is ever requested after setup, so the only error that can
		 * arrive answers the event selection: without it there is no lock. */
		if (event[0] == X_ERROR)
		{
			fprintf(stderr, PROGRAM_NAME ": the X server returned error code %u.\n", event[1]);
			ok = false;

			break;
		}

		/* Off, Cycle, and whatever the server sends every client: not ours. */
		if ((event[0] & ~X_EVENT_SENT) != first_event + SAVER_NOTIFY || event[1] != SAVER_STATE_ON)
			continue;

		/* The locker may have exited while this event was on its way. */
		reap_locker(&locker_pid, locker[0]);

		/* Still locked from last time. A second locker would only fail to grab
		 * the keyboard, or worse, stack a second lock on the first. */
		if (locker_pid != 0)
			continue;

		locker_pid = start_locker(locker, &original_mask);
	}

	/* The locker is deliberately left running: killing it would unlock the
	 * screen, which is never this program's call. */
	close(file_descriptor);

	return ok ? EXIT_SUCCESS : EXIT_FAILURE;
}
