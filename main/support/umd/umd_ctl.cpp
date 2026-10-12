// umd_ctl.cpp -- see umd_ctl.h and main/README.md.
//
// HARVESTED from MiSTer_DVD main/support/dvd/dvd_ctl.cpp. Kept, with its reasons:
//   * a RUNTIME arm (the presence of /media/fat/umd_hil, re-checked every 2 s), not a
//     build flag: telemetry costs no rebuild of Main or of the core; nothing is active in
//     a Main that is not armed -- no SPI, no file writes, no FIFO. It runs on the poll
//     thread that also services the core's block reads, where needless work is a video
//     artefact rather than a latency nit.
//   * one SPI transaction per sample: the core latches the rate pairs on the command
//     strobe, so the words are one snapshot.
//   * the JSON is written to a temp file and renamed: a reader never sees half of it.
//   * the command FIFO is opened O_RDWR | O_NONBLOCK (never blocks, never sees EOF) and
//     read at most once per tick.
// CHANGED: the words and their names come from umd_telem_fields.h, generated from
// tools/telem_layout.py -- the same table the RTL word mux is generated from.

#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

#include "../../user_io.h"
#include "../../spi.h"
#include "../../hardware.h"
#include "umd_ctl.h"
#include "umd_telem_fields.h"
#include "umd_b2.h"
#include "umd_host.h"
#include "umd_menu.h"
#include "umd_psp.h"

#define UMD_CTL_ARM     "/media/fat/umd_hil"
#define UMD_CTL_FIFO    "/tmp/umd_ctl"
#define UMD_TELEM_FILE  "/tmp/umd_telem.json"
#define UMD_HOST_FILE   "/tmp/umd_host.json"
#define UMD_CTL_LOG     "/tmp/umd_ctl.log"
#define TELEM_PERIOD_MS 250

static int ctl_fd = -1;
static unsigned last_telem_ms = 0;
static int armed = 0;
static unsigned last_arm_ms = 0;

void umd_ctl_log(const char *fmt, ...)
{
	va_list ap;
	FILE *f = fopen(UMD_CTL_LOG, "a");
	if (!f) return;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fprintf(f, "\n");
	fclose(f);
}

static unsigned now_ms()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (unsigned)(ts.tv_sec * 1000u + ts.tv_nsec / 1000000u);
}

// ---------------------------------------------------------------------------
// telemetry: one transaction, the words named by the generated table
// ---------------------------------------------------------------------------
static void telem_read()
{
	uint16_t w[UMD_TELEM_NWORDS];
	w[0] = spi_uio_cmd_cont(UIO_UMD_TELEM);
	for (int i = 1; i < UMD_TELEM_NWORDS; i++) w[i] = spi_w(0);
	DisableIO();

	if (w[0] != UMD_TELEM_MAGIC) return;           // no responder in this core build
	int fmt = w[1] >> 8, n = w[1] & 0xFF;          // an older core answers fewer words

	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	double t = ts.tv_sec + ts.tv_nsec / 1e9;

	char tmp[64];
	snprintf(tmp, sizeof(tmp), "%s.tmp", UMD_TELEM_FILE);
	FILE *f = fopen(tmp, "w");
	if (!f) return;
	fprintf(f, "{\"t\":%.6f,\"format\":%d,\"nwords\":%d", t, fmt, n);
	for (unsigned k = 0; k < sizeof(umd_telem_fields) / sizeof(umd_telem_fields[0]); k++)
	{
		const struct umd_telem_field *fd = &umd_telem_fields[k];
		if (fd->word >= n || fd->word >= UMD_TELEM_NWORDS) continue;
		// raw words: the host unwraps the 16-bit counters and applies each one's scale
		// (tools/telem_layout.py, the same table)
		switch (fd->kind)
		{
		case 2:   // s16
			fprintf(f, ",\"%s\":%d", fd->name, (int)(int16_t)w[fd->word]);
			break;
		default:  // c16 (a counter, pre-divided by fd->scale), v16, bits
			fprintf(f, ",\"%s\":%u", fd->name, (unsigned)w[fd->word]);
			break;
		}
	}
	fprintf(f, "}\n");
	fclose(f);
	rename(tmp, UMD_TELEM_FILE);
}

// ---------------------------------------------------------------------------
// command FIFO
// ---------------------------------------------------------------------------
static void ctl_open()
{
	if (ctl_fd >= 0) return;
	struct stat st;
	if (stat(UMD_CTL_FIFO, &st) || !S_ISFIFO(st.st_mode))
	{
		unlink(UMD_CTL_FIFO);
		if (mkfifo(UMD_CTL_FIFO, 0666)) return;
	}
	ctl_fd = open(UMD_CTL_FIFO, O_RDWR | O_NONBLOCK | O_CLOEXEC);
}

static void ctl_exec(char *line)
{
	while (*line == ' ') line++;
	if (!*line) return;

	if (!strncmp(line, "osd ", 4))
	{
		// "osd [4:3] 2" -- the option's status bits (as CONF_STR names them) and a value
		char *opt = line + 4;
		char *sp = strchr(opt, ' ');
		if (!sp) { umd_ctl_log("UMD_CTL: bad osd command"); return; }
		*sp = 0;
		uint32_t val = (uint32_t)strtoul(sp + 1, NULL, 0);
		user_io_status_set(opt, val);
		umd_ctl_log("UMD_CTL: osd %s = %u", opt, val);
	}
	else if (!strncmp(line, "mount ", 6))
	{
		user_io_file_mount(line + 6, 0);
		umd_ctl_log("UMD_CTL: mount %s", line + 6);
	}
	else if (!strncmp(line, "b2 ", 3))
	{
		umd_b2_cmd(line + 3);      // B2's probe (umd_b2.h)
	}
	else if (!strcmp(line, "ping"))
	{
		umd_ctl_log("UMD_CTL: ping");
	}
	else
	{
		umd_ctl_log("UMD_CTL: unknown command '%s'", line);
	}
}

// the running core is this one (CONF_STR's first field, "UMD"): from Main's public core
// name, so the integration patches nothing inside user_io.cpp but the include and the tick
char is_umd()
{
	const char *n = user_io_get_core_name(1);
	return n && !strcasecmp(n, "UMD");
}

// the host module's counters, beside the telemetry (HIL only): /tmp/umd_host.json
static void host_stats_write()
{
	char tmp[64];
	snprintf(tmp, sizeof(tmp), "%s.tmp", UMD_HOST_FILE);
	FILE *f = fopen(tmp, "w");
	if (!f) return;
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	fprintf(f, "{\"t\":%.6f,\"host\":", ts.tv_sec + ts.tv_nsec / 1e9);
	umd_host_stats(f);
	fprintf(f, ",\"menu\":");             // P9: the disc menus' worker and logic (umd_menu.cpp)
	umd_menu_stats(f);
	fprintf(f, ",\"psp\":");              // a PSP's disc over USB (umd_psp.cpp)
	umd_psp_stats(f);
	fprintf(f, "}\n");
	fclose(f);
	rename(tmp, UMD_HOST_FILE);
}

// The ONE hook the integration patches into Main's poll loop (apply_integration.py). The host
// module (umd_host: the subtitle decode, A7) runs for EVERY user under the UMD core, armed or
// not; everything below the arm check is the HIL's alone.
void umd_ctl_tick()
{
	umd_b2_tick();                 // first: B2's poll-gap timestamp is the top of the tick
	if (!is_umd()) { umd_host_away(); umd_psp_away(); return; }
	umd_host_tick();
	umd_psp_tick();                // a PSP's disc over USB, found and mounted (docs/psp_disc.md)

	unsigned now = now_ms();
	if (!last_arm_ms || now - last_arm_ms >= 2000)
	{
		last_arm_ms = now ? now : 1;
		struct stat st;
		int was = armed;
		armed = (stat(UMD_CTL_ARM, &st) == 0);
		if (armed != was) umd_ctl_log("UMD_CTL: %s (%s)", armed ? "armed" : "disarmed", UMD_CTL_ARM);
		if (!armed && ctl_fd >= 0)
		{
			close(ctl_fd);
			ctl_fd = -1;
			unlink(UMD_CTL_FIFO);
			unlink(UMD_TELEM_FILE);
			unlink(UMD_HOST_FILE);
		}
	}
	if (!armed) return;

	ctl_open();
	if (ctl_fd >= 0)
	{
		char buf[512];
		int n = read(ctl_fd, buf, sizeof(buf) - 1);
		if (n > 0)
		{
			buf[n] = 0;
			char *p = buf;
			while (p && *p)
			{
				char *nl = strchr(p, '\n');
				if (nl) *nl = 0;
				ctl_exec(p);
				p = nl ? nl + 1 : NULL;
			}
		}
	}

	unsigned t = now_ms();
	if (t - last_telem_ms >= TELEM_PERIOD_MS)
	{
		last_telem_ms = t;
		telem_read();
		host_stats_write();
	}
}
