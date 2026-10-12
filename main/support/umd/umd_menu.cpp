// umd_menu.cpp -- see umd_menu.h; the decisions are umd_menu_run.c's, umd_menu_host.c's and
// umd_menu_logic.c's (pure, PC-benched).
//
// Two threads, as umd_host.cpp's (docs/hps_host.md §1):
//   * the POLL thread (Main's, CPU 1) runs umd_menu_step at every HOST_RD, with the levels the
//     worker last published, and hands each (HOST_RD, its events) pair to the worker's mailbox in
//     order. Nothing slow runs here: it also serves the core's sector reads.
//   * the WORKER (ours, CPU 0, beside the subtitle worker) owns the runner: the engine, the disc
//     image (its own file handle: Main's is the core's sector reads'), the RCO loads, the decoders,
//     the render. It never holds a lock while it runs a script, reads the image or draws: the logic
//     state (the queues the engine's plays push into) takes its own lock inside each call
//     (umd_menu_set_lock), held for a queue operation at most.
//   The mailbox: a (HOST_RD, events) item per read, never two reads merged when either carries
//   events (the host reads its resume point from the read that came with them); reads without
//   events replace the last such item still waiting, so a busy worker (an RCO load) does not fill it.
//
// Imlib2 (the JPEGs) is not thread-safe and its context is global: only this worker calls it, and
// under the UMD core nothing else in Main does (Main draws with it in the menu core only).
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "../../user_io.h"
#include "../../file_io.h"
#include "../../menu.h"
#include "../../input.h"
#include "../../shmem.h"
#include "../../lib/imlib2/Imlib2.h"
#include "libpng/png.h"
#include "umd_host_proto.h"
#include "umd_menu.h"
#include "umd_menu_run.h"
#include "umd_ctl.h"
#include "umd_host.h"
#include "umd_psp.h"

#define PLANE0_HPS   0x32800000u
#define PLANE1_HPS   0x32C00000u
#define PCM_HPS      0x33000000u               // the sound one-shot's region: core word 0x0660_0000
#define PLANE2_HPS   0x33800000u               // P6d: the control panel's planes, core words 0x0670_0000 /
#define PLANE3_HPS   0x33C00000u               //   0x0678_0000 (umd/sub/sub_flip.sv, docs/panel.md §2)
#define PCM_BYTES    (UMD_MR_PCM_WORDS * 8u)   //   (umd/pcm_shot.sv, docs/p9.md §3.2 item 5), 8 MB
#define PLANE_BYTES  (UMD_MR_W * UMD_MR_H * 4u)
#define PLANE_MAP    ((PLANE_BYTES + 4095u) & ~4095u)
#define TMP_DIR      "/tmp/umd_menu"           // tmpfs: the JPEG decode's scratch file
#define KEPT_SUB     CONFIG_DIR "/umd"         // RS1 (docs/resume.md R1): the kept text a disc, on the SD
                                               // card -- a power cycle keeps it (the PSP's RAM does not);
                                               // before RS1 it was in TMP_DIR, lost at every power-off
                                               // (not migrated)
#define HIL_ARM      "/media/fat/umd_hil"
#define TRACE_FILE   "/tmp/umd_menu.log"
#define TRACE_MAX    (4u << 20)

static uint64_t now_us()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000u + ts.tv_nsec / 1000u;
}
static uint32_t now_ms() { return (uint32_t)(now_us() / 1000u); }

// ---- the logic state, the poll side's ---------------------------------------------------------
static pthread_mutex_t lk_logic = PTHREAD_MUTEX_INITIALIZER;
static void logic_lock(void *, int on) { if (on) pthread_mutex_lock(&lk_logic); else pthread_mutex_unlock(&lk_logic); }
static umd_menu_state L;
static int L_up = 0;
static pthread_mutex_t lk_lv = PTHREAD_MUTEX_INITIALIZER;
static umd_menu_levels lv_pub;                 // the worker's last levels (lk_lv)
static int sub_busy = 0;                       // __atomic
static int osd_req = 0;                        // __atomic: P9-6, the worker asks the poll side

// ---- the mailbox ------------------------------------------------------------------------------
enum { MI_RD, MI_MOUNT, MI_SHUTDOWN, MI_AWAY };
typedef struct {
	int kind;
	int have_rd;
	umd_menu_rd rd;
	umd_menu_event ev[UMD_MENU_EVQ];
	int nev;
	int ok;
	char path[1024];
	char lang[4];
	int menus_off;                  // MI_MOUNT: the OSD's Disc Menus Off (O[15], M3b)
} mitem;
#define MBOX 512
static pthread_mutex_t lk_mb = PTHREAD_MUTEX_INITIALIZER;
static mitem mb[MBOX];
static int mb_r = 0, mb_n = 0;
static uint32_t n_mb_full = 0, n_mb_merged = 0;
// the worker's wake-up and the shutdown's answer: condition variables on CLOCK_MONOTONIC (MiSTer sets
// its wall clock from NTP after boot: a step back would stall a CLOCK_REALTIME wait by its size)
static pthread_cond_t w_cv, w_done_cv;
static int w_done = 0;                         // lk_mb
static pthread_t w_thread;
static int w_started = 0;

static void mb_post(const mitem *it)
{
	pthread_mutex_lock(&lk_mb);
	if (it->kind == MI_RD && it->nev == 0 && mb_n) {
		// a read without events replaces the last waiting one without events (the state only moves on)
		mitem *last = &mb[(mb_r + mb_n - 1) % MBOX];
		if (last->kind == MI_RD && last->nev == 0) { *last = *it; n_mb_merged++; pthread_cond_signal(&w_cv); pthread_mutex_unlock(&lk_mb); return; }
	}
	if (mb_n == MBOX) n_mb_full++;          // (never on the rig: counted, the item dropped)
	else { mb[(mb_r + mb_n) % MBOX] = *it; mb_n++; }
	pthread_cond_signal(&w_cv);
	pthread_mutex_unlock(&lk_mb);
}
static int mb_take(mitem *it)
{
	pthread_mutex_lock(&lk_mb);
	int got = mb_n > 0;
	if (got) { *it = mb[mb_r]; mb_r = (mb_r + 1) % MBOX; mb_n--; }
	pthread_mutex_unlock(&lk_mb);
	return got;
}

// ---- the worker's services ---------------------------------------------------------------------
static FILE *trace_f = NULL;
static uint32_t trace_bytes = 0;
static void w_trace(void *, const char *line)
{
	if (!trace_f || trace_bytes > TRACE_MAX) return;
	trace_bytes += (uint32_t)fprintf(trace_f, "%s\n", line);
	fflush(trace_f);
}

static int dec_png(const uint8_t *d, size_t n, int *w, int *h, uint8_t **out)
{
	png_image im;
	memset(&im, 0, sizeof(im));
	im.version = PNG_IMAGE_VERSION;
	*out = NULL;
	if (!png_image_begin_read_from_memory(&im, d, n)) return -1;
	im.format = PNG_FORMAT_RGBA;
	*out = (uint8_t *)malloc(PNG_IMAGE_SIZE(im));
	if (!*out || !png_image_finish_read(&im, NULL, *out, 0, NULL)) { free(*out); *out = NULL; png_image_free(&im); return -1; }
	*w = (int)im.width; *h = (int)im.height;
	return 0;
}
// Imlib2 loads from a file only: the JPEG goes through /tmp (51 in the library, a few a disc)
static int dec_jpeg(const uint8_t *d, size_t n, int *w, int *h, uint8_t **out)
{
	*out = NULL;
	const char *tmp = TMP_DIR "/img.jpg";
	FILE *f = fopen(tmp, "wb");
	if (!f) return -1;
	size_t wn = fwrite(d, 1, n, f);
	fclose(f);
	if (wn != n) { unlink(tmp); return -1; }
	// IMMEDIATELY and WITHOUT the cache: imlib_load_image reads the header alone and the pixels when
	// first asked -- after the unlink below (the rig: every JPEG "not decoded"); and the cache would
	// hand the next JPEG, written to the same name, this one's pixels
	Imlib_Image img = imlib_load_image_immediately_without_cache(tmp);
	unlink(tmp);
	if (!img) return -1;
	imlib_context_set_image(img);
	int iw = imlib_image_get_width(), ih = imlib_image_get_height();
	const DATA32 *px = imlib_image_get_data_for_reading_only();
	uint8_t *o = (iw > 0 && ih > 0 && px) ? (uint8_t *)malloc((size_t)iw * (size_t)ih * 4) : NULL;
	if (o)
		for (size_t i = 0; i < (size_t)iw * (size_t)ih; i++) {
			uint32_t p = px[i];                   // ARGB
			o[4 * i] = (uint8_t)(p >> 16); o[4 * i + 1] = (uint8_t)(p >> 8); o[4 * i + 2] = (uint8_t)p; o[4 * i + 3] = 255;
		}
	imlib_free_image();
	if (!o) return -1;
	*out = o; *w = iw; *h = ih;
	return 0;
}
static int w_decode(void *, int fmt, const uint8_t *d, size_t n, int *w, int *h, uint8_t **rgba)
{
	return fmt == 0 ? dec_png(d, n, w, h, rgba) : fmt == 1 ? dec_jpeg(d, n, w, h, rgba) : -1;
}

// the kept text: one file a disc, under its id (the id's own characters only), in Main's config/umd
// (resolved on Main's thread at up(): getFullPath's buffer is Main's own)
static char kept_dir[512];
static void kept_path(const char *id, char *p, size_t n)
{
	char s[64];
	size_t k = 0;
	for (const char *c = id; *c && k + 1 < sizeof(s); c++)
		s[k++] = ((*c >= 'A' && *c <= 'Z') || (*c >= 'a' && *c <= 'z') || (*c >= '0' && *c <= '9') || *c == '_' || *c == '-') ? *c : '_';
	s[k] = 0;
	snprintf(p, n, "%s/%s.txt", kept_dir, s);
}
static char *w_kept_load(void *, const char *id, size_t *len)
{
	char p[600];
	kept_path(id, p, sizeof(p));
	*len = 0;
	FILE *f = fopen(p, "rb");
	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	char *t = (n > 0 && n < (1 << 20)) ? (char *)malloc((size_t)n + 1) : NULL;
	if (t && fread(t, 1, (size_t)n, f) == (size_t)n) { t[n] = 0; *len = (size_t)n; }
	else { free(t); t = NULL; }
	fclose(f);
	return t;
}
// written whole to <file>.tmp, flushed to the card, renamed over the file: a power cut between leaves
// the old text or the new, never half of one (docs/resume.md §3)
static int w_kept_store(void *, const char *id, const char *text, size_t len)
{
	char p[600], tmp[620];
	kept_path(id, p, sizeof(p));
	if (!len) return (unlink(p) == 0 || errno == ENOENT) ? 0 : -1;
	snprintf(tmp, sizeof(tmp), "%s.tmp", p);
	FILE *f = fopen(tmp, "wb");
	if (!f) { printf("UMD: resume: %s not written: %s\n", tmp, strerror(errno)); return -1; }
	int ok = fwrite(text, 1, len, f) == len;
	ok = (fflush(f) == 0) && ok;
	ok = (fsync(fileno(f)) == 0) && ok;
	ok = (fclose(f) == 0) && ok;
	if (ok && rename(tmp, p) == 0) {
		int d = open(kept_dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);   // (the rename itself on the card)
		if (d >= 0) { fsync(d); close(d); }
		return 0;
	}
	printf("UMD: resume: %s not written: %s\n", p, strerror(errno));     // (Main's console; the trace and
	unlink(tmp);                                                           //  the stats count it too)
	return -1;
}

static volatile uint64_t *plane[2] = {NULL, NULL};
// what each plane buffer holds, cached: a frame goes out row by row where it differs (a focus change
// moves a few rows; the uncached stores are the cost). Invalid at a ui rise: under ui = 0 the
// subtitle decode writes the planes
static uint64_t *shadow[2] = {NULL, NULL};
static int shadow_ok[2] = {0, 0};
static uint32_t rows_put = 0;
static uint32_t put_us_last = 0, put_us_max = 0, render_us_last = 0, render_us_max = 0;
static umd_mr_acc p_frame, p_put;             // THE PROFILE (umd_menu_run.h): the whole frame, the plane put
// (`frame` the DRAW: canvas, stretch, the panel's copy -- the put is `put`; render_us is the last draw + its put)
// ... and the period between frames: a flip pushed -> its acknowledgement seen (the round trip), that -> the
// next put, and the worker's own tick (the engine's scripts, animations; the mailbox)
static umd_mr_acc p_echo, p_gap, p_tick;
// a frame into the plane: 64-bit stores into uncached memory (B2: the stores are the cost), then a
// barrier before the flip
static void w_plane_put(void *, int buf, const uint8_t *frame)
{
	if (!plane[0]) {
		plane[0] = (volatile uint64_t *)shmem_map(PLANE0_HPS, PLANE_MAP);
		plane[1] = (volatile uint64_t *)shmem_map(PLANE1_HPS, PLANE_MAP);
	}
	int b = buf & 1;
	volatile uint64_t *d = plane[b];
	if (!d) return;
	if (!shadow[b]) shadow[b] = (uint64_t *)malloc(PLANE_BYTES);
	uint64_t t0 = now_us();
	umd_mr_t0 pt0 = umd_mr_clock();
	const uint64_t *s = (const uint64_t *)frame;
	const size_t rw = UMD_MR_W * 4 / 8;                 // a row in 64-bit words
	rows_put = 0;
	for (size_t y = 0; y < UMD_MR_H; y++) {
		const uint64_t *sr = s + y * rw;
		if (shadow[b] && shadow_ok[b] && !memcmp(shadow[b] + y * rw, sr, rw * 8)) continue;
		volatile uint64_t *dr = d + y * rw;
		for (size_t i = 0; i < rw; i++) dr[i] = sr[i];
		if (shadow[b]) memcpy(shadow[b] + y * rw, sr, rw * 8);
		rows_put++;
	}
	if (shadow[b]) shadow_ok[b] = 1;
	__sync_synchronize();
	umd_mr_acc_add(&p_put, pt0);
	put_us_last = (uint32_t)(now_us() - t0);
	if (put_us_last > put_us_max) put_us_max = put_us_last;
}
static void w_open_osd(void *) { __atomic_store_n(&osd_req, 1, __ATOMIC_RELEASE); }

// ---- P6d, the control panel's page (docs/panel.md §2) ----
// the subtitle unit sub_sched shows: its plane and rectangle, as the subtitle host decoded it
static int w_sub_unit(void *, uint8_t seq, int *buf, int *x, int *y, int *w, int *h)
{
	return umd_host_unit(seq, buf, x, y, w, h);
}
// a rectangle of subtitle plane 0 / 1 read back into the page (uncached 32-bit loads: a few hundred KB at
// most, only when the subtitle under an open panel changes); the front plane: nothing writes it meanwhile
static uint32_t pget_us_last = 0, pput_us_last = 0;
static void w_plane_get(void *, int buf, int x, int y, int w, int h, uint8_t *frame)
{
	if (!plane[0]) {
		plane[0] = (volatile uint64_t *)shmem_map(PLANE0_HPS, PLANE_MAP);
		plane[1] = (volatile uint64_t *)shmem_map(PLANE1_HPS, PLANE_MAP);
	}
	volatile uint32_t *src = (volatile uint32_t *)plane[buf & 1];
	if (!src) return;
	uint64_t t0 = now_us();
	for (int yy = y; yy < y + h; yy++) {
		uint32_t *d = (uint32_t *)(void *)(frame + ((size_t)yy * UMD_MR_W + (size_t)x) * 4);
		volatile uint32_t *sr = src + (size_t)yy * UMD_MR_W + (size_t)x;
		for (int i = 0; i < w; i++) d[i] = sr[i];
	}
	pget_us_last = (uint32_t)(now_us() - t0);
}
// a rectangle of the page into the panel's plane 2 / 3 (32-bit stores), then a barrier before its flip
static volatile uint32_t *pplane[2] = {NULL, NULL};
static void w_plane_put_rect(void *, int buf, const uint8_t *frame, int x, int y, int w, int h)
{
	if (!pplane[0]) {
		pplane[0] = (volatile uint32_t *)shmem_map(PLANE2_HPS, PLANE_MAP);
		pplane[1] = (volatile uint32_t *)shmem_map(PLANE3_HPS, PLANE_MAP);
	}
	volatile uint32_t *dst = pplane[(buf - 2) & 1];
	if (!dst) return;
	uint64_t t0 = now_us();
	for (int yy = y; yy < y + h; yy++) {
		const uint32_t *sr = (const uint32_t *)(const void *)(frame + ((size_t)yy * UMD_MR_W + (size_t)x) * 4);
		volatile uint32_t *d = dst + (size_t)yy * UMD_MR_W + (size_t)x;
		for (int i = 0; i < w; i++) d[i] = sr[i];
	}
	__sync_synchronize();
	pput_us_last = (uint32_t)(now_us() - t0);
}

// a sound into the PCM region: 64-bit stores (the samples' bytes in order, little-endian: mono four
// samples, stereo two frames a word), the last word zero-padded, a barrier before its trigger is sent
static volatile uint64_t *pcm_map = NULL;
static void w_pcm_put(void *, uint32_t word, const int16_t *pcm, uint32_t samples)
{
	if (!pcm_map) pcm_map = (volatile uint64_t *)shmem_map(PCM_HPS, PCM_BYTES);
	if (!pcm_map || word >= UMD_MR_PCM_WORDS) return;
	uint32_t whole = samples / 4, rest = samples % 4;
	if (word + whole + (rest ? 1 : 0) > UMD_MR_PCM_WORDS) return;      // (the runner never asks this)
	volatile uint64_t *d = pcm_map + word;
	for (uint32_t i = 0; i < whole; i++) {
		uint64_t w;
		memcpy(&w, pcm + 4 * i, 8);
		d[i] = w;
	}
	if (rest) {
		uint64_t w = 0;
		memcpy(&w, pcm + 4 * whole, rest * 2);
		d[whole] = w;
	}
	__sync_synchronize();
}

// ---- the worker --------------------------------------------------------------------------------
static umd_menu_run R;
static int img_fd = -1;
static size_t img_read(void *ud, uint64_t off, void *buf, size_t n)
{
	ssize_t r = pread((int)(intptr_t)ud, buf, n, (off_t)off);
	return r < 0 ? 0 : (size_t)r;
}

static void w_mount(const mitem *it, uint32_t now)
{
	if (img_fd >= 0) { close(img_fd); img_fd = -1; }
	if (trace_f) { fclose(trace_f); trace_f = NULL; }
	struct stat st;
	if (stat(HIL_ARM, &st) == 0) {
		rename(TRACE_FILE, TRACE_FILE ".1");     // (the previous mount's kept: a remount must not erase it)
		trace_f = fopen(TRACE_FILE, "w");
		trace_bytes = 0;
	}
	umd_mr_set_trace(&R, trace_f ? w_trace : NULL);
	uint64_t size = 0;
	if (it->ok) {
		img_fd = open(it->path, O_RDONLY | O_CLOEXEC);
		if (img_fd >= 0) { struct stat fs; if (fstat(img_fd, &fs) == 0) size = (uint64_t)fs.st_size; }
		else if (trace_f) w_trace(NULL, "HOST the image does not open (a zip?): the core plays on its own");
	}
	R.menus_off = it->menus_off;
	snprintf(R.image_name, sizeof(R.image_name), "%s", it->ok ? it->path : "");   // (RS4: the title's fallback)
	umd_mr_mount(&R, it->ok && img_fd >= 0, img_read, (void *)(intptr_t)img_fd, size, it->lang[0] ? it->lang : NULL, now);
}

static void *worker(void *)
{
	mkdir(TMP_DIR, 0755);
	umd_mr_services sv;
	memset(&sv, 0, sizeof(sv));
	sv.decode_image = w_decode; sv.kept_load = w_kept_load; sv.kept_store = w_kept_store;
	sv.plane_put = w_plane_put; sv.open_osd = w_open_osd; sv.trace = NULL; sv.pcm_put = w_pcm_put;
	sv.sub_unit = w_sub_unit; sv.plane_get = w_plane_get; sv.plane_put_rect = w_plane_put_rect;   // P6d
	umd_mr_init(&R, &sv, &L);
	for (;;) {
		struct timespec ts;
		clock_gettime(CLOCK_MONOTONIC, &ts);
		ts.tv_nsec += 10 * 1000000;               // the engine's tick: 10 ms
		if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
		pthread_mutex_lock(&lk_mb);
		if (!mb_n) pthread_cond_timedwait(&w_cv, &lk_mb, &ts);   // (drained below)
		pthread_mutex_unlock(&lk_mb);
		uint32_t now = now_ms();
		mitem it;
		while (mb_take(&it)) {
			switch (it.kind) {
			case MI_RD:       umd_mr_feed(&R, it.have_rd ? &it.rd : NULL, it.ev, it.nev); break;
			case MI_MOUNT:    w_mount(&it, now); break;
			case MI_SHUTDOWN:
				umd_mr_shutdown(&R);
				pthread_mutex_lock(&lk_mb); w_done = 1; pthread_cond_signal(&w_done_cv); pthread_mutex_unlock(&lk_mb);
				break;
			case MI_AWAY:     umd_mr_shutdown(&R); if (img_fd >= 0) { close(img_fd); img_fd = -1; } break;
			}
		}
		umd_mr_t0 kt0 = umd_mr_clock();
		umd_mr_tick(&R, now);
		umd_mr_acc_add(&p_tick, kt0);
		static umd_mr_t0 t_flip, t_echo;
		static int flip_out = 0, echo_seen = 0;
		static uint32_t draw_us_last = 0;
		umd_menu_levels lv;
		umd_mr_levels(&R, &lv);
		static int ui_was = 0;
		if (lv.ui && !ui_was) shadow_ok[0] = shadow_ok[1] = 0;   // (the subtitles may have drawn meanwhile)
		ui_was = lv.ui;
		pthread_mutex_lock(&lk_lv);
		lv_pub = lv;
		pthread_mutex_unlock(&lk_lv);
		// RENDER, PIPELINED (umd_menu_run.h): the drawn frame put when the flip is back, then the next one drawn
		// while that flip is out (a fresh draw with the channel idle goes out at once)
		int sb = __atomic_load_n(&sub_busy, __ATOMIC_ACQUIRE);
		for (int pass = 0; pass < 2; pass++) {
			if (flip_out && umd_menu_flip_idle(&L)) { umd_mr_acc_add(&p_echo, t_flip); t_echo = umd_mr_clock(); flip_out = 0; echo_seen = 1; }
			int b = umd_mr_put_want(&R, sb);
			if (b >= 0) {
				if (echo_seen) { umd_mr_acc_add(&p_gap, t_echo); echo_seen = 0; }
				uint64_t t0 = now_us();
				umd_mr_put_frame(&R, b);
				umd_mr_render_flip(&R, b);
				t_flip = umd_mr_clock(); flip_out = 1;
				render_us_last = (uint32_t)(now_us() - t0) + draw_us_last;
				if (render_us_last > render_us_max) render_us_max = render_us_last;
			}
			if (pass || !umd_mr_draw_want(&R)) break;
			uint64_t t0 = now_us();
			umd_mr_t0 ft0 = umd_mr_clock();
			umd_mr_draw_frame(&R);
			umd_mr_acc_add(&p_frame, ft0);
			draw_us_last = (uint32_t)(now_us() - t0);
		}
		// P6d: the control panel's own page in playback (planes 2 / 3, the subtitle under it)
		int pb = umd_mr_panel_want(&R);
		if (pb >= 0) {
			umd_mr_panel_frame(&R, pb);
			umd_mr_panel_flip(&R, pb);
		}
	}
	return NULL;
}

static void up()
{
	if (!kept_dir[0]) {                              // (Main's thread: its path buffer)
		FileCreatePath(CONFIG_DIR);
		FileCreatePath(KEPT_SUB);
		snprintf(kept_dir, sizeof(kept_dir), "%s", getFullPath(KEPT_SUB));
	}
	if (!L_up) {
		umd_menu_init(&L);
		umd_menu_set_lock(&L, logic_lock, NULL);
		L_up = 1;
	}
	if (w_started) return;
	pthread_condattr_t ca;
	pthread_condattr_init(&ca);
	pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
	pthread_cond_init(&w_cv, &ca);
	pthread_cond_init(&w_done_cv, &ca);
	pthread_condattr_destroy(&ca);
	pthread_attr_t attr;
	pthread_attr_init(&attr);
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(0, &set);                               // Main's poll is on CPU 1 (main.cpp)
	pthread_attr_setaffinity_np(&attr, sizeof(set), &set);
	if (pthread_create(&w_thread, &attr, worker, NULL) == 0) w_started = 1;
	pthread_attr_destroy(&attr);
}

// ---- the poll side -----------------------------------------------------------------------------
void umd_menu_poll(uint32_t now, const uint16_t *rdw, uint16_t *wr, int *want_write, int *want_fast)
{
	up();
	umd_menu_rd rd;
	if (rdw) umd_menu_decode(rdw, UMD_HOST_NWORDS, &rd);
	umd_menu_levels lv;
	pthread_mutex_lock(&lk_lv);
	lv = lv_pub;
	pthread_mutex_unlock(&lk_lv);
	mitem it;
	it.kind = MI_RD;
	it.nev = 0;
	umd_menu_step(&L, now, rdw ? &rd : NULL, &lv, it.ev, &it.nev, wr, want_write, want_fast);
	if (rdw || it.nev) {
		it.have_rd = rdw != NULL;
		if (rdw) it.rd = rd;
		mb_post(&it);
	}
	if (__atomic_exchange_n(&osd_req, 0, __ATOMIC_ACQ_REL)) menu_key_set(KEY_F12 | UPSTROKE);   // P9-6
}

int umd_menu_writes(void) { return L_up && L.adopted; }
int umd_menu_keys_only(void) { return L_up && L.keys_only; }
void umd_menu_sub_busy(int busy) { __atomic_store_n(&sub_busy, busy, __ATOMIC_RELEASE); }

void umd_menu_mounted(int index, int ok, const char *name)
{
	if (index != 0 || !is_umd()) return;
	umd_psp_note_mount(index, ok, name);     // a PSP's disc over USB: whose image slot 0 now holds (psp_disc.md)
	up();
	mitem it;
	memset(&it, 0, sizeof(it));
	it.kind = MI_MOUNT;
	it.ok = ok && name && name[0];
	if (it.ok) snprintf(it.path, sizeof(it.path), "%s", getFullPath(name));
	const char *code = umd_mh_lang_code(user_io_status_get("[14:11]"));
	snprintf(it.lang, sizeof(it.lang), "%s", code ? code : "EN");
	it.menus_off = user_io_status_get("[15]") & 1;     // Disc Menus: On (0), Off (1) -- read at the mount
	mb_post(&it);
}

void umd_menu_shutdown(void)
{
	if (!w_started) return;
	mitem it;
	memset(&it, 0, sizeof(it));
	it.kind = MI_SHUTDOWN;
	pthread_mutex_lock(&lk_mb);
	w_done = 0;
	pthread_mutex_unlock(&lk_mb);
	mb_post(&it);
	// bounded: the disc's onExit and one file write (Main re-execs after this returns)
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	ts.tv_nsec += 300 * 1000000;
	if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
	pthread_mutex_lock(&lk_mb);
	while (!w_done && pthread_cond_timedwait(&w_done_cv, &lk_mb, &ts) == 0) {}
	pthread_mutex_unlock(&lk_mb);
}

void umd_menu_away(void)
{
	if (!w_started || !R.started) return;
	mitem it;
	memset(&it, 0, sizeof(it));
	it.kind = MI_AWAY;
	mb_post(&it);
}

void umd_menu_stats(FILE *f)
{
	fprintf(f, "{\"started\":%d,\"mode\":%d,\"disc\":\"%s\",\"frames\":%u,\"quits\":%u,\"starts\":%u,"
	           "\"render_us\":%u,\"render_us_max\":%u,\"put_us\":%u,\"put_us_max\":%u,\"rows_put\":%u,\"mb_full\":%u,\"mb_merged\":%u,"
	           "\"cmds\":%u,\"bad\":%u,\"retries\":%u,\"gave_up\":%u,\"resync\":%u,\"dropped\":%u,"
	           "\"panel_open\":%d,\"panel_sel\":%d,\"panel_pages\":%u,\"panel_acts\":%u,\"presses\":%u,"
	           "\"pget_us\":%u,\"pput_us\":%u,\"kept_writes\":%u,\"kept_same\":%u,\"kept_fail\":%u,\"stale_chapter\":%u,\"held\":%u,\"res_stop\":%u,"
	           "\"prof\":{\"frame\":[%llu,%llu,%llu],\"draw\":[%llu,%llu,%llu],\"stretch\":[%llu,%llu,%llu],\"put\":[%llu,%llu,%llu],"
	           "\"echo\":[%llu,%llu,%llu],\"gap\":[%llu,%llu,%llu],\"tick\":[%llu,%llu,%llu]}}",
	        R.started, R.H.mode, R.disc_id, R.n_frames, R.n_quits, R.n_starts, render_us_last, render_us_max,
	        put_us_last, put_us_max, rows_put, n_mb_full, n_mb_merged, L.n_cmds, L.n_bad, L.n_retries, L.n_gave_up,
	        L.n_resync, L.n_dropped, R.P.open, R.P.sel, R.n_panel_pages, R.n_panel_acts, L.n_presses,
	        pget_us_last, pput_us_last, R.n_kept_writes, R.n_kept_same, R.n_kept_fail, R.H.n_stale_chapter, R.H.n_held, R.H.n_res_stop,
	        // THE PROFILE: [count, wall us, thread CPU us], running sums
	        (unsigned long long)p_frame.n, (unsigned long long)p_frame.wall_us, (unsigned long long)p_frame.cpu_us,
	        (unsigned long long)R.p_draw.n, (unsigned long long)R.p_draw.wall_us, (unsigned long long)R.p_draw.cpu_us,
	        (unsigned long long)R.p_stretch.n, (unsigned long long)R.p_stretch.wall_us, (unsigned long long)R.p_stretch.cpu_us,
	        (unsigned long long)p_put.n, (unsigned long long)p_put.wall_us, (unsigned long long)p_put.cpu_us,
	        (unsigned long long)p_echo.n, (unsigned long long)p_echo.wall_us, (unsigned long long)p_echo.cpu_us,
	        (unsigned long long)p_gap.n, (unsigned long long)p_gap.wall_us, (unsigned long long)p_gap.cpu_us,
	        (unsigned long long)p_tick.n, (unsigned long long)p_tick.wall_us, (unsigned long long)p_tick.cpu_us);
}
