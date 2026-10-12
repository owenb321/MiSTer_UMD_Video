// umd_psp_logic.c -- see umd_psp_logic.h; the rules are docs/psp_disc.md §3.
//
// What the PSP shows (measured, psp_disc.md §2): leaving USB mode removes the file (an open fd
// reads EIO); entering it re-enumerates (a new device, a new inode, maybe another usbN); a disc
// swapped WITHOUT leaving USB mode changes nothing the filesystem says -- same inode, the old
// disc's size -- only the sectors, so the PVD's hash is the one witness of it.
#include <string.h>
#include <strings.h>
#include "umd_psp_logic.h"

void umd_psp_init(umd_psp_state *s)
{
	memset(s, 0, sizeof(*s));
}

static void unmount_(umd_psp_state *s, umd_psp_act *a)
{
	a->unmount = 1;
	s->owned = 0;
	s->fp_mounted = 0;
	s->n_unmount++;
}

static void tell(umd_psp_state *s, umd_psp_act *a, int msg, uint32_t fp)
{
	if (s->fp_told == fp) return;      // once per disc (an edge clears it)
	s->fp_told = fp;
	a->msg = msg;
	if (msg == UMD_PSP_MSG_GAME) s->n_game++;
	else s->n_reenter++;
}

void umd_psp_step(umd_psp_state *s, const umd_psp_view *v, umd_psp_act *a)
{
	memset(a, 0, sizeof(*a));
	if (s->have_seq && v->seq == s->last_seq) return;     // (the tick runs far more often than the scan)
	int first = !s->have_seq;          // the first view since Main started: nothing was witnessed changing
	s->have_seq = 1;
	s->last_seq = v->seq;

	if (!v->present) {
		// USB mode left, the cable pulled: Main's fd now reads EIO -- give the slot back at once
		if (s->owned) unmount_(s, a);
		if (s->was_present) s->n_edge++;
		s->was_present = 0;
		s->fp = 0;
		s->fp_told = 0;
		s->suppressed = 0;
		s->stale = 0;
		return;
	}

	// an edge: the file appeared, or came back as another device / inode / usbN (USB mode re-entered
	// between two scans), or its disc changed under the same file (a known hash that differs). Each
	// is a deliberate act -- a disc put in, USB mode entered -- so it wins over a foreign image and
	// over the user's own unmount, as an insertion does for dvd_phys. The first view is none: an MGL
	// that loaded a library ISO with the PSP already attached keeps its image.
	int appeared = !first && !s->was_present;
	int moved = !first && s->was_present && (v->usb != s->usb || v->dev != s->dev || v->ino != s->ino);
	int swapped = !first && !appeared && !moved && v->fp && s->fp && v->fp != s->fp;
	if (appeared || moved || swapped) {
		s->n_edge++;
		s->foreign = 0;
		s->suppressed = 0;
		s->fp_told = 0;
	}
	if (first) s->first_pending = 1;   // the first disc read: judged by its size (below)
	if (first || appeared || moved) s->stale = 0;   // a FAT built for this disc
	if (swapped) s->stale = 1;         // the FAT is the previous disc's: not mounted until USB mode is re-entered
	s->was_present = 1;
	s->usb = v->usb;
	s->dev = v->dev;
	s->ino = v->ino;
	if (first || appeared || moved || v->fp) s->fp = v->fp;

	// a Main started after a swap it did not see (a core reload): a fresh FAT is the PVD's size (80 of
	// the library's 84 dumps exactly, 4 one sector short), so a file far from it is a previous disc's
	if (s->first_pending && v->kind != UMD_PSP_K_UNREAD && v->kind != UMD_PSP_K_ERR) {
		s->first_pending = 0;
		uint64_t d = v->vol_bytes > v->size ? v->vol_bytes - v->size : v->size - v->vol_bytes;
		if (d > UMD_PSP_FAT_SLACK) s->stale = 1;
	}

	if (v->kind == UMD_PSP_K_UNREAD || v->kind == UMD_PSP_K_ERR) {
		// no hash to judge by: wait -- but a disc we hold on a device that is gone is Main's old fd
		if (moved && s->owned) unmount_(s, a);
		return;
	}

	if (s->owned && !s->fp_mounted) s->fp_mounted = v->fp;    // someone else's mount of a PSP path: adopt
	if (s->owned && (moved || v->fp != s->fp_mounted)) {
		if (!moved) s->n_swap++;
		unmount_(s, a);                // a re-enumeration is mounted again below; a swap waits for USB mode re-entered
	}

	if (v->kind == UMD_PSP_K_GAME) {
		if (s->owned) unmount_(s, a);  // adopted from an MGL's / the OSD's mount: not left playing
		tell(s, a, UMD_PSP_MSG_GAME, v->fp);
		return;
	}
	// a disc swapped inside USB mode is never mounted under the old disc's FAT, whatever its size: a
	// smaller disc would play, a bigger one would not (reads past the file's end return nothing), and
	// the user cannot tell which is which -- so one rule (the maintainer, 2026-10-10): re-enter USB mode
	if (s->stale) {
		if (s->owned) unmount_(s, a);  // adopted on a stale FAT (an MGL after a swap Main never saw)
		tell(s, a, UMD_PSP_MSG_REENTER, v->fp);
		return;
	}
	if (s->owned || s->foreign || s->suppressed) return;
	a->mount = 1;
	a->usb = v->usb;
	s->owned = 1;
	s->fp_mounted = v->fp;
	s->n_mount++;
}

void umd_psp_mounted(umd_psp_state *s, int ok, int is_psp, int path_empty)
{
	if (path_empty) {                  // the OSD's unmount: a slot emptied by hand stays empty until an edge,
		s->suppressed = 1;             // whichever image it held (the PSP's disc is not put back behind the user)
		s->owned = 0;
		s->fp_mounted = 0;
		s->foreign = 0;
		return;
	}
	if (!ok) {                         // an open that failed: Main tells the core size 0, an empty slot
		s->owned = 0;
		s->fp_mounted = 0;
		s->foreign = 0;
		return;
	}
	if (is_psp) {                      // an MGL's, the OSD's or the HIL's mount of the PSP's file: ours to watch
		s->owned = 1;
		s->fp_mounted = s->fp;         // the disc last read (0: adopted at the next read)
		s->foreign = 0;
		s->suppressed = 0;
	} else {                           // another image: the user's choice, not pre-empted
		s->owned = 0;
		s->fp_mounted = 0;
		s->foreign = 1;
	}
}

void umd_psp_self_failed(umd_psp_state *s)
{
	// our own mount did not open: not retried until an edge (a scan a second would loop on it)
	s->owned = 0;
	s->fp_mounted = 0;
	s->suppressed = 1;
}

int umd_psp_path_usb(const char *p)
{
	static const char pre[] = "/media/usb";
	if (!p || strncmp(p, pre, sizeof(pre) - 1)) return -1;
	p += sizeof(pre) - 1;
	if (p[0] < '0' || p[0] >= '0' + UMD_PSP_NUSB || p[1] != '/') return -1;
	return strcasecmp(p + 2, "UMD9660.ISO") ? -1 : p[0] - '0';
}
