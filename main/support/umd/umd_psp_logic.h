// umd_psp_logic.h -- a PSP's UMD over USB ("USB Device: UMD", UMD9660.ISO): WHEN to mount and
// unmount it (docs/psp_disc.md §3). Plain C, no I/O: umd_psp.cpp's worker fills a view, its tick
// runs one step per new view and applies the action; bench/umd/run_psp_scan.sh drives it on the PC.
#ifndef UMD_PSP_LOGIC_H
#define UMD_PSP_LOGIC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define UMD_PSP_FAT_SLACK (1u << 20)   // a fresh FAT vs the PVD's size: one sector short seen; a swap differs by far more
#define UMD_PSP_NUSB 8                 // /media/usb0..usb7 (/media holds eight; Main's findPrefixDir stops at 5)

enum {                                 // the PVD's system id (LBA 16, bytes 8..39)
	UMD_PSP_K_UNREAD = 0,              // present, LBA 16 not (yet) read: wait
	UMD_PSP_K_VIDEO,                   // "UMD VIDEO"
	UMD_PSP_K_GAME,                    // "PSP GAME": never mounted, one message
	UMD_PSP_K_OTHER,                   // an ISO with another id: mounted, the core judges it
	UMD_PSP_K_ERR                      // the read failed (EIO, short, not CD001): wait
};

enum {                                 // a message for the user (umd_psp.cpp's Info text)
	UMD_PSP_MSG_NONE = 0,
	UMD_PSP_MSG_GAME,                  // "The PSP's disc is a game, not a UMD Video."
	UMD_PSP_MSG_REENTER                // a disc swapped inside USB mode: leave USB mode, enter it again
};

typedef struct {                       // one scan by the worker
	uint32_t seq;                      // scans completed; a step runs once per new seq
	int      present;                  // a UMD9660.ISO found
	int      usb;                      // its /media/usbN
	uint64_t dev, ino, size;           // its stat (size: the FAT's, built when USB mode started)
	int      kind;                     // UMD_PSP_K_*
	uint32_t fp;                       // a hash of the whole PVD sector (0 unless read)
	uint64_t vol_bytes;                // the PVD's volume space size * 2048 (the log's)
} umd_psp_view;

typedef struct {
	uint32_t last_seq;
	int      have_seq;
	// the disc last seen
	int      was_present, usb;
	uint64_t dev, ino;
	uint32_t fp;                       // its PVD hash (0: not read yet)
	// slot 0
	int      owned;                    // it holds a PSP path (our mount, or an MGL's / the OSD's / the HIL's)
	uint32_t fp_mounted;               // the disc it holds (0: adopt the next hash read)
	int      foreign;                  // the user holds it with another file: never pre-empted until an edge
	int      suppressed;               // the user unmounted the PSP's disc: not again until an edge
	uint32_t fp_told;                  // a message already shown for this disc
	int      stale;                    // the disc was swapped inside USB mode: the FAT is the previous disc's
	int      first_pending;            // the first disc since Main started is not judged yet (its size vs the PVD's)
	// counters (/tmp/umd_host.json)
	unsigned n_mount, n_unmount, n_swap, n_game, n_reenter, n_edge;
} umd_psp_state;

typedef struct {
	int unmount;                       // user_io_file_mount("", 0) -- first, when both
	int mount;                         // then user_io_file_mount(path, 0)
	int usb;                           // ...path = /media/usb<usb>/UMD9660.ISO
	int msg;                           // UMD_PSP_MSG_*
} umd_psp_act;

void umd_psp_init(umd_psp_state *s);
// one step per new view (a repeated seq does nothing)
void umd_psp_step(umd_psp_state *s, const umd_psp_view *v, umd_psp_act *a);
// slot 0 changed by someone else (the OSD, an MGL, the HIL FIFO): path empty = an unmount;
// is_psp = the path is a /media/usbN/UMD9660.ISO. The glue does not call it for its own mounts.
void umd_psp_mounted(umd_psp_state *s, int ok, int is_psp, int path_empty);
// our own mount failed to open: not retried until an edge
void umd_psp_self_failed(umd_psp_state *s);
// the path test the glue and the bench share: /media/usb<N>/UMD9660.ISO (any case) -> N, else -1
int umd_psp_path_usb(const char *full_path);

#ifdef __cplusplus
}
#endif

#endif
