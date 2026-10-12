// umd_psp.cpp -- see umd_psp.h; the decisions are umd_psp_logic.c's (pure, PC-benched by
// bench/umd/run_psp_scan.sh), the measurements behind them docs/psp_disc.md §2.
//
// Two threads:
//   * the WORKER (ours) does every file operation on the PSP: about once a second it finds a PSP among
//     /proc/mounts' /media/usb0..7 (by its SCSI identity in sysfs: no other drive is touched), stats its
//     UMD9660.ISO, opens it, drops LBA 16's page from the cache, reads
//     the PVD and closes the file again. A read the PSP does not answer (a disc being swapped: ~8 s;
//     a dirty one: until USB mode is left) blocks only this thread. It holds no fd between scans:
//     a held fd keeps the old /dev/sdX alive across a re-enumeration (measured: sdb, not sda).
//   * the POLL thread (Main's) takes the worker's last view, steps the logic and makes the mount
//     calls -- the same user_io_file_mount the OSD makes. The core's sectors are then Main's
//     ordinary synchronous service, as for any image (psp_disc.md §3: step 0 measured it clean).
#ifndef _GNU_SOURCE
#define _GNU_SOURCE                    // strcasestr
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <limits.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>

#include "../../user_io.h"
#include "../../file_io.h"
#include "../../menu.h"
#include "../arcade/mra_loader.h"   // mgl_get(): an MGL launch in progress
#include "umd_psp_logic.h"
#include "umd_psp.h"

#define PSP_SCAN_MS   1000             // the worker's period (a PVD read costs ~10 ms: the PSP caches the disc's head)
#define PSP_LOG       "/tmp/umd_psp.log"
#define PSP_INFO_MS   5000
#define PSP_MSG_DELAY_MS 2000           // an unmount (the core goes idle) and a core load each change the video
                                        // mode, and Main's own resolution box (video_info) replaces any Info
                                        // shown before it: a message waits for it (the maintainer saw it blip)

static pthread_mutex_t lk = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  cv = PTHREAD_COND_INITIALIZER;
static umd_psp_view    g_view;         // the worker's last scan (lk)
static int             w_started = 0;
static int             w_run = 0;      // scanning (lk): the UMD core is up
static int             w_kick = 0;     // scan now (lk)

static umd_psp_state   S;
static int             S_up = 0;
static int             self_op = 0;    // our own user_io_file_mount: the mount hook ignores it
static int             msg_pending = UMD_PSP_MSG_NONE;
static unsigned long   msg_at = 0;     // its time (ms)

static unsigned long now_ms()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (unsigned long)ts.tv_sec * 1000ul + ts.tv_nsec / 1000000;
}

// decisions only (never the scan): one file to ask a reporter for
static void psp_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void psp_log(const char *fmt, ...)
{
	FILE *f = fopen(PSP_LOG, "a");
	if (!f) return;
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	fprintf(f, "%ld.%03ld ", (long)ts.tv_sec, ts.tv_nsec / 1000000);
	va_list ap;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

static uint32_t fnv1a(const uint8_t *p, size_t n)
{
	uint32_t h = 2166136261u;
	while (n--) { h ^= *p++; h *= 16777619u; }
	return h | 1;                      // never 0 (0 = not read)
}

// Is the disk behind this mount a PSP? From sysfs only (memory, never a read from any disk), so the
// scan never looks into another USB drive -- a lookup that missed the dentry cache (a FUSE NTFS stick,
// memory pressure) would wake a sleeping disk. The strings differ between PSPs: this one answers
// SCSI "Sony" / "PSP" and USB 054c "PSP Type A"; another's log reads SCSI "SONY" / "\"PSP\" MS"
// (psp_disc.md §2). So: Sony by the SCSI vendor (any case) or the USB vendor id 054c, AND "psp"
// anywhere in the SCSI model or the USB product string (a Sony Micro Vault stick is 054c too).
static int sysfs_has(const char *path, const char *needle)
{
	char buf[64];
	FILE *f = fopen(path, "r");
	if (!f) return 0;
	int ok = fgets(buf, sizeof(buf), f) && strcasestr(buf, needle);
	fclose(f);
	return ok;
}

static int is_psp_disk(const char *dev)
{
	if (strncmp(dev, "/dev/sd", 7)) return 0;
	char disk[16], d[64], u[96];
	int i = 0;
	for (const char *p = dev + 5; *p >= 'a' && *p <= 'z' && i < (int)sizeof(disk) - 1; p++) disk[i++] = *p;
	disk[i] = 0;                        // /dev/sdb1 -> sdb (the PSP has no partition table, a stick may)
	snprintf(d, sizeof(d), "/sys/block/%s/device", disk);           // the SCSI device
	snprintf(u, sizeof(u), "%s/../../../..", d);                    // its USB device (host, target, lun, interface up)
	char a[128], b[128];
	snprintf(a, sizeof(a), "%s/vendor", d);
	snprintf(b, sizeof(b), "%s/idVendor", u);
	if (!sysfs_has(a, "sony") && !sysfs_has(b, "054c")) return 0;
	snprintf(a, sizeof(a), "%s/model", d);
	snprintf(b, sizeof(b), "%s/product", u);
	return sysfs_has(a, "psp") || sysfs_has(b, "psp");
}

static void scan_once(umd_psp_view *v)
{
	char path[64];
	struct stat st;
	v->present = 0;
	v->kind = UMD_PSP_K_UNREAD;
	v->fp = 0;
	v->vol_bytes = 0;
	FILE *m = fopen("/proc/mounts", "r");
	if (!m) return;
	char line[512], dev[128], dir[128];
	while (!v->present && fgets(line, sizeof(line), m)) {
		int n;
		if (sscanf(line, "%127s %127s", dev, dir) != 2) continue;
		if (sscanf(dir, "/media/usb%d", &n) != 1 || n < 0 || n >= UMD_PSP_NUSB) continue;
		snprintf(path, sizeof(path), "/media/usb%d", n);
		if (strcmp(dir, path) || !is_psp_disk(dev)) continue;
		snprintf(path, sizeof(path), "/media/usb%d/UMD9660.ISO", n);   // vfat: any case matches
		if (stat(path, &st) || !S_ISREG(st.st_mode)) continue;        // (a PSP in Memory Stick mode: no file)
		v->present = 1;
		v->usb = n;
		v->dev = st.st_dev;
		v->ino = st.st_ino;
		v->size = st.st_size;
	}
	fclose(m);
	if (!v->present) return;

	v->kind = UMD_PSP_K_ERR;
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) return;
	// the page, not the 2 KB range: a range under a page drops nothing -- and a disc swapped in USB
	// mode keeps the old disc's PVD in the page cache, so the read must reach the PSP
	posix_fadvise(fd, 16 * 2048, 4096, POSIX_FADV_DONTNEED);
	uint8_t b[2048];
	ssize_t r = pread(fd, b, sizeof(b), 16 * 2048);
	close(fd);
	if (r != (ssize_t)sizeof(b) || b[0] != 1 || memcmp(b + 1, "CD001", 5)) return;
	if (!memcmp(b + 8, "UMD VIDEO", 9))     v->kind = UMD_PSP_K_VIDEO;
	else if (!memcmp(b + 8, "PSP GAME", 8)) v->kind = UMD_PSP_K_GAME;
	else                                    v->kind = UMD_PSP_K_OTHER;
	v->fp = fnv1a(b, sizeof(b));       // the whole PVD: its dates and application field tell two discs apart
	v->vol_bytes = ((uint64_t)b[80] | (uint64_t)b[81] << 8 | (uint64_t)b[82] << 16 | (uint64_t)b[83] << 24) * 2048u;
}

static void *worker(void *)
{
	for (;;) {
		pthread_mutex_lock(&lk);
		while (!w_run) pthread_cond_wait(&cv, &lk);
		pthread_mutex_unlock(&lk);

		umd_psp_view v;
		memset(&v, 0, sizeof(v));
		scan_once(&v);

		pthread_mutex_lock(&lk);
		v.seq = g_view.seq + 1;
		g_view = v;
		struct timespec ts;
		clock_gettime(CLOCK_REALTIME, &ts);
		ts.tv_nsec += PSP_SCAN_MS * 1000000L;
		while (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
		while (w_run && !w_kick && pthread_cond_timedwait(&cv, &lk, &ts) == 0) {}
		w_kick = 0;
		pthread_mutex_unlock(&lk);
	}
	return NULL;
}

static void up()
{
	if (!S_up) { umd_psp_init(&S); S_up = 1; }
}

void umd_psp_tick()
{
	up();
	pthread_mutex_lock(&lk);
	if (!w_run) { w_run = 1; w_kick = 1; pthread_cond_broadcast(&cv); }   // the core came up: scan now
	umd_psp_view v = g_view;
	pthread_mutex_unlock(&lk);
	if (!w_started) {
		pthread_t t;
		if (pthread_create(&t, NULL, worker, NULL) == 0) { pthread_detach(t); w_started = 1; }
	}
	// an MGL launch owns the UI until it is done (docs/mgl_launch.md lesson 1: an Info raised from a poll
	// tick in that window freezes it), and its own mount comes last: wait it out -- no mount, no message
	// -- as dvd_phys does; the first view then finds its image (the PSP's file adopted, another foreign)
	if (!mgl_get()->done) return;
	if (msg_pending && (long)(now_ms() - msg_at) >= 0) {
		if (msg_pending == UMD_PSP_MSG_GAME)
			Info("The PSP's disc is a game,\nnot a UMD Video.", PSP_INFO_MS);
		else
			Info("Disc changed on the PSP.\nLeave USB mode and enter\nit again to play it.", PSP_INFO_MS);
		msg_pending = UMD_PSP_MSG_NONE;
	}
	if (!v.seq) return;                // no scan yet

	umd_psp_act a;
	umd_psp_step(&S, &v, &a);
	if (a.unmount) {
		psp_log("unmount (%s)", v.present ? "the disc changed" : "the PSP's file is gone");
		self_op = 1;
		user_io_file_mount("", 0);
		self_op = 0;
	}
	if (a.mount) {
		char path[64];
		snprintf(path, sizeof(path), "/media/usb%d/UMD9660.ISO", a.usb);
		self_op = 1;
		int ok = user_io_file_mount(path, 0);
		self_op = 0;
		psp_log("mount %s (%llu bytes, PVD %08x): %s", path, (unsigned long long)v.size, v.fp, ok ? "ok" : "FAILED");
		if (!ok) umd_psp_self_failed(&S);
	}
	if (a.msg) {
		if (a.msg == UMD_PSP_MSG_GAME) psp_log("a game disc (PVD %08x): not mounted", v.fp);
		else psp_log("a disc swapped inside USB mode (PVD %08x, %llu bytes under a %llu-byte file): re-enter USB mode",
		             v.fp, (unsigned long long)v.vol_bytes, (unsigned long long)v.size);
		msg_pending = a.msg;
		msg_at = now_ms() + PSP_MSG_DELAY_MS;
	}
}

void umd_psp_away()
{
	pthread_mutex_lock(&lk);
	w_run = 0;
	pthread_cond_broadcast(&cv);
	pthread_mutex_unlock(&lk);
}

void umd_psp_note_mount(int index, int ok, const char *name)
{
	if (index != 0 || self_op) return;
	up();
	int empty = !name || !name[0];
	int usb = -1;
	if (!empty) {
		char real[PATH_MAX];
		const char *full = getFullPath(name);
		usb = umd_psp_path_usb(realpath(full, real) ? real : full);
	}
	umd_psp_mounted(&S, ok, usb >= 0, empty);
	psp_log("slot 0: %s%s", empty ? "unmounted" : name, empty ? "" : usb >= 0 ? " (the PSP's)" : ok ? " (another image)" : " (did not open)");
}

void umd_psp_stats(FILE *f)
{
	fprintf(f, "{\"present\":%d,\"usb\":%d,\"owned\":%d,\"foreign\":%d,\"suppressed\":%d,\"stale\":%d,"
	        "\"mounts\":%u,\"unmounts\":%u,\"swaps\":%u,\"games\":%u,\"reenter\":%u,\"edges\":%u,\"seq\":%u}",
	        S.was_present, S.usb, S.owned, S.foreign, S.suppressed, S.stale,
	        S.n_mount, S.n_unmount, S.n_swap, S.n_game, S.n_reenter, S.n_edge, S.last_seq);
}
