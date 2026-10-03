/* SPDX-License-Identifier: ISC */

/* fakex - a fake X server for the xidlelock test suite.
 *
 * Binds /tmp/.X11-unix/X<display>, answers the connection setup, QueryExtension
 * and GetInputFocus, and logs every request it receives to stdout so a shell
 * test can assert against it. It never touches a real display.
 *
 * It serves MIT-SCREEN-SAVER under major opcode 144 with its first event at 91,
 * or 150 and 95 in "moved" mode. A real server assigns both at startup; these
 * collide with no core opcode or event, and the second pair exists so a program
 * that hard-coded the first cannot pass. Events are sent on command: each line
 * written to the CONTROL fifo is one of
 *
 *   on        ScreenSaverNotify, state On (1), as the idle timeout sends it
 *   forced    ScreenSaverNotify, state On, forced: what a real server sends for
 *             ForceScreenSaver (`xset s activate`) and a DPMS power-down
 *   off       ScreenSaverNotify, state Off (0)
 *   cycle     ScreenSaverNotify, state Cycle (2)
 *   sent      ScreenSaverNotify, state On, with the SendEvent bit (0x80) set
 *   mapping   a core MappingNotify (34), which a server sends every client
 *   error     an X error (code 17) that answers no request
 *   hangup    close the client's connection
 *
 * A ScreenSaverNotify reaches only a client that selected it, as on a real
 * server; otherwise it is logged as DROPPED and not sent.
 *
 * Log lines use RAW protocol numbers on purpose. A test that asserted against
 * xidlelock's own macros would compare the program to itself and pass even if a
 * constant were wrong, so tests match the literal 98/144/2/1 from the X11
 * spec, and fakex's own opcode, instead.
 *
 *   usage: fakex DISPLAYNUM MODE CONTROL
 *
 *   MODE   ok       normal service
 *          moved    normal service, with the extension at 150 and 95
 *          refuse   reject the connection setup with a reason string
 *          nosaver  report MIT-SCREEN-SAVER as absent
 *          error    answer ScreenSaverSelectInput with an X error (code 9)
 *          split    send every reply and event in two writes, to exercise
 *                   short reads
 *          deaf     stop reading, then answer the connection setup, so the
 *                   client's first request fails with EPIPE
 *
 * Log lines:
 *   LISTENING <path>
 *   SETUP authname=<len> authdata=<len>
 *   REQUEST opcode=<n> length=<n>
 *   QUERYEXTENSION name=<text>
 *   SELECTINPUT minor=<n> window=0x<hex> mask=<n>
 *   GETINPUTFOCUS
 *   SENT <command>
 *   DROPPED <command>
 *   DISCONNECT
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define FAKE_ROOT_WINDOW 0x000002a5u
#define MAX_REQUEST 65536
#define MAX_COMMAND 64

#define SAVER_FIRST_ERROR 160

enum mode
{
	MODE_OK,
	MODE_MOVED,
	MODE_REFUSE,
	MODE_NOSAVER,
	MODE_ERROR,
	MODE_SPLIT,
	MODE_DEAF
};

static volatile sig_atomic_t running = 1;
static enum mode             server_mode;
static char                  socket_path[108];
static uint16_t              sequence;
static uint32_t              saver_mask;
static uint8_t               saver_major_opcode = 144;
static uint8_t               saver_first_event  = 91;
static char                  command[MAX_COMMAND];
static size_t                command_length;

static void on_signal(int signal_number)
{
	(void)signal_number;

	running = 0;
}

static void put16(uint8_t *buffer, uint16_t value)
{
	buffer[0] = (uint8_t)(value & 0xffu);
	buffer[1] = (uint8_t)((value >> 8) & 0xffu);
}

static void put32(uint8_t *buffer, uint32_t value)
{
	buffer[0] = (uint8_t)(value & 0xffu);
	buffer[1] = (uint8_t)((value >> 8) & 0xffu);
	buffer[2] = (uint8_t)((value >> 16) & 0xffu);
	buffer[3] = (uint8_t)((value >> 24) & 0xffu);
}

static uint16_t get16(const uint8_t *buffer)
{
	return (uint16_t)((uint16_t)buffer[0] | (uint16_t)((uint16_t)buffer[1] << 8));
}

static uint32_t get32(const uint8_t *buffer)
{
	return (uint32_t)buffer[0] | ((uint32_t)buffer[1] << 8) | ((uint32_t)buffer[2] << 16) | ((uint32_t)buffer[3] << 24);
}

static size_t pad4(size_t length) { return (length + 3u) & ~(size_t)3u; }

static bool read_all(int file_descriptor, uint8_t *buffer, size_t length)
{
	size_t have = 0;

	while (have < length)
	{
		ssize_t chunk = read(file_descriptor, buffer + have, length - have);

		if (chunk < 0 && errno == EINTR)
			continue;

		if (chunk <= 0)
			return false;

		have += (size_t)chunk;
	}

	return true;
}

/* In split mode every reply goes out as two writes, so the client is forced to
 * cope with a packet that does not arrive all at once. */
static bool write_all(int file_descriptor, const uint8_t *buffer, size_t length)
{
	size_t written = 0;
	size_t first   = (server_mode == MODE_SPLIT && length > 1) ? length / 2 : length;

	while (written < length)
	{
		size_t  want  = (written < first) ? first - written : length - written;
		ssize_t chunk = write(file_descriptor, buffer + written, want);

		if (chunk < 0 && errno == EINTR)
			continue;

		if (chunk < 0)
			return false;

		written += (size_t)chunk;
	}

	return true;
}

/* Minimal but structurally valid setup reply: one screen, one pixmap format,
 * a short vendor string. 88 bytes of additional data. */
static bool send_setup_success(int file_descriptor)
{
	uint8_t prefix[8];
	uint8_t body[88];

	memset(prefix, 0, sizeof prefix);
	memset(body, 0, sizeof body);

	prefix[0] = 1; /* success */
	put16(prefix + 2, 11);
	put16(prefix + 4, 0);
	put16(prefix + 6, (uint16_t)(sizeof body / 4));

	put32(body + 0, 1);           /* release */
	put32(body + 4, 0x00400000u); /* resource-id base */
	put32(body + 8, 0x001fffffu); /* resource-id mask */
	put32(body + 12, 256);        /* motion buffer size */
	put16(body + 16, 5);          /* vendor length: "fakex" */
	put16(body + 18, 65535);      /* maximum request length */
	body[20] = 1;                 /* number of screens */
	body[21] = 1;                 /* number of pixmap formats */
	body[22] = 0;                 /* image byte order: LSB first */
	body[23] = 0;                 /* bitmap bit order */
	body[24] = 32;                /* bitmap scanline unit */
	body[25] = 32;                /* bitmap scanline pad */
	body[26] = 8;                 /* min keycode */
	body[27] = 255;               /* max keycode */

	memcpy(body + 32, "fakex", 5); /* padded to 8 by the zero fill */

	body[40] = 24; /* one pixmap format: depth, bpp, scanline pad, 5 pad */
	body[41] = 32;
	body[42] = 32;

	/* The screen. xidlelock reads only the first field, the root window. */
	put32(body + 48, FAKE_ROOT_WINDOW);
	put32(body + 52, 0x20u); /* default colormap */
	put32(body + 56, 0x00ffffffu);
	put32(body + 60, 0);
	put32(body + 64, 0);
	put16(body + 68, 1920);
	put16(body + 70, 1080);
	put16(body + 72, 508);
	put16(body + 74, 285);
	put16(body + 76, 1);
	put16(body + 78, 1);
	put32(body + 80, 0x21u); /* root visual */
	body[84] = 0;            /* backing store */
	body[85] = 0;            /* save unders */
	body[86] = 24;           /* root depth */
	body[87] = 0;            /* number of depths */

	return write_all(file_descriptor, prefix, sizeof prefix) && write_all(file_descriptor, body, sizeof body);
}

static bool send_setup_refusal(int file_descriptor)
{
	static const char reason[] = "fakex refuses this connection";

	uint8_t prefix[8];
	uint8_t body[32];
	size_t  length = sizeof reason - 1;

	memset(prefix, 0, sizeof prefix);
	memset(body, 0, sizeof body);

	prefix[0] = 0; /* failed */
	prefix[1] = (uint8_t)length;
	put16(prefix + 2, 11);
	put16(prefix + 4, 0);
	put16(prefix + 6, (uint16_t)(sizeof body / 4));

	memcpy(body, reason, length);

	return write_all(file_descriptor, prefix, sizeof prefix) && write_all(file_descriptor, body, sizeof body);
}

static bool send_focus_reply(int file_descriptor)
{
	uint8_t packet[32];

	memset(packet, 0, sizeof packet);

	packet[0] = 1; /* reply */
	packet[1] = 0;
	put16(packet + 2, sequence);
	put32(packet + 4, 0);
	put32(packet + 8, FAKE_ROOT_WINDOW);

	return write_all(file_descriptor, packet, sizeof packet);
}

static bool send_extension_reply(int file_descriptor, bool present)
{
	uint8_t packet[32];

	memset(packet, 0, sizeof packet);

	packet[0] = 1; /* reply */
	put16(packet + 2, sequence);
	put32(packet + 4, 0);

	if (present)
	{
		packet[8]  = 1;
		packet[9]  = saver_major_opcode;
		packet[10] = saver_first_event;
		packet[11] = SAVER_FIRST_ERROR;
	}

	return write_all(file_descriptor, packet, sizeof packet);
}

static bool send_error(int file_descriptor, uint8_t code, uint8_t major, uint8_t minor)
{
	uint8_t packet[32];

	memset(packet, 0, sizeof packet);

	packet[0] = 0; /* error */
	packet[1] = code;
	put16(packet + 2, sequence);
	put32(packet + 4, 0);
	put16(packet + 8, minor);
	packet[10] = major;

	return write_all(file_descriptor, packet, sizeof packet);
}

/* ScreenSaverNotify: code, state, sequence, time, root, saver window, kind,
 * forced, then padding to 32 bytes. A real server sets forced for everything
 * but its own idle timeout. */
static bool send_saver_notify(int file_descriptor, uint8_t code, uint8_t state, uint8_t forced)
{
	uint8_t packet[32];

	memset(packet, 0, sizeof packet);

	packet[0] = code;
	packet[1] = state;
	put16(packet + 2, sequence);
	put32(packet + 4, 0);
	put32(packet + 8, FAKE_ROOT_WINDOW);
	put32(packet + 12, 0x00400001u);
	packet[16] = 0; /* kind: blanked */
	packet[17] = forced;

	return write_all(file_descriptor, packet, sizeof packet);
}

static bool send_mapping_notify(int file_descriptor)
{
	uint8_t packet[32];

	memset(packet, 0, sizeof packet);

	/* Byte 1 is unused in a MappingNotify, and nothing obliges a server to zero
	 * it. It carries 1 here -- the value of On in a ScreenSaverNotify -- so a
	 * client that read the state without checking the code would lock. */
	packet[0] = 34; /* MappingNotify */
	packet[1] = 1;
	put16(packet + 2, sequence);
	packet[4] = 1; /* request: MappingKeyboard */
	packet[5] = 8; /* first keycode */
	packet[6] = 1; /* count */

	return write_all(file_descriptor, packet, sizeof packet);
}

/* Log the extension name with non-printables escaped, so a shell test can
 * compare a single stable line. */
static void log_extension_name(const uint8_t *name, size_t length)
{
	printf("QUERYEXTENSION name=");

	for (size_t i = 0; i < length; i++)
	{
		if (name[i] >= 0x20 && name[i] < 0x7f)
			putchar((int)name[i]);
		else
			printf("\\x%02x", name[i]);
	}

	putchar('\n');
}

/* Read and answer one request. Returns false once the client has gone. */
static bool serve_request(int file_descriptor)
{
	static uint8_t request[MAX_REQUEST];

	uint8_t  header[4];
	uint16_t length;
	size_t   rest;

	if (!read_all(file_descriptor, header, sizeof header))
		return false;

	sequence++;
	length = get16(header + 2);

	if (length == 0 || (size_t)length * 4u > sizeof request)
		return false;

	rest = ((size_t)length * 4u) - sizeof header;

	memcpy(request, header, sizeof header);

	if (rest > 0 && !read_all(file_descriptor, request + sizeof header, rest))
		return false;

	printf("REQUEST opcode=%u length=%u\n", request[0], length);

	if (request[0] == 98) /* QueryExtension */
	{
		size_t name_length = get16(request + 4);
		bool   is_saver;

		if (8u + pad4(name_length) > (size_t)length * 4u)
			return false;

		log_extension_name(request + 8, name_length);

		is_saver = name_length == 16 && memcmp(request + 8, "MIT-SCREEN-SAVER", 16) == 0;

		if (!send_extension_reply(file_descriptor, is_saver && server_mode != MODE_NOSAVER))
			return false;
	}
	else if (request[0] == 43) /* GetInputFocus */
	{
		printf("GETINPUTFOCUS\n");

		if (!send_focus_reply(file_descriptor))
			return false;
	}
	else if (request[0] == saver_major_opcode && request[1] == 2 && length == 3) /* ScreenSaverSelectInput */
	{
		printf("SELECTINPUT minor=%u window=0x%08x mask=%u\n", request[1], get32(request + 4), get32(request + 8));

		saver_mask = get32(request + 8);

		if (server_mode == MODE_ERROR && !send_error(file_descriptor, 9, saver_major_opcode, 2))
			return false;
	}

	fflush(stdout);

	return true;
}

/* Carry out one control command. Returns false once the client should be
 * dropped. */
static bool run_command(int file_descriptor, const char *name)
{
	bool is_saver = true;
	bool sent;

	if (strcmp(name, "hangup") == 0)
	{
		printf("SENT hangup\n");

		return false;
	}

	if (strcmp(name, "mapping") == 0 || strcmp(name, "error") == 0)
		is_saver = false;

	if (is_saver && (saver_mask & 1u) == 0)
	{
		printf("DROPPED %s\n", name);

		return true;
	}

	if (strcmp(name, "on") == 0)
		sent = send_saver_notify(file_descriptor, saver_first_event, 1, 0);
	else if (strcmp(name, "forced") == 0)
		sent = send_saver_notify(file_descriptor, saver_first_event, 1, 1);
	else if (strcmp(name, "off") == 0)
		sent = send_saver_notify(file_descriptor, saver_first_event, 0, 0);
	else if (strcmp(name, "cycle") == 0)
		sent = send_saver_notify(file_descriptor, saver_first_event, 2, 0);
	else if (strcmp(name, "sent") == 0)
		sent = send_saver_notify(file_descriptor, (uint8_t)(saver_first_event | 0x80u), 1, 0);
	else if (strcmp(name, "mapping") == 0)
		sent = send_mapping_notify(file_descriptor);
	else if (strcmp(name, "error") == 0)
		sent = send_error(file_descriptor, 17, 0, 0);
	else
	{
		printf("UNKNOWN %s\n", name);

		return true;
	}

	if (!sent)
		return false;

	printf("SENT %s\n", name);

	return true;
}

/* Read what the tests have written to the control fifo and run every complete
 * line. Returns false once the client should be dropped. */
static bool run_commands(int file_descriptor, int control)
{
	char    chunk[MAX_COMMAND];
	ssize_t got = read(control, chunk, sizeof chunk);

	if (got <= 0)
		return true;

	for (ssize_t i = 0; i < got; i++)
	{
		if (chunk[i] != '\n')
		{
			if (command_length < sizeof command - 1)
				command[command_length++] = chunk[i];

			continue;
		}

		command[command_length] = '\0';
		command_length          = 0;

		if (!run_command(file_descriptor, command))
		{
			fflush(stdout);

			return false;
		}
	}

	fflush(stdout);

	return true;
}

static void serve(int file_descriptor, int control)
{
	uint8_t prefix[12];
	size_t  skip;

	static uint8_t auth[MAX_REQUEST];

	sequence   = 0;
	saver_mask = 0;

	if (!read_all(file_descriptor, prefix, sizeof prefix))
		return;

	skip = pad4(get16(prefix + 6)) + pad4(get16(prefix + 8));

	if (skip > sizeof auth || (skip > 0 && !read_all(file_descriptor, auth, skip)))
		return;

	printf("SETUP authname=%u authdata=%u\n", get16(prefix + 6), get16(prefix + 8));
	fflush(stdout);

	if (server_mode == MODE_REFUSE)
	{
		(void)send_setup_refusal(file_descriptor);

		printf("DISCONNECT\n");
		fflush(stdout);

		return;
	}

	/* Stopped reading first, so the client's next write fails with EPIPE
	 * however soon it comes. A server that only closed the connection after
	 * answering would race that write: one that came first would succeed, and
	 * the client would read the end of the stream instead. */
	if (server_mode == MODE_DEAF)
	{
		if (shutdown(file_descriptor, SHUT_RD) != 0)
		{
			perror("fakex: shutdown");

			return;
		}

		(void)send_setup_success(file_descriptor);

		printf("DISCONNECT\n");
		fflush(stdout);

		return;
	}

	if (!send_setup_success(file_descriptor))
		return;

	while (running)
	{
		struct pollfd watch[2];

		watch[0].fd      = file_descriptor;
		watch[0].events  = POLLIN;
		watch[0].revents = 0;
		watch[1].fd      = control;
		watch[1].events  = POLLIN;
		watch[1].revents = 0;

		if (poll(watch, 2, -1) < 0)
		{
			if (errno == EINTR)
				continue;

			break;
		}

		/* Requests first, so a selection that is already on its way counts
		 * for a command that arrived at the same time. */
		if ((watch[0].revents & (POLLIN | POLLHUP | POLLERR)) != 0 && !serve_request(file_descriptor))
			break;

		if ((watch[1].revents & POLLIN) != 0 && !run_commands(file_descriptor, control))
			break;
	}

	printf("DISCONNECT\n");
	fflush(stdout);
}

int main(int argc, char *argv[])
{
	union
	{
		struct sockaddr    any;
		struct sockaddr_un local;
	} address;

	struct sigaction action;
	const char      *mode_name;
	int              listener;
	int              probe;
	int              control;

	if (argc != 4)
	{
		fprintf(stderr, "usage: fakex DISPLAYNUM ok|moved|refuse|nosaver|error|split|deaf CONTROL\n");

		return 2;
	}

	mode_name = argv[2];

	if (strcmp(mode_name, "ok") == 0)
		server_mode = MODE_OK;
	else if (strcmp(mode_name, "moved") == 0)
	{
		server_mode        = MODE_MOVED;
		saver_major_opcode = 150;
		saver_first_event  = 95;
	}
	else if (strcmp(mode_name, "refuse") == 0)
		server_mode = MODE_REFUSE;
	else if (strcmp(mode_name, "nosaver") == 0)
		server_mode = MODE_NOSAVER;
	else if (strcmp(mode_name, "error") == 0)
		server_mode = MODE_ERROR;
	else if (strcmp(mode_name, "split") == 0)
		server_mode = MODE_SPLIT;
	else if (strcmp(mode_name, "deaf") == 0)
		server_mode = MODE_DEAF;
	else
	{
		fprintf(stderr, "fakex: unknown mode '%s'\n", mode_name);

		return 2;
	}

	/* Read-write, so the fifo always has a writer and never reads as end of
	 * file between two commands; non-blocking, so a read never stalls serving. */
	control = open(argv[3], O_RDWR | O_NONBLOCK | O_CLOEXEC);

	if (control < 0)
	{
		fprintf(stderr, "fakex: cannot open '%s': %s\n", argv[3], strerror(errno));

		return 1;
	}

	if (snprintf(socket_path, sizeof socket_path, "/tmp/.X11-unix/X%s", argv[1]) < 0)
		return 2;

	memset(&address, 0, sizeof address);
	address.local.sun_family = AF_UNIX;
	memcpy(address.local.sun_path, socket_path, strlen(socket_path) + 1);

	/* Take over a stale socket, but never steal a live one: a concurrent run
	 * (or the real X server) must make us fail so the caller picks another
	 * display number. */
	probe = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);

	if (probe >= 0)
	{
		bool in_use = connect(probe, &address.any, (socklen_t)sizeof address.local) == 0;

		close(probe);

		if (in_use)
		{
			fprintf(stderr, "fakex: '%s' is already served\n", socket_path);

			return 1;
		}

		unlink(socket_path);
	}

	listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);

	if (listener < 0)
	{
		perror("fakex: socket");

		return 1;
	}

	if (bind(listener, &address.any, (socklen_t)sizeof address.local) != 0)
	{
		fprintf(stderr, "fakex: cannot bind '%s': %s\n", socket_path, strerror(errno));
		close(listener);

		return 1;
	}

	if (listen(listener, 8) != 0)
	{
		perror("fakex: listen");
		close(listener);

		return 1;
	}

	memset(&action, 0, sizeof action);
	action.sa_handler = on_signal;
	sigemptyset(&action.sa_mask);
	sigaction(SIGINT, &action, NULL);
	sigaction(SIGTERM, &action, NULL);

	memset(&action, 0, sizeof action);
	action.sa_handler = SIG_IGN;
	sigemptyset(&action.sa_mask);
	sigaction(SIGPIPE, &action, NULL);

	printf("LISTENING %s\n", socket_path);
	fflush(stdout);

	while (running)
	{
		int client = accept(listener, NULL, NULL);

		if (client < 0)
		{
			if (errno == EINTR)
				continue;

			break;
		}

		serve(client, control);
		close(client);
	}

	close(listener);
	close(control);
	unlink(socket_path);

	return 0;
}
